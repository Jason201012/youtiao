# 更新日志（Changelog）

## v2.9.3（2026-09-19）

### 功能增强（依据《有条功能增强建议报告（v2.9.2）》第一梯队 T1-1 ~ T1-4 全量落地）

#### T1-1 · 任务「预计时长」落库 + 今日智能排程建议（`lib/models/task.dart`、`lib/services/task_parser.dart`、`lib/services/schedule_advisor.dart`(新增)、`lib/widgets/new_task_sheet.dart`、`lib/screens/today_screen.dart`、`lib/screens/task_detail_screen.dart`）
- **时长终于落库**：自然语言解析器早已能识别「预计 45 分钟」，但 Task 模型没有对应字段，解析结果只能塞进备注文本——用户反复输入却永远不成为结构化数据。新增 `Task.estimateMinutes`（int?，JSON 同名键，范围夹取 1..43200 分钟，旧数据缺省 null 零迁移），`copyWith` 用 `_kKeep` 哨兵支持**显式清空**；解析器 `toTask()` 改落字段，`composedNote` 不再拼「预计X」（避免详情页出现两份重复信息）。
- **录入入口**：新建/编辑弹层新增「预计时长」区（15/30/45/60/90/120/240 快捷 chip + 自定义输入 + 一键清除），并纳入「有改动未保存」判定，避免只改时长后误关弹层静默丢失；快速录入解析出的值自动预填。
- **今日排程建议**（新增纯函数 `buildScheduleAdvice`）：按「截止时间 → 预计时长 → 优先级 → id」全序排序（全序保证同输入同输出），从当前时刻起串行顺延，给出每条任务的预计起止时刻、「预计超过截止」风险、「今天排不下」的超出分钟数，以及未设预估时用的兜底时长与条目数（明确标注「约」，不把占位值伪装成用户设定）。
- **偏差提示**：新增 `estimateBiasLabel`（±20% 容差、下限 5 分钟），任务详情展示「可能高估 / 可能低估」，与排程建议共用同一函数，两处口径不会漂移。
- **导出补齐**：任务表新增「预计时长(分钟)」列（CSV / Excel 共用 `taskTableHeaders` 单一真源，15 → 16 列），Markdown 行内附「预计 X」。

#### T1-2 · 习惯「量化目标值」打卡（计数型习惯）（`lib/models/habit.dart`、`lib/models/checkin.dart`、`lib/state/habit_provider.dart`、`lib/screens/habit_screen.dart`、`lib/models/today.dart`、`lib/models/period_review.dart`、`lib/models/review.dart`、`lib/services/daily_briefing.dart`）
- **模型**：`Habit.dailyTarget`（null = 布尔打卡，向后兼容）+ `CheckIn.value`（当日累计量，≥1，旧记录缺省 1）。「每天喝 8 杯水」「阅读 30 分钟」这类定量习惯从此有承载。
- **写盘单一入口**：所有打卡写入（打卡 / +1 / 设数量 / 补卡 / 撤卡）收进 `setCheckInValue`（值为 0 即删除记录），顺带消除「某个入口忘记重排提醒」的经典缺陷。
- **统计口径统一为「达标日」**：新增内部 `_metDaysOf`（量化习惯需当日累计量 ≥ 每日目标），连续天数、累计达标天数、周目标进度、连续达成周数、周报/月报、晚简报「习惯达成」、23:00 漏卡挽留全部改按达标判定——否则「只喝了 1 杯」也会被当成完成，统计系统性虚高。布尔习惯两者等价，**旧数据行为零变化**。
- **UI**：习惯列表量化行显示「今日 x/y」+「+1」圆钮（点击累加并在**达标那一刻**播放连续天数庆祝，长按直接设数量）；详情页新增「今日进度」块（进度条 + 设置数量 + 清空今日）；热力图对量化习惯按当日达成度四档着色；今日页量化习惯改为「+1」累加（不再误用「已打卡 / 取消打卡」）；新建与编辑弹层均可设每日目标量。
- **导出**：习惯表补「每日目标」「宽限日」两列，打卡记录表补「累计量」列；Markdown 附累计量与目标。

#### T1-3 · 任务一键转习惯的完整字段迁移（`lib/services/habit_migration.dart`(新增)、`lib/state/habit_provider.dart`、`lib/screens/task_detail_screen.dart`）
- **原实现只搬标题**：用任务标题建一条「每天、无提醒、无周目标」的习惯，星期、提醒时刻、每周循环次数全部丢失，用户还得去习惯页重设一遍。现新增纯函数 `HabitDraft.fromTask`，按规定映射迁移：打卡日（每周X → 相同星期；仅工作日 → 周一~周五；每天/每隔1天 → 每天）、提醒时刻（优先重复提醒时刻，其次截止时间的时分，两者皆无则不提醒——不擅自替用户安排打扰时间）、周目标（每天 7 / 工作日 5 / 每周X天 X / 每隔N天 ⌈7/N⌉ / 每月 1）。
- **如实告知折算**：无法用「星期 + 周目标」表达的规则（`每隔 N 天`、`每月`）会在**转换预览弹层**里明确写出折算结果，避免「转完发现提醒节奏变了」的黑箱感；确认后再询问原任务是保留还是删除（删除走回收站可恢复）。

#### T1-4 · 习惯管理入口补齐：提醒时刻编辑 / 删除撤销 / 补卡升级 / 宽限日（`lib/state/habit_provider.dart`、`lib/screens/habit_screen.dart`、`lib/models/habit.dart`）
- **编辑层补齐三项**：此前编辑弹层只能改名称/星期/周目标/归档，**没有提醒时刻**——而列表页的提醒 chip 只在「已有提醒」时渲染，于是「建习惯时忘了设提醒」等于永远没有入口补设。现编辑层新增「每日提醒时刻」（可设可清）、「每日目标量」、「宽限日」三行；`updateHabit` 相应增收 `reminderMinute`/`clearReminder`/`dailyTarget`/`clearDailyTarget`/`graceDays`，且**只在提醒相关字段真的变化时**才取消重挂系统闹钟（改个名字不再无谓抖动调度）。
- **删除可撤销**：`deleteHabit` 改为返回 `DeletedHabit` 快照（习惯本体 + 全部打卡记录 + 原列表下标），新增 `restoreHabit` 原样放回（幂等：同 id 已存在则不重复插入），删除后 SnackBar 提供 10 秒「撤销」。此前一次误触就永久抹掉连续天数与全部历史打卡，而任务侧早就有撤销，属明显的交互不对等。
- **补卡升级为「补卡 / 撤卡 / 改数量」**：已打卡的日期原先只弹一句「已打过卡」就结束，补错的卡无法取消、也无法修正数量。现改为三选一（撤销打卡 / 修改数量 / 取消），无记录时量化习惯还可填「那天到底做了多少」。
- **宽限日**：`Habit.graceDays`（0..3）——每周允许若干天计划日缺卡而不断签，缺卡消耗当周额度、额度用尽才断签。streak 计算同时合并了原先分叉的「自然日」与「计划日」两套实现为单一 `_streakFor`，`graceDays = 0` 时与旧行为逐位一致（回归测试钉死）。

> 说明：本版为功能增强，未新增任何网络调用，全部能力纯本地计算，沿用「严格离线」红线。

---

## v2.9.2（2026-09-19）

### 功能与操作审计修复（依据《有条功能与操作审计报告（v2.9.1）》：P1=0、P2×7、P3×14、U1×1、U2×4、U3×3 全量落地）

#### P2-1 · 「完成」与「跳过」互斥横向推广到全部入口（`lib/state/task_provider.dart`）
- v2.9.1 只把互斥做进详情页弹层专用的 `markOccurrenceDone`：首页 / 今日页勾选走 `toggleDone`、看板拖拽走 `setStatus`、反向的 `skipOccurrence` 全都绕过去了——同一天同时进入 `doneDates` 与 `skipDates` 后，撤销跳过当天仍被判为已完成、提醒不回弹、完成统计虚计。
- 新增 `_clearSkipFor` / `_clearDoneFor` 两个写盘助手，四个入口共用同一口径；`markOccurrenceDone` 改为复用。

#### P2-2 · iCal 转义解码改单趟左到右（`lib/services/ical.dart`）
- 旧实现是两趟 `replaceAll`（先实体后反斜杠），无论顺序如何都会把标题里**字面**的 `\n` / `\t` / `\\` 解错（`a\nb` 往返后变成「a + 真换行 + b」）。现改为逐字符扫描、`\` 一次性消费两个字符并**不回扫**，往返完全守恒；未知转义原样保留。

#### P2-3 · 日历拖拽改期的守卫漏算提醒提前量（`lib/screens/calendar_screen.dart`）
- 注释声称比较 `dueDate − reminderOffsetMin`，实现却只比 `dueDate`：截止明日 10:15、提前 30 分钟提醒的任务，今天 10:00 拖到今天 10:15 不弹确认，保存后提醒 09:45 早已过去 → 静默丢提醒。现按提醒时刻判定，并在弹窗里带出提前量。

#### P2-4 · 周重复 `BYDAY=MO..SU` 不再被误判为「仅工作日」（`lib/services/ical.dart`）
- 旧判据「长度 ≥5 且包含周一~周五」会被 7 天全选命中，往返时周六日静默丢失。现收紧为「**恰好**等于 MO-FR」。

#### P2-5 · CSV 导出补 UTF-8 BOM（`lib/services/csv_safe.dart`、`lib/widgets/export_sheet.dart`）
- 简体中文 Windows 的 Excel / WPS 无 BOM 时按 ANSI（GBK）解码，中文全量乱码、功能形同失效。现 CSV 首部写 `U+FEFF`（`withUtf8Bom` 幂等），Markdown / JSON 不加。

#### P2-6 · CSV / Excel 任务表补齐字段（`lib/state/task_provider.dart`、`lib/services/report_exporter.dart`、`lib/widgets/export_sheet.dart`）
- 两处原来各写一份 8 列结构，都缺备注、标签、子任务、开始时间、重复规则 / 提醒时刻、累计专注——把可读副本当归档副本用时不可逆丢数据。现列与取值收进 `TaskProvider.taskTableHeaders` / `taskTableValues`（单一真源，CSV 与 Excel 共用），8 列 → 15 列；导出弹层副标题同时明示「可读副本，完整数据请用备份」。

#### P2-7 · 更新链路强制签名门槛收口 + 取消「仍要安装」兜底（`lib/services/update_policy.dart`、`lib/services/update_checker.dart`、`lib/widgets/update_download_dialog.dart`）
- 门槛退化为**无条件强制**：不再保留「本地与清单自报版本均 < 2.8.0 时可接受无签名清单」的渐进兼容尾巴，预发布形态（`2.9.0-beta`）也不再豁免。清单签名是唯一的「来源可信」锚（`apkSha256` 由同一份清单自带，只能证明文件与清单一致）。
- 清单**缺 apkSha256** 时不再提供「仍要安装（风险自担）」路径：一律拒绝下载、删除半成品，改由「浏览器下载」兜底。

#### P3-1 · 导出 `DUE` 自「提醒未过去」的首个循环日起算（`lib/services/ical.dart`）
- 上午导出「每天 07:00」的任务会写出今天 07:00 的落点 + `TRIGGER:PT0S`，第三方日历同步后立刻补响过期提醒。现与 occurrence_sheet「今天提醒已过则自明天起算」同口径。

#### P3-2 · 「已结束重复」角标横向推广（`lib/widgets/today_card.dart`、`lib/screens/today_screen.dart`、`lib/widgets/share_card.dart`）
- 今日卡片、今日页、分享长图此前仍对已结束重复的任务显示「每天 07:00 至 …」。现统一显示「已结束重复」。

#### P3-3 · 「仅此一次改期」目标日 == 原日时不再同日产生两条任务（`lib/state/task_provider.dart`、`lib/screens/task_detail_screen.dart`）
- 旧算法因 `isAtSameMomentAs` 恒为 false，把「今天改到今天」走成「skip 今天 + 新建一条 dueDate=今天的一次性副本」，同一天两条任务且副本提醒已过、静默不响。现整体无操作并给出反馈。

#### P3-4 · interval 重复跨夏令时不再漂移（`lib/models/task.dart`）
- `difference().inDays` 是绝对时距，跨 DST 会把 7 个自然日算成 6 天 23 小时 → 相位整体错位。改用 UTC 零点求差。

#### P3-5 · iCal 属性值不再被 `trim()`（`lib/services/ical.dart`）
- RFC 5545 值内空白有意义（`SUMMARY:  foo` 的前导空格属于标题）。现结构判定仍用 trim 后的行，属性值取自原始行。

#### P3-6 · `FREQ=WEEKLY` 无 `BYDAY` 以落点周几为锚（`lib/services/ical.dart`）
- 第三方合法写法此前静默默认周一，会把「每周三」搬成「每周一」；同时合并了 `days.length==1` 与 `isNotEmpty` 的重复死分支。

#### P3-7 · 秒级 `TRIGGER` 取最近分钟 + 重复提醒迁移统计如实（`lib/services/ical.dart`）
- `-PT90S` 原向下取整为 1 分钟（少 30 秒）、`-PT30S` 变成「准点」。现四舍五入到最近分钟；重复任务的提醒由 `repeatMinute` 表达，只有提前量为 0 时才真正迁移（并回填 `repeatMinute`），非零提前量如实计入「提醒未迁移」。
- 另修一处往返污染：`VALARM` 内的 `DESCRIPTION` 会在 VTODO 无备注时顶替成备注（导出→导入把备注污染成标题），现按 `ALARM.` 前缀隔离存放。

#### P3-8 · `csvCell` 剥离集覆盖 BOM / NBSP 等 Unicode 空白（`lib/services/csv_safe.dart`）
- `\uFEFF=evil`、`\u00A0=1+1` 这类「Unicode 空白 + 公式引导符」此前拿不到前置单引号，与「前导空白全覆盖」的注释不符。

#### P3-9 · 看板泳道宽度按「列数」扣间距（`lib/widgets/kanban_board.dart`）
- 每列都带 `margin.right: 8`（含最后一列），旧算法扣「列数 − 1」，未夹取时整行实宽 = 可用宽 + 8，宽屏下莫名其妙多出 8px 溢出与滚动条。

#### P3-10 · Markdown 导出不再套用 `csvCell`（`lib/state/task_provider.dart`、`lib/state/habit_provider.dart`）
- `csvCell` 的职责是防 Excel 公式执行，Markdown 没有该执行面：套用会给 `=` 开头的标题硬加 `'` 前缀、把引号变成 `""`，污染可读副本。

#### P3-11 · 标签泳道同频时按字典序次级排序（`lib/widgets/kanban_board.dart`）
- Dart 的 `List.sort` 非稳定排序，同频标签的先后依赖实现内部顺序，与「顺序稳定可复现」的注释不符。

#### P3-12 · 更新清单拉取补最终落地主机白名单（`lib/services/update_checker.dart`）
- 默认 `http.Client` 会自动跟随重定向且不校验目标主机，与 APK 下载器的逐跳白名单不对称；现对最终 URL 校验主机（内容签名仍为最终兜底）。

#### P3-13 · 清单字段读取改为 `toString` 容错（`lib/services/update_checker.dart`）
- `as String?` 遇到 JSON 数字（如 `"version": 2.9.2` 少了引号）会抛 TypeError，被外层 catch 兜成无上下文的错误，并绕过「缺失签名」的明确拒绝分支。

#### P3-14 · 预发布版本同样强制验签（`lib/services/update_policy.dart`）
- 长期停留在预发布版的设备此前与 P2-7 拥有同一条投毒面。

#### U1-1 · 详情页「本次跳过」不再假成功（`lib/screens/task_detail_screen.dart`）
- 非循环日点击仍弹「已跳过今天这一次」，实际只往 `skipDates` 塞了一个无效日期（日后规则覆盖该日时会永久静默跳过）。现禁用按钮并改文案「今天不是循环日」；任务已「结束重复」时整块重复管理区（跳过 / 改期 / 预览）不再展示。

#### U2-1 · 首页标题不再被锁 80px（`lib/widgets/task_row.dart`）
- 80px 是 v2.4.1 为「无界宽度」场景加的兜底，但拖拽重排默认常开 → 每行标题恒 80px，长标题只剩 ~8 字、备注 / 标签 chips 竖排堆叠。现用 `LayoutBuilder` 探真实可用宽：有界即放开 `Expanded`，仅无界 / 过窄才回退 80px。

#### U2-2 · 「仅此一次改期」补结果反馈（`lib/screens/task_detail_screen.dart`）
- 目标日恰为循环日（只跳过、不建副本）时页面静默 pop，用户找不到副本。现按返回值分支提示：同日无变化 / 循环日覆盖未建副本 / 已建一次性副本。

#### U2-3 · 「无操作自动锁定」依赖联动（`lib/screens/settings_screen.dart`）
- 应用锁未开启时该设置静默无效。现依赖未满足时禁用整行，副标题点明需先开启「应用锁」。

#### U2-4 · 日历可进入任务详情（`lib/screens/calendar_screen.dart`）
- 日期弹层里此前只有勾选框可点，整个日历模块没有到达详情页的路径。现任务行整行可点（含右侧箭头），收起弹层后推详情页。

