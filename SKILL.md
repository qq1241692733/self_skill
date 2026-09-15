---
name: disk-monitor-cleanup
description: "C盘空间监控、增长归因与安全清理（v4 按需版）。当用户提到C盘满了、磁盘空间不足、清理C盘、什么占了空间、为什么C盘又满了、最近磁盘涨了很多、监控磁盘增长、缓存清理、临时文件清理、WinSxS、磁盘搬家、预防C盘爆满、什么在吃C盘空间时使用。核心能力：①每次运行都留下账本，第二次运行即可精确 diff（不需要后台常驻）；②单次运行就能回答“为什么涨”——按文件最后写入时间做回顾式归因，无需历史基线；③残差驱动的动态监控名单（标记打在独立注册表里，不绑层级）；④账本对账不变量（卷剩余变化必须能被各项解释）；⑤安全清理（清单→预演→确认→执行→复验）。零外部依赖，任意 Windows 可用。"
---

# C 盘监控与清理 v4（按需版）

## 设计前提（先看这一节，否则会用错）

1. **按需运行，默认零后台**。用户"发现 C 盘涨了才跑"是常态，所以设计不依赖高频扫描：

   - **基线 = 上一次运行的账本**（每次 run 都会落一份树 + 账本），跑得越勤越细，跑得少也不缺基线。

   - **单次运行自带答案**：靠"文件最后写入时间"的年龄直方图（≤7/30/90/365 天），一次扫描就能说清"近 30 天涨了什么"。

2. **绝不提前拍"文件级基线"**（按需模式下拍不上）。需要文件名级时用提权读 USN 日志。

3. **重活在 C#（lib\DmScan.cs），PowerShell 只做编排与渲染**。不要用 PS 遍历目录树（旧的 `+=` 写法在大盘上会跑几十分钟）。

## 命令（统一入口）

```powershell
cd <技能目录>
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\diskmonitor.ps1 run        # 全盘扫描 + 报告（默认 150 秒硬上限）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\diskmonitor.ps1 run -Json  # 结构化输出（给 agent 用）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\diskmonitor.ps1 report      # 只看报告（不扫描，用最近两次快照对比）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\diskmonitor.ps1 diff        # 只要增量对比（阈值 1MB）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\diskmonitor.ps1 clean       # 清理预演（不删除）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\diskmonitor.ps1 clean -Execute
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\diskmonitor.ps1 clean-restore           # 列出可回滚的清理
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\diskmonitor.ps1 clean-restore -Stamp <stamp>   # 回滚（把隔离区文件放回原位）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\diskmonitor.ps1 clean-restore -Stamp <stamp> -Purge  # 确认无误后丢弃隔离区
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\diskmonitor.ps1 mark        # “记住现在”（清理后/装完软件后，60 秒轻量点）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\diskmonitor.ps1 status
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\diskmonitor.ps1 verify      # 引擎自检 + 正确性断言（有界，约 10 秒）
```

旧入口仍可用：`disk_snapshot.ps1`(=run)、`disk_report.ps1`(=report)、`disk_clean.ps1`(=clean，默认预演)、`disk_newfiles.ps1`(=report)。

## 决策树

| 用户诉求 | 执行 |
| --- | --- |
| 看看现在什么占空间 / 为什么涨 | `run`（首次就会给出"近 30 天写入 Top 目录 + 类别"） |
| 这段时间为什么少了 X GB | `run`（有上次快照时自动出 diff；没有就隔一段时间再 run） |
| 清理后又爆满，想找根源 | `run` → 看"回顾式归因"里的类别与"回涨"迹象；根治动作见 migration-guide.md |
| C 盘快满了要释放空间 | `clean` 预演 → 确认后 `clean -Execute` |
| 清完想反悔 / 恢复被清的文件 | `clean-restore` 列出 → `clean-restore -Stamp <stamp>` 回滚 |
| 清完/装完软件，想留个点 | `mark` |
| 磁盘/引擎是否可信 | `verify`（28 项断言：引擎布局、账本对账、D1 名单闸门、D2 记录规则、G1 清理回滚） |

## 输出内容（报告结构）

1. 运行信息（耗时、状态 DRAINED/CAPPED、权限盲区目录数）；

