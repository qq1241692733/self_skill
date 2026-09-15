# C盘增长底层原理与快照对比方法论

> 本文件支撑技能的设计依据，综合了 NTFS 文件系统机制、学术论文、开源工具实现与 Windows 实际观察。\ 引用来源见文末"参考资料"。

## 1. 为什么"清理工具"治标不治本

市面工具分两类：

| 类型 | 代表 | 原理 | 短板 |
| --- | --- | --- | --- |
| 全盘分析 | WinDirStat、TreeSize、SpaceSniffer | 递归遍历目录树 + Treemap 可视化 | 扫描慢（500GB SSD 约10-30分钟）；只给"现状快照"，无法回答"这段时间为什么涨" |
| MFT直读 | WizTree、Everything、FastWinDirStat | 直接解析 NTFS 主文件表（MFT），绕过文件系统API | 秒级全盘扫描（1-3秒/TB）；但仍是"静态快照"，没有时间维度对比 |
| 系统清理 | cleanmgr、CCleaner、DISM | 清可再生缓存/更新残留 | 不知道"清完为什么又满"；误删风险；对 WinSxS 只会 Dism |

**本技能的核心差异 = 时间维度**：用"高速快照 + 对比归因"回答三个问题：

1. 这段时间**哪些目录涨了、哪些降了**（增量定位）；

2. 增长**对应哪个应用**（路径归因）；

3. 清理后**回涨的来源**（清理记录 + 后续 diff 闭环验证）。

参考：WizTree 官方说明 MFT 直读原理（wiztree.com/about）；WinDirStat 使用 FindFirstFile/FindNextFile 递归扫描（windirstat.net）；gdu 用 Go 并发 goroutine 实现 8x 加速（gdu GitHub）；ncdu 2.5+ 加入 `-t8` 并行扫描（dev.yorhel.nl/ncdu）。

## 2. 底层机制：NTFS 如何"记账"

### 2.1 MFT（主文件表）

- NTFS 为每个文件/目录在 MFT 中保存一条 1024 字节记录，内含 `$STANDARD_INFORMATION`（时间戳/权限）、`$FILE_NAME`（名称/父目录）、`$DATA`（数据区或簇运行指针）。

- 因为 MFT 常驻缓存且物理连续，WizTree/Everything 直接批量读 MFT 即可秒级列出全盘文件——这正是"高速"的天花板。

- 本技能不直接读 MFT（需要管理员+解析二进制，且各版本有差异），采用 **Win32 FindFirstFile 并行遍历**：兼容所有 Windows、无权限依赖、每项仅一次系统调用，速度介于"传统递归"与"MFT直读"之间，实测目标是把全盘扫描压到 20-60 秒。

### 2.2 USN 变更日志（$UsnJrnl）

- NTFS 以环形缓冲记录卷上每次创建/删除/修改/重命名事件（含文件ID、时间、原因）。Everything 靠它实现 ~100ms 级索引增量更新。

- 价值：**快照之间的精确"发生了什么"**。本技能设计为可选增强（管理员 + `fsutil usn readjournal C: csv`）：记录上次查询的 USN，下次读取增量即可获得"新增/删除/改名了哪些文件"，可弥补目录级对比对"已删除文件"的盲区。因需要管理员权限，默认关闭，作为 L3 深查选项。

### 2.3 硬链接与 WinSxS

- WinSxS 用硬链接让同一物理文件被多个路径引用（更新不替换旧组件、保留回滚能力）。按路径求和会**重复计数约 2 倍**。

- WizTree 特意处理硬链接（按文件唯一引用计数），报告与 Windows 实际占用一致。

- 本技能：目录级快照按逻辑大小计数（趋势仍有效），WinSxS 真实占用以 `DISM /AnalyzeComponentStore` 为准，避免误导。

### 2.4 压缩/稀疏文件与"逻辑大小 vs 分配大小"

- NTFS 压缩与稀疏文件会导致"逻辑大小"≠"磁盘实际占用"。快照对比要求**两次口径一致**即可正确反映增量；绝对占用建议用 WizTree/系统报告核对。

## 3. C盘增长的八大来源（为什么总是它）