#### U3-1 · 撤销时限文案与时长统一（`lib/screens/home_screen.dart`、`lib/screens/task_detail_screen.dart`）
- 确认框写「可在 5 秒内撤销」而 SnackBar 只有 4 秒。现统一为 5 秒；详情页删除文案改为如实说明「移入回收站，可在设置 → 回收站中恢复」。

#### U3-2 · 撤销路径指引改正（`lib/screens/task_detail_screen.dart`）
- 「长按任务行的重复标签」实际是**点按**（长按会进多选）。

#### U3-3 · 开启加密备份时注明口令来源（`lib/screens/settings_screen.dart`）
- 已设过口令时再次开启加密会静默沿用旧口令，现副标题注明「沿用已存口令」并指向「修改 / 重置备份口令」。

### 质量
- 新增 `test/v291_audit_fix_test.dart`（25 用例）钉死上述口径；全量测试 **627 项通过 / 0 失败**（基线 602 + 新增 25）；`dart analyze lib test` 零 error。

## v2.9.1（2026-09-18）

### 功能与操作审计修复（依据《有条功能与操作审计报告（v2.9.0）》：P2-1、P3-1~P3-6、U1~U4 全量落地）

#### P2-1 · 与系统日历互通：提醒段双向打通（`lib/services/ical.dart`）
- **导出**：`VTODO` 内新增 `VALARM` 提醒段——非重复任务按 `reminderOffsetMin` 写 `TRIGGER:-PT{n}M`（`0` 表示与落点同时刻，写零时长 `PT0S`；RFC 5545 不允许 `-PT0M` 这种「负零」）；重复任务的 `DUE` 由「录入侧占位值」改为**今天起首个循环日 + `repeatMinute`** 的真实落点，配 `TRIGGER:PT0S`。此前导出既不写提醒、重复任务的 `DUE` 又常为 `null`（RRULE 无起点），导入第三方日历后「到点不响」却显示同步成功。
- **导入**：解析 RFC 5545 `TRIGGER`（含 `-P1DT2H` 等复合时长、`PT0S`）与 vCalendar 1.0 `AALARM`（绝对时刻，与落点求差）→ 回填 `Task.reminderOffsetMin`；新增 `IcsImportResult.reminderMigrated` / `reminderDropped`，无法表达的形态（如「晚于落点才提醒」）在导入对话框与结果文案里**如实提示「提醒未迁移」**，不再静默丢失。

#### P3-1 · 更新清单「强制签名」门槛改以本地版本为准（`lib/services/update_checker.dart`）
- 旧口径只看清单自报的 `version`：把版本号改小（如 `2.5.0`）并删除 `signature`，即可让「是否强制验签」退化为否——虽不会下发旧版本，但能**压住修复推送**使安全问题无法到达设备。
- 现判定为 `requiresMandatorySignature(本地版本) || requiresMandatorySignature(清单自报版本)`：装在 2.8.0+ 的设备遇到缺签名清单**一律拒绝**。

#### P3-2 · 未来循环日预览窗口口径（`lib/models/task.dart`、`lib/widgets/occurrence_sheet.dart`）
- 窗口此前恒从「今天」起算：上午 10 点打开「每天 07:00」的预览，今天仍排第一行且可操作，而提醒早已响过。
- 现规则：今天仍是循环日 **且** 提醒时刻已过 **且** 今天既未跳过也未完成 → 自明天起算，并在标题注明「今天的提醒时刻已过，自明天起算」；今天已跳过 / 已完成时保留今天（撤销入口不可隐藏）。
- 新增 `Task.occursOnIgnoringSkip`（`_repeatsOnIgnoringSkip` 的公开入口），供 UI 复用「忽略跳过」的日历判定。

#### P3-3 · 跳过与完成互斥（`lib/state/task_provider.dart`、`lib/widgets/occurrence_sheet.dart`）
- `markOccurrenceDone` 命中 `skipDates` 的日子时**原子撤销跳过**，杜绝同日同时进入 `doneDates` 与 `skipDates`（否则撤销跳过后当天仍被判为已完成、提醒不回弹，UI 等于说谎）。
- 弹层菜单改互斥：已跳过的日期只提供「撤销跳过」，不再出现可点的「标记完成」。

#### P3-4 · 看板分组模式持久化（`lib/widgets/kanban_board.dart`）
- 分组模式（状态 / 分类 / 标签）写入 `SharedPreferences`（键 `kanban_group_mode`），宿主重建 / 重启后沿用上次选择（此前是纯页面内存态，习惯标签视图的用户每次都要重切）。读写失败均静默回退默认，不影响看板可用性。

#### P3-5 · 历史 5 条测试失败归零（`test/*`、`lib/services/csv_safe.dart`）
- `task_repeats_on_test` / `undo_delete_anchor_test` **无法编译**（`Task` 缺 required 的 `priority`/`category`、`_installMocks` 未定义）→ 补齐构造参数与 mock 装配；
- `task_provider_test` 的 `clearSampleTasks` ×2 缺 `flutter_secure_storage` 通道 mock（`read`→null / `containsKey`→false / `readAll`→`{}`）→ 补上；
- `csv_injection_test` 双引号断言与实现不符 → **修的是实现**：`csvCell` 的公式判定面从「转义后」改回「转义前的原始值」，且前导双引号也算可忽略字符。此前 `"=evil"` / `"=evil` 会漏拦，而写出行又把字段包在 `"` 里，宽容解析器还原出的单元格仍以 `=` 开头。断言同步更正。
- 顺带移除 `task_provider.dart` 一处无引用的 `_fmtMinute` 死代码（静态分析提示）。

#### P3-6 · 「移到下一天」的跳过痕迹（`lib/widgets/occurrence_sheet.dart`）
- 目标日本就是循环日时只走 skip 不建副本，此前仅靠一条 4 秒 SnackBar 说明；现被跳过的那一行标注「已跳过（经「移到下一天」）」（会话级痕迹，零新增持久字段），SnackBar 时长 4s → 8s。

#### U1 · 详情页「本次跳过」撤销窗口（`lib/screens/task_detail_screen.dart`）
- 撤销气泡 5s → 10s，文案同时给出常驻路径（长按任务行的重复标签 → 「未来循环日预览」），与弹层的「撤销跳过」入口联动（两处走同一个 `unskipOccurrence`）。

#### U2 · 标题显示统一为 2 行（`lib/widgets/task_row.dart`、`lib/screens/calendar_screen.dart`）
- 任务行标题放开到 2 行，容器由固定高度改为 `minHeight`（单行标题外观与原先一致，长标题整行自动增高）；日历列表 / 日程条 2 行，月视图密集条保持 1 行（格子高度固定，2 行会溢出）。

#### U3 · 「已结束重复」角标（`lib/models/task.dart`、`lib/widgets/task_row.dart`）
- 新增派生标记 `Task.repeatEnded`（`isRepeating` 且 `repeatUntil` 早于今天，零 schema 变更）；卡片显示「已结束重复」角标，替代此前仍按重复样式渲染的「每天 07:00 至 …」，避免 `endRepeat(markDone:false)` 后被误认为已删除。

#### U4 · 看板泳道宽度自适应（`lib/widgets/kanban_board.dart`）
- 新增 `kanbanLaneWidthFor(可用宽, 列数)`：窄屏（<600dp）沿用 220；宽屏按可用宽铺满并夹在 200~280，平板 / 横屏下不再「一列 220 宽、右侧大片空白」；列数过多时仍夹到下限并保留横向滚动（「有界宽度」前提不变）。

### 说明
- **测试**：新增 `test/v290_audit_fix_test.dart`（21 用例，覆盖 iCal 提醒段导出/导入往返、`occursOnIgnoringSkip`、跳过与完成互斥、`repeatEnded`、看板模式解析、泳道宽度矩阵）；`test/kanban_lane_layout_test.dart` 因 U4 调整列宽语义，原 220 断言改用窄屏画布，并新增宽屏自适应用例。
- **验证**：全量 `flutter test --no-pub` → **602 通过 / 0 失败**（历史 5 条预存失败全部闭环）；`dart analyze lib test` 改动文件零 error / 零 warning（仓库既有 44 条 warning 均在未触碰文件）。
- **严格离线红线**：纯本地改动，未新增除现有 update-check 之外的任何网络调用。
- **无破坏性机制变更**：通知 id 方案号维持 4，存量用户升级后无「首启重建提醒」类一次性动作。

## v2.9.0（2026-09-13）

### 看板布局修复（泳道「有界宽度」——修掉一处 debug 断言与一处静默降级）
- **背景（既有缺陷）**：看板泳道的泳道头是 `Row + Spacer()`（计数需要右对齐）、卡片标题是 `Expanded(Row + Spacer)`（需要换行填充），二者都要求父级给出**有界宽度**；但 Flutter 的 `Row` 给「非 flex 子项」的约束只有 `maxHeight`、`maxWidth` 是**无界**的。此前泳道作为普通子项直接塞进 `Row`，拿到无界宽度：
  - debug 构建：布局阶段抛断言 `RenderFlex children have non-zero flex but incoming width constraints are unbounded`；
  - release 构建：断言被编译掉，`RenderFlex` 把无界约束下的 flex 子项按非 flex 处理 → `Spacer` **静默塌成 0**（泳道标题与计数紧贴）、卡片宽度按内容自适应 —— 注释里承诺的「双列等宽铺满」其实从未实现。
- **修复 · 状态模式（双列等宽铺满）**：两条泳道改为 `Expanded` 子项，各占一半宽度，泳道头 `Spacer` 与卡片 `Expanded` 恢复正常，「等宽铺满」真正落地。
- **修复 · 分类 / 标签模式（固定列宽）**：这两类泳道位于横向滚动视口内（宽度必然无界，`Expanded` 在此同样非法），改为给每条泳道固定宽度 **220px** —— 同样满足「有界宽度」前提，同时保留「列数可变 + 横向滚动」的既有交互。

### 说明
- 新增 `test/kanban_lane_layout_test.dart`（4 用例，覆盖三种分组模式：状态双列等宽 / 状态空列不塌陷 / 标签固定 220 且横向滚动保留 / 分类三条均 220）；核心断言为「布局阶段无异常」+ 泳道宽度（等宽或 220）。两处修复各自做过**反向验证**（临时移除 `Expanded` 或 `SizedBox` 时对应用例必然以该断言失败，且互不影响）。
- 全量测试 **571 通过 / 5 预存失败（历史基线）**，零回归；`dart analyze` 改动文件零 error / 零 warning。
- 严格离线红线：纯本地改动，未新增除现有 update-check 之外的任何网络调用。
- 无破坏性机制变更：存量用户升级后无「首启重建提醒」类一次性动作（通知 id 方案号维持 4）。

## v2.8.9（2026-09-13）

### 功能与操作审计修复（依据 v2.8.8 审计报告 P2-1 / P2-2 / P3-1~3 全量落地）
- **P2-1【P2】手动「从备份恢复」后偏好类设置不在当前会话生效**：`applyAppPrefs` 只把偏好写回 SharedPreferences，而免打扰时段、延后时长、回收站保留期、专注与周目标、自动备份开关、早晚简报与习惯挽留时刻、日历农历、锁屏隐私等**全是 `load()` 读入的内存字段**；原实现仅 `notifyListeners()` 刷 UI，导致恢复后设置页仍显示旧值、行为仍按旧值运行（且 `rescheduleFixedTimeReminders` 按旧时刻把简报与挽留重排一遍），需重启才生效。现手动恢复路径补齐与自动备份还原路径**完全一致**的 Provider 重载（`task / focus / habit / theme / onboarding.load()` + `appLockProvider.refreshEnabled()`——AppLock 不能 `load()`，否则立即锁屏），恢复即时生效。
- **P2-2【P2】「跳过一次」无撤销入口（误触不可逆）**：详情页「本次跳过」原为点击即关页、无确认无撤销；且「未来循环日预览」里**已跳过的日子根本不会显示**——`occurrencesBetween` 复用 `repeatsOn`，而后者会排除 `skipDates`，使弹层的「已跳过 / 撤销」分支成为不可达死代码。现新增 `Task.occurrencesBetweenIncludingSkipped()`（把 `repeatsOn` 的 skip 一段拆为 `_repeatsOnIgnoringSkip`）作为弹层数据源，让已跳过行可见；弹层菜单按状态互斥（已跳过 → **撤销跳过**，不再展示两个必然 no-op 的项），列表头部标注「含 N 个已跳过」；详情页「本次跳过」补 SnackBar 撤销。
- **P3-1【P3】日历拖拽改期到过去日期无提示**：日历 `_reschedule` 是 v2.8.4「同一件事提示口径统一」里唯一漏网的入口，可静默把任务拖到昨天/上周（改完立刻变「逾期」且提醒永不触发）。现接入统一守卫 `PastDueGuard.confirm`，与新建 / 详情页改期 / 批量改期 / 逾期区顺延同口径；取消则中止本次改期、不写库。
- **P3-2【P3】日历可拖动重复任务、改出无意义的占位 `dueDate`（假成功）**：重复任务的提醒与循环由 `repeatMinute / repeatUntil / skipDates` 表达，`dueDate` 自 v2.8.5 起只是占位；原实现仍允许拖拽并写入，用户看到「已改期至 X」却当天照常循环、提醒时刻不变。现对重复任务**禁用拖拽改期**（长按给出「请在详情页使用『仅此一次改期』」提示），两处 `DragTarget` 一并拒绝重复任务作兜底。
- **P3-3【P3】看板「标签」分组多标签任务跨泳道重复、计数虚高**：此前带多个标签的任务会在每个命中的标签泳道各出现一次，泳道计数之和大于实际任务数（与「状态 / 分类」的互斥口径不一致）。现改为「每个任务只归入其第一个命中的 top 标签」（按频次降序优先，顺序稳定可复现），空泳道自动隐藏，「其他」语义不变（收纳不含任何 top 标签的任务，含无标签任务）；分组口径抽为纯函数 `buildKanbanLanes`，可被单测直接钉死。

### 说明
- 新增 `test/v289_audit_fix_test.dart`（9 用例）；`dart analyze` 改动文件零 error / 零 warning；全量测试 **567 通过 / 5 预存失败（历史基线）**，零回归。
- 全部修复保持严格离线红线：纯本地路径，未新增除现有 update-check 之外的任何网络调用；三站（Gitee releases-3 + 内网 Forgejo + GitLab 8567）发布，release keystore 签名，arm64-v8a 单架构。
- 无破坏性机制变更：存量用户升级后无「首启重建提醒」类一次性动作（通知 id 方案号维持 4）。

## v2.8.8（2026-09-12）

### 功能与操作审计修复（依据 v2.8.7 审计报告 P2-1 / P2-2 / P3-1~4 全量落地）
- **P2-1【P2】恢复备份 / 换机后「提醒时区」静默丢失**：`reminder_timezone_override` 纳入备份偏好白名单（`prefs_backup`），恢复侧新增 `NotificationService.reloadTimezoneOverride()` 重解析内存时区并应用到本地时区；手动恢复与自动快照还原两条路径同步接入。
- **P2-1 配套【P2】**：恢复备份后自动重建被 `restoreFromJson` 内 `cancelAll` 清空的早晚简报 / 习惯挽留 / 回收站预告 / 习惯打卡提醒（既有缺口：原流程只重排任务提醒，重启前其余提醒静默失效）。
- **P2-2【P2】切换提醒时区后固定时刻提醒不重排**：新增 `daily_briefing.rescheduleFixedTimeReminders()`，一并重排简报×2、习惯挽留、回收站预告（与 `onDayChanged` 全量入口对齐），时区切换即时生效，不再按旧时区错时响一次。
- **P3-1 / P3-3【P3】**：帮助页 FAQ 与设置行副标题说明「提醒时区」能力边界；设置页新增「自定义 IANA 时区」入口（`tz.getLocation` 校验）+ 切换后反馈。
- **P3-2 / P3-4【P3】**：`_invalidateArmedCache()` 内绑定清 `_occurrenceMemo`，杜绝「已过落点补弹」的缓存失效不同步；CHANGELOG 补齐 v2.8.5 / v2.8.6 版本记录（v2.8.7 / v2.8.8 于本次一并补录）。

## v2.8.7（2026-09-12）

