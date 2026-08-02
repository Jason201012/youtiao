# 更新日志（Changelog）

## v1.8.6（未发布）

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