2. **回顾式归因**：全盘近 30 天写入量 + 写入最多的目录 Top15 + 按类别汇总（这条**不需要历史数据**）；

3. 最大的文件 Top10；

4. **与上次对比**（有基线时）：增长 Top15（含子树增量/自身增量/文件数变化/类别）、减少 Top10、新增/消失目录数；

5. **对账**：卷已用变化 = 树内变化 + 非目录桶（休眠/分页/回收站/卷影/MFT/USN）± 差值；差值大时提示提权重扫；

6. 监控名单（注册表）状态：一级/二级/休眠项数与得分最高项（含残差）；

7. 可立即处理清单（清理预演结果）；

8. 盲区与置信度声明。

## 快照结构（5 个对象，都在数据目录里）

数据目录：`DISKMON_DATA_DIR` 环境变量 > `D:\DiskMonitor`（沿用历史）> 非系统盘剩余最大盘 > `%USERPROFILE%\.diskmonitor`。

| 对象 | 位置 | 说明 |
| --- | --- | --- |
| 目录树 | `trees\tree_*.bin` | 每个目录：子树体积 / 文件数 / 最新活动时间 / 实际占用(探针) / 近30天写入 / 5 个年龄桶（热目录）。**前缀压缩 + GZip**，保留 `KeepTrees` 份 |
| 账本 | `trees\ledger_*.json` | 卷容量/剩余、hiberfil/pagefile/swapfile、回收站、卷影、MFT、USN 游标（提权时） |
| 监控名单 | `registry\watch.json` | **标记打在这里**：`(路径, tier, 状态, 统计, hit_mb/hit_gap 计入基线, memory_of)`。tier1 = 每期必看 |
| 时间序列 | `series\series.jsonl` + `segments.jsonl` | 记录线：**累计**变化 ≥ ThetaRecMB 才落一点（不是每次 run 都写），7 天心跳保底；硬上限 `KeepSeriesPoints`；清理时把该段合并成一行摘要（保留最近 2 段明细） |
| 事件流 | `events\events.jsonl`、`cleanup_history.jsonl`、`agent_rules.jsonl`、`manifest_*.json`、`deleted_*.jsonl` | 每次运行/清理/agent 结论（带 glob + 有效期）；清理的计划与逐条删除记录（含原路径）也在这里 |
| 隔离区 | `quarantine\<stamp>\` | `clean -Execute` 时 ≥ `QuarantineMinMB` 的条目是**移动**过来的，不是删除；`clean-restore` 可放回 |

## 监控名单的闸门（tier1 凭什么在里面）

一项要留在 tier1（每期必看），必须满足下面任一条，**全部以"变化"为准**：

1. **子树自上次计入以来累计增长 ≥ ThetaRecMB**（256MB）——不是单次运行的增量，所以跑得勤或跑得稀都一样能拿到名额；

2. **未点名残差自上次计入以来累计增长 ≥ ThetaRecMB**——说明里面有新冒出来的深目录，该点名了；

3. **近 30 天写入 ≥ ThetaCleanMB**（1024MB）——持续高 churn（如浏览器缓存：净尺寸不变但在反复写）。这是唯一的"水平量"，门槛取"值得清理"的量级，且窗口滚动，不写了就自然失效。

连续 **DemoteAfterRuns**（14）期没有任何信号 → 降为二级；**SleepAfterRuns**(30) 期 → 休眠。\ **注意闸门里没有"绝对尺寸"**：一个恒定 5GB 但不再增长的目录会被正常降级；一个每次只涨 120MB（低于阈值）但在持续增长的目录会靠累计拿到名额。

> 历史教训：v4 早期版本用"绝对残差 ≥ ThetaRecMB"提升，导致 tier1 退化成"最大的 300 个目录"、且降级分支永远无法触发（每一项每期都越线）。改完第一次实测：300 项全部 `hits=0`、`zero_streak≥5`；修正后只有真正在增长/高 churn 的项拿到名额。

## 残差机制（防漏检的核心）

```
某监控项的残差 = 它子树的总量 − 它下面"已被监控的子项"之和
```

- 子项都没动、父项总量涨了 → 残差必然越线 → 立刻发现（**所以"只扫一层"不会有盲区**，根节点永远隐含是一级监控项）；

- 根节点的残差 == 对账不变量的差额 —— **"残差的*****增长*****驱动标记提升"与"对账"是同一件事**（注意是增长量，不是残差的绝对值）；

- 残差**只能说明"没被点名的那部分涨了多少"，不能说明是哪几个**（父减子只是合计）。定位顺序：USN 变更目录 → 目录 mtime 变化（只反映增删改名）→ 抽样 → 二分下钻。

## 清理安全模型

- 白名单：临时文件、更新下载缓存、着色器缓存、崩溃转储、WER、缩略图缓存、npm/yarn/uv/pip 缓存、浏览器 Cache（不碰书签/密码/历史）。

- **默认预演**：`clean` 只出清单；`-Execute` 才删；回收站必须 `-RecycleBin` 显式确认。

- **可回滚**（G1）：`-Execute` 时**先把整个计划落盘**（`events\manifest_<stamp>.json`），再逐条执行并记录原路径（`events\deleted_<stamp>.jsonl`）；单条 ≥ `QuarantineMinMB`（默认 100MB）的条目是**移入 `quarantine\<stamp>\` 而不是删除**，`clean-restore -Stamp <stamp>` 可原样放回（放不回原位会明确报 `Failed` 计数）。小于阈值的条目才是真删。

- **按龄过滤**：`CleanMinAgeDays`（默认 7 天，临时文件类），只删老于该天数的条目。

- **只清内容不删目录**；占用中的文件跳过；执行后复验（对比卷剩余变化，而不是只信自己的估算）。

- 绝不触碰：个人文件、已装软件、`System32`、`WinSxS`（只走 DISM）、`Windows\Installer`、`hiberfil/pagefile/swapfile`、OneDrive、UWP 数据。

## agent 与脚本的边界（重要）

- **脚本负责确定性**：采集、统计、阈值、下钻、对账、执行已批准的清理动作。数字只能来自脚本。

- **agent 负责语义**：解释"这是什么软件在用""能不能迁/能不能删""为什么涨"。**不得直接执行删除**。

- **人负责授权**：删除/迁移/提权/改系统设置。

- agent 的结论用 `agent-rule` 沉淀成规则（`-Glob` 路径模式 → 归属/类别/可清理性/建议 + 有效期），下次同类目录直接命中，不再重复推理：

  ```powershell

  powershell -File scripts\diskmonitor.ps1 agent-rule -Glob "C:\Users\*\AppData\Local\Foo\*" -App "Foo" -Category "缓存·可再生" -Clean "安全可配迁移" -Advice "设置里可改缓存目录"

  ```



## 性能与边界（实测，本机 Ryzen 5 5600 / NVMe）

- 引擎：单线程约 1.2 万目录/秒，4 线程约 2–3.7 万目录/秒；40 万目录全盘约 20–35 秒（`MaxSeconds` 默认 150 秒兜底）。

- 每目录历史 `HotMinMB` 以上才带完整 5 桶直方图（默认 8MB）；树文件约 0.4MB/3 万目录，保留 12 份。

- 低优先级：工作线程用 `THREAD_MODE_BACKGROUND_BEGIN`（**不动整个进程**，避免拖慢调用它的 agent shell）。

- 硬上限：`MaxSeconds` / `MaxDirs`；到点即停并标 `CAPPED`（结果标注为不完整，不会假装成功）。

- 未提权时：卷影/保留存储/MFT/USN 不可见，报告会明确写出盲区，不猜。

## 故障速查

| 现象 | 处理 |
| --- | --- |
| 报告期 `state=CAPPED` | 加大 `MaxSeconds`（config）或缩小 `-Root` 重扫 |
| 对账差值很大 | 提权重扫（卷影/保留存储/MFT 需要管理员）；硬链接会让路径求和高估，属正常 |
| `verify` 报 layout 错 | `lib\DmScan.cs` 的 `WIN32_FIND_DATAW` 布局被改坏了——引擎会拒绝扫描，这是有意的保护 |
| 想彻底重置 | 删除数据目录下的 `trees/registry/series/events` 子目录（历史清零） |