### 功能与操作审计修复（依据 v2.8.6 审计报告 P1-1 / P2-1~4 / P3-1~3 全量落地）
- **P1-1【P1】首页拖拽排序双基准**：首页五分区直接消费 `TaskProvider.homeTasks`（`pinned → order → 日期` 三级）同一份序列，删除 home_screen 本地排序；拖拽仅在 `filter==all && 无标签筛选` 下开启，UI `dragIndex` 与 `reorderTasks` 共享索引空间，`newIndex` 按 ReorderableListView「移除后下标」语义对齐——拖错任务 / 排序回跳不再可能。
- **P2-1【P2】编辑弹层脏检测漏提醒字段**：`_isDirty` 基线补齐 `repeatTime / repeatWeekdays / repeatInterval / repeatUntil / reminderOffsetMin` 五组字段，离开弹层不再静默丢弃改动。
- **P2-2【P2】改期副本完成历史双算**：`rescheduleOnceOccurrence` 显式 `doneDates: const []`，顺延不再把原日完成记录带到新副本、重复计入统计。
- **P2-3【P2】提醒时区硬编码**：调度时区改为「设置页覆盖 > 原生 `getTimeZoneId` > 偏移扫描兜底 > UTC」四级解析；设置页新增「提醒时区」，变更后经 `rescheduleAllNotifications` 全量重排。
- **P2-4【P2】换口令后旧加密快照残留**：`changeAutoBackupPassphrase` 把旧口令快照改名 `.stale.enc.json`，`listAutoBackups` 跳过 stale 项，按日期自然滚动淘汰；UI 明示失效份数。
- **P3-1【P3】习惯通知 id `String.hashCode` 跨引擎不稳定**：改自实现 FNV-1a；`_kNotifIdScheme` 3→4，升级首启 `cancelAll` 后全量重建（存量用户首次启动会重建全部提醒）。
- **P3-2【P3】更新重定向端口白名单缺口**：`_isHttpsAllowedHost` 补 `uri.port != 443` 拒绝，显式端口与省略端口口径一致。
- **P3-3【P3】15 分钟守护全量扫描开销**：新增落点内容缓存 `_occurrenceMemo`（`_repeatContentSig` 签名），守护轮复用上一轮落点，千级任务省去逐日重扫；勿扰 / 时区变更时失效。

### 说明
- 新增 `test/v286_audit_fix_test.dart`（9 用例）；`dart analyze lib test` 零新增 error；全量测试 553 通过 / 5 预存失败（历史基线），零回归。
- 全部修复保持严格离线红线：纯本地路径，未新增除现有 update-check 之外的任何网络调用；三站（Gitee releases-3 + 内网 Forgejo + GitLab 8567）发布，release keystore 签名，arm64-v8a 单架构。

## v2.8.6（2026-09-12）

### 功能与操作审计修复（依据 v2.8.5 审计报告 F-1~F-11，10/11 落地）
- **F-1【P2】调度互斥**：新增 `shouldScheduleDeadlineReminder` 判定——重复任务不再同时挂一次性截止提醒；`_rescheduleAllActive` 幂等 cancel 清理存量「双响」闹钟。
- **F-2【P2】改期副本撞循环日**：`rescheduleOnceOccurrence` 对「daily 改到明天」等与循环落点重合的场景只 skip 不建副本；task_detail 改期接入 PastDueGuard。
- **F-3【P2】`endRepeat(markDone:)` 双动作弹窗**：结束重复时可同时完成当日实例，消除语义歧义。
- **F-4【P2】习惯 streak 口径**：`_plannedStreakFor` 按 weekdays 计划日计算连续天数，非计划日不再断签。
- **F-5【P2】原生回收站清理残留**：到期清理补删附件目录（`dataDir/app_flutter/attachments`），并按 id 段取消对应通知。
- **F-6【P3】勿扰起止相等的提示分支**：起止相同视为全天不限制并在 UI 明示。
- **F-7【P3】默认提醒时刻统一**：抽共享常量 `kDefaultRepeatMinute = 07:00`，快速录入与编辑弹层两条路径对齐（v2.8.3 F-04 残留闭环）。
- **F-8【P3】非法 `repeatUntil` 自愈**：清空非法值 + `_healRepeatAnchors` 补齐 interval 缺失锚点。
- **F-9【P3】删除 120 行不可达死算法**。
- **F-10【P3】（核对后仅部分成立）**：`ical.dart` 早已解析 DAILY/WEEKLY/MONTHLY 并对降级计数，本轮仅补 `partialRepeat` 部分保留计数。
- **F-11【P3】interval 扫描窗自适应**：按间隔与锚点动态调整逐日扫描窗口，避免长间隔漏算。

### 说明
- 新增 `test/v285_audit_fix_test.dart`（约 20 用例）；`occurrence_undo` / `repeat_reminder_fix` 旧用例按 F-2 新语义改造；全量测试 544 通过 / 5 预存失败，零回归。

## v2.8.5（2026-09-12）

### 功能与操作审计修复（依据 v2.8.4 审计报告 F-1~F-11 全量落地）
- **F-1【P1】调度门槛只由 `repeatUntil` 决定**：删除「dueDate 未过」多余分支，修复 P1 级「静默丢提醒」。
- **F-2【P1】重复提醒全改「一次性闹钟 × 预挂 8 次」**：新增纯函数 `repeatOccurrenceTimes` / `habitOccurrenceTimes`（消费 `repeatsOn` + `isDoneOn`），复杂每月规则与系统月循环漂移一并根治。
- **F-3【P2】勿扰顺延接入重复 / 习惯提醒**。
- **F-4【P2】改期副本取 `repeatMinute`**，不再丢失提醒时刻。
- **F-5【P2】`endRepeat` 清 `dueDate`** + `_effectiveDue` 中性化 + home_screen 分区口径改 `isRepeatEnded`。
- **F-6【P2】补每月「月内第 N 个周几」规则 UI**。
- **F-7【P2】`Task.pruneHistory` 400 天滚动窗口**，完成历史不再无限膨胀。
- **F-8【P2】`fromJson` 数值范围夹取**，畸形备份数据不再越界。
- **F-9【P3】`monthlyWeekday/monthlyWeekIndex` 改 `_kKeep` 哨兵**，与「未设置」语义区分。
- **F-10【P3】未来循环日禁「标记完成」**。
- **F-11【P3】恢复备份后清理附件孤儿**。
- **配套**：新增 `_armedSignatures` 落点签名缓存（15 分钟守护稳态零平台往返）；`_kNotifIdScheme` 2→3；解除「选重复即钉 dueDate=当天 23:59」的旧约定（`new_task_sheet` + `task_parser`）。

### 说明
- 新增 `test/repeat_reminder_fix_test.dart`（38 条）；`dart analyze lib` 零新增 error；全量测试 520 通过 / 5 预存失败，零回归。

## v2.8.4（2026-09-11）

### 功能与操作审计修复（依据 v2.8.3 审计报告 P1-1 / P2-1~3 / P3-1~5 全量落地）
- **P1-1【P1】跨天重排依赖「恰有重复任务被重置」**：`TaskProvider` 新增 `_lastResetDay` 日边界基线，`checkDailyReset()` 不再以 `_resetDailyIfNeeded()` 的返回值为准——只有一次性任务的用户 App 后台跨过 00:00 时也会重排简报 / 习惯挽留，次日不再静默断更。
- **P2-1【P2】顺延「撤销」只删副本、不退 skipDates**：`rescheduleOnceOccurrence` 返回新建的一次性副本，撤销按副本 id 精确移除（原先按「标题 + 日期」反查，同名任务同日改期会误删别人）；新增 `unskipOccurrence` 与 `skipOccurrence` 严格互逆，原日不再残留「已跳过」。顺带修掉一处静默失效——原撤销调用的 `permanentDelete` 只作用于回收站，对活动列表任务是 no-op，副本其实从未被删；新增 `discardTask` 承担活动列表的彻底移除。
- **P2-2【P2】canonical JSON 对非 BMP 字符编码不一致**：`_writeJsonString` 改按 `runes`（code point）迭代并显式展开代理对，emoji / 生僻字不再退化成 U+FFFD；此前 releaseNotes 里一旦出现 emoji，该版本所有用户「检查更新」都会因验签字节不一致被拒收（潜伏雷）；同步修正离线校验脚本 `test/c2_verify_sign.dart` 中的同一份实现。
- **P2-3【P2】编辑弹层脏字段残留**：新增 `Task.normalizedRepeatFields()`（纯函数）并在保存前调用——切回「不重复」清 `repeatUntil`、非 interval 清 `repeatInterval`、无截止时间清 `reminderOffsetMin`，避免污染备份导出与「未来 30 天预览」，也避免提醒重排判定被无害残留误触发；`repeatAnchor` 刻意保留（惰性字段，清掉会改变「改回每隔 N 天」的相位）。
- **P3-1【P3】分享附件流在主线程同步复制**：`MainActivity` 把 content provider 元数据查询 + 跨进程字节流复制整段移入后台线程，冷启动收到大文件分享不再阻塞 UI（白屏 / ANR）；新增 `deliverSharedUri` 统一投递入口，保证「引擎就绪直发」与「挂 pending 等补发」互斥不重复投递。
- **P3-2【P3】已完成实例菜单仍标「标记完成」**：改为按实例状态动态显示「标记未完成 / 标记完成」，语义与行为一致。
- **P3-3【P3】重定向白名单分支 2 未校验 host**：`attach_file(s)` 路径前缀分支一并限定 gitee 系主机，堵掉 `https://github.com/attach_files/...` 这类组合。
- **P3-4【P3】礼貌挽留顺延勿扰后文案时态错位**：抽出 `NotificationService.nextHabitNudgeTime`（墙钟口径，调度层与文案层同源），顺延跨天时把「今天」改写成明确日期，次日早晨不再读到「今天还没打卡」。
- **P3-5【P3】过去时间警告仅覆盖弹层保存**：新增 `PastDueGuard`（判定 + 提示）并接入批量改期与逾期区「顺延到今天」，同一件事的提示口径统一；重复任务不参与（其提醒会再次循环触发，提示属误报）。

### 说明
- 新增 5 个回归测试文件（canonical JSON 非 BMP、挽留顺延文案、PastDueGuard 判定、occurrence 撤销幂等、重复字段归一化）；`dart analyze lib test` 零新增 error，全量测试 482 通过 / 5 预存失败（均为 HEAD 已有的历史问题，非本次回归）。
- 全部修复保持严格离线红线：纯本地路径修复，未新增除现有 update-check 之外的任何网络调用；三站（Gitee releases-3 + 内网 Forgejo + GitLab 8567）发布，固定 release keystore 签名，arm64-v8a 单架构。

## v2.8.3（2026-09-06）

### 安全 / 功能 / 交互审计修复（依据 v2.8.2 审计报告 F-01~F-15 全量落地）
- **F-01【P0】更新签名强制门槛比较方向写反**：`UpdatePolicy.requiresMandatorySignature` 修正为「声明版本 ≥ 2.8.0（不含预发布）必须携带合法 ECDSA-P256 签名」，封死「删 signature 字段绕过 C-2 验签」的攻击链；补判定矩阵单测。
- **F-02【P1】重复提醒 notifyId 低位未留位宽互相顶掉闹钟**：重排 id 布局 `1600000000 + slot*8 + dayIndex%8`（slot 预留星期槽位宽，整体下移保 int32 不溢出）；升级时取消旧段位全部闹钟再全量重排；补多任务×多星期槽唯一性单测。
- **F-03【P1】复杂「每月」重复用系统按月循环闹钟导致日期漂移**：`isOneShotMonthly`（月末/倒数第N天/第N个周几/31号）改一次性闹钟 + 启动·回前台·午夜重置时重算 `_nextMonthlyOccurrence`（尊重 repeatsOn/skipDates，3 个月内无命中返回 null）；「每月 X 号且 X≤28」保留系统月循环。
- **F-04【P1】快速录入「每天…」无时间生成哑重复任务**：解析到重复规则却无时刻时补默认 `repeatMinute`（固定 09:00），与编辑弹层默认 07:00 行为对齐，次日必响。
- **F-05【P2】删除撤销按旧索引归位错位**：改锚点定位（`_resolveUndoIndex` + `_renumberSection`），归位后重算所在分区 order，不再受后续增删/勾选/拖拽影响。
- **F-06【P2】15 分钟跨天守护循环无异常保护**：`Future.doWhile` 循环体整体 try/catch，捕获后记录并恒 `return true` 继续轮询，interval 跨天补挂不再静默停摆。
- **F-07【P2】简报/漏卡挽留周期闹钟烘焙陈旧文案**：简报与习惯挽留改为一次性闹钟（投递前由 App 动态生成内容），长期不开 App 也显示当日数据。
- **F-08【P2】`repeatsOn` 结束日期「含当日」契约脆弱**：函数开头对 `day` 做 date-only 归一化，与 `isRepeatEnded` 及原生 MidnightResetReceiver 口径一致。
- **F-09【P3】单条右滑直接删除无确认**：右滑删除前弹二次确认（与批量删除一致），降低误触率。
- **F-10【P3】「每隔 N 天」默认值 2 而非 1**：默认值改为 1；`rescheduleOnceOccurrence` 一次性副本去除残留 `repeatInterval:2` 脏字段。
- **F-11【P3】CSV 公式注入防护不完整**：新增 `csv_safe.dart` `csvCell()`，对去空白后首有效字符 `= + - @` 及前导 `\t`/`\r` 前置单引号，覆盖 OWASP 全部引导情形。
- **F-12【P3】外部调用受保护 `notifyListeners`**：`TaskProvider` 暴露公开 `refreshAfterPrefs()`，移除 analyzer 报错的非法内部调用。
- **F-13【P3】文档与实现不同步**：README 下载链接/「最新版」对齐 v2.8.3、特性描述对齐「无截止归入今天」；CHANGELOG 补齐 v2.8.0/2.8.1/2.8.2 条目。
- **F-14【P3】下载重定向 host 白名单过宽 + 无总时长上限**：重定向逐跳校验完整路径前缀（`/jason1012/`、`/attach_files/`、`/attach_file/`）；新增 `maxDownloadDuration`（10 分钟）熔断，防慢速 drip 无限拖。
- **F-15【P3】分享流复制无总量熔断**：`MainActivity.dispatchShareStream` 改为带增量计数器的缓冲复制，超 `MAX_SHARE_BYTES` 即中止；`dart analyze` 仍 0 error（存量 warning/info 与基线一致）。

### 说明
- 全部修复保持严格离线红线：纯本地路径修复，未新增除现有 update-check 之外的任何网络调用；三站（Gitee releases-3 + 内网 Forgejo + GitLab 8567）发布，固定 release keystore 签名，arm64-v8a 单架构。

## v2.8.2（2026-09-05）

### 交互增强（依据 v2.8.1 审计报告，UX 批次 U1-U20 全量收口）
- 标签真实新增、习惯编辑/删除、补卡 + 通知打卡 action、命令面板移动端适配、task_row 标题全宽。
- 顺延保留原日期 + 撤销、帮助页重写、脏数据保护 + 日期清除、过去时间警告、引导深色、专注/番茄报错兜底。
- 已打卡先确认、语义色、设置数据三拆、提醒取消确认、日历回今天 + 勿扰跨天说明、消除交互死路。
- 全部修复保持严格离线红线（无新增网络调用）。

## v2.8.1（2026-09-05）

### 安全 / 健壮性修复（依据 v2.8.0 审计报告）
- 功能与交互审计 F1/F9/F12/F13/F14/F15 + P2-4/5/6/9/12/15/16/19/21/24 + U6/U7/U8 全量落地。
- 持续保持严格离线红线：纯本地路径修复，未新增除现有 update-check 之外的任何网络调用。

## v2.8.0（2026-09-05）

### 更新链路签名（C-2 / F12，安全关键）
- 更新清单（update.json）引入 **ECDSA-P256 固定公钥签名**：声明版本 ≥ 2.8.0（不含预发布）的清单**必须携带合法 `signature`**，否则拒绝；作者私钥仅存于发版机，绝不进仓库 / 不进 App。
- 清单规范化 JSON（排序键 / 紧凑分隔符 / UTF-8）与发版签名端逐字节对齐；下载继续走白名单 + 体积熔断 + SHA-256 校验 + TLS 证书固定 + 禁明文。
- 校验失败一律视为被篡改并拒收更新，即便 Gitee 账户或 TLS 被攻破也无法伪造清单。

## v2.7.9（2026-08-30）

### 安全修复（依据 v2.7.8 审计报告）

- **应用锁可被通知 / 桌面小组件点击绕过（M-01，中危）**：根 Navigator 跳转此前盖在解锁页之上。现所有外部意图（通知点击、小组件、分享）消费前先判锁状态，锁定时只暂存意图、解锁后由监听回调统一消费，不再泄露详情。
- **更新链路供应链纵深（L-01~L-04、L-10、L-13）**：清单 `version` 做 semver 白名单且下载落盘固定名 `updates/update.apk`（防沙箱内路径穿越）；APK 直链在主机白名单之上叠加作者发布仓 `releases/download/` 路径前缀，重定向逐跳校验主机；APK 下载 200MB 硬上限熔断；`releaseUrl` 走发布仓前缀白名单不再直跳钓鱼页；下载失败/取消统一清理半成品 APK；`releaseNotes` 截断到 8000 字。
- **隐私一致性（L-05、L-06、L-07、L-08、L-12）**：原生 `installApk` 增加 `updates/` 分隔符边界校验（防兄弟目录前缀绕过）；通知渠道默认 `visibility:private` 且设置可「锁屏隐藏通知内容」；新增 FLAG_SECURE 开关（设置「禁止截屏与录屏」）；自动备份可选 AES-GCM 加密 `.enc.json`（口令存本机不随备份出）；备注链接默认复制到剪贴板、不外跳浏览器，正则收紧尾部标点。
- **健壮性（L-09、L-11）**：导入/备份读取增加 32MB 大小预检、附件改为流式复制避免 OOM；`debugPrint` 统一封装 `AppLog`，release 模式静默不输出业务内容。
- **网络纵深（I-02）**：新增 `network_security_config.xml` 显式禁明文 + 仅系统 CA，Manifest 接入。
- **文档（I-04）**：README 重写 release keystore 签名与用户哈希校验指引。

