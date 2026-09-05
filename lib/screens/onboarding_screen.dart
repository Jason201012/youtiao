import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:todolist/main.dart'; // MainScaffold（仅在 _finish 内导航用到，无顶层初始化依赖）
import 'package:todolist/state/onboarding_provider.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/services/notification_service.dart';
import 'package:todolist/theme/app_theme.dart';

/// 首次启动引导页：3 屏轻量引导（**不可跳过**，必须走到末页「开始使用」）。
///
/// - 屏 1 欢迎 / 本地优先（数据只存手机、无需账号）
/// - 屏 2 核心能力（全部为 App 真实已有功能）
/// - 屏 3 开启提醒说明 + 示例任务选择（保留示例 / 从零开始）+ 开始使用
///
/// 仅末页「开始使用」会调用 [OnboardingProvider.complete] 并进入主页，
/// 之后任何启动都不再显示（标志位已持久化）。
///
/// [onFinished] 供测试注入：非 null 时完成流程只回调它、不真正导航到主页，
/// 避免 widget 测试去构建沉重的 [MainScaffold]。
class OnboardingScreen extends StatefulWidget {
  final VoidCallback? onFinished;
  const OnboardingScreen({super.key, this.onFinished});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _pageController = PageController();
  static const int _lastPage = 2;

  int _page = 0;
  bool _keepSample = true; // 默认保留示例任务
  bool _permissionRequested = false;
  bool _exactAlarmOk = true;

  @override
  void initState() {
    super.initState();
    _checkExactAlarm();
  }

  /// 查询精确闹钟权限（ColorOS 等国产 ROM 决定定时提醒是否准点）。
  Future<void> _checkExactAlarm() async {
    try {
      final ok = await NotificationService.instance.canScheduleExactAlarms();
      if (mounted) setState(() => _exactAlarmOk = ok);
    } catch (_) {
      // 查询失败（如桌面/测试环境）默认视为已具备，不阻塞引导。
    }
  }

  /// 进入屏 3 时顺带请求一次通知权限（init 已请求过，已授权则无感；未授权此刻弹窗）。
  Future<void> _requestPermissionIfNeeded() async {
    if (_permissionRequested) return;
    _permissionRequested = true;
    try {
      await Provider.of<TaskProvider>(context, listen: false)
          .requestNotificationPermission();
    } catch (_) {
      // 无平台（测试）环境：requestPermission 返回 null，不抛错，忽略。
    }
  }

  void _onPageChanged(int i) {
    setState(() => _page = i);
    if (i == _lastPage) _requestPermissionIfNeeded();
  }

  void _next() {
    if (_page < _lastPage) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else {
      _finish();
    }
  }

  /// 完成引导：按选择清空/保留示例任务 → 请求权限 → 标记已看 → 进主页。
  Future<void> _finish() async {
    final task = Provider.of<TaskProvider>(context, listen: false);
    final onboarding = Provider.of<OnboardingProvider>(context, listen: false);
    // 选「从零开始」则清空首启示例任务。
    if (!_keepSample) {
      try {
        await task.clearSampleTasks();
      } catch (_) {
        // 清空失败不应阻塞进入主页。
      }
    }
    // 再次请求通知权限（保证用户在引导内完成授权）。
    try {
      await task.requestNotificationPermission();
    } catch (_) {}
    await onboarding.complete();
    if (!mounted) return;
    if (widget.onFinished != null) {
      widget.onFinished!();
    } else {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const MainScaffold()),
        (_) => false,
      );
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  // ===== U13：语义化次要文本色（修复硬编码 Colors.blackXX 在深色模式隐形）=====
  Color get _muted => Theme.of(context).brightness == Brightness.dark
      ? Colors.white70
      : Colors.black54;
  Color get _faint => Theme.of(context).brightness == Brightness.dark
      ? Colors.white60
      : Colors.black45;
  Color get _outline => Theme.of(context).brightness == Brightness.dark
      ? Colors.white24
      : Colors.black12;

  @override
  Widget build(BuildContext context) {
    final colors = appColors(context);
    final primary = Theme.of(context).colorScheme.primary;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: Column(
          children: [
            // 三屏内容
            Expanded(
              child: PageView(
                controller: _pageController,
                onPageChanged: _onPageChanged,
                children: [
                  _pageWelcome(colors),
                  _pageFeatures(colors),
                  _pageRemind(colors, primary),
                ],
              ),
            ),
            // 页码指示器
            _buildIndicators(primary),
            // 主按钮：前两屏「下一步」，末屏「开始使用」
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 28),
              child: Semantics(
                button: true,
                label: _page < _lastPage ? '下一步' : '开始使用',
                child: FilledButton(
                  onPressed: _next,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(50),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: Text(_page < _lastPage ? '下一步' : '开始使用'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 页码圆点：当前页高亮拉长。
  Widget _buildIndicators(Color primary) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(
          _lastPage + 1,
          (i) => AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            margin: const EdgeInsets.symmetric(horizontal: 4),
            width: i == _page ? 18 : 7,
            height: 7,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(4),
              color: i == _page ? primary : _outline,
            ),
          ),
        ),
      ),
    );
  }

