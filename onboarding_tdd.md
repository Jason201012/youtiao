# 「有条」首次启动引导页 · TDD 拆分

> 配套设计稿：`onboarding_design.html`（3 屏 + 路由流程图 + 设计规范）
> 现状核实：当前**无** onboarding；`task_provider.load()` 首启预置 7 条 mock；`local_database.tasksEmpty` 可判新装；`shared_preferences` 无 `hasSeenIntro` 标志；主题主色 `#0061A4`，Inter 字体，Material 3。

## 验收总目标

1. 全新安装首次打开显示 3 屏可跳过引导；之后任何启动都不再显示（标志位持久化）。
2. 引导内可一次性完成通知权限授权，并说明 ColorOS 精确闹钟权限。
3. 首启提供「保留示例 / 从零开始」选择，决定 7 条 mock 任务是否保留。
4. 任意屏「跳过」立即进入主页且不强制任何权限。
5. 交互/文案符合 App 现有主题（主色 `#0061A4`、Inter、lightTheme）。

---

## 任务拆分

### T1 · `OnboardingProvider`（标志位 + 持久化）
- 新增 `lib/state/onboarding_provider.dart`，`ChangeNotifier`。
- 字段：`bool _seen`；getter `hasSeenIntro`。
- `load()`：从 `shared_preferences` 读 `onboarding_seen`（默认 `false`）。
- `complete({bool keepSample})`：写 `onboarding_seen=true`；并按 `keepSample` 决定首启是否清空 mock。
- 测试用例（`test/onboarding_provider_test.dart`）：
  - `hasSeenIntro` 默认 `false`。
  - 调用 `complete()` 后 `hasSeenIntro==true`，且 SP 落盘（`getBool` 读回 `true`）。
  - `complete(keepSample:false)` 后 `tasksEmpty==true`（mock 被清空）；`keepSample:true` 则保留。
  - `setUp` 内 `SharedPreferencesStorePlatform.instance = InMemorySharedPreferencesStore.empty()`（参照现有测试惯例，避免跨用例串扰）。

### T2 · 启动路由门控
- 在 `main()` / 路由判定处：读取 `OnboardingProvider.hasSeenIntro`；为 `false` → 进 `OnboardingScreen`，为 `true` → 进 `HomeScreen`。
- 复用 `local_database.tasksEmpty` 判新装（仅首启且 `keepSample:false` 时清空 mock）。
- 测试用例：
  - Widget 测试：`hasSeenIntro==false` 时根组件首帧渲染 `OnboardingScreen`；`true` 时渲染 `HomeScreen`（用 `MaterialApp(theme: lightTheme)` 包裹，避免 `appColors` 的 Null check）。
  - 集成测试：模拟首启→完成→重启，第二次不再显示引导。

### T3 · 引导页外壳（Pager + 跳过 + 页码）
- 新增 `lib/screens/onboarding_screen.dart`：一个 `PageView`(3 页) + 顶部「跳过 ›」+ 底部页码(1/2/3) + 主按钮（前两页「下一步」、末页「开始使用」）。
- 「跳过」与「开始使用」都调用 `OnboardingProvider.complete(...)` 并 `Navigator.pushReplacement` 到主页。
- 测试用例：
  - 渲染 TopBar「跳过」、3 个 `PageView` 子页、底部页码与按钮。
  - 点击「下一步」翻到下一页；末页按钮文案为「开始使用」。
  - 点击「跳过」→ `complete()` 被调用且路由跳到主页。

### T4 · 屏 1 欢迎 / 本地优先
- 组件：Logo（圆角方块 + 对勾）、App 名「有条」、主标语、副文案（数据只存手机 / 无需账号·不上传云端）。
- 文案固定，无动态数据。
- 测试用例：断言存在上述 4 个文本节点与 Logo；不依赖任何 Provider 状态。

### T5 · 屏 2 核心能力
- 6 行能力卡（图标 + 标题 + 一句说明），内容取自 App 真实功能：**速记建单 / 习惯热力图 / 看板视图 / 全局搜索 / 专注计时 / 日历**（均经代码核实存在，勿写未实现功能）。
- 测试用例：断言 6 个标题文本全部出现；图标 `ficon` 数量为 6。

### T6 · 屏 3 开启提醒 + 选择
- 组件：铃铛图标、双开关（通知 / 精确闹钟）、说明文案、示例提示、二选一（保留示例 / 从零开始）、主按钮「开始使用」。
- 进入该屏即调用 `TaskProvider.requestNotificationPermission()`；精确闹钟说明针对 ColorOS（文案提示，不强跳系统页）。
- 「保留示例 / 从零开始」选择驱动 `complete(keepSample:)`。
- 测试用例：
  - 断言两开关、说明文案、二选一、主按钮存在。
  - 选「从零开始」后 `complete` 以 `keepSample:false` 调用 → mock 清空。
  - 选「保留示例」→ `keepSample:true` → mock 保留。
  - 通知权限请求方法被调用（mock `TaskProvider` 验证）。

### T7 · 无障碍 / 主题回归
- 三屏均套 `lightTheme`（并验证 `darkTheme` 下不崩，遵循现有 `appColors(context)` 主题扩展要求）。
- 文本对比度符合 WCAG AA；按钮可聚焦、`Semantics` 标注「跳过 / 下一步 / 开始使用」。
- 门禁：全量 `flutter analyze` 0 issue；`flutter test` 全绿（含本模块用例）。

---

## 文件清单（新增 / 修改）

| 文件 | 动作 | 说明 |
|------|------|------|
| `lib/state/onboarding_provider.dart` | 新增 | 标志位 + SP 持久化 + 首启 mock 处理 |
| `lib/screens/onboarding_screen.dart` | 新增 | 3 屏 Pager + 跳过 + 页码 + 完成逻辑 |
| `lib/widgets/onboarding_*_page.dart` | 新增（可选） | 将屏 1/2/3 拆为独立 widget，便于测试 |
| `lib/main.dart` / 路由 | 修改 | 启动判 `hasSeenIntro` 决定首屏 |
| `test/onboarding_provider_test.dart` | 新增 | T1 用例 |
| `test/onboarding_screen_test.dart` | 新增 | T2–T6 用例 |

## 风险与注意

- **不能强依赖 GCM / 系统弹窗**：通知权限请求用现有 `requestNotificationPermission()`，测试中以 mock Provider 验证调用，勿在 widget 测试里真弹系统框。
- **mock 清空时机**：`complete(keepSample:false)` 必须在 `TaskProvider.load()` 预置 7 条之后、主页渲染之前执行；建议放入 `OnboardingProvider.complete` 内统一处理，避免与现有 `load()` 竞态。
- **不要承诺云同步**：文案仅限「本地优先 / 不上传 / 无需账号」，与 App 零云端架构一致。
- **主题一致性**：所有页面 `MaterialApp` 必须传 `theme: lightTheme`（参照现有 widget 测试教训），否则 `appColors` 扩展 Null check 崩。

## 建议提交粒度

分 2 个 commit：① `feat: 新增 OnboardingProvider + 启动门控`（T1+T2，含测试）；② `feat: 新增 3 屏引导 UI`（T3–T7，含测试）。发版前跑 `scripts/check.sh` 门禁。