### 说明
- I-01（包名占位符 `com.example.todolist`）按报告路线图留作远期评估；I-03（更新清单离线 Ed25519 签名）为远期项，本轮未动。
- 测试：新增 `update_policy_test` 13 条、`update_checker_schema_test` 回归用例，全量 439 通过 / 0 失败。固定 release keystore 签名。

## v2.7.7（2026-08-30）

### 安全修复（P1，依据 v2.7.6 审计报告）
- **批量编辑撤销不重排提醒（P1-1）**：`undoBatchEdit` 此前直接按索引覆盖内存，不走 `updateTask`——批量顺延「+N 天」后点撤销，截止日期虽回滚到原日期，但系统里残留的提醒仍指向顺延后的新日期，通知与任务状态错位。现改为逐条走 `updateTask(orig)`，复用既有提醒重排 / 拼音重算 / 持久化逻辑。
- **批量编辑撤销按索引定位会错位覆盖（P1-2）**：快照在 `batchUpdate` 执行时记录索引，之后若新增/删除/排序过任务，按旧索引写回会覆盖到无辜任务（本地单机数据错乱）。现改为按 id 定位（`indexWhere(id)`），任务已删除时跳过不复活；`_lastEditIndices` 字段整体移除。

### 修复（P2）
- **设置页「习惯挽留提醒」重复渲染（P2-2）**：同一段配置块被整体复制了两份（v2.7.6 复制粘贴遗留），删除重复的第二份。
- **命令面板 `/week` 名不符实（P2-7）**：`/week` 实际行为只是回首页，与命令名不符且与导航类 `/home`、`/today` 重复，已移除；帮助文案补入 `/home`。

### 说明
- P2-4（`READ_MEDIA_IMAGES` 冗余权限）延续开放：需先在 ColorOS 等国产 ROM 实测 Photo Picker（`requestFullMetadata=false`）后再移除。
- P2-5（更新清单独立签名）为远期项，本轮不动。

## v2.7.6（2026-08-29）

### 安全修复（P0）
- **加密备份「勾选加密仍写明文」+ UI 谎报「已加密保存」已修复（P0-1）**：
  - 根因：勾选加密后 UI 先清空口令输入框，再把已被清空的 `controller.text` 传给备份流程，导致落盘的是**明文**，而 UI 仍提示「已加密保存到下载目录（凭口令恢复）」；
  - 修复：口令在清空输入框**之前**锁定为局部变量 `confirmedPass` 再传出；新增 `buildBackupPayload` 守卫——`encryptOn` 为真而口令缺失/为空时抛 `BackupEncryptException` **显式中止**整个备份（不写任何文件、不谎报已加密）；
  - 新增回归单测 `test/backup_crypto_payload_test.dart` 覆盖「勾选加密+空口令必须失败 / 有效口令产出信封且不含明文」。

### 功能
- **命令面板动作命令扩充（F7）**：新增 `/新建`（快速录入）、`/回收站`、`/标签`、`/导出`、`/备份`、`/本周` 等动作命令，复用既有 `/done` 注入范式；无回调的命令安全降级提示。
- **专注「打断」数据展示闭环（F2）**：分享卡 / 晚简报 / 月报 narrative 显示「专注被打断 N 次」（数据早已采集，本次在展示层消费）。
- **习惯漏卡挽留可配置化（F4）**：设置页新增独立开关 + 时刻；打卡 / 增删习惯后触发重排；排程感知勿扰时段，避免挽留撞进勿扰或被吞。

### 修复（P2 健壮性）
- **晚简报专注 / 习惯口径按投递日聚合（P2-1）**：`focusMin`/`pomodoros`/`isCheckedToday` 改用与任务侧一致的投递日口径，修复跨天混合口径。
- **批量编辑「+N 天」无边界（P2-4）**：`clamp(0, 3650)`，禁止负数把截止提前、超大值溢出。
- **重复任务「每隔 N 天」无上界（P2-5）**：设上界 `<= 365`。

### 其他
- 固定 release keystore 签名（延续 v2.6.0 起的设计，无 debug 回退）。
- 三站同步发布源码与 APK：Gitee `youtiao`（源码）+ `youtiao-releases-2`（APK）、内网 Forgejo `rootnas/youtiao`、新增 8567 站 `rootnas/youtiao`。

## v2.7.5（2026-08-29）

### 改动
- **移除桌面小组件「隐藏标题」功能**（P2-5）：
  - 此前桌面小组件提供「隐藏标题」开关，开启后任务标题在桌面显示为 `••••••` 以作隐私保护；
  - 经评估该开关使用频率低，且与「单条任务私密性」需求错位（真要保护应走归档 / 加密，而非桌面打码），
    同时增加 Kotlin / Dart 两侧维护成本，故整体移除；
  - 原生侧 `TodayWidgetProvider` 不再读取 `flutter.widget_hide_titles`，
    `TaskProvider` 同步移除对应状态与 `setWidgetHideTitles`，设置页开关入口一并删除；
  - 注意：分享卡片 / 分享长图的「隐藏标题」是**另一个**独立功能（隐藏分享图中的标题），本次未动。

## v2.7.4（2026-08-29）

### 修复
- **早晚简报按「投递日」聚合，修复日期口径串天**（P1-8）：
  - 简报文案在排程时烘焙（闹钟到点时 App 未必在内存），而晨报总在**前一天**排好
    （如周一 21:00 排周二 07:30）。原实现按排程当下 `DateTime.now()` 聚合，
    导致周二早上推给用户的是**周一**的「今日待办 / 逾期积压 / 昨日未完成」——
    不只是内容陈旧，是日期整个串了；
  - 新增 `NotificationService.nextBriefingTime()` 作为「下次触发时刻」的唯一口径，
    排程方与调度共用，避免两边各算一套导致日期漂移；
  - 聚合函数新增可选 `forDay`，缺省仍为当下，不传参时行为不变。
- 补充说明：通知仍以 `matchDateTimeComponents=time` 每日重复，同一份文案会按天重发；
  用户连续多日不打开 App 时，第二日起内容仍会滞后。彻底解决需原生侧每日重烘焙，
  会让简报口径在 Kotlin / Dart 两边各存一份，暂不实施。

## v2.7.3（2026-08-29）

### 修复
- **真正修复桌面小组件在 MIUI 等 ROM 上报「载入窗口小部件时出现问题」**（v2.7.2 的异常兜底对本题无效）：
  - 根因：任务项布局 `widget_today_item.xml` 用裸 `<View>` 作圆点，而 RemoteViews（AppWidget）
    **只允许白名单控件**（FrameLayout / LinearLayout / RelativeLayout / GridLayout、TextView、
    ImageView、ProgressBar 等），裸 `View` 不在其中，桌面宿主 inflate 时抛
    `InflateException: Class not allowed to be inflated android.view.View`；
  - 该异常发生在**启动器进程**而非本 App 进程，`AppWidgetProvider` 中的 try-catch 无法拦截，
    故 v2.7.2 的兜底修复对本题完全无效；
  - 因只在 `addView` 填充任务列表时才 inflate item 布局，故障表现为「今天有任务才崩、
    无任务走空状态正常」；
  - 修法：圆点改用白名单内的 `ImageView`，保留 `android:background` 渲染，视觉与交互不变。

## v2.7.2（2026-08-29）

### 修复
- 桌面小组件（`TodayWidgetProvider`）`onUpdate` 异常兜底：构建视图任何异常回落空状态视图，修复 MIUI 等国产 ROM「载入窗口小部件时出现问题」的崩溃；
- 任务项点击 `PendingIntent` 改用 `task.id.hashCode()` 作为 `requestCode`，配合 data URI 保证每项唯一，避免 `FLAG_UPDATE_CURRENT` 互相覆盖导致点击错位。

## v2.7.1（2026-08-29）

### 安全修复
- 用户模板路径穿越防护：模板 id 走白名单校验（`isSafeTemplateId` / `sanitizeTemplateId`），拼接后 `startsWith` 双重断言；导入时无条件重分配 id
- iCal / 外部 id 治理：`_canReuseExternalId()` 校验（纯数字 + 小于 idSeq + 无冲突），指纹不符时新建而非覆盖，避免导入覆盖本地既有任务
- 附件孤儿清理修复：`_planOrphans` 的 known 集合改为按 id 合并，不再相互覆盖
- 系统分享加固：清理 24 小时以上的陈旧分享收件箱；文件名显式拒绝 `""` / `"."` / `".."`；三个 SEND intent-filter 合并为单个

### 功能
- 批量编辑：多选后批量改分类 / 优先级 / 截止日期 / 加标签 / 删除
- 逾期一键顺延：今天 / 明天 / 3 天 / 7 天 / 自定义日期
- 农历展示：日历页显示农历与节气，设置页可开关（复用内置 lunar 依赖，全程离线）
- 专注中断感知：记录切出应用次数并在专注结束提示
- 快速录入语法扩展：日期区间「周五~周日」、`@地点`、「预计2小时30分钟」
- 桌面快捷键：Cmd/Ctrl+1~6 切换 Tab、Cmd/Ctrl+Enter 完成选中项；命令面板新增 `/done`、`/goto 日历` 等 `/` 命令
- 习惯漏卡挽留提醒：23:00 聚合提醒，多个习惯合并为一条通知
- 每月重复「月末最后几天」：「每月最后一天」「每月倒数第3天」
- 帕累托分析 + 年度时间线：回顾页新增「80/20 投入分析」，年报新增「年度时间线」并自动标注起点 / 峰值 / 空窗月

### 修复
- 全新安装首启示例任务丢失：`load()` 用数据库内容覆盖内存列表时会清掉内置的 7 条首启示例，
  导致新用户首启实际看到空白列表而非设计中的 7 条示例。改为在载入前快照、全新安装时回填
- 备份校验放过非法字段：priority / category 为非字符串时，`Task.fromJson` 会静默降级
  （该容错为刻意设计，用于防止非法备份导致恢复崩溃），校验层因此误判为「校验通过」。
  改为在校验层显式拦截类型级损坏，避免「校验通过、恢复后数据悄悄变形」

### 质量
- 补充单测：安全与批量编辑、习惯挽留、命令面板、帕累托分析等
- 修复 5 项长期预存的单测失败（示例预置 2 项、备份校验 2 项、成就满配上下文 1 项）
- 全量回归 408 通过 / 0 失败，首次全绿
- 版本升至 v2.7.1（versionCode 92）

## v2.7.0（2026-08-28）

- 早晚简报 + 今日回顾（daily_briefing / today_review_screen）：每日晨/晚本地推送，含今日完成/专注/习惯汇总，晚间可进入当日复盘页
- 附件管理页（storage_screen / attachment_service）：统一查看本地附件占用、预览、清理无主文件
- iCal / CSV 导入幂等去重（importDedup）：去重 / 覆盖 / 模糊去重可选，重复导入不再产生副本
- 用户模板可视化编辑（user_template_editor / task_templates）：内置模板库 + 自定义常用任务模板
- 重复「未来 30 天预览」（occurrence_sheet）：逐次实例可单独标记完成 / 跳过 / 顺延
- 农历重复（task_parser）：支持按农历日期设置重复任务（离线转换，不联网）
- 专注时段面板（focus_screen）：周视图按日展示当天专注时段条
- 命令面板（command_palette）：全局快捷命令入口（Ctrl/Cmd+F 聚焦搜索等）
- 导出增强（report_exporter）：回顾 / 任务导出可选「包含附件清单」列
- 系统分享建任务（MainActivity + quick_entry_sheet）：其它 App 分享图片 / 文件直接建任务并带附件
- 回收站过期预告（notification_service）：即将永久删除的任务本地通知提醒
- 全局标签管理（tag_manage_screen）：重命名 / 合并 / 归档 / 删除、批量绑定任务
- 通知稍后提醒（snooze）：到期提醒一键延后、按时长顺延
- 版本升至 v2.7.0（versionCode 91）。

## v2.6.9（2026-08-27）

- 任务附件（P0-1）：图片 / 拍照 / 录音 / 任意文件，全程本地落盘，严格离线不联网
- 详情页附件：图片全屏缩放预览、录音内联播放、文件系统分享打开
- 附件随本地加密备份（AES-256-GCM）打包还原，自动 + 手动备份均纳入
- 修复：录音原始文件孤儿、播放订阅泄漏、编辑模式取消保存孤儿清理
- 版本升至 v2.6.9（versionCode 90）。

## v2.6.8（2026-08-26）

- **✨ 6 大功能**：
  - **① 分享文本 → 快速建任务**：系统分享面板直达「有条」，自动解析标题与清单项。
  - **② 重复任务补全**：支持「仅跳过本次 / 单次改期 / 设结束日期」三种语义，日历视图同步。
  - **③ 备份口令加密导出**：AES-256-GCM + PBKDF2（HMAC-SHA256, 15 万轮）本地加密，无口令无法还原。
  - **④ 桌面小组件（4×2 今日清单）**：跨进程读 SQLite（WAL + busy_timeout），点击直达任务。
  - **⑤ iCal（.ics）标准导入导出**：遵循 RFC 5545，支持 VTODO / RRULE 与多日历互导。
  - **⑥ R8 资源收缩**：剔除未使用资源，包体更小、零混淆回归风险。
- 版本号 v2.6.8（versionCode 89）；release 签名（固定 keystore），arm64-v8a 单架构，双站（Gitee youtiao-releases-2 + 内网 Forgejo）发布。

## v2.6.7（2026-08-25）

- **🔒 安全审计修复（S2 / S4 / S5 / S8 / S10 / S11）**：
  - **S2 构建签名加固**：release 构建缺签名环境变量时直接抛 `GradleException` 终止，彻底杜绝静默回退到 debug keystore（v2.5.9 曾误发 debug 包的根因）。
  - **S4 更新说明显示修复**：`update_checker` 改为读取 `update.json` 的 `releaseNotes` 字段（旧代码误读 `notes` 导致更新说明永远空白），并抽离 `parseManifest` 供回归测试覆盖。
  - **S5 发版链路收敛**：废弃 `_build2.py`，统一走 `_publish_v266.py` 唯一入口；兜底 `releaseUrl` 由旧仓 `youtiao-releases` 改为 `youtiao-releases-2`，与权威清单一致。
  - **S8 下载体验加固**：更新 APK 改为流式 `sha256` 校验（不再 `readAsBytes` 整包载入约 85MB，规避 OOM）；安装前二次确认；下载中可取消。
  - **S10 跨进程 SQLite 写入加固**：`MidnightResetReceiver`（`:guard` 进程）写主进程 `youtiao.db` 时启用 WAL（尽力）+ `busy_timeout=5s` + `SQLITE_BUSY` 重试 3 次 + 失败日志，不再静默丢弃每日重置；回退路径 `SharedPreferences` 由 `.apply()` 改 `.commit()` 保证落盘。
  - **S11 CSV 公式注入防护**：任务/习惯/专注 CSV 导出对以 `= + - @` 开头的单元格加 `'` 前缀，防 Excel/WPS 公式注入。
- 版本号 v2.6.7（versionCode 88）；release 签名（固定 keystore），arm64-v8a 单架构，双站（Gitee youtiao-releases-2 + 内网 Forgejo）发布。

## v2.6.6（2026-08-25）

- **🐛 自动备份目录创建修复**：自动备份写入 `backup/auto/YYYY-MM-DD.json` 时，因 `backup/auto/` 子目录此前从未被创建，`writeAsString()` 抛 `PathNotFoundException` 导致自动备份静默失败。修复公共方法 `DataIo.saveToAppDocs()`，在写 `.tmp` 前先 `parent.create(recursive: true)`，一次性覆盖所有带子路径的写入（自动备份 + 手动导出）。
- **✨ 自动备份扩展纳入应用偏好**：自动备份 JSON 现额外写入 `prefs` 段，涵盖主题配色（`theme_*`）、应用锁开关、番茄钟/专注设置、免打扰时段、提醒延后、周目标、回收站保留期、后台保活、引导页标记等共 26 个偏好键；还原时自动写回并刷新各 Provider 内存态（规避还原即锁屏）。**明确不备份**：系统生物特征（系统保管不可导出）、更新检查状态、运行中的计时器、示例数据标记——换机/清数据后体验基本完整，系统面容/指纹仍需在新机重录。

## v2.6.5（2026-08-25）

- **🔓 支持手机锁屏密码解锁**：指纹/面容多次失败或不可用时，系统弹窗可降级用手机锁屏密码（PIN/图案/密码）解锁，不再被锁在门外。
- **🌐 系统验证弹窗文案全面汉化**：Android BiometricPrompt 与 iOS 弹窗的标题、按钮、提示等文案全部中文化（此前部分为英文默认文案）。
- **📱 设置页**：应用锁副标题更新，说明可用锁屏密码替代。

