/// 轻量全局导航钩子（U4：命令面板移动端入口用）。
///
/// 各主 Tab 页（首页/看板/日历/专注/习惯/设置）顶栏的「命令面板」按钮需要
/// 「切到第 N 个 Tab」，但 Tab 状态归 MainScaffold 所有、子页无法直接 setState。
/// 与 FocusProvider.jumpToFocusTab / TaskProvider.onRequestHome 同模式：
/// MainScaffold 在 initState 注册回调，子页通过静态方法触发，零反向依赖。
class AppNav {
  /// MainScaffold 注入：切换底部 Tab（越界下标由注册方自行忽略）。
  static void Function(int index)? onJumpToTab;

  /// 子页调用：请求切到第 [index] 个 Tab（0=首页 … 5=设置）。
  static void jumpToTab(int index) => onJumpToTab?.call(index);
}
