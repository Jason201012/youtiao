# 有条

一款基于 Flutter 的轻量级待办 / 任务管理应用，支持分类、优先级、回收站、数据备份导出、深浅色主题、周趋势统计与定时提醒。

## ✨ 功能特性

- 📝 **任务管理**：新增、编辑、删除，支持分类与优先级
- 👉 **手势操作**：向左滑编辑、向右滑删除
- 🗑️ **回收站**：误删任务可在回收站恢复或彻底删除
- 💾 **数据安全**：本地备份 / 恢复，导出 CSV 与 Markdown
- 🌗 **主题**：浅色 / 深色，支持跟随系统自动切换
- 📊 **看板**：周趋势统计，直观查看每日完成情况
- 🔔 **提醒**：支持任务的定时通知
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

## 📁 项目结构

```
lib/
  main.dart              # 应用入口
  models/                # 数据模型（Task 等）
  state/                 # 状态管理（Provider）
  screens/               # 页面（首页 / 设置 / 回收站 / 帮助）
  widgets/               # 可复用组件
assets/                  # 图标等静态资源
android/ ios/            # 原生平台工程
```

## 📄 开源协议

（待补充）