## v2.6.4（2026-08-25）

- **🐛 生物识别解锁修复**：指纹/面容验证成功后仍停留在锁定页——根因是系统验证页（BiometricPrompt Activity）关闭时触发的 `resumed` 生命周期事件与 `authenticate()` 完成存在竞态，`onResumed()` 把刚解开的锁立即盖回。现以「验证中守卫 + 解锁后 3 秒宽限期」双保险豁免该竞态。
- **✅ 测试**：新增应用锁宽限期回归测试（mock local_auth 平台通道固化竞态语义）；全量 310 项测试通过。

## v2.6.3（2026-08-24）

- **🔧 发布后代码审查缺陷修复（基于 v2.6.2 审查报告 P0/P1/P2）**：
  - **P0-1 应用锁 Android 锁死**：`MainActivity` 由 `FlutterActivity` 改为 `FlutterFragmentActivity`，使 `local_auth` 的 BiometricPrompt 能正常拉起（否则 `authenticate()` 抛 `no_fragment_activity` 走「维持锁定」把用户锁死）。
  - **P0-2 自动备份缺专注/习惯数据**：跨日首启快照从 `TaskProvider.load()` 内移除，改到 `main` 在 `FocusProvider`/`HabitProvider` 全部 `load()` 之后、首启前显式触发，备份不再遗漏专注/习惯数据。
  - **P1-1 拼音首字母实为全拼**：`computePinyinInitials` 由 `getFirstWordPinyin`（全拼）改为 `getShortPinyin`（首字母，如「整理」→`zl`）。
  - **P1-2 恢复备份后拼音搜索失效**：`restoreFromJson` 恢复时对每个任务按标题重算 `pinyinInitials`（旧备份该字段为空串）。
  - **P1-3 iOS 缺 FaceID 描述**：`Info.plist` 补 `NSFaceIDUsageDescription`。
  - **P2 清理**：移除未用 `_lastUnlockAt` 字段、`focus_hour_chart` 未用 import 与分钟「0」毛刺；`review_card` 两处 `read`→`watch`；`backup_sheet` 快照还原硬编码 `true`→`includeTrash` 透传；新增拼音/备份校验/时段分布/应用锁/周目标 5 组回归测试。
- **签名**：固定 release keystore（与 v2.5.8 同源），arm64-v8a 单架构；双站（Gitee youtiao-releases-2 + 内网 Forgejo）发布。

## v2.6.2（2026-08-24）

- **✨ 八项实用功能（S/A/B 线）**：
  - **S1 本地自动备份（滚动快照）**：设置页可开启「本地自动备份」，跨日首启自动在 App 私有目录生成当日滚动快照（保留最近 7 天），「备份与恢复」面板可一键还原；备份采用原子写（.tmp + rename），导入前经 `BackupValidator` 强校验拦截废档，纯本地不上传。
  - **S2 子任务纳入搜索**：全局搜索现在命中任务子任务标题。
  - **S3 备份导入强校验**：恢复前 `BackupValidator` 双重校验（来源判定 + 干跑解析），拒绝非「有条」备份 / 结构损坏，避免「校验失败后才清空数据」。
  - **S5 任务一键转习惯**：任务详情页可把任务一键转为习惯（每天打卡），原任务可留在回收站。
  - **B1 周目标（本周完成数）**：设置页可选「每周完成 N 个」目标（0/10/20/30/50），周报卡展示 `done/goal` 进度。
  - **A1 拼音首字母搜索**：任务标题落库时计算拼音首字母（如「整理」→ `zl`），搜 `zl` 即可命中。
  - **A2 专注时段分布图**：专注页新增 24 小时直方图，观察个人「专注生物钟」，零新增存储。
  - **A4 应用锁（生物识别）**：设置页可开启应用锁，冷启动 / 回前台需指纹或面容验证；`biometricOnly` 不留 PIN 后门，零生物特征落盘，符合离线红线。
- **⚠️ 发布后代码审查发现的缺陷（已在后续版本修复，见对应条目）**：应用锁在 Android 需宿主 Activity 继承 `FlutterFragmentActivity`（S1 自动备份启动时序导致快照缺专注/习惯数据）、拼音首字母 API 误用导致实际存全拼、恢复备份后拼音搜索静默失效。详见修复版本说明。
- 版本号 v2.6.2（versionCode 83）；release 签名（与 v2.5.8 同源 keystore），双站（Gitee youtiao-releases-2 + 内网 Forgejo）发布。

## v2.6.1（2026-08-24）

- **✨ 任务开始时间 / 时间段**：任务新增可选「开始时间」字段（`startDate`，可空、零迁移），与截止时间共同构成时间段；首页 / 看板 / 日历按「开始时间」与「截止时间」双锚点呈现任务跨度，未设开始时间的任务保持原「仅截止」行为。今日排序键改为 `截止时间 ?? 开始时间`。
- **✨ 自定义每日专注目标（用户可设值）**：设置页新增「每日专注目标」行，可选 关闭 / 30 / 60 / 90 / 120 / 180 分钟（默认 120，0=关闭），持久化到 `focusGoalMinutes`；今日页专注目标进度从此读取用户设定值，而非硬编码。
- **✨ 备注链接可点击打开**：任务详情页备注区识别 `https?://` 链接，渲染为可点击文本，点击经系统浏览器 `launchUrl` 打开；其余备注文本保持原样显示。
- 改动文件：`models/task.dart`、`state/task_provider.dart`、`models/today.dart`、`widgets/new_task_sheet.dart`、`screens/task_detail_screen.dart`（含 `url_launcher` + `gestures`）、`widgets/task_row.dart`、`screens/settings_screen.dart`。`flutter analyze` 0 error。
- 版本号 v2.6.1（versionCode 82）；release 签名（与 v2.5.8 同源 keystore），双站（Gitee youtiao-releases-2 + 内网 Forgejo）发布。

## v2.6.0（2026-08-24）

- **🔧 修复升级安装签名冲突（固定 release keystore）**：v2.5.9 因构建期未将签名环境变量传入 Gradle，回退到 debug keystore，导致手机上已装 release 版（v2.5.8）在覆盖安装时报「与已安装应用签名不同」。本次在构建前显式 `export` 4 个签名环境变量（`YOUTIAO_KEYSTORE` / `YOUTIAO_KEY_ALIAS` / `YOUTIAO_KEYSTORE_PASSWORD` / `YOUTIAO_KEY_PASSWORD`），重建后 apksigner 校验确认命中固定 release keystore（SHA-256 与 v2.5.8 一致）。
- **⚠️ 注意**：v2.5.9 的 APK 为 debug 签名，建议已装该版本的用户先卸载再装 v2.6.0+，或直接升级到 v2.6.1。
- 版本号 v2.6.0（versionCode 81）；无功能变更，纯签名修复 + 双站重发。

## v2.5.9（2026-08-14）

- **✨ 通知栏「完成」按钮**：任务 / 重复 / 习惯提醒新增「完成」action 按钮，点击直接在通知栏把任务标记为已完成，并弹出覆盖式确认，无需进入 App。
- **✨ 回收站自动清理**：设置页新增「回收站保留期」选项（7 / 30 / 90 天 / 永不），每日 00:00 原生清理接收器 + App 启动兜底清理超期条目；`-1` 表示永不自动清理。
- **✨ 稍后提醒自定义时长 + 勿扰时段**：「稍后提醒」支持 10 / 30 / 60 / 120 分钟可选（原固定 10 分钟）；新增「勿扰时段」（可跨午夜），落在区间内的一次性提醒自动顺延到勿扰结束后再响。
- **✨ 任务置顶 / 星标**：任务支持「置顶」（所属分区内固定排最前，优先于手动 `order`）与「星标」（列表星标标识），常驻高频 / 重要任务于列表顶部。
- 改动覆盖 `notification_service.dart`、`task_provider.dart`、`task.dart`、`main.dart`、`settings_screen.dart`、`new_task_sheet.dart`、`task_row.dart`、`home_screen.dart` 等；`flutter analyze` 0 error。
- 版本号 v2.5.9（versionCode 80）。**注**：该版本 APK 误用 debug 签名（见 v2.6.0 修复说明），用户侧请以 v2.6.1 为准。

## v2.5.8（2026-08-14）

- **🐛 代码审查问题修复（6 缺陷 + 2 安全加固）**：
  - Bug1 习惯提醒僵尸通知：恢复备份前先 `cancelHabitReminder` 旧 id，避免残留定时提醒。
  - Bug2 测试通知 id 与习惯段重叠：测试通知 id 挪到 `1200000+` 独立段，不再与习惯提醒冲突。
  - Bug3 备份恢复非原子：task / focus / habit 分步 `try/catch` 累积失败，避免单表失败导致整体中断。
  - Bug4 专注结束时间落在未来：`ended` 取 `now` 与 `start + total` 的较大者，杜绝负时长 / 未来时间戳。
  - Bug6 版本号含 `-beta` 比较异常：解析前剥离 pre-release 后缀再比对。
  - Security1 FileProvider 路径用 `canonicalPath` 校验，防路径穿越。
  - Security2 `AndroidManifest.xml` 关闭 `allowBackup`，降低数据被 adb 备份导出风险。
  - （Bug5 undoDelete 索引按报告择机延后，本次未做。）
- 版本号 v2.5.8（versionCode 79）。

## v2.5.7（2026-08-13）

- **🔧 固定 release 签名重发**：`android/app/build.gradle.kts` 接入固定 release keystore 配置——凭据从 4 个环境变量读取（绝不硬编码进仓库），不再依赖 AGP 自动生成的 debug keystore，避免跨机 / 重建导致的签名漂移（`INSTALL_FAILED_UPDATE_INCOMPATIBLE`）。环境变量缺失时回退 debug（保持本地 `flutter run --release` 可用）。无功能变更，属签名可靠性重发。
- 版本号 v2.5.7（versionCode 78）。

## v2.5.6（2026-08-13）

- **🐛 代码审查 19 项问题修复 + APK 完整性校验**：逐条验证审查报告 21 项，修复 19 项真实问题——午夜重置改读 SQLite（不再依赖内存态）、编辑任务丢字段、逾期口径统一、习惯周提醒 `skipToday`、番茄钟重入保护、备份恢复事务化、SQLite 快照防并发、`installApk` 路径前缀安全校验、APK 完整性 sha256 校验等。
- **🔧 编译阻塞修复**：`data_io.dart` 适配 `file_picker` v12 的 API 变更（`FilePicker.pickFiles`，移除已移除的 `.platform` 访问器），解除编译失败。
- `update.json` 同步 v2.5.6（含 `apkSha256` 完整性 pinning）；`flutter analyze` 0 error，280 项测试全绿。
- 版本号 v2.5.6（versionCode 77）。

## v2.5.4（2026-08-13）

- **✨ 单习惯详情弹层**：点击习惯进入详情，含专属「单习惯打卡热力图」、当前/最长/累计连续天数统计与「分享」入口。
- **✨ streak 破纪录全屏庆祝动效**：打卡后当前连续天数超过历史最长时，触发全屏火焰庆祝 overlay（「新纪录！连续 N 天」）。
- **✨ 单习惯 streak 分享长图**：单个习惯战绩生成竖版分享图，支持浅/深主题切换，可保存相册或分享。
- **🐛 修复分享长图页脚溢出**：窄屏（360px）下页脚两行总宽超卡片内宽 77px，导出 PNG 会裁切 gitee 地址；改为 `Flexible` + 省略号彻底解决。
- `flutter analyze` 0 error，`flutter test` **280/280 全绿**（新增 6 个用例，无回归）。版本升至 v2.5.4（versionCode 75）。

## v2.5.3（2026-08-11）

- **🔧 KGP 插件迁移（构建可靠性）**：将 4 个仍在构建期触发「plugins that apply Kotlin Gradle Plugin」警告的插件升级到内置 Kotlin 兼容版本，消除 Flutter 未来版本中潜在的构建失败风险——`dynamic_color ^1.7.0→^1.9.0`、`share_plus ^10→^13.0.0`、`package_info_plus ^9→^10.0.0`、`add_2_calendar ^2→^3.1.1`；为解开 `win32 ^5 vs ^6` 依赖冲突、实现四个插件全量脱 KGP，将 `file_picker` 升级到 `^12.0.0-beta.1`（当前唯一脱 KGP 版本，为 beta）。调用点仅适配 `share_plus`（`SharePlus.instance.share(ShareParams(...))`）与 `file_picker`（`FilePicker.pickFiles(...)`，删除已移除的 `.platform` 访问器）；另两插件 API 兼容无需改动。
- **🔧 首选项持久化加固（SP 可靠性）**：为防御 ColorOS / Realme 等激进 ROM 在进程被杀时 `shared_preferences.apply()` 丢写，于 `main.dart` 应用生命周期 `paused/detached` 时统一调用各 Provider / 服务的 `persist()` 兜底落盘（新增 `FocusProvider` / `OnboardingProvider` / `FocusAudioService` 的 `persist()`；`FocusAudioService` 加 `_initialized` 标志，避免未初始化时用默认值覆盖真实偏好）。
- `flutter analyze` 0 error，`flutter test` **274/274 全绿**；release 构建已验证 KGP 警告彻底消失。
- 版本升至 v2.5.3（versionCode 74）。

## v2.5.2（2026-08-11）

- **✨ 稍后提醒（snooze）**：任务 / 习惯通知新增「稍后提醒」按钮，点击后于 10 分钟后以**覆盖式**重新提醒（复用原通知 id，不叠加新通知、不刷屏）；冷启动点按同样支持暂存并在导航就绪后跳转。
- **🔧 消除 `HabitHeatmap` 重名**：`focus_chart.dart` 中的热力图组件与习惯页同名类冲突，改名 `FocusHabitHeatmap`，避免潜在命名污染。
- **🔧 校正 CHANGELOG「归档」虚标**：`task_detail` 仅做编辑 + 删除，并无归档动作，移除此前不实记录。
- **🔧 修复 `search_render_test` 卡死**：测试补齐通知通道 mock（headless 下未挂载 `dexterous.com/flutter/local_notifications` 通道导致 `addHabit`→`scheduleHabitReminder` 永久挂起），并将 `_settle` 改为有限手动 `pump`（`pumpAndSettle` 本版无 `timeout` 形参）。
- `flutter analyze` 0 error，`flutter test` **274/274 全绿**。
- 版本升至 v2.5.2（versionCode 73）。

## v2.5.1（2026-08-11）

- **🐛 修复「从零开始」示例任务重启复活**：引导页选「从零开始」后，退出重进示例任务又出现。根因是 `TaskProvider.load()` 把「空库」误判为「全新安装」重新落盘 7 条示例，且 7 条 mock 写在字段初始化器里、每次启动都会被装回内存。新增持久标志 `samples_seeded_v1`，仅首次且未清空过时预置示例；`clearSampleTasks()` 改为 async 并在清空后写入该标志，杜绝重启复活。新增 2 个回归测试（从零开始→重启不复活 / 全新安装仍预置示例）。`flutter analyze` 0 error，`task_provider_test` 41/41、`onboarding_test` 5/5 全绿。
- 版本升至 v2.5.1（versionCode 72）。

## v2.5.0（2026-08-11）

- **✨ 提醒提前量（提前 N 分钟响铃）**：任务新增 `reminderOffsetMin` 字段（默认 0，向后兼容旧数据）。「新建/编辑任务」中，当任务为「不重复 + 有截止时间」时，在「截止时间」下方新增「提醒提前量」下拉（准时 / 提前 5 / 10 / 15 / 30 / 60 分钟）；调度逻辑在 `NotificationService.scheduleForTask` 内将触发时刻改为 `截止时间 - 提前量`。仅对一次性截止提醒生效，重复任务走各自的 `repeatMinute` 不受影响。新增 `reminder_offset_test` 5 个用例（默认值 / json 往返 / 旧数据回退 / copyWith）。`flutter analyze` 0 error，新单测全绿。
- 版本升至 v2.5.0（versionCode 71）。

## v2.4.9（2026-08-11）

- **✨ 通知点击跳转任务详情**：任务 / 重复 / 习惯提醒现在携带 `payload`（`task:` / `habit:` 前缀 + 实体 id），点击通知直接从应用内导航到对应任务详情页或习惯页；冷启动（被杀后点开通知）也能正确跳转——`main.dart` 注入根 `navigatorKey`，`NotificationService.onNotificationTap` 按前缀解析并 `push`，导航器未就绪时暂存 `pending` 待首帧消费。新增 `parseTaskId` / `parseHabitId` 解析助手与 6 个单测。`flutter analyze` 0 issue。`flutter test` 通过（新增 payload 解析用例 6 项；`search_render_test` 2 项超时属历史遗留、与本次无关）。
- 版本升至 v2.4.9（versionCode 70）。

## v2.4.8（2026-08-10）

- **🔧 首次启动引导页改为「不可跳过」**：删除原右上角「跳过」按钮，必须走到末页「开始使用」才进入主页，强制新用户看完引导、建立本地优先认知。引导三屏内容不变（屏1 本地优先理念 / 屏2 核心能力地图 / 屏3 开启提醒 + 精确闹钟引导 +「保留示例 / 从零开始」二选一）。
- 版本升至 v2.4.8（versionCode 69）。

