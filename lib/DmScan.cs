// DmScan.cs - disk-monitor-cleanup scan engine (v4)
// Design rules baked in (see docs: review / lazy-scan design / on-demand v3):
//   1. WIN32_FIND_DATAW layout MUST be canonical: sizeof == 592, cFileName offset == 44.
//      Self-checked at startup - a wrong layout turns "." / ".." into empty names and the walk
//      re-enqueues every directory as its own child => unbounded queue => OOM (the 2026-09-15 freeze).
//   2. Self-enqueue guard on the canonicalized child path (not on the "." / ".." literals only).
//   3. Hard caps: wall-clock, dir count, entry count. Caps are re-checked INSIDE the per-directory
//      entry loop (256-entry granularity) so no worker lingers on a giant directory.
//   4. All worker threads are Joined before results are read (no cross-run contamination).
//   5. Runs at background priority (PROCESS/THREAD_MODE_BACKGROUND_BEGIN) so the desktop stays responsive.
//   6. Heavy work (walk, serialize, diff) stays in C#; PowerShell only orchestrates and renders.
//   7. Ages are bucketed by last-write time: <=7d, <=30d, <=90d, <=1y, older.
//   8. Tree storage = sorted entries + prefix-compressed paths + GZip; full histogram only for hot dirs.
//
// C# 5 compatible (Add-Type / CodeDom on PowerShell 5.1). No external dependencies.

