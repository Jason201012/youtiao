# 有条

一款基于 Flutter 的轻量级待办 / 任务管理应用，支持分类、优先级、回收站、数据备份导出、深浅色主题、周趋势统计与定时提醒。

应用名「有条」，包名 `com.example.todolist`（发布标识，发布后不可更改）。

## ✨ 功能特性

- 📝 **任务管理**：新增、编辑、删除，支持分类与优先级
- 👉 **手势操作**：向左滑编辑、向右滑删除
- 🗑️ **回收站**：误删任务可在回收站恢复或彻底删除
- 💾 **数据安全**：本地备份 / 恢复，导出 CSV 与 Markdown
- 🌗 **主题**：浅色 / 深色，支持跟随系统自动切换
- 📊 **看板**：周趋势统计，直观查看每日完成情况
- 🔔 **定时提醒**：支持任务的定时通知
- 🛡️ **后台提醒守护**：前台服务常驻，保证在国产 ROM（ColorOS / MIUI 等）上划掉后台后定时提醒仍能准点触发
- 🎨 **设计**：Material 3 设计语言

## 🛠 技术栈

- Flutter 3.x / Dart
- Material 3
- Provider（状态管理）
- flutter_local_notifications（定时通知）
- package_info_plus（版本读取）
- shared_preferences（本地持久化）

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

> 当前 release 使用 debug 密钥签名，可直接侧载安装。若上架应用商店，请在 `android/app/build.gradle.kts` 配置正式的签名 keystore。

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

安装包不纳入 git（二进制大文件，被 `.gitignore` 忽略）。如需下载正式安装包，请前往 Gitee 仓库的 **「发行版 / Releases」** 页面，对应版本（如 `v1.8.4`）的附件中下载 `app-release.apk`。

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

（待补充）