## v2.4.7（2026-08-10）

- **✨ 首次启动引导页（新装必看）**：全新安装首次打开进入 3 屏轻量引导页（右上「跳过」随时可走，标记位存 `shared_preferences`，看过即不再弹）。
  - **屏1 欢迎 + 本地优先理念**：明确「数据只存你手机、无需账号、不上传云端」，在首屏建立隐私信任；引导文案严格不提及同步 / 云账号，与 App 本地优先定位一致。
  - **屏2 核心能力地图**：六宫格展示速记建单 / 习惯热力图 / 看板 / 全局搜索 / 专注计时 / 日历，全部为 App 已有功能，帮新用户快速建立功能认知。
  - **屏3 开启提醒 + 首启示例选择**：先讲清「任务 / 习惯到点提醒」为何要授权，并针对 ColorOS 提示精确闹钟权限以提升授权转化率；再用「保留示例 / 从零开始」二选一接管 `TaskProvider` 首启预置的 7 条示例任务，比默默塞示例更体面（新增 `clearSampleTasks()`）。
- 启动路由加门控：`OnboardingProvider` 读取 `hasSeenIntro`，未看过走 `OnboardingScreen`、看过直进主页，零新增存储。`flutter analyze` 0 issue，`flutter test` 全绿（新增 onboarding 用例 6 项）。
- 版本升至 v2.4.7（versionCode 68）。

## v2.4.6（2026-08-10）

- **✨ AI 周报/月报自动文案**：回顾周报与月报/年报页新增「AI 小结」卡片——本地模板式自然语言生成（纯 Dart、复用 Provider 公开状态内存现算、零新增存储、不接 LLM），空数据返回鼓励语不崩；分享长图同步纳入 AI 小结，导出即带本周/本期一句话总结。
- **🔧 修复分享卡 Inter 字体溢出（真实生产 bug）**：分享卡在强制浅色 Inter 主题下数值卡底部 0.647px 溢出、页脚 gitee 链接 77px 右溢出；修复 `StatCard` 内边距（14→12）与页脚链接 `Expanded`+省略号约束，旧 Roboto 冒烟测试未能暴露此真实生产缺陷。
- **🔧 修复习惯 id 撞车（真实数据损坏）**：`HabitProvider.addHabit` 同毫秒内两次调用拿到相同时间戳 id，按 id 存 Map 静默丢习惯、打卡串号；改为叠加进程内自增序号保证唯一。
- 全部基于现有任务/专注/习惯三套数据聚合，零新增存储，升级无需迁移。`flutter analyze` 0 issue，`flutter test` 253 项全绿。
- 版本升至 v2.4.6（versionCode 67）。

## v2.4.5（2026-08-10）

- **🔥 习惯打卡热力图**：习惯页新增「打卡热力图」卡片（近 18 周密度网格）与「连续天数」排行区；打卡密度支持单习惯二值高亮 / 多习惯聚合分级着色，连续天数用火焰徽章突出展示，习惯条目副标题统一改用 StreakBadge，可视化长期坚持轨迹。
- **💾 数据备份与导出补齐习惯盲区**：本地备份包 / CSV / Markdown 导出现已纳入习惯与打卡记录（此前仅覆盖任务与专注，恢复会丢习惯）；备份 schema version 升级至 3，老备份无 habits 字段时跳过恢复、不会清空现有习惯。换机 / 误删的数据安全保险丝补上。
- 全部基于现有任务 / 专注 / 习惯三套数据聚合，零新增存储，升级无需迁移。`flutter analyze` 0 issue，`flutter test` 247 项全绿。
- 版本升至 v2.4.5（versionCode 66）。

## v2.4.4（2026-08-09）

- **✨ 自然语言快速录入（B 线）**：首页右下角 FAB 唤起快速录入，一句话解析截止时间 / 优先级 / 分类 / 标签（支持「下周三」自然周语义与每日 / 每周 / 每隔 N 天 / 工作日重复规则）；实时 chip 预览，可一键转入完整编辑。
- **🔎 全局搜索升级为「任务 + 习惯」分组（D 线）**：搜索结果覆盖任务与习惯，按分组展示；习惯命中标题 / 频率 / 提醒时间，点结果直达习惯 Tab。
- **📅 月报 / 年报 + 成就墙分组（C 线）**：首页右上角「月报 / 年报」入口进入独立回顾页，含本期完成 / 专注分 / 番茄数 / 习惯达成率 4 指标 + 环比、按天（月报）/ 按月（年报）趋势、专注去向 Top、习惯达成、分类分布；内置浅 / 深色分享长图。成就墙按习惯 / 任务 / 专注 / 综合分组，计数型带进度条与「32/50」进度，底部「即将解锁」提示。
- 全部基于现有任务 / 专注 / 习惯三套数据实时聚合（零新增存储、不新增第 7 个 tab），升级无需数据迁移。`flutter analyze` 0 issue，`flutter test` 240 项全绿。
- 版本升至 v2.4.4（versionCode 65）。

## v2.4.2（2026-08-09）

- **✨ 新增「回顾周报」模块（低成本高获得感）**：零新存储，全部从任务 / 专注 / 习惯三套 Provider 公开状态聚合计算，不新增任何表或字段。
  - 首页新增「本周回顾」摘要卡（本周完成数 / 专注分钟 / 习惯达成率 + 周区间），仅默认全量视图、非搜索态显示；点击进入独立周报页。
  - 周报页（`review_screen`）含：2×2 核心指标（本周完成 / 专注分钟 / 番茄数 / 习惯达成率）、本周 Mon–Sun 每日完成趋势（含上周环比）、专注去向 Top3、习惯达成率进度条、分类完成分布。
  - 内置分享长图（`ReviewShareCard`）：强制浅 / 深色主题 + 关闭系统字体缩放，支持保存到相册或系统分享；分享面板支持明暗一键切换。
  - 入口沿用「首页摘要卡 + 独立页」两屏方案，不新增第 7 个底部 tab（保持 Material 3 导航节奏）。
  - 新增文件：`models/review.dart`、`widgets/review_card.dart`、`screens/review_screen.dart`、`widgets/review_share_sheet.dart`；改动：`screens/home_screen.dart` 接入摘要卡。`flutter analyze` 0 issue，`flutter test` 全绿（131 项）。
- 版本升至 v2.4.2（versionCode 63）。

## v2.4.1（2026-08-08）

- **🔥 修复「重复」分区任务标题不显示（渲染层根因）**：v2.4.0 修复了数据层 `title` 的 null 兜底，但用户升级后重复区部分任务（如「背单词」）仍整行空白。经多轮真机诊断（黄底探针→码点显影→红块→边界标记→固定宽度对照），锁定真正根因为**布局层**：首页各分区用 `ReorderableListView`（shrinkWrap + NeverScrollable）嵌套在 `SingleChildScrollView` 中，该嵌套滚动约束下任务行 `Row` 的弹性插槽收到**零宽度**，导致标题 `Expanded` 被压扁到不可见（重复区布局最先暴露此问题）。
  - `task_row.dart`：标题区由 `Expanded` 改为固定 `SizedBox(width: 80)`（绕过零宽约束，长标题走省略号）；右侧 MetaInfo 由「多层嵌套 Row（图标+文字）→ 外层 Row」重写为**单个 `Text` 字符串拼接**（内联 `↻`/`⏱` Unicode 图标），彻底消除窄空间下图标与文字重叠/溢出的结构性矛盾。
  - 已完成区隐藏时间信息：已完成任务不再渲染截止时间 / 循环提醒 / 专注时长，行布局只剩「色条 + 勾选框 + 标题」，干净无空白、无溢出。
  - 新增 2 个 `task_row` 回归测试（空标题渲染 `(无标题)`、有标题渲染真实标题）。`flutter test` 全绿（131 项）。
- 版本升至 v2.4.1（versionCode 62）。

## v2.4.0（2026-08-08）

- **🔥 修复「重复任务名称不显示」**：首页「重复」分区的任务标题区域空白，只剩重复规则（如「每天 07:00 8月15日 23:59」）。根因：`Task.fromJson`（`task.dart`）读取标题用 `j['title'] as String` **无 null 兜底**，而同文件 `note` 字段正确写了 `?? ''`；当 JSON 中 `title` 为 `null` 或键缺失时（旧版备份恢复 / 数据迁移等边界路径），标题变成空字符串，`TaskRow` 直接渲染空串 → 空白行。普通任务因有标题不受影响，故仅「缺标题」的重复任务暴露此问题。
  - `task.dart`：`Task.fromJson` 标题改为 `(j['title'] as String?) ?? ''`（与 `note` 对齐）。
  - 防御性 UI：空标题时首页 / 详情 / 日历 / 看板均显示 `(无标题)`，通知显示 `无标题任务`，避免诡异空白行。
  - 新增 3 个回归测试（null 标题 / 键缺失 / 空串往返）。`flutter test` 全绿（129 项）。
- 版本升至 v2.4.0（versionCode 61）。

## v2.3.9（2026-08-08）

- **🔥 修复「纯黑背景」开关重启后不持久**：开启纯黑背景、退出再进 App 又变回非纯黑。根因：`shared_preferences_android` 底层写盘用 `apply()` 而非 `commit()`（内存即时、磁盘异步，进程被杀前不保证刷盘），叠加设置开关回调为 `void Function(bool)`，纯黑写盘未被 await，关 App 太快会丢写。因纯黑是唯一「非默认值」项，其它开关丢写无感，故仅纯黑表现为丢持久化。
  - `settings_row.dart`：`onSwitchChanged` 改为 `Future<void> Function(bool)?`，`Switch.onChanged` 内 `await`，点一下立即触发落盘。
  - `theme_provider.dart`：新增 `persist()`，把全部主题首选项重新落盘。
  - `main.dart`：`MainScaffold` 加 `WidgetsBindingObserver`，在 `paused`/`detached`（进程将死）时调 `theme.persist()` 兜底刷盘。
  - `task_provider.dart`：`setNotificationsEnabled`/`setSoundEnabled` 由 `void` 改 `Future<void>` 并 `await` 落盘（与同类一致）。
  - 新增 3 个主题测试：跨实例 round-trip、动态取色分支纯黑、`persist()` 全量落盘。`flutter test` 全绿（126 项）。
- 版本升至 v2.3.9（versionCode 60）。

## v2.3.8（2026-08-07）

- **任务详情页**：单击任务进入详情页，分区查看优先级色条 / 标题 / 完成状态、备注全文、标签、截止与重复规则、累计专注时长；子任务清单可逐项勾选（实时刷新 done/total 进度）；底部操作栏支持编辑、开始专注与删除。
- **专注可视化（零依赖自绘）**：专注页底部新增「近 7 日」专注时长柱状图（CustomPaint 绘制，复用主题色 token）与习惯打卡热力（GridView 小方块），直观呈现专注节奏与打卡连续性。
- 版本升至 v2.3.8（versionCode 59）。`flutter test` 全绿（123 项）。

## v2.3.7（2026-08-07）

- **习惯打卡提醒**：习惯现在可设置「每日提醒」时间（默认 21:00，可清除）。
  - 打卡日为「每天」则每天到点提醒；选了具体星期则按每个星期各提醒一次。
  - **今天已打卡则自动跳过今日**，直接挂到下一个循环日，不会「已完成还催你」。
  - 沿用 setAlarmClock 调度，息屏/省电模式下也能准点弹出，不被 ColorOS 拦截。
  - 习惯页：新建弹层新增「每日提醒」行；列表项 🔔 时间芯片点击改时间、长按清除。
- **从任务一键开始专注**：任务行未完成任务新增「专注」按钮，点击直达专注页并预选该任务，计时中在大圆环下方显示关联任务名；切走再切回时从进行中会话恢复关联任务，不再退化成「独立专注」。
- 修复：习惯 id 为毫秒时间戳，直接作通知 id 会超 int32 导致建/删带提醒习惯失败（已折叠到独立 id 段）；`Habit.copyWith` 支持显式清除可空字段。
- 版本升至 v2.3.7（versionCode 58）。

## v2.3.6（2026-08-07）热修复

- **🔥 修复启动卡 splash 白屏**：v2.3.5 新增的 `ThemeProvider` / `HabitProvider` 在 `main()` 中串行加载，任一抛出未捕获异常会导致 `runApp()` 永远不被调用，app 卡在启动页无法进入。
  - `main()` 全部 `await load()` 加 `_safeLoad()` try-catch 容错：单个 Provider 加载失败时打印日志并跳过，不影响其他模块，**确保 runApp() 始终被调用**。
  - `HabitProvider.load()` / `_persistHabits()` / `_persistCheckIns()` 加独立 try-catch：DB 升级（version 1→2）或新表查询异常时优雅降级（习惯功能暂不可用，但主界面正常）。
  - `DynamicColorBuilder` 内的 `buildThemes()` 加 try-catch + 默认主题 fallback：动态取色异常时不崩溃。
- 版本升至 v2.3.6（versionCode 57）。

## v2.3.5（2026-08-07）

- **主题自定义 / Material You**：应用主题现在可由用户自定义。
  - 新增独立的主题状态管理（ThemeProvider），从任务状态中剥离，SharedPreferences 持久化。
  - 跟随系统动态取色（Material You / `dynamic_color`）：自动采用系统壁纸配色；关闭或取色不可用时回退到种子色 / 默认品牌色。
  - 种子色主题：内置 6 种预设色板 + 默认品牌色，可手动选定；新增「纯黑背景」深浅色开关。
  - 设置页新增一组控件：跟随系统 / 深色模式 / Material You 跟随取色 / 纯黑背景 / 主题色板（选中白边 + 对勾）。
- **习惯打卡 / 成就**：新增第六个底部导航「习惯」。
  - 习惯模型：标题、emoji、颜色、每周打卡日；打卡以「日期」为单位稳定去重（主键 `$habitId@YYYY-MM-DD`）。
  - 习惯页：今日 / 连续 / 累计概览，圆形勾选打卡；连续天数与最长连击统计（支持「今天未打卡但昨天连着」的容差）。
  - 成就系统：8 项成就（首次打卡 / 连续 3 天 / 连续 7 天 / 打卡满 100 次 / 建立 3 个习惯 / 完成任务 50 / 专注 60 分钟 / 全成就），按当前数据自动解锁并高亮。
  - 数据层：SQLite 新增 `habits` / `check_ins` 两表（整段 JSON 存储，版本升 2），旧库首启自动迁移，**无需手动操作**。
- 版本升至 v2.3.5（versionCode 56）。

## v2.3.4（2026-08-07）

- **标签（Tags）**：任务支持用户自定义自由标签（如「紧急」「会议」），用于检索与筛选。
  - 新建/编辑任务弹层新增「标签」分区：输入框回车或加号成 chip，可单独删除；下方展示全库已有标签供一键快捷添加。
  - 首页搜索框命中范围扩展至标签（标题/分类/优先级/备注/重复规则 + 标签）。
  - 首页新增「标签筛选」芯片行：存在标签时显示，点击切换筛选、再点取消；与分段筛选、拖拽重排互斥于全量视图。
  - 任务行在有标签时显示「#标签」小圆角块（高 64→78 自适应）。
  - 数据模型 `Task` 新增 `tags` 字段（字符串列表），序列化进任务 JSON，复用 SQLite 存储，**无需数据库迁移**，旧数据缺省空列表兼容。
- **专注时长回填任务**：专注会话（带关联任务）结束后，其时长自动累加进任务的「累计专注」字段，任务行右侧显示「🍅 N分钟」。专注 Provider 通过 `onFocusRecorded` 回调联动任务 Provider 的 `addFocusSec`，无关联任务或独立专注不受影响。
- **拖拽排序**：首页各分区（逾期/今天/未来/每天/已完成）支持长按左侧拖拽手柄手动重排，顺序写入任务的 `order` 字段持久化（手动顺序优先于日期排序）。新建任务自动落点至对应分区末尾，不破坏既有手动顺序。
- 版本升至 v2.3.4（versionCode 55）。

## v2.3.3（2026-08-07）

- **子任务清单**：任务可拆分为可勾选的细项并跟踪进度。
  - 新建/编辑任务弹层新增「子任务」分区：输入框添加、点文案改名、勾选框标记完成、✕ 删除。
  - 任务行在有子任务时显示「✓ 已完成/总数」进度徽标 + 细进度条（高 64→78 自适应）。
  - 数据模型用 `List<SubTask>` 取代原有的 `subtaskTotal/subtaskDone` 两个整数字段，进度由列表派生；`subtasks` 序列化进任务 JSON，复用 SQLite 存储，**无需数据库迁移**，旧数据缺省空列表兼容。
  - 新增/调整单元测试覆盖 `SubTask` 序列化、`Task.subtasks` 派生进度与兼容。`flutter test` 全绿。
- 版本升至 v2.3.3（versionCode 54）。

## v2.3.2（2026-08-07）

