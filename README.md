# self_skill

个人 Agent 技能库。每个子目录是一个独立、自包含的技能，互不依赖，可以单独取用。

[English](./README.en.md) | 简体中文

## 技能索引

| 技能 | 目录 | 解决什么问题 | 一句话 |
| --- | --- | --- | --- |
| 磁盘清理 | [disk-cleanup](./disk-cleanup) | 盘快满了、清完又满、不知道空间去哪了 | 增量监控 + 回顾式归因 + 可回滚的安全清理 |

---

## 磁盘清理 `disk-cleanup`

> 完整规格见 [disk-cleanup/SKILL.md](./disk-cleanup/SKILL.md)。
> C 盘是最典型的场景，但这个技能并不绑定 C 盘：配置里的 `Drive` 和命令行的 `-Root` 都可以指向任意盘符或目录。
> 零外部依赖，任意 Windows（PowerShell 5.1+）直接可跑。

### 适用场景

- **盘快满了**：想知道到底是什么在吃空间，而不是对着一个红色的进度条发呆。
- **清完又满了**：清理没过几天又爆，想找到**持续增长的源头**并根治，而不是反复打扫。
- **最近涨了很多**：想回答"这一段时间到底涨在哪"，但手上没有历史基线。
- **想知道少掉的几十 GB 去哪了**：这段时间为什么少了 X GB。
- **想长期监控磁盘增长**，但不想装一个后台常驻服务。
- **想安全清理**：能预演、能回滚，而不是一把梭删文件然后祈祷。

### 核心能力

1. **增量监控（账本 diff）**
   每次运行都留下"目录树 + 账本"，**第二次运行就能给出精确 diff**——增长 Top15、减少 Top10、新增/消失目录数。
   不需要后台常驻，按需运行即可；跑得越勤越细，跑得稀也不缺基线。

2. **回顾式归因（单次运行自带答案）**
   靠"文件最后写入时间"的年龄直方图（≤7 / 30 / 90 / 365 天），**一次扫描就能说清"近 30 天涨了什么"**，并给出写入最多的 Top15 目录与按类别汇总。
   这不需要任何历史数据。

3. **定位"清理了又满"的根因**
   - **残差驱动的动态监控名单**：监控标记打在独立注册表（`registry/watch.json`）里，不绑目录层级。
     `残差 = 子树总量 − 已点名子项之和`，所以"只扫一层"也不会有盲区。
   - **闸门只看变化、不看绝对大小**：一个恒定 5GB 但不再增长的目录会被正常降级；一个每次只涨 120MB 但**持续**在涨的目录，会靠累计拿到名额。
     这正是"清完又满"的元凶通常长什么样。
   - **下钻链**：USN 变更目录 → 目录 mtime 变化 → 抽样 → 二分下钻。
   - **根治而非打扫**：定位到持续增长源后，按 [migration-guide](./disk-cleanup/references/migration-guide.md) 把缓存/数据目录迁出系统盘，从源头断掉增长。

4. **安全清理（清单 → 预演 → 确认 → 执行 → 复验）**
   - 白名单制：临时文件、更新下载缓存、着色器缓存、崩溃转储、WER、缩略图缓存、npm/yarn/uv/pip 缓存、浏览器 Cache（**不碰书签/密码/历史**）。
   - **默认只预演**，`-Execute` 才真正删；回收站必须显式 `-RecycleBin`。
   - **可回滚**：执行前先把整个计划落盘，再逐条执行并记录原路径；单条 ≥ `QuarantineMinMB`（默认 100MB）的条目是**移入隔离区而不是删除**，`clean-restore -Stamp <stamp>` 可原样放回。
   - 按龄过滤（`CleanMinAgeDays`，默认 7 天）、只清内容不删目录、占用中的文件跳过、执行后**对比卷剩余做复验**（不只信自己的估算）。
   - 绝不触碰：个人文件、已装软件、`System32`、`WinSxS`（只走 DISM）、`Windows\Installer`、`hiberfil/pagefile/swapfile`、OneDrive、UWP 数据。

5. **对账不变量（不骗人）**
   `卷已用变化 = 树内变化 + 非目录桶（休眠/分页/回收站/卷影/MFT/USN）± 差值`。
   差值大时明确提示提权重扫；未提权时卷影/保留存储/MFT/USN 不可见，报告会**明确写出盲区，不猜**。

### 优势