  // ===== 屏 1：欢迎 / 本地优先 =====
  Widget _pageWelcome(AppColorsExt colors) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Logo：圆角方块 + 对勾
          Semantics(
            label: '有条 Logo',
            child: Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Theme.of(context)
                        .colorScheme
                        .primary
                        .withAlpha(40),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: const Icon(Icons.check, color: Colors.white, size: 40),
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            '有条',
            style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            '本地优先的待办 · 习惯 · 专注',
            style: TextStyle(fontSize: 14, color: _muted),
          ),
          const SizedBox(height: 18),
          Text(
            '数据只存在你手机上\n无需账号 · 不上传云端',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: _faint, height: 1.7),
          ),
        ],
      ),
    );
  }

  // ===== 屏 2：核心能力 =====
  Widget _pageFeatures(AppColorsExt colors) {
    const features = [
      (Icons.edit_note, '速记建单', '一句话写任务，自动识别时间'),
      (Icons.grid_view, '习惯热力图', '连续打卡一目了然'),
      (Icons.dashboard, '看板视图', '拖拽管理任务状态'),
      (Icons.search, '全局搜索', '任务·习惯一搜即达'),
      (Icons.timer, '专注计时', '番茄钟 + 累计时长'),
      (Icons.calendar_month, '日历', '按日期纵览安排'),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 22),
      child: Column(
        children: [
          const SizedBox(height: 8),
          const Text(
            '这个 App 能帮你',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 16),
          ...features.map((f) => _featureRow(colors, f.$1, f.$2, f.$3)),
        ],
      ),
    );
  }

  Widget _featureRow(AppColorsExt colors, IconData icon, String title, String desc) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colors.chip.withAlpha(70),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: colors.chip,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                Text(desc, style: TextStyle(fontSize: 11.5, color: _muted)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ===== 屏 3：开启提醒 + 示例选择 =====
  Widget _pageRemind(AppColorsExt colors, Color primary) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 22),
      child: Column(
        children: [
          const SizedBox(height: 6),
          // 铃铛
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              color: colors.chip,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Icon(Icons.notifications_none, size: 30, color: primary),
          ),
          const SizedBox(height: 10),
          const Text(
            '开启提醒',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 14),
          // 通知行
          _infoRow(
            Icons.notifications_active,
            '通知',
            '任务、习惯到点提醒',
          ),
          const SizedBox(height: 10),
          // 精确闹钟行（ColorOS 需手动开启才准点，可点击跳转设置）
          _exactAlarmRow(colors, primary),
          const SizedBox(height: 10),
          Text(
            '任务、习惯到点提醒；ColorOS 需精确闹钟权限才准点',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: _faint),
          ),
          const SizedBox(height: 14),
          Text(
            '已为你放入 7 条示例任务',
            style: TextStyle(fontSize: 12, color: _muted),
          ),
          const SizedBox(height: 10),
          // 示例任务二选一
          Row(
            children: [
              Expanded(
                child: _choicePill(
                  '保留示例',
                  selected: _keepSample,
                  onTap: () => setState(() => _keepSample = true),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _choicePill(
                  '从零开始',
                  selected: !_keepSample,
                  ghost: true,
                  onTap: () => setState(() => _keepSample = false),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _infoRow(IconData icon, String title, String desc) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface.withAlpha(180),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                Text(desc, style: TextStyle(fontSize: 11, color: _muted)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _exactAlarmRow(AppColorsExt colors, Color primary) {
    final needGrant = !_exactAlarmOk;
    return InkWell(
      // 已具备权限则不可点；否则点击跳转到系统精确闹钟设置页。
      onTap: needGrant
          ? () async {
              try {
                await NotificationService.instance.openExactAlarmSettings();
              } catch (_) {}
            }
          : null,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: needGrant ? colors.chip.withAlpha(70) : Theme.of(context).colorScheme.surface.withAlpha(180),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(Icons.alarm, size: 18, color: primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('精确闹钟', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                  Text('ColorOS 需开启才准点', style: TextStyle(fontSize: 11, color: _muted)),
                ],
              ),
            ),
            if (needGrant)
              Icon(Icons.open_in_new, size: 16, color: _faint)
            else
              Icon(Icons.check_circle, size: 16, color: primary),
          ],
        ),
      ),
    );
  }

  Widget _choicePill(String label, {required bool selected, bool ghost = false, required VoidCallback onTap}) {
    final primary = Theme.of(context).colorScheme.primary;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? primary : _outline,
              width: selected ? 1.5 : 1,
            ),
            color: selected ? primary.withAlpha(12) : Colors.transparent,
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: selected ? primary : _muted,
            ),
          ),
        ),
      ),
    );
  }
}