- **APK 大幅瘦身（↓57%，85MB → 36.6MB）**：
  - 构建只编 `arm64-v8a`（原 universal 含 arm64 / armeabi-v7a / x86_64 三套原生库），`lib/` 由 55.8MB 降至 19.1MB。现代手机（含本机 Realme）均为 64 位，32 位老设备仍可下载 v2.3.1 的 universal 包兜底。
  - 环境音循环时长 120s → 50s（雨声 / 海浪 / 篝火 / 风声 四个长循环按原合成算法重算，单声道 22050Hz 不变，50s 恰好是 0.08/0.1/0.2Hz 潮汐 LFO 周期整数倍，无缝循环），`assets/` 由 23.0MB 降至 11.2MB。
  - `classes*.dex`（Dart 代码）维持不变——当前 JDK25/Gradle9.1 下 R8 会崩，故不靠它压缩。
- 版本升至 v2.3.2（versionCode 53）。

## v2.3.1（2026-08-07）

- **番茄钟循环专注**：专注页新增「番茄循环」开关，开启后在 专注 / 短休 / 长休 之间自动循环。
  - 三阶段时长与「每几轮长休一次」均可在设置中自定义（默认 专注 25 / 短休 5 / 长休 15，每 4 轮长休）。
  - 阶段运行态（当前阶段 / 本轮回合已完成数 / 轮次）随计时持久化，杀后台或切 Tab 不丢，重启后自动续跑下一阶段。
  - 专注完成提示「该休息」，休息结束提示「开始下一个番茄」；锁屏进度通知按阶段显示「专注中 / 休息中」与剩余时间。
  - 统计口径收敛到专注阶段：「今日专注」只计专注时长、「完成番茄」只计专注阶段跑满次数（休息不计入）；趋势图同步改为专注阶段口径。
  - 今日记录与分享卡按阶段显示图标（🔥专注完成 / ⏱专注片段 / ☕休息）。
  - 对应单元测试：`nextPhaseFrom` 阶段切换、`FocusPhase` 序列化、番茄循环配置持久化、专注阶段统计口径。`flutter test` 全绿（69 项）。

## v2.3.0（2026-08-07）

- **无截止日期任务归入「今天」段**：首页与看板「当日事件总数」现在把没有截止日期的非循环任务视为当天事务（此前被归入「未来」段）；因截止日期为空恒等于「今天」，跨天自动顺延到第二天，无需额外重置逻辑。循环（每天）任务与逾期口径保持不变（无截止任务永不计入逾期）。
- 版本升至 v2.3.0（versionCode 51）。`flutter test` 全绿（63 项）。

## v2.2.9（2026-08-06）

- 固化看板「当日事件」行为：新增回归测试，证明「之前设置的每日任务（截止日早于今天）也计入当日事件」，与创建日期无关；`flutter test` 全绿（60 项）。
- 版本升至 v2.2.9（versionCode 50）。

## v2.2.8（2026-08-06）

- 看板「逾期」统计与首页口径对齐：循环任务（重复规则≠不重复）不再被计入「逾期」，避免「每天/每周」等循环任务因截止日设在创建当天而被误标为逾期（与首页「每天」分区逻辑一致）。
- 说明：看板「当日事件」自 v2.2.7 起已通过循环日（`repeatsOn`）把「重复≠不重复」的任务计入当天、与创建日期无关；本次仅修正逾期口径的一致性。
- 新增回归测试：循环任务（过去截止日）计入当日事件且不被标逾期。版本升至 v2.2.8（versionCode 49）。

## v2.2.7（2026-08-06）

- **看板概览改为当日口径**：完成率卡片与统计网格的「已完成 / 总任务」改为「当日已完成 / 当日事件总数」——只统计截止今天或今天为循环日的任务（不含已删除），逾期指标保持不变。看板顶部「概览」由此成为真正的「今日概览」。
- 版本升至 v2.2.7（versionCode 48）。

## v2.2.6（2026-08-06）

- **专注页布局优化**：将「专注历史趋势图」下移，置于大圆环计时钟下方（原本在数据统计区上方），让专注计时更靠前突出、趋势走势紧随其后。
- 版本升至 v2.2.6（versionCode 47）。

## v2.2.5（2026-08-06）

- **深化专注 Tab**：
  - 专注页接入「专注历史趋势图」（日/周/月专注时长走势，与看板页一致）。
  - 新增「关联任务」可选入口：开始专注前可选择一个任务（也可留空＝独立专注），完成后写入会话。
  - 新增「任务专注统计」：按关联任务聚合累计时长与次数，直观看每件事花了多少时间。
  - 新增**锁屏常驻进度通知**：专注进行中时状态栏/锁屏持续显示剩余时间并随每秒刷新（暂停/停止/完成自动取消）。
  - 专注结束自动「记一笔到日历」：**应用内日历**对应日期显示该次专注；并在设置中新增「专注结束记入系统日历」开关（默认关闭），开启后每次专注结束自动写入系统日历事件。
- 版本升至 v2.2.5（versionCode 46）。

## v2.2.4（2026-08-06）

- **本地存储迁移至 SQLite**：任务、回收站与专注记录原先全部以单个 JSON 字符串存于 SharedPreferences，现已迁入 sqflite 数据库（tasks / trash / focus_sessions 三张表）。旧版 SharedPreferences 中的 JSON 会在首次启动时自动迁移到数据库并清除旧 key，老用户数据无缝升级、不丢失。
- 版本升至 v2.2.4（versionCode 45）。

## v2.2.3（2026-08-06）

- **修复「检查更新」跳转浏览器下载**：改为应用内直接下载 APK（http 流式下载到外部缓存，带实时进度条），下载完成后经 FileProvider + 系统安装器直接安装，不再跳转到外部浏览器；仅保留「浏览器下载」作为失败兜底。
- 版本升至 v2.2.3（versionCode 44）。

## v2.2.2（2026-08-05）

- 发版流程自动化：新增 _build2.py 一条龙脚本，自动从 pubspec 同步 local.properties 版本，串起「改版本→构建→提交→打标签→推送→发 Gitee」，并清理历史构建垃圾
- 版本号三处（pubspec / local.properties / Settings 兜底）与 update.json / CHANGELOG / README 随发版自动同步，彻底杜绝不一致
- 版本升至 v2.2.2（versionCode 43）。

## v2.2.1（2026-08-05）

- **修复「检查更新」HTTP 403**：Gitee 自 2026-08 起对匿名 `api/v5` 访问统一返回 403，原「检查更新」依赖的发行版 API 因此失效。改为在仓库内维护一份静态清单文件 `update.json`，App 通过 Gitee 的 raw 文件访问（公开仓库无需鉴权）读取最新版本号与下载直链，彻底绕开 API 封锁。
- 版本升至 v2.2.1（versionCode 42）。

## v2.2.0（2026-08-05）

- **专注环境音：淡入淡出 + 多音叠加**：
  - **淡入淡出**：切换 / 停止环境音时音量做 500ms 线性渐变（而非硬切），消除突兀的爆音与静默断层，听感更柔和自然。
  - **多音叠加**：环境音从「单选一种」升级为「可多选同时播放」，雨声+海浪、篝火+风声等任意组合实时叠加；专注页改为多选芯片，可一键「关闭」清空全部。
  - **底层重构**：`FocusAudioService` 改为 `Map<FocusSoundType, AudioPlayer>` 多播放器架构，引入 `_epoch` 计数防止「异步淡出途中又被新指令打断」的竞态；`setTypes(Set)` 按集合差量只对新加入 / 移除的音做淡入 / 淡出，互不干扰。
  - **持久化迁移**：旧的单一整型偏好 `focus_sound_type` 自动迁移为字符串列表 `focus_sound_types`（旧值 0→空集合、>0→对应音），老用户无感升级，读后删除旧 key。

## v2.1.9（2026-08-05）

- **专注页 UI 优化**：控制按钮（停止 / 播放）与环境音卡片之间增加 16px 垂直间距，布局更透气协调。
- 版本升至 v2.1.9（versionCode 40）。

## v2.1.8（2026-08-05）

- **新增四种柔和专注环境音（雨声 / 海浪 / 篝火 / 风声）**：替换原先偏「机器感」的纯白噪音，听感更自然、更适合长时间专注。四种音均为程序化合成（零版权，无第三方音频素材）：雨声=带通白噪音、海浪=棕噪音+极慢潮汐起伏、篝火=低频暖隆隆+轻微火焰嘶嘶、风声=带通粉噪音+缓慢变频；均做头尾交叉淡化实现无缝循环。`FocusSoundType` 枚举在 `brown` 之后追加 `rain/ocean/campfire/wind`（保持既有枚举索引不变，已存的用户偏好不受影响），专注页环境音卡片自动出现新选项。
- 版本升至 v2.1.8（versionCode 39）。

## v2.1.7（2026-08-05）

- **专注环境音改用 just_audio 播放引擎**：原先的 audioplayers 在 Android 上从 asset 播放 WAV 始终无声（路径 lookup / 音频路由问题），替换为 Flutter 社区最稳定的 just_audio，彻底修复白 / 粉 / 棕三种噪音无法播放的问题。

## v2.1.6（2026-08-05）

- **修复专注环境音无声**：原实现中「是否该播放」标志仅在音效非关闭时于专注开始处设置，导致**先点「开始专注」再选音效**的路径完全无声。重构 `FocusAudioService`，将「选了哪种音效」与「专注是否进行中」两个维度彻底解耦，无论先选音效还是先开始专注都能正确播放；并改用更可靠的 `play(..., mode: loop)` 启动循环播放。

## v2.1.5（2026-08-05）

- **专注环境音**：番茄钟新增可选背景音（关闭 / 白噪音 / 粉噪音 / 棕噪音 + 音量调节）。音源为程序化生成的三种可无缝循环噪音 WAV（零版权），仅在专注进行中播放，选择记忆到本地。新增 `audioplayers` 依赖。

## v2.1.4（2026-08-05）

- **修复「检查更新」报错 HTTP 404**：更新检测请求的 Gitee API 域名路径误用了已失效的 `api/v3`，改为现行 `api/v5`（`releases/latest` 端点），手动「检查更新」与启动自动检测均可正常拉取最新发行版。

## v2.1.3（2026-08-05）

- **应用内更新检测**：启动后自动检测 Gitee 发行版（每日最多提示一次，可「跳过此版本」不再打扰），发现新版本弹窗展示更新说明并一键跳转下载 APK；设置页新增「检查更新」手动入口。新增 `http` / `url_launcher` 依赖与 `INTERNET` 权限。
- 版本号回到 v2.1.x 线（此前 v2.2.0 发行版已撤回，未正式发布）。

## v2.2.0（2026-08-05，已撤回·未正式发布）

- **应用内更新检测**：同上方 v2.1.3 内容（该能力仍保留在代码中）。此版本号仅作内部尝试，发行版已撤回，用户请以 v2.1.3 为准。

## v2.1.2（2026-08-05）

- **备份文件可靠性修复**：
  - 备份 JSON 改为带缩进的多行格式（`JsonEncoder.withIndent('  ')`），便于人工查看、分段恢复数据（此前 `jsonEncode` 无 `indent` 参数会导致单行超长）。旧的紧凑格式备份仍可正常恢复（`jsonDecode` 对空白不敏感）。
  - `saveToAppDocs` 改为原子写（先写 `.tmp` 再 `rename` 覆盖），避免写入中途被杀后台 / 断电导致整文件 JSON 损坏、备份报废。该改动同时惠及「导出 CSV / Markdown」。

## v2.1.1（2026-08-05）

- **番茄钟数据并入备份与导出**：「备份与恢复」「导出数据」现在同时包含番茄钟每日专注记录。备份 JSON 新增 `focus_sessions` 字段（含每次专注的开始/结束/计划时长/实际时长/是否完成/关联任务），恢复时一并还原；CSV / Markdown 导出在任务内容之后追加专注记录段落，便于查找与恢复数据。

## v2.1.0（2026-08-05）

- **番茄钟后台存活**：专注计时逻辑从页面 `State` 下沉到 `FocusProvider`（顶层常驻，切 Tab / 杀后台不销毁）；剩余时间改用墙钟时刻推算，运行态持久化到 `SharedPreferences`，被杀后重新打开 App 按持久化起点恢复（未跑满继续累计、已跑满静默补录），时长零丢失。
- **番茄钟完成提醒**：复用 `NotificationService` 的 `setAlarmClock` 模式（ColorOS / Realme 被杀后仍准点触发），开始 / 恢复时在「完成时刻」挂系统闹钟通知，暂停 / 停止 / 自然完成时取消或覆盖。

## v2.0.9（2026-08-05）

- **日历增强**：日历 Tab 升级为「月视图 / 周视图」分段切换。
  - 月视图每日期格保留完成热力底色，当天到期任务以条状呈现；条状任务支持**长按拖拽**到任意日期格，**松手即改期**（`dueDate` 变更后自动重排提醒），并弹「已改期至 X月X日」提示。
  - 周视图横向 7 列展示，沿用同一套拖拽改期交互。
  - 已完成任务灰显且不可拖；日期格作为放置目标实时高亮。
  - 任务详情弹窗改用 `Consumer` 刷新，改期后明细即时更新。

## v2.0.8（2026-08-05）

- 专注趋势上墙：看板页新增「专注趋势」区块，复用 TrendStats 同一套图表组件按周/月/年展示每日专注时长（含上一周期对比）。
- 抽取共享 `TrendChart` 组件，`TrendStats` 与 `FocusTrendStats` 共用，视觉与交互统一；专注趋势与专注 Tab 呼应。

## v2.0.7（2026-08-05）

- **彻底移除「进行中」状态**：`TaskStatus` 精简为 `{todo, done}`；看板、首页筛选、「进行中」统计卡/芯片、分享卡一并移除。
- 存量 `doing` 任务在 `Task.fromJson` 安全映射回 `todo`，旧数据不丢、不崩。
- 看板概览改为「总任务 / 已完成 / 逾期」三卡一行。

## v2.0.6（2026-08-05）
- 调整：看板底部改为两列布局，移除「进行中」列（仅保留「待办」与「已完成」）。单击卡片直接在 待办↔已完成 间切换；长按拖拽仍可在两列间改状态。
- 版本号升至 v2.0.6（versionCode 25）。

## v2.0.5（2026-08-04）
- 新增：专注记录「删除」与「分享」。
  - 删除：每条记录支持左滑删除（右滑红色背景），删除后弹「撤销」提示；列表头部新增「清空今日」按钮（二次确认后清空当天全部记录）。
  - 分享：新建专注分享长图卡片（`FocusShareCard`，支持浅/深色），列表头部「分享」按钮一键打开分享面板（`showFocusShareSheet`），可直接保存到相册或系统分享当天专注记录。
  - `FocusProvider` 新增 `removeSession(id)` 与 `clearToday()`，删除后即时持久化。
- 版本号升至 v2.0.5（versionCode 24）。

## v2.0.4（2026-08-04）
- 新增：专注页「自定义时长」功能。预设行末尾新增「自定义」芯片，点开弹窗可设置「分钟 + 秒」，并提供 10 / 20 / 30 / 45 / 60 / 90 分钟快捷选项；确认后切换到自定义模式，倒计时圆环、今日统计与专注记录均按自定义时长工作。
- 自定义时长本地持久化（shared_preferences，key `focus_custom_sec`，默认 30 分钟），下次进入仍生效；自定义模式按「专注」着色（非休息色）。
- 版本号升至 v2.0.4（versionCode 23）。

## v2.0.3（2026-08-04）
- 修复：专注页两个控制按钮（停止/重置 与 开始/暂停）大小不一致（56×56 vs 72×72），现统一为 64×64 等大圆形按钮。
- 修复：按钮内图标未居中（OutlinedButton/FilledButton 默认内边距导致偏移），已设 `padding: EdgeInsets.zero` 使图标严格居中。
- 移除：「关联任务」功能从专注页移除（简化交互，专注记录统一显示为「独立专注」）。
- 版本号升至 v2.0.3（versionCode 22）。

## v2.0.2（2026-08-04）
- 修复：底部导航第 5 个 Tab「专注」点进去却是设置页、而「设置」点进去却是专注页。`MainScaffold.pages` 的页面顺序与 `AppBottomNav._items` 的标签顺序不一致（专注/设置两个位置反了）。已把 `pages` 调整为与导航一致：`[首页, 看板, 日历, 专注, 设置]`，两个列表索引一一对应。
- 版本号升至 v2.0.2（versionCode 21）。

## v2.0.1（2026-08-04）
- 新增「专注计时（番茄钟）」功能，作为底部导航第 5 个 Tab（首页 / 看板 / 日历 / 专注 / 设置）。内置番茄钟倒计时（预设 25 / 5 / 15 分钟，支持开始 / 暂停 / 停止），可关联某个具体任务，自动记录每次专注时长与「今日专注统计」（总时长 + 完成番茄数）并本地持久化（shared_preferences）。此前该功能已实现于工作区但尚未发布，本次随 v2.0.1 一并发布。
- 版本号升至 v2.0.1（versionCode 20）。