using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace DmFast
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct WFD
    {
        public uint attr;
        public uint creLo, creHi, accLo, accHi, wrtLo, wrtHi;
        public uint sizeHi, sizeLo, res0, res1;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
        public string name;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 14)]
        public string alt;
    }

    public sealed class Ent
    {
        public string P;          // full path
        public long B;            // rollup bytes (self + descendants)
        public long A;            // rollup allocated bytes (probed files only; 0 when not probed)
        public long F;            // rollup file count
        public long M;            // directory last-write time (ticks)
        public long N30;          // rollup bytes whose last-write is within 30 days
        public int Age;           // newest last-write age in days (-1 = empty)
        public bool Hot;          // carries the full 5-bucket histogram
        public long B0, B1, B2, B3, B4;  // histogram, rollup, by mtime bucket
    }

    public sealed class Opt
    {
        public int Threads = 4;
        public double MaxSeconds = 0;          // 0 = unlimited
        public long MaxDirs = 0;
        public long MaxEntries = 0;
        public string[] SkipPaths;             // absolute subpaths to skip (prefix match, case-insensitive)
        public string[] SkipNames;             // directory names to skip anywhere
        public int HotTopN = 3000;
        public long HotMinBytes = 8L * 1024 * 1024;
        public long AllocProbeMinBytes = 64L * 1024 * 1024;
        public string[] AllocProbeSuffix;      // lowercase suffixes, e.g. ".vhdx"
        public bool LowPriority = true;
        public long MinTopFileBytes = 20L * 1024 * 1024;   // per-file collection threshold
        public int MaxTopFiles = 5000;
    }

    public sealed class FileHit
    {
        public string P;
        public long B;
        public long M;
        public long C;
    }

    /// <summary>Per-path difference between two trees. DB/DF/DN30 are rollup deltas, OwnB is the self-only delta.</summary>
    public sealed class Delta
    {
        public string P;
        public long DB, DF, DN30, OwnB;
        public bool Hot;
        public long B0, B1, B2, B3, B4;
        public long N30;          // current value in the new tree (used for retro attribution)
        public long CurB, CurF;
        public int Age;
        public string Mtime = "";
    }

    public sealed class DiffResult
    {
        public ScanResult OldT, NewT;
        public List<Delta> Grow = new List<Delta>();
        public List<Delta> Shrink = new List<Delta>();
        public List<Delta> Hot = new List<Delta>();
        public long TreeNetDelta;      // rollup delta of the scanned root == sum of self deltas
        public long SumGrow, SumShrink;
        public int Vanished, Appeared;
        public long NewBytes, OldBytes;
    }

    public sealed class ScanResult
    {
        public string Root;
        public bool TopFilesTruncated;
        public DateTime At;
        public List<Ent> Ents = new List<Ent>();
        public List<FileHit> TopFiles = new List<FileHit>();
        public long Dirs, Files, Denied, Reparse, Bytes, Alloc, Skipped;
        /// <summary>Path -> entry lookup, built by Engine.BuildIndex. Not serialized.</summary>
        public Dictionary<string, Ent> Meta;
        public double Sec;
        public bool Capped;
        public string State = "DRAINED";
        public int Threads;
        public int Version = 4;
    }

    public static class Engine
    {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr FindFirstFileW(string p, out WFD d);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool FindNextFileW(IntPtr h, out WFD d);
        [DllImport("kernel32.dll")]
        static extern bool FindClose(IntPtr h);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern uint GetCompressedFileSizeW(string p, out uint hi);
        [DllImport("kernel32.dll")]
        static extern IntPtr GetCurrentProcess();
        [DllImport("kernel32.dll")]
        static extern bool SetPriorityClass(IntPtr h, uint cls);
        [DllImport("kernel32.dll")]
        static extern bool SetThreadPriority(IntPtr h, int prio);
        [DllImport("kernel32.dll")]
        static extern IntPtr GetCurrentThread();

        const uint PROCESS_MODE_BACKGROUND_BEGIN = 0x00100000;
        const int THREAD_MODE_BACKGROUND_BEGIN = 0x00010000;

        /// <summary>Guard against the layout bug that caused the machine freeze. Throws when wrong.</summary>
        public static void SelfCheck()
        {
            int size = Marshal.SizeOf(typeof(WFD));
            long offName = (long)Marshal.OffsetOf(typeof(WFD), "name");
            long offSizeHi = (long)Marshal.OffsetOf(typeof(WFD), "sizeHi");
            if (size != 592 || offName != 44 || offSizeHi != 28)
                throw new InvalidOperationException(
                    "WIN32_FIND_DATAW layout is wrong: sizeof=" + size + " nameOffset=" + offName +
                    " sizeHiOffset=" + offSizeHi + " (expected 592 / 44 / 28). Refusing to scan.");
        }

        public static string LayoutInfo()
        {
            return "sizeof=" + Marshal.SizeOf(typeof(WFD)) +
                   " nameOffset=" + Marshal.OffsetOf(typeof(WFD), "name") +
                   " sizeHiOffset=" + Marshal.OffsetOf(typeof(WFD), "sizeHi");
       }

        /// <summary>FILETIME (100ns since 1601) -> .NET ticks (100ns since 0001). Never throws.</summary>
        public static long NetTicksFromFileTime(long ft)
        {
            if (ft <= 0) return 0;
            if (ft > 2650467743999999999L) ft = 2650467743999999999L;
            try { return DateTime.FromFileTimeUtc(ft).Ticks; } catch { return 0; }
        }

        /// <summary>Local ISO string for a .NET-ticks value; empty string when unset.</summary>
        public static string IsoFromTicks(long netTicks)
        {
            if (netTicks <= 0) return "";
            try { return new DateTime(netTicks, DateTimeKind.Utc).ToLocalTime().ToString("yyyy-MM-dd HH:mm"); }
            catch { return ""; }
        }

        private static bool SuffixMatch(string name, string[] suffixes)
        {
            if (suffixes == null) return false;
            string low = name.ToLowerInvariant();
            for (int i = 0; i < suffixes.Length; i++)
                if (low.EndsWith(suffixes[i], StringComparison.Ordinal)) return true;
            return false;
        }

        private static bool NameMatch(string name, string[] names)
        {
            if (names == null) return false;
            for (int i = 0; i < names.Length; i++)
                if (string.Equals(name, names[i], StringComparison.OrdinalIgnoreCase)) return true;
            return false;
        }

        private static bool PathSkip(string path, string[] prefixes)
        {
            if (prefixes == null) return false;
            for (int i = 0; i < prefixes.Length; i++)
            {
                if (prefixes[i] == null || prefixes[i].Length == 0) continue;
                if (path.StartsWith(prefixes[i], StringComparison.OrdinalIgnoreCase)) return true;
            }
            return false;
        }

        /// <summary>Bounded parallel walk. Never runs unbounded: every cap is enforced.</summary>
        public static ScanResult Scan(string root, Opt o)
        {
            SelfCheck();
            if (o == null) o = new Opt();
            root = root.TrimEnd('\\');
            if (root.Length == 2 && root[1] == ':') root = root + "\\";
            if (!root.EndsWith("\\")) root = root + "\\";
            string rootNorm = root.TrimEnd('\\');

            // Background mode is applied per worker thread only. The engine is Add-Type'd into the
            // caller's PowerShell process, so demoting the whole PROCESS would slow the agent's shell.

            var sw = Stopwatch.StartNew();
            var q = new ConcurrentQueue<string>();
            q.Enqueue(rootNorm);
            var dirDirect = new ConcurrentDictionary<string, long>(StringComparer.OrdinalIgnoreCase);
            var dirAlloc = new ConcurrentDictionary<string, long>(StringComparer.OrdinalIgnoreCase);
            var dirFiles = new ConcurrentDictionary<string, long>(StringComparer.OrdinalIgnoreCase);
            var dirMtime = new ConcurrentDictionary<string, long>(StringComparer.OrdinalIgnoreCase);
            var dirB = new ConcurrentDictionary<string, long[]>(StringComparer.OrdinalIgnoreCase); // 5 buckets
            var topFiles = new List<FileHit>();
            var topLock = new object();
            long dirs = 0, files = 0, bytes = 0, denied = 0, reparse = 0, skipped = 0, alloc = 0;
            int inflight = 1;
            bool capped = false;
            var done = new ManualResetEventSlim(false);

            int threads = Math.Max(1, Math.Min(o.Threads <= 0 ? 4 : o.Threads, Environment.ProcessorCount));
            var workers = new Thread[threads];
            for (int w = 0; w < threads; w++)
            {
                workers[w] = new Thread(delegate()
                {
                    if (o.LowPriority) { try { SetThreadPriority(GetCurrentThread(), THREAD_MODE_BACKGROUND_BEGIN); } catch { } }
                    while (true)
                    {
                        if ((o.MaxSeconds > 0 && sw.Elapsed.TotalSeconds > o.MaxSeconds) ||
                            (o.MaxDirs > 0 && Interlocked.Read(ref dirs) >= o.MaxDirs))
                        { capped = true; done.Set(); return; }

                        string dir;
                        if (!q.TryDequeue(out dir))
                        {
                            if (Interlocked.CompareExchange(ref inflight, 0, 0) <= 0) { done.Set(); return; }
                            Thread.Sleep(1);
                            continue;
                        }
                        Interlocked.Increment(ref dirs);

                        long directBytes = 0, directFiles = 0, directAlloc = 0;
                        var buckets = new long[5];
                        long newestTicks = 0;
                        WFD d;
                        IntPtr h = FindFirstFileW(dir + "\\*", out d);
                        if (h == (IntPtr)(-1))
                        {
                            Interlocked.Increment(ref denied);
                        }
                        else
                        {
                            int n = 0;
                            do
                            {
                                if (((++n) & 0xFF) == 0 && o.MaxSeconds > 0 && sw.Elapsed.TotalSeconds > o.MaxSeconds)
                                { capped = true; break; }
                                if (d.name == null || d.name.Length == 0) continue;
                                if (d.name == "." || d.name == "..") continue;
                                bool isDir = (d.attr & 0x10) != 0;
                                bool isReparse = (d.attr & 0x400) != 0;
                                string full = dir + "\\" + d.name;

                                if (isDir)
                                {
                                    if (isReparse) { Interlocked.Increment(ref reparse); continue; }
                                    if (NameMatch(d.name, o.SkipNames) || PathSkip(full, o.SkipPaths)) { skipped++; continue; }
                                    if (string.Equals(full, dir, StringComparison.OrdinalIgnoreCase)) continue; // self-enqueue guard
                                    Interlocked.Increment(ref inflight);
                                    q.Enqueue(full);
                                }
                                else
                                {
                                    long len = ((long)d.sizeHi << 32) | d.sizeLo;
                                    if (len <= 0) continue;
                                    directBytes += len;
                                    directFiles++;
                                    directAlloc += len;
                                    Interlocked.Add(ref bytes, len);
                                    Interlocked.Add(ref alloc, len);
                                    Interlocked.Increment(ref files);

                                    long wTicks = (long)d.wrtLo | ((long)d.wrtHi << 32);
                                    if (wTicks > newestTicks) newestTicks = wTicks;
                                    long fileTicks = NetTicksFromFileTime(wTicks);
                                    double days = (DateTime.UtcNow.Ticks - fileTicks) / 864000000000.0;
                                    if (days <= 7) buckets[0] += len;
                                    else if (days <= 30) buckets[1] += len;
                                    else if (days <= 90) buckets[2] += len;
                                    else if (days <= 365) buckets[3] += len;
                                    else buckets[4] += len;

                                    // Allocation size is probed only for big files / configured suffixes:
                                    // one extra metadata call per probed file, so we keep the probe set small.
                                    if ((len >= o.AllocProbeMinBytes) ||
                                        (o.AllocProbeSuffix != null && SuffixMatch(d.name, o.AllocProbeSuffix)))
                                    {
                                        uint hi;
                                        uint lo2 = GetCompressedFileSizeW(full, out hi);
                                        if (!(lo2 == 0xFFFFFFFF && hi == 0xFFFFFFFF))
                                        {
                                            long al = ((long)hi << 32) | lo2;
                                            directAlloc += (al - len);
                                            Interlocked.Add(ref alloc, al - len);
                                        }
                                    }

                                    if (o.MinTopFileBytes > 0 && len >= o.MinTopFileBytes)
                                    {
                                        lock (topLock)
                                        {
                                            if (topFiles.Count < o.MaxTopFiles * 2)
                                            {
                                                FileHit fh = new FileHit();
                                                fh.P = full; fh.B = len; fh.M = fileTicks;
 fh.C = NetTicksFromFileTime((long)d.creLo | ((long)d.creHi << 32));
                                                topFiles.Add(fh);
                                            }
                                        }
                                    }
                                }
                            } while (FindNextFileW(h, out d));
                            FindClose(h);
                        }

                        dirDirect[dir] = directBytes;
                        dirAlloc[dir] = directAlloc;
                        dirFiles[dir] = directFiles;
                        dirMtime[dir] = newestTicks;
                        dirB[dir] = buckets;
                        if (Interlocked.Decrement(ref inflight) <= 0) done.Set();
                    }
                });
                workers[w].IsBackground = true;
                workers[w].Start();
            }

            done.Wait(TimeSpan.FromSeconds(o.MaxSeconds > 0 ? o.MaxSeconds + 30 : 3600));
            foreach (Thread t in workers) if (t != null) t.Join(10000);
            foreach (Thread t in workers) if (t != null && t.IsAlive) capped = true;

            // ---- rollup pass: process deepest first, accumulate into parents ----
            var paths = new List<string>(dirDirect.Keys);
            var depthOf = new Dictionary<string, int>(paths.Count, StringComparer.OrdinalIgnoreCase);
            for (int i = 0; i < paths.Count; i++)
            {
                string p = paths[i];
                int depth = 0;
                for (int k = 0; k < p.Length; k++) if (p[k] == '\\') depth++;
                depthOf[p] = depth;
            }
            paths.Sort(delegate(string a, string b)
            {
                int da = depthOf[a], db = depthOf[b];
                if (da != db) return db.CompareTo(da);           // deeper first
                return string.CompareOrdinal(a, b);
            });

            var rollB = new Dictionary<string, long>(paths.Count, StringComparer.OrdinalIgnoreCase);
            var rollA = new Dictionary<string, long>(paths.Count, StringComparer.OrdinalIgnoreCase);
            var rollF = new Dictionary<string, long>(paths.Count, StringComparer.OrdinalIgnoreCase);
            var rollBk = new Dictionary<string, long[]>(paths.Count, StringComparer.OrdinalIgnoreCase);
            var rollM = new Dictionary<string, long>(paths.Count, StringComparer.OrdinalIgnoreCase);
            for (int i = 0; i < paths.Count; i++)
            {
                string p = paths[i];
                long b = dirDirect.ContainsKey(p) ? dirDirect[p] : 0;
                long[] bk = dirB.ContainsKey(p) ? dirB[p] : new long[5];
                if (rollB.ContainsKey(p)) { b += rollB[p]; bk[0] += rollBk[p][0]; bk[1] += rollBk[p][1]; bk[2] += rollBk[p][2]; bk[3] += rollBk[p][3]; bk[4] += rollBk[p][4]; }
                long a = dirAlloc.ContainsKey(p) ? dirAlloc[p] : 0;
                if (rollA.ContainsKey(p)) a += rollA[p];
                long f = dirFiles.ContainsKey(p) ? dirFiles[p] : 0;
                if (rollF.ContainsKey(p)) f += rollF[p];
                // newest activity is rolled up as well: a directory holding only subdirectories is not idle
                long m = dirMtime.ContainsKey(p) ? dirMtime[p] : 0;
                if (rollM.ContainsKey(p) && rollM[p] > m) m = rollM[p];
                rollB[p] = b; rollA[p] = a; rollF[p] = f; rollBk[p] = bk; rollM[p] = m;

                int li = p.LastIndexOf('\\');
                if (li >= 2)
                {
                    string parent = p.Substring(0, li);
                    if (!rollB.ContainsKey(parent)) { rollB[parent] = 0; rollA[parent] = 0; rollF[parent] = 0; rollBk[parent] = new long[5]; rollM[parent] = 0; }
                    rollB[parent] += b;
                    rollA[parent] += a;
                    rollF[parent] += f;
                    if (m > rollM[parent]) rollM[parent] = m;
                    long[] pb = rollBk[parent];
                    pb[0] += bk[0]; pb[1] += bk[1]; pb[2] += bk[2]; pb[3] += bk[3]; pb[4] += bk[4];
                }
            }

            var res = new ScanResult();
            res.Root = rootNorm;
            res.At = DateTime.Now;
            res.Dirs = dirs; res.Files = files; res.Bytes = bytes;
            res.Alloc = alloc; res.Denied = denied; res.Reparse = reparse; res.Skipped = skipped;
            res.Sec = sw.Elapsed.TotalSeconds;
            res.Capped = capped;
            res.State = capped ? "CAPPED" : "DRAINED";
            res.Threads = threads;

            // hot dirs get the full histogram; everything else keeps the 2 derived numbers
            var hot = new List<Ent>();
            foreach (string p in paths)
            {
                var e = new Ent();
                e.P = p;
                e.B = rollB[p];
                e.A = rollA.ContainsKey(p) ? rollA[p] : 0;
                e.F = rollF.ContainsKey(p) ? rollF[p] : 0;
                e.M = NetTicksFromFileTime(rollM.ContainsKey(p) ? rollM[p] : 0);
                long[] bk = rollBk[p];
                e.N30 = bk[0] + bk[1];
                double ageDays = e.M > 0 ? (DateTime.UtcNow.Ticks - e.M) / 864000000000.0 : -1;
                e.Age = ageDays < 0 ? -1 : (int)Math.Round(ageDays);
                if (e.N30 >= o.HotMinBytes)
                {
                    e.Hot = true;
                    e.B0 = bk[0]; e.B1 = bk[1]; e.B2 = bk[2]; e.B3 = bk[3]; e.B4 = bk[4];
                }
                res.Ents.Add(e);
                if (e.Hot) hot.Add(e);
            }
            if (hot.Count > o.HotTopN && o.HotTopN > 0)
            {
                hot.Sort(delegate(Ent x, Ent y) { return y.N30.CompareTo(x.N30); });
                for (int i = o.HotTopN; i < hot.Count; i++)
                {
                    hot[i].Hot = false; hot[i].B0 = hot[i].B1 = hot[i].B2 = hot[i].B3 = hot[i].B4 = 0;
                }
            }

            if (o.MaxTopFiles > 0 && topFiles.Count > o.MaxTopFiles)
            {
                topFiles.Sort(delegate(FileHit x, FileHit y) { return y.B.CompareTo(x.B); });
                topFiles.RemoveRange(o.MaxTopFiles, topFiles.Count - o.MaxTopFiles);
            }
            res.TopFiles = topFiles;

            return res;
        }

        // ---------------- storage: sorted + prefix-compressed + GZip ----------------
        /// <summary>Build the path lookup so PowerShell never has to enumerate the whole entry list.</summary>
        public static void BuildIndex(ScanResult r)
        {
            if (r == null) return;
            Dictionary<string, Ent> d = new Dictionary<string, Ent>(r.Ents.Count, StringComparer.OrdinalIgnoreCase);
            for (int i = 0; i < r.Ents.Count; i++) d[r.Ents[i].P] = r.Ents[i];
            r.Meta = d;
        }

        public static Ent Get(ScanResult r, string path)
        {
            if (r == null || r.Meta == null || path == null) return null;
            Ent e;
            if (r.Meta.TryGetValue(path, out e)) return e;
            return null;
        }

        /// <summary>Hot directories (bytes written within 30 days) sorted desc - the retro-attribution work list.</summary>
        public static List<Delta> HotList(ScanResult r, int maxOut)
        {
            List<Delta> l = new List<Delta>();
            if (r == null) return l;
            for (int i = 0; i < r.Ents.Count; i++)
            {
                Ent e = r.Ents[i];
                if (!e.Hot) continue;
                Delta x = new Delta();
                x.P = e.P; x.N30 = e.N30; x.CurB = e.B; x.CurF = e.F; x.Age = e.Age;
                x.Hot = true; x.B0 = e.B0; x.B1 = e.B1; x.B2 = e.B2; x.B3 = e.B3; x.B4 = e.B4;
                x.Mtime = IsoFromTicks(e.M);
                l.Add(x);
            }
            l.Sort(delegate(Delta x, Delta y) { return y.N30.CompareTo(x.N30); });
            if (maxOut > 0 && l.Count > maxOut) l.RemoveRange(maxOut, l.Count - maxOut);
            return l;
        }

        /// <summary>
        /// Hot directories carrying SELF (non-double-counted) 30-day writes: each hot node's value has its
        /// nearest hot descendant's value subtracted, so ancestors and descendants are never summed twice.
        /// OwnB carries the self amount; N30 keeps the rollup value.
        /// </summary>
        public static List<Delta> HotSelfList(ScanResult r, long minSelfBytes, int maxOut)
        {
            List<Delta> l = new List<Delta>();
            if (r == null || r.Meta == null) return l;
            Dictionary<string, long> childSum = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
            foreach (KeyValuePair<string, Ent> kv in r.Meta)
            {
                if (!kv.Value.Hot) continue;
                string p = kv.Key;
                while (true)
                {
                    int li = p.LastIndexOf('\\');
                    if (li < 2) break;
                    p = p.Substring(0, li);
                    Ent pe;
                    if (r.Meta.TryGetValue(p, out pe) && pe.Hot)
                    {
                        long cur;
                        if (!childSum.TryGetValue(p, out cur)) cur = 0;
                        childSum[p] = cur + kv.Value.N30;
                        break;
                    }
                }
            }
            foreach (KeyValuePair<string, Ent> kv in r.Meta)
            {
                Ent e = kv.Value;
                if (!e.Hot) continue;
                long cs;
                if (!childSum.TryGetValue(kv.Key, out cs)) cs = 0;
                long self = e.N30 - cs;
                if (self < minSelfBytes) continue;
                Delta x = new Delta();
                x.P = e.P; x.N30 = e.N30; x.CurB = e.B; x.CurF = e.F; x.Age = e.Age;
                x.Hot = true; x.OwnB = self;
                x.B0 = e.B0; x.B1 = e.B1; x.B2 = e.B2; x.B3 = e.B3; x.B4 = e.B4;
                x.Mtime = IsoFromTicks(e.M);
                l.Add(x);
            }
            l.Sort(delegate(Delta x, Delta y) { return y.OwnB.CompareTo(x.OwnB); });
            if (maxOut > 0 && l.Count > maxOut) l.RemoveRange(maxOut, l.Count - maxOut);
            return l;
        }

        /// <summary>Top "maxDepth" levels (drive root children by default), biggest first - used to seed the watch registry.</summary>
        public static List<Delta> ShallowList(ScanResult r, int maxDepth, long minBytes, int maxOut)
        {
            List<Delta> l = new List<Delta>();
            if (r == null) return l;
            for (int i = 0; i < r.Ents.Count; i++)
            {
                Ent e = r.Ents[i];
                if (e.P.Length == 0) continue;
                if (e.P.TrimEnd('\\').Length == 2 && e.P[1] == ':') continue;   // the drive root itself
                int depth = 0;
                for (int k = 0; k < e.P.Length; k++) if (e.P[k] == '\\') depth++;
                if (depth > maxDepth) continue;
                if (e.B < minBytes) continue;
                Delta x = new Delta();
                x.P = e.P; x.CurB = e.B; x.CurF = e.F; x.N30 = e.N30; x.Age = e.Age;
                x.Hot = e.Hot; x.B0 = e.B0; x.B1 = e.B1; x.B2 = e.B2; x.B3 = e.B3; x.B4 = e.B4;
                x.Mtime = IsoFromTicks(e.M);
                l.Add(x);
            }
            l.Sort(delegate(Delta x, Delta y) { return y.CurB.CompareTo(x.CurB); });
            if (maxOut > 0 && l.Count > maxOut) l.RemoveRange(maxOut, l.Count - maxOut);
            return l;
        }

        private static Delta MakeDelta(string k, long d, long df, long dn, ScanResult b, Dictionary<string, int> ib)
        {
            Delta x = new Delta();
            x.P = k; x.DB = d; x.DF = df; x.DN30 = dn;
            int idx;
            if (ib.TryGetValue(k, out idx))
            {
                Ent e = b.Ents[idx];
                x.CurB = e.B; x.CurF = e.F; x.Age = e.Age; x.N30 = e.N30;
                x.Hot = e.Hot; x.B0 = e.B0; x.B1 = e.B1; x.B2 = e.B2; x.B3 = e.B3; x.B4 = e.B4;
                x.Mtime = IsoFromTicks(e.M);
            }
            return x;
        }

        /// <summary>
        /// Diff two trees. All heavy lifting stays here - PowerShell never touches the full entry list.
        /// DB/DF/DN30 are rollup deltas; OwnB is the self-only delta (children subtracted) so that
        /// per-path attribution never counts the same byte twice.
        /// </summary>
        public static DiffResult Diff(ScanResult a, ScanResult b, long minBytes, int maxOut)
        {
            var res = new DiffResult();
            res.OldT = a; res.NewT = b;
            res.OldBytes = a.Bytes; res.NewBytes = b.Bytes;

            var ia = new Dictionary<string, int>(a.Ents.Count, StringComparer.OrdinalIgnoreCase);
            for (int i = 0; i < a.Ents.Count; i++) ia[a.Ents[i].P] = i;
            var ib = new Dictionary<string, int>(b.Ents.Count, StringComparer.OrdinalIgnoreCase);
            for (int i = 0; i < b.Ents.Count; i++) ib[b.Ents[i].P] = i;

            var keys = new List<string>(a.Ents.Count + b.Ents.Count);
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            for (int i = 0; i < a.Ents.Count; i++) if (seen.Add(a.Ents[i].P)) keys.Add(a.Ents[i].P);
            for (int i = 0; i < b.Ents.Count; i++) if (seen.Add(b.Ents[i].P)) keys.Add(b.Ents[i].P);

            var db = new Dictionary<string, long>(keys.Count, StringComparer.OrdinalIgnoreCase);
            var df = new Dictionary<string, long>(keys.Count, StringComparer.OrdinalIgnoreCase);
            var dn = new Dictionary<string, long>(keys.Count, StringComparer.OrdinalIgnoreCase);
            var childSum = new Dictionary<string, long>(keys.Count, StringComparer.OrdinalIgnoreCase);
            for (int i = 0; i < keys.Count; i++)
            {
                string k = keys[i];
                int idx;
                long ob = 0, of = 0, on = 0, nb = 0, nf = 0, nn = 0;
                if (ia.TryGetValue(k, out idx)) { ob = a.Ents[idx].B; of = a.Ents[idx].F; on = a.Ents[idx].N30; }
                else res.Appeared++;
                if (ib.TryGetValue(k, out idx)) { nb = b.Ents[idx].B; nf = b.Ents[idx].F; nn = b.Ents[idx].N30; }
                else res.Vanished++;
                db[k] = nb - ob; df[k] = nf - of; dn[k] = nn - on;
                int li = k.LastIndexOf('\\');
                if (li > 2)
                {
                    string parent = k.Substring(0, li);
                    long cur;
                    if (!childSum.TryGetValue(parent, out cur)) cur = 0;
                    childSum[parent] = cur + (nb - ob);
                }
            }
            for (int i = 0; i < keys.Count; i++)
            {
                string k = keys[i];
                long cs;
                if (!childSum.TryGetValue(k, out cs)) cs = 0;
                res.TreeNetDelta += db[k] - cs;
                long d = db[k];
                if (d >= minBytes)
                {
                    Delta x = MakeDelta(k, d, df[k], dn[k], b, ib);
                    x.OwnB = d - cs;
                    res.Grow.Add(x); res.SumGrow += d;
                }
                else if (d <= -minBytes)
                {
                    Delta x = MakeDelta(k, d, df[k], dn[k], b, ib);
                    x.OwnB = d - cs;
                    res.Shrink.Add(x); res.SumShrink += d;
                }
            }
            res.Grow.Sort(delegate(Delta x, Delta y) { return y.DB.CompareTo(x.DB); });
            res.Shrink.Sort(delegate(Delta x, Delta y) { return x.DB.CompareTo(y.DB); });
            if (maxOut > 0)
            {
                if (res.Grow.Count > maxOut) res.Grow.RemoveRange(maxOut, res.Grow.Count - maxOut);
                if (res.Shrink.Count > maxOut) res.Shrink.RemoveRange(maxOut, res.Shrink.Count - maxOut);
            }

            // retro attribution: hottest directories by "bytes written within 30 days" (no baseline needed)
            for (int i = 0; i < b.Ents.Count; i++)
            {
                Ent e = b.Ents[i];
                if (!e.Hot) continue;
                Delta x = new Delta();
                x.P = e.P; x.N30 = e.N30; x.CurB = e.B; x.CurF = e.F; x.Age = e.Age;
                x.Hot = true; x.B0 = e.B0; x.B1 = e.B1; x.B2 = e.B2; x.B3 = e.B3; x.B4 = e.B4;
                x.Mtime = IsoFromTicks(e.M);
                res.Hot.Add(x);
            }
            res.Hot.Sort(delegate(Delta x, Delta y) { return y.N30.CompareTo(x.N30); });
            if (maxOut > 0 && res.Hot.Count > maxOut) res.Hot.RemoveRange(maxOut, res.Hot.Count - maxOut);
            return res;
        }
        private static void W(BinaryWriter w, long v) { w.Write(v); }
        private static void WS(BinaryWriter w, string s) { w.Write(s); }

        public static void Save(ScanResult r, string path)
        {
            var sorted = new List<Ent>(r.Ents);
            sorted.Sort(delegate(Ent a, Ent b) { return string.CompareOrdinal(a.P, b.P); });
            string dir = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir)) Directory.CreateDirectory(dir);
            using (var fs = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16))
            using (var gz = new GZipStream(fs, CompressionMode.Compress))
            using (var w = new BinaryWriter(gz, Encoding.UTF8))
            {
                w.Write(4);                       // format version
                WS(w, r.Root);
                w.Write(r.At.ToString("o"));
                w.Write(r.Dirs); w.Write(r.Files); w.Write(r.Denied); w.Write(r.Reparse);
                w.Write(r.Bytes); w.Write(r.Alloc); w.Write(r.Skipped);
                w.Write(r.Sec); w.Write(r.Capped); WS(w, r.State); w.Write(r.Threads);
                w.Write(sorted.Count);
                string prev = "";
                for (int i = 0; i < sorted.Count; i++)
                {
                    Ent e = sorted[i];
                    int common = 0;
                    int max = Math.Min(prev.Length, e.P.Length);
                    while (common < max && prev[common] == e.P[common]) common++;
                    w.Write(common);
                    WS(w, e.P.Substring(common));
                    w.Write(e.B); w.Write(e.A); w.Write(e.F); w.Write(e.M); w.Write(e.N30); w.Write(e.Age);
                    w.Write(e.Hot);
                    if (e.Hot) { w.Write(e.B0); w.Write(e.B1); w.Write(e.B2); w.Write(e.B3); w.Write(e.B4); }
                    prev = e.P;
                }
                w.Write(r.TopFiles.Count);
                for (int i = 0; i < r.TopFiles.Count; i++)
                {
                    FileHit f = r.TopFiles[i];
                    w.Write(f.P); w.Write(f.B); w.Write(f.M); w.Write(f.C);
                }
            }
        }

        public static ScanResult Load(string path)
        {
            var r = new ScanResult();
            using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16))
            using (var gz = new GZipStream(fs, CompressionMode.Decompress))
            using (var br = new BinaryReader(gz, Encoding.UTF8))
            {
                int ver = br.ReadInt32();
                if (ver != 4) throw new InvalidOperationException("unsupported tree version " + ver);
                r.Root = br.ReadString();
                r.At = DateTime.Parse(br.ReadString());
                r.Dirs = br.ReadInt64(); r.Files = br.ReadInt64(); r.Denied = br.ReadInt64(); r.Reparse = br.ReadInt64();
                r.Bytes = br.ReadInt64(); r.Alloc = br.ReadInt64(); r.Skipped = br.ReadInt64();
                r.Sec = br.ReadDouble(); r.Capped = br.ReadBoolean(); r.State = br.ReadString(); r.Threads = br.ReadInt32();
                int n = br.ReadInt32();
                r.Ents = new List<Ent>(n);
                string prev = "";
                for (int i = 0; i < n; i++)
                {
                    int common = br.ReadInt32();
                    string suffix = br.ReadString();
                    string p = common > 0 ? prev.Substring(0, common) + suffix : suffix;
                    var e = new Ent();
                    e.P = p;
                    e.B = br.ReadInt64(); e.A = br.ReadInt64(); e.F = br.ReadInt64();
                    e.M = br.ReadInt64(); e.N30 = br.ReadInt64(); e.Age = br.ReadInt32();
                    e.Hot = br.ReadBoolean();
                    if (e.Hot) { e.B0 = br.ReadInt64(); e.B1 = br.ReadInt64(); e.B2 = br.ReadInt64(); e.B3 = br.ReadInt64(); e.B4 = br.ReadInt64(); }
                    r.Ents.Add(e);
                    prev = p;
                }
                int nf = br.ReadInt32();
                for (int i = 0; i < nf; i++)
                {
                    var f = new FileHit();
                    f.P = br.ReadString(); f.B = br.ReadInt64(); f.M = br.ReadInt64(); f.C = br.ReadInt64();
                    r.TopFiles.Add(f);
                }
            }
            return r;
        }
    }
}
