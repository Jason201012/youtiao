# 有条

一款基于 Flutter 的轻量级待办 / 任务管理应用，支持分类、优先级、回收站、数据备份导出、深浅色主题、周趋势统计、定时提醒与专注环境音。

应用名「有条」，包名 `com.example.todolist`（发布标识，发布后不可更改）。

开源协议 **[MIT](LICENSE)**

> ⬇️ **最新安装包请到专用仓库下载**：本仓库已停止上传 APK（Gitee 附件配额按仓 1 GB）。发布仓依次承接：≤v2.4.0 在 **[youtiao-releases](https://gitee.com/jason1012/youtiao-releases/releases)**，v2.4.1~v2.7.7 在 **[youtiao-releases-2](https://gitee.com/jason1012/youtiao-releases-2/releases)**，v2.7.8~v3.0.0 在 **[youtiao-releases-3](https://gitee.com/jason1012/youtiao-releases-3/releases)**（已满，只读保留），**v3.0.1 起在 [youtiao-releases-4](https://gitee.com/jason1012/youtiao-releases-4/releases)**。点此直达**全部发行版列表（最新）** 👉 <https://gitee.com/jason1012/youtiao-releases-4/releases>

## ✨ 功能特性

> 按 v3.1.x 实际能力重写（此前清单停留在 v2.7 时代）。六大 Tab：首页 / 看板 / 日历 / 专注 / 习惯 / 设置；**严格离线**——网络仅限应用内更新检查，零账号、零云同步、零遥测。

### 任务与计划

- 📝 **任务管理**：分类（工作/生活/学习）、优先级、子任务、备注、标签、附件（图片/录音/文件）、预计时长、手动排序、置顶
- 🗓️ **重复规则**：每天 / 每周X / 仅工作日 / 每隔N天 / 每月N日 / 每月第几个周X / 每月倒数第N天，含结束日期、跳过某天、暂停到某日、提前量提醒与重复时刻提醒；未来 30 天逐次完成 / 跳过 / 顺延
- 🗑️ **回收站**：删除任务可恢复或彻底删除，保留期可配（7/30/90 天或永不），过期前一天推送预告
- 🔎 **全局搜索**：标题 / 备注 / 标签 / 子任务 / 分类 / 优先级 / 拼音首字母与**全拼**（搜「zhoulibao」可命中「周立波」），支持搜索历史与一键清空
- ✍️ **自然语言录入**：单行解析日期、时刻、优先级、标签、地点、时长、区间、一次性农历日期（如「农历八月十五」）；支持从剪贴板一键粘贴
- ⌨️ **命令面板**：`/new` `/pin` `/done` `/trash` `/tags` `/export` `/backup` + 页面直达；桌面端 Ctrl/Cmd+N/P/F、Cmd+Enter
- ⭐ **今日三件（MIT）**：首页「今天最重要的一件事 ×3」承诺卡，空态按逾期→今天→高优先级给建议，日切自动清空
- 📌 **置顶**：任务详情一键置顶 / 取消置顶，多选后可用命令面板 `/pin` 批量置顶

### 看板 / 日历 / 专注

- 📊 **看板**：待办/完成两列拖拽换态，状态 / 分类 / 标签三种分组，全局与列级 WIP 上限，完成率 / 优先级分布 / 分类进度 / 周趋势统计卡
- 📅 **日历**：月 / 周视图、农历 / 节气 / 传统节日标注、完成热力、长按建任务、任务条长按拖拽改期（自动重排提醒）、当日计划占时与专注时段面板
- ⏱️ **专注（番茄钟）**：专注 / 短休 / 长休可配置循环，自定义时长，任务绑定，七种环境音多选叠加（音量 + 淡入淡出），锁屏进度通知、墙钟恢复、中断计数、时段分布与趋势图、手动补录、每日目标、战绩分享卡

### 习惯与回顾

- 🔥 **习惯打卡**：布尔与**量化目标**（如「每天 8 杯」，支持自定义单位）、按周几计划、周目标、宽限日、补卡与撤销、当前/最长连续、热力图、破纪录庆祝、打卡确认条（通知栏可打卡/撤销）、漏卡挽留、归档/恢复、列表长按拖拽排序、详情编辑 / 删除 / 分享
- 📈 **回顾报告**：周报 / 月报 / 年报 / 学期报，Pareto 分析、年度时间线、专注与习惯拆解、本地叙事小结、分享长图与 PDF 导出
- 🏆 **成就系统**：20 项本地成就

### 数据安全（本地优先）

- 💾 **备份**：手动备份（可 AES-256-GCM 口令加密 + 口令提示）、每日本地自动快照（滚动 7 份，可加密）
- 🩺 **恢复三件套**：恢复前**差异预演**（备份内容 / 时间范围 / 当前对比 / 设置差异键名）、**恢复前自动快照**（`backup/pre-restore/` 滚动 3 份，可从「本地自动备份」列表一键回滚）、**恢复范围选择**（可只恢复数据不恢复设置）；旧备份弱提示、空备份强确认
- 📤 **导出 / 导入**：CSV / Markdown / Excel / PDF / iCal 导出，CSV / iCal 导入（幂等去重）；数据体检（重复任务 / 空子项 / 失效附件 / 超期回收站）、存储空间清理
- 🔒 **隐私**：应用锁（含生物识别 / 自动锁定）、防截屏、锁屏隐藏通知正文、勿扰时段、提醒时区、**全局提醒临时静音**（1 小时 / 今天 / 到明天 08:00，错过不补发）、桌面小组件（今日任务列表 + 快速新建 + 直达详情）

### 触达

- 🔔 **定时通知**：任务截止 / 重复落点 / 习惯打卡提醒均带「稍后提醒 + 完成 / 打卡」通知栏操作，完成与打卡可撤销
- 🌅 **早晚简报**：早间待办 / 晚间小结定时推送，时刻可配
- 🛡️ **后台提醒守护**：前台服务常驻（独立 `:guard` 进程），保证国产 ROM（ColorOS / MIUI 等）划掉后台后提醒准点触发

- 🎨 **设计**：Material 3 设计语言，纯黑白 token 体系，支持 Material You 取色与浅深色跟随系统

## 🛠 技术栈

- Flutter 3.x / Dart
- Material 3
- Provider（状态管理）
- flutter_local_notifications（定时通知）
- package_info_plus（版本读取）
- shared_preferences（开关/偏好持久化）
- sqflite（任务、回收站与专注记录持久化）

## 📦 环境要求

- Flutter SDK 3.x
- Android SDK（minSdk 24，targetSdk 36，compileSdk 36）
- iOS 需 macOS + Xcode

## 🚀 构建与运行

```bash
flutter pub get
flutter run                   # 调试运行
flutter build apk --release   # 构建 Android release 包
```

### 🔐 Release 签名（必读）

自 v2.6.0 起，release 构建**强制使用固定 keystore 签名**，不再使用 debug 密钥：

- `android/app/build.gradle.kts` 在 `buildTypes.release` 里检查四个环境变量：
  `YOUTIAO_KEYSTORE` / `YOUTIAO_KEY_ALIAS` / `YOUTIAO_KEYSTORE_PASSWORD` / `YOUTIAO_KEY_PASSWORD`；
- **缺任一变量时构建直接失败**，绝不静默回退到公开 debug keystore
  （v2.5.9 曾误发 debug 签名包，debug 密钥是公开的，任何人都能用它伪造「同名安装包」诱导覆盖安装）；
- keystore 与口令**不入库**（`.gitignore` 已忽略），仅保存在本机与构建脚本使用的环境变量中。

构建 release 前先导出变量（PowerShell 示例）：

```powershell
$env:YOUTIAO_KEYSTORE = "E:\path\to\youtiao-release.jks"
$env:YOUTIAO_KEY_ALIAS = "youtiao"
$env:YOUTIAO_KEYSTORE_PASSWORD = "<store password>"
$env:YOUTIAO_KEY_PASSWORD = "<key password>"
flutter build apk --release --target-platform android-arm64
```

用户侧校验：安装后若签名不一致，Android 会直接拒绝覆盖安装并提示「未安装」。

#### 用户如何核验安装包真伪

侧载场景下，建议在下完 APK 后核一次哈希再安装：

```powershell
# PowerShell：比对 sha256 与发布说明中给出的值
Get-FileHash .\app-release-x.y.z-arm64.apk -Algorithm SHA256
```

App 内的更新流程已内置同一道校验（下载后比对 `update.json` 的 `apkSha256`，
不一致即拒绝安装）；手动下载时请自行比对发布说明里的哈希值。

> 关于信任链：目前能防到「传输被篡改 / 下载不完整」，**尚不能防「作者 Gitee 账号
> 被盗后伪造清单」**——那种情况下 `apkUrl` 与 `apkSha256` 会被同时改掉。
> 根治方案是给 `update.json` 做离线 Ed25519 签名、App 内置公钥验签（已在路线图中，
> 属远期项）。在此之前，请以发布页说明与哈希为准。

### 关于 Gradle（本机 Windows 提示）

本工程在 Windows 上构建时，建议把 `GRADLE_USER_HOME` 设在与工程**同盘**的路径（如 `D:/workbuddy/.gradle`），可规避 Gradle 9.1 跨盘符号链接快照失败（`not a regular file`）。另外 `android/app/build.gradle.kts` 已对 `merge*NativeLibs` / `extract*NativeSymbolTables` 任务关闭状态追踪作为兜底。

## 🔔 后台提醒守护（重要）

为了让定时提醒在「划掉后台」后依然准时触发，应用内置了一个**前台守护服务**：

- 服务运行在独立进程 `:guard`，App 主进程被划掉后守护进程仍存活；
- 闹钟的接收器（`ScheduledNotificationReceiver`）也声明在 `:guard` 进程，闹钟到点直接在守护进程内投递通知，无需重启主进程；
- 设置页提供「后台提醒守护」总开关（默认开），关闭即停止该服务。

**注意事项（国产 ROM 用户必读）：**

1. 状态栏会常驻一条「有条 · 提醒守护中」通知，这是前台服务的硬性要求，点开即回到 App，无需理会。
2. **不要用手机管家的「一键加速 / 强力清理」去清「有条」** —— 那是强杀，前台服务也挡不住；正常使用「最近任务上滑划掉」不受影响。
3. 建议一并开启：设置 → 应用 → 有条 → **自启动**、**电池无限制 / 允许后台运行**、**精确闹钟（闹钟和提醒）**，并把 App 加入手机管家清理白名单、在最近任务卡片下拉锁定。
4. 开机重启后守护服务会自动重新排程已有的定时提醒。

> 为什么需要这套机制？普通本地 App 在 ColorOS / MIUI 上被划掉后台后，系统会冻结其后台闹钟，导致定时通知不响。微信 / QQ 能扛住是因为接入了厂商系统推送（ROM 默认白名单），而本地 App 没有服务器，只能用「前台服务 + 独立进程 + 同进程接收器」这套方案保活。

## 📦 发行版（Release）

安装包不纳入 git（二进制大文件，被 `.gitignore` 忽略）。**本仓库已停止上传 APK**，发布仓按 Gitee 附件配额（1 GB/仓）依次承接：

- ≤ v2.4.0：**[youtiao-releases](https://gitee.com/jason1012/youtiao-releases/releases)**（配额已满）
- v2.4.1 ~ v2.7.7：**[youtiao-releases-2](https://gitee.com/jason1012/youtiao-releases-2/releases)**（配额已满）
- v2.7.8 ~ v3.0.0：**[youtiao-releases-3](https://gitee.com/jason1012/youtiao-releases-3/releases)**（配额已满，只读保留）
- **v3.0.1 起：[youtiao-releases-4](https://gitee.com/jason1012/youtiao-releases-4/releases)**（当前）

- 📥 全部发行版列表（最新）：<https://gitee.com/jason1012/youtiao-releases-4/releases>（U2-2，v3.0.5 审计：改用**不带硬编码版本号**的稳定链接，发版无需同步改 README）

## 📁 项目结构

```
lib/
  main.dart                 # 应用入口
  models/                   # 数据模型（Task 等）
  state/                    # 状态管理（Provider）
  services/                 # 通知 / 前台守护服务封装
  screens/                  # 页面（首页 / 设置 / 回收站 / 帮助）
  widgets/                  # 可复用组件
assets/                     # 图标等静态资源
android/ ios/               # 原生平台工程
```

## 📄 开源协议

本项目基于 [MIT License](LICENSE) 开源。

简单来说：可以自由使用、复制、修改、合并、发布、分发、再授权及销售本软件，唯一要求是**在所有副本或主要部分中保留版权声明与许可声明**。软件按「原样」提供，不附带任何担保，作者不对使用本软件产生的任何索赔或损失负责。

完整条款见仓库根目录的 [`LICENSE`](LICENSE) 文件。