## v2.0.0（2026-08-04）
- 修复：一次性「截止时间提醒」在任务提前完成后仍会弹出。非重复任务打勾完成后现在会取消其已调度的一次性截止提醒（含「应用内兜底」定时器一并拦截）；`scheduleForTask` 对已完成任务不再挂一次性截止提醒。此前 v1.9.8 只修了重复提醒，漏掉了一次性截止提醒。
- 版本号升至 v2.0.0（versionCode 19）。

## v1.9.9（2026-08-04）
- 新增「完成日历」Tab（底部导航第 3 项）：月历视图按每天完成数做热力着色（GitHub 贡献图风格），可前后翻月；点击有完成的日期弹出当天完成的任务明细（标题 / 分类 / 完成时间）。页顶展示「本月完成数 + 连续打卡天数」。复用既有 `completedAt` 数据，无需迁移；浅色/深色主题自适应。

## v1.9.8（2026-08-04）
- 修复：每天/每周/工作日/每隔N天等「重复提醒」任务，当天提前点击完成后，到原定时刻仍弹提醒。调度时增加「当天已完成（completedAt 为今日）则跳过今日、改挂下一个循环日」判定；`toggleDone`/`setStatus` 完成时重排提醒，用同一 notifyId 覆盖今日未触发的闹钟；午夜原生重置后次日照常提醒。

## v1.9.7（2026-08-03）
- 新增「连续打卡 streak」：看板页顶部展示连续完成天数（🔥）、历史最长连续与今日完成数；跨天中断自动归零（以「当天或昨天有完成记录」为存活判定）。
- 完成趋势升级为可切换周期：周 / 月 / 年 三视图。周视图保留「上周同期对比」；月视图为本月逐日；年视图为本年逐月。各视图附汇总指标（总数 / 日均或月均 / 最佳日或月 / 最长连续）。
- 复用既有 `completedAt` 数据，无需迁移，旧任务与「每天/每周/每隔N天/工作日」重复任务均计入打卡。
- 优化：完成趋势柱状图在内容不足一屏（如周视图 7 天）时自动居中，消除右侧留白；仅内容超出屏幕宽（月/年视图）时才横向滚动。

## v1.9.6（2026-08-03）

- **修复：新建任务选择「不重复」时保存按钮不可见**。根因：不重复模式下额外渲染「截止时间」区块，使弹层内容超出屏幕高度，底部「保存」按钮被裁切（键盘弹出时尤为明显）。修复：将弹层内容包进 `SingleChildScrollView`，并约束最大高度为「屏幕高 − 键盘高度 − 12」，内容超高时可滚动，保存按钮始终可达。

## v1.9.5（2026-08-03）

- **灵活重复规则**：在原有「每天」基础上新增「每周X / 每隔N天 / 仅工作日」，复用既有 00:00 重置 + 闹钟机制。
  - 模型：用 `RepeatType`（none/daily/weekly/interval/weekday）替代原 `dailyReminder` 布尔；新增 `repeatWeekdays`（每周所选星期）、`repeatInterval`（每隔N天）、`repeatMinute`（提醒时刻）、`repeatAnchor`（间隔锚点日期）。
  - 00:00 重置：Dart `_resetDailyIfNeeded` 与 Android 原生 `MidnightResetReceiver` 同步按 `repeatsOn(今天)` 判断——每天恒重置；工作日仅周一~周五；每周仅所选星期；每隔N天按锚点取模。仅在「今天是其循环日、且上次完成早于今天、且未过截止日」才重置为待办。
  - 提醒调度：`scheduleRepeatReminder` 按规则挂闹钟——每天用 `time` 组件；每周/工作日按所选星期逐个 `dayOfWeekAndTime`（各自独立 id）；每隔N天用「下次 occurrence 一次性 setAlarmClock」，App 启动/回前台时重排兜底。
  - 弹层 UI：「重复」分段（不重复/每天/每周/每隔N天/仅工作日）；每周显星期多选、每隔N天显间隔步进；任意重复类型都可设提醒时间；旧「每日提醒」开关移除。
  - 展示：首页「重复」板块（原「每天」）、看板/任务行/分享卡/搜索均显示规则摘要（如「每周 一、三 09:00」「每2天」「工作日」）。
  - 兼容：旧备份无 `repeat` 字段时，`dailyReminder=true` 回退为「每天」；`dailyReminderMinute` 回退为 `repeatMinute`。

## v1.9.4（2026-08-03）

- **任务备注（解释 / 说明）**：新建与编辑任务时新增「备注」多行输入框，可记录补充说明、链接、思路等。
  - 备注随任务持久化（`Task.note`，写进 shared_preferences JSON，兼容旧备份缺省为空串）。
  - 首页任务行在有备注时自动增高一行，灰色显示备注预览（单行截断）；编辑时回显既有备注。
  - 首页分享长图的任务明细行同步展示备注（隐藏标题开关开启时不显示）。
  - 首页搜索增加备注文本匹配，搜得到备注内容。
  - 注意：`TaskProvider.updateTask` 原本用 `old.copyWith(...)` 重建、未透传 `note`，已补 `note: updated.note`，否则编辑任务会清空备注。
  - 弹层布局优化：「备注」输入框上移到任务名称正下方、优先级上方，顺手位置更顺。

## v1.9.3（2026-08-03）

- **首页新增「搜索」功能**：顶栏搜索图标进入输入框模式，实时过滤全部任务。
  - 匹配范围：任务标题、分类（工作/生活/学习）、优先级（高/中/低），忽略大小写。
  - 结果以扁平列表复用现有任务行（保留滑动删除 / 编辑 / 多选），显示「找到 N 条」；空关键字提示「输入关键字搜索任务」，无结果显示「没有匹配的任务」。
  - 搜索态为本地 UI 状态，不污染全局 `TaskFilter`；退出搜索恢复日期分区视图。
- **搜索模式 UI 收口**：进入搜索后自动隐藏首页「新增任务」悬浮按钮与底部「首页 / 看板 / 设置页」导航栏，呈现纯净搜索界面，退出搜索一切复原。
- **修复：系统侧滑返回误退 App**：搜索模式（及多选模式）下，Android 边缘返回手势原本会直接 `pop` 根路由、退回桌面；现用 `PopScope` 拦截，侧滑改为先退出子模式回到首页，空态侧滑才退出 App。
- 版本号更新至 `1.9.3`（versionCode 12）。

## v1.9.2（2026-08-03）

- **首页新增「分享」功能（与看板页分享同源）**：把首页的日期分区清单一键生成竖版长图，保存到相册或直接分享。
  - 入口在首页右上角的分享图标，面板交互与看板页完全一致（实时预览 + 浅/深色卡片）。
  - 卡片内容**只含「日期分区」**（逾期 / 今天 / 未来 / 每天 / 已完成），不混入看板页的完成率、统计、优先级等分析板块——面板「包含内容」里也只有「日期分区」一个开关。
  - 每个分区**列出真实任务明细**：任务标题 + 分类 + 相对截止时间（如「今天 10:27」「8月16日 23:59」「每天 07:00」），行首色条跟随任务优先级，与首页分区口径（按天比较、互不重叠、空分区自动隐藏）完全一致。
  - 顶部品牌行随场景切换为「有条 · 我的清单」，保存到相册的文件名前缀为「有条清单」。
  - 复用既有的原生 `saveImageToGallery`（MediaStore 写入 `Pictures/有条`，免存储权限）与 `share_plus`，未新增任何依赖。
- 版本号更新至 `1.9.2`（versionCode 11）。

## v1.9.1（2026-08-03）

- **看板页新增「分享」功能**：把当前看板数据一键生成一张竖版长图，保存到相册或直接分享给好友。
  - 入口在看板页右上角的分享图标，点开是分享面板，**上方实时预览**整张长图，勾选什么就画什么，所见即所得。
  - **可勾选的板块**（6 个）：完成率、数据统计（总任务/已完成/逾期/进行中）、优先级、分类进度、近 7 日趋势、看板明细；默认前 5 项开启，「看板明细」默认关闭（含任务标题，避免误分享）。
  - **卡片外观**支持「浅色 / 深色」独立切换，与 App 当前主题解耦——深色聊天背景下也能发一张深色卡。
  - 勾选「看板明细」后可再开「**隐藏任务标题**」，只显示三列数量，不暴露具体任务内容（隐私优先）。
  - 卡片顶部为「有条 · 任务看板 + 日期」品牌行，底部为「有条 · 极简待办清单 + 开源地址」署名行。
  - 图片规格：360 逻辑像素宽的卡片按 pixelRatio 3 导出，成图约 **1080px 宽**的 PNG，微信/QQ 直发不糊。
  - 数据在打开面板的瞬间做快照，勾选切换时数字不会跳动；文字缩放锁定 1.0，系统字体放大也不会把版式撑乱。
- **新增「保存到相册」能力**：原生 `file_io` 通道新增 `saveImageToGallery`，走 MediaStore 写入 `Pictures/有条`，Android 10+ **无需任何存储权限**；分享则复用已有的 `share_plus`，全程未新增任何第三方依赖。
- 版本号更新至 `1.9.1`（versionCode 10）。

## v1.9.0（2026-08-03）

- **首页分区改为「真·按日期」切分**：由原来的「今天 / 每天 / 已完成」重构为 **「逾期 / 今天 / 未来 / 每天」四段 + 已完成**。
  - 此前「今天」实际是「所有未完成任务」的别名，一个月后到期的任务也堆在里面，名不副实；现在按截止日期真正落到对应分区。
  - 分区口径（互不重叠，一个任务只出现在一个板块）：
    - **逾期**：未完成、非每日提醒，截止日期早于今天；按截止时间升序（拖最久的排最前）。
    - **今天**：未完成、非每日提醒，截止日期就是今天；按当天时刻升序。
    - **未来**：未完成、非每日提醒，截止日期在今天之后；**无截止日期的任务也归此段**，并排在有日期的之后。
    - **每天**：未完成且开启每日提醒；不参与日期切分，按提醒时刻升序。
    - **已完成**：所有已完成任务，不按日期切分。
  - 五个分区标题**字号完全统一**（20 / Bold），统一走 `_sectionTitleFontSize` 常量，避免后续改动时字号漂移；仅「逾期」的计数徽标用醒目色区分，标题本身无差异。
  - **空分区自动隐藏**，首页不再出现一排「0」的空标题；「今天」为常驻分区，即使为空也保留标题。
- **修正「逾期」口径不一致**：筛选芯片的「逾期」此前用精确到时刻比较（`dueDate.isBefore(now)`），会把「今天 09:00 截止、现在 10:00」的任务判为逾期，而任务行标签却显示「今天 09:00」，两者矛盾。现统一为**按天比较**，与分区、行内标签口径一致。
- **文档**：补全 README「开源协议」章节（本项目采用 **MIT License**，条款见根目录 `LICENSE`），并在标题下方增加版本 / 协议速览；发行版下载说明同步到 `v1.9.0`。
- 版本号更新至 `1.9.0`（versionCode 9）。

## v1.8.9（2026-08-03）

- **每日任务「当天 00:00 自动重置」**：不再依赖打开 App。
  - 通过原生 `setAlarmClock` 午夜闹钟（运行于 `:guard` 守护进程，与 07:00 每日提醒同机制，ColorOS 上不被电池优化拦截）在每天 00:00 后台将「已完成且完成日期早于当天、且未过截止日」的每日任务重置为未完成，实现真正的「每天循环打卡」。
  - 开机（BOOT_COMPLETED）后自动重新挂上该闹钟；重启 App 时 `load()` 仍保留兜底重置，二者逻辑一致。
  - 附加：App 在前台/后台存活期间，由周期守护（15 分钟）+ 回到前台补查，保证打开了 App 跨午夜时 UI 也即时刷新。
- 版本号更新至 `1.8.9`（versionCode 8）。

## v1.8.8（2026-08-03）

- **首页新增「每天」板块**：位于「今天」与「已完成」之间，专门集中展示开启了「每日提醒」的任务（进行中状态）。
  - 分区口径调整：「今天」仅含进行中且非每日提醒的任务，「每天」含进行中且开启每日提醒的任务，二者不重叠；「已完成」不变。
  - 每日任务行右侧已有的 🔁 HH:mm 标识继续保留，一眼识别定时。
- 版本号更新至 `1.8.8`（versionCode 7）。

## v1.8.7（2026-08-02）

- **看板页优化（统计仪表盘 + 真·看板分列）**：
  - 新增「后台提醒守护」状态卡，一眼查看前台服务保活是否开启（影响 ColorOS 上定时/每日提醒是否准点）；
  - 新增「优先级分布」进度条（高/中/低，统计未完成任务占比）；
  - 统计卡（总任务/已完成/逾期/进行中）改为可点击，点击跳回首页并套用对应筛选（全部/已完成/逾期/进行中）；
  - 周趋势增加「上周同期」淡色柱对比，完成度环比一目了然；
  - 修正统计口径：原「今日概览 / 今日任务完成率」与全局数字不一致，改为「概览 / 任务完成率」（数字本就是全局口径）；
  - 新增看板三列（待办 / 进行中 / 已完成）：长按卡片可拖拽到其它列改状态，单击卡片在 待办→进行中→已完成 间循环切换（ColorOS 上更稳妥的兜底交互）。
- 任务模型新增 `TaskStatus`（待办/进行中/已完成），`done` 改为由状态派生的只读属性；JSON 兼容旧版仅含 `done` 布尔的备份。
- 首页新增筛选芯片行（全部/待办/进行中/已完成/逾期），与看板统计卡联动。
- 版本号更新至 `1.8.7`（versionCode 6）。

## v1.8.6（2026-08-02）

- **长按任务改为「多选模式」**：长按任意任务进入多选，任务行显示选择框（已选高亮），顶部出现选择栏（已选 N / 全选 / 删除 / 取消）。
  - 多选下整行点击切换选中，可一次勾选多个任务；
  - 支持「全选」当前可见任务（今天 + 已完成），再次点击取消全选；
  - 批量删除所选任务，移动至回收站，并弹出带「撤销」的提示，可整体还原；
  - 多选模式下禁用单条滑动删除 / 编辑手势，避免误操作。
- 底层删除 / 撤销机制重构为批量缓冲，单条删除与多选删除共用同一套撤销逻辑。
- 版本号更新至 `1.8.6`（versionCode 5）。

## v1.8.5（2026-08-02）

- **新增「每日提醒」功能**：为任务设置「每天固定时间提醒」，例如「每天早上 7:00 背单词」，应用会在每天设定时刻准时推送提醒。
  - 新建 / 编辑任务弹层新增「每日提醒」开关与时间选择器；
  - 调度使用 `flutter_local_notifications` 的 `matchDateTimeComponents: time` + `setAlarmClock` 模式，复用既有的 `:guard` 守护进程与 `ScheduledNotificationReceiver`，即使主进程被 ColorOS 划掉也能准点触发；
  - 每日提醒与一次性「截止提醒」使用独立的通知 id，互不干扰；
  - 任务行右侧新增 🔁 HH:mm 标识，一眼识别每日提醒任务；
  - 每日任务完成态按天循环：今天打勾后，次日启动自动重置为未完成，便于持续打卡；
  - 删除 / 移入回收站 / 永久删除时自动取消对应每日提醒，恢复时自动重新排程。
- 备份导出（Markdown / CSV）增加每日提醒时间列。
- 版本号更新至 `1.8.5`（versionCode 4）。

## v1.8.4（2026-08-02）

- **新增后台提醒守护（前台服务）**：在 ColorOS / MIUI 等国产 ROM 上，划掉后台后定时提醒不再失效。
  - 前台服务常驻 + `START_STICKY` + `stopWithTask=false`；
  - 守护服务运行在独立进程 `:guard`，主进程被清后服务仍存活；
  - 关键修复：`flutter_local_notifications` 的 `ScheduledNotificationReceiver` 必须在 Manifest 显式声明，并同样放到 `:guard` 进程，闹钟到点直接在守护进程内投递，无需重启主进程；
  - 新增 `ScheduledNotificationBootReceiver`，开机后自动重新排程；
  - 设置页新增「后台提醒守护」开关（默认开）。
- 提升构建稳定性：`GRADLE_USER_HOME` 改用与工程同盘路径，规避 Gradle 9.1 跨盘符号链接快照失败；`build.gradle.kts` 对 `merge*NativeLibs` / `extract*NativeSymbolTables` 任务关闭状态追踪作为兜底。
- 版本号更新至 `1.8.4`（versionCode 3）。

## v1.8.3（2026-08-01）

- 修复 release 包在「测试通知」后崩溃：`R8` 混淆导致 Gson 泛型签名丢失（`Missing type parameter`），新增 `proguard-rules.pro` 保留 `flutter_local_notifications` / Gson。
- 修复设置页版本号写死 `1.0.0` 的问题，改为运行时通过 `package_info_plus` 读取真实版本。
- 应用改名「有条」：落地到 Android / iOS 显示名及所有用户可见文案（包名 `com.example.todolist` 保持不变）。
- 设计并集成全新应用图标（蓝色渐变 + 白圆徽标 + 蓝勾）。

## v1.0.0

- 初始版本：任务管理、分类、优先级、回收站、备份导出、深浅色主题、周趋势统计、定时提醒。