1. **系统更新**：WinSxS 只增不减（每次更新保留旧组件）+ SoftwareDistribution 下载缓存 + Delivery Optimization 传递优化缓存。微软官方确认 WinSxS 是系统分区膨胀主因。

2. **休眠/虚拟内存**：hiberfil.sys 占物理内存 40%~75%；pagefile.sys 默认自动管理；两者合计常达 10-40GB。

3. **应用缓存回涨**：浏览器 Cache/Code Cache、微信/QQ 聊天文件（图片视频）、网易云音乐缓存、JetBrains 索引、npm/yarn/pnpm/uv/pip 包缓存、Playwright、Adobe、WPS 备份——**清掉后应用会以同样速度写回来**，这是"清理后又爆满"最常见的原因。

4. **临时/日志/转储**：%TEMP%、C:\Windows\Temp、Logs、WER、Minidump、MEMORY.DMP、CbsTemp、CrashDumps，日积月累。

5. **虚拟机/子系统**：WSL2 的 ext4.vhdx 与 Docker Desktop 的 vhdx 是**稀疏文件，删除内部文件后不会自动收缩**，体积只增不减（需 compact）。

6. **系统还原/卷影副本**：默认最多占卷容量的一定比例，随还原点累积。

7. **更新残留**：Windows.old、C:\Windows\Installer（缓存安装包，删除会导致卸载/修复失败）、DriverStore 旧驱动。

8. **用户行为**：下载/桌面/文档大文件放 C 盘；软件默认安装到 C 盘；OneDrive 按需文件占位。

## 4. 快照对比的测量口径与坑

- **口径一致性**：同一次对比必须同口径（本技能统一"直属大小自底向上累加"，跨 v1/v2/v3 归一化）。

- **权限盲区**：无管理员时部分系统目录扫不到（如 System Volume Information），报告会显示"未定位差值"，提示用管理员重扫——这是真实世界的常态，不是 bug。

- **时间竞争**：快照是瞬态记录，拍摄期间有文件增删，微小的±偏差属正常。

- **"减少"的解读**：目录变小≠坏消息（日志轮转、缓存过期、手动清理都算），diff 同时展示增长与减少，避免只盯增长。

## 5. 为什么"清理后很快又满"——闭环验证

1. 清理前 `snapshot`（基线）→ `clean -Execute`（记录释放量到 cleanup\_history.jsonl）→ 清理后再 `snapshot`；

2. 数天后再 `snapshot` → `diff`；

3. 归因表会显示：**如果增长集中在"缓存·可再生"，说明应用在持续写缓存，治本是迁移路径（migration-guide.md）；如果集中在"通讯社交/游戏/媒体"，是个人数据增长，需应用内迁移；如果集中在"系统更新"，是更新周期使然，可周期性 DISM**。

4. 这个"清理→对比→归因"闭环正是本技能区别于单次清理工具的核心价值。

## 6. 参考资料

- WizTree 官方：MFT 直读原理、硬链接正确处理（https://wiztree.com/about，https://www.diskanalyzer.com/about）

- WinDirStat：递归扫描与 treemap（https://windirstat.net/）

- gdu（Go并行扫描，SSD 8x）：https://github.com/dundee/gdu；ncdu 2.5 并行扫描：https://dev.yorhel.nl/ncdu

- Microsoft Learn：fsutil usn / 更改日记记录（https://learn.microsoft.com/windows-server/administration/windows-commands/fsutil-usn）

- Microsoft Q\&A：WinSxS 为系统分区增长主因（https://learn.microsoft.com/en-us/answers/questions/4372740/why-my-system-partition-is-growing-so-big）

- 学术：IJSRET《Forensic Analysis of NTFS: Structure, Vulnerabilities, and Novel Recovery Techniques》（MFT 记录结构）；ACM《Time for Truth: Forensic Analysis of NTFS Timestamps》；《A Forensic Timeline Reconstruction…》（MFT+USN+LogFile 多证据关联）

- Everything 基于 USN Journal 增量索引：CSDN《Windows高效文件查找神器Everything实战指南》

- WSL2 vhdx 不自动收缩：CSDN《Windows WSL2 占用磁盘空间清理释放》
