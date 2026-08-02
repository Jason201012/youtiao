# 更新日志（Changelog）

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