- **快——算法与工程上的关键设计**
  - 重活在 C# 引擎（`lib/DmScan.cs`），**PowerShell 只做编排与渲染**，绝不用 PS 遍历目录树（旧的 `+=` 写法在大盘上会跑几十分钟）。
  - 实测（Ryzen 5 5600 / NVMe）：单线程约 **1.2 万目录/秒**，4 线程约 **2–3.7 万目录/秒**，**40 万目录全盘约 20–35 秒**。
  - 目录树**前缀压缩 + GZip**，约 0.4MB / 3 万目录，保留 12 份。
  - **有界扫描**：`MaxSeconds`（默认 150 秒）/ `MaxDirs` 硬上限，到点即停并标 `CAPPED`——结果标注为不完整，**不会假装成功**。
  - **低优先级**：工作线程走 `THREAD_MODE_BACKGROUND_BEGIN`，只降工作线程不降整个进程，不拖慢调用它的 agent shell。

- **准——不靠"拍脑袋的基线"**
  按需模式下**绝不提前拍文件级基线**（拍不上）；需要文件名级时用提权读 USN 日志。
  `verify` 子命令带 28 项断言（引擎布局、账本对账、名单闸门、记录规则、清理回滚），随时自证可信。

- **省——时间序列只在有意义时才记**
  累计变化 ≥ `ThetaRecMB` 才落一个点（不是每次 `run` 都写），7 天心跳保底，硬上限 `KeepSeriesPoints`；清理时把该段合并成一行摘要，只保留最近 2 段明细。

- **可沉淀——agent 的结论会变成规则**
  agent 的语义判断（这是什么软件在用 / 能不能迁 / 能不能删）可以用 `agent-rule` 沉淀成规则（路径 glob → 归属 / 类别 / 可清理性 / 建议 + 有效期），下次同类目录直接命中，不再重复推理。

### 快速开始

```powershell
cd self_skill\disk-cleanup

# 全盘扫描 + 报告（默认 150 秒硬上限）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\diskmonitor.ps1 run
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\diskmonitor.ps1 run -Json   # 结构化输出，给 agent 用
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\diskmonitor.ps1 report      # 只看报告，不扫描
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\diskmonitor.ps1 diff        # 只要增量对比

# 清理：先预演，确认后再执行
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\diskmonitor.ps1 clean
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\diskmonitor.ps1 clean -Execute
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\diskmonitor.ps1 clean-restore -Stamp <stamp>   # 回滚

powershell -NoProfile -ExecutionPolicy Bypass -File scripts\diskmonitor.ps1 mark        # "记住现在"，留一个轻量检查点
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\diskmonitor.ps1 status
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\diskmonitor.ps1 verify      # 引擎自检 + 正确性断言
```

**该用哪条命令**

| 我想…… | 用 |
| --- | --- |
| 看看现在什么占空间 / 为什么涨 | `run` |
| 查这段时间为什么少了 X GB | `run` |
| 清理后又爆满，想找根源 | `run` → 看"回顾式归因"与"回涨"迹象 → 按 migration-guide 根治 |
| 盘快满了要释放空间 | `clean` 预演 → `clean -Execute` |
| 清完想反悔 / 恢复文件 | `clean-restore` → `clean-restore -Stamp <stamp>` |
| 确认结果可不可信 | `verify` |

### 目录结构

```
disk-cleanup/
  SKILL.md                    # 完整规格：设计前提、命令、报告结构、快照结构、闸门与残差、安全模型、性能边界
  config/diskmonitor.conf.json  # 全部可调参数（时间上限、阈值、保留份数）
  lib/
    DmScan.cs                 # C# 扫描引擎（按需编译）
    dm-core.ps1               # 编排核心
    dm-clean.ps1              # 清理计划与执行
    dm-report.ps1             # 报告渲染
  scripts/
    diskmonitor.ps1           # 统一入口
    disk_snapshot.ps1         # 旧入口：= run
    disk_report.ps1           # 旧入口：= report
    disk_clean.ps1            # 旧入口：= clean（默认预演）
    disk_newfiles.ps1         # 旧入口：= report
  references/
    migration-guide.md        # 把缓存迁出系统盘，从根源预防爆满
    growth-theory.md          # 增长归因是怎么算的
```

### 安全边界

- **脚本负责确定性**：采集、统计、阈值、下钻、对账、执行已批准的清理动作。**数字只能来自脚本。**
- **agent 负责语义**：解释"这是什么软件在用""能不能迁/能不能删""为什么涨"。**不得直接执行删除。**
- **人负责授权**：删除、迁移、提权、改系统设置。

---

## 新增一个技能

在仓库根目录建一个全小写、连字符命名的目录（如 `my-skill/`），至少包含 `SKILL.md`，然后：

1. 把技能放进目录，自包含、不依赖其它技能；
2. 在本 README 的**技能索引**里加一行（中英文两个版本都要加）；
3. 补一节「适用场景 / 核心能力 / 优势」。

运行时产生的数据（日志、缓存、快照等）请写进根目录的 `.gitignore`，不要提交。
