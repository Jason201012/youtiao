/// P2-2（v3.1.6 审计）：**弹层内可见消息**的唯一真源。
library;

import 'dart:async';

import 'package:flutter/material.dart';

/// P2-2（v3.1.6 审计）：**弹层内可见消息**的唯一真源。
///
/// 旧实现的所有提示都走 `ScaffoldMessenger.of(context).showSnackBar`，
/// 而 `showModalBottomSheet` / `showDialog` 是 Navigator 中更高的路由：
/// SnackBar 挂在主 Scaffold 上，被弹层整块盖住。审计探针实测
/// 「snack=Rect(0,552,800,600) 落在 sheet=Rect(0,300,800,600) 内、
/// scaffold ancestors: sheet=0 snack=1」，即提示存在但用户永远看不到。
/// 快速录入 500 字上限、新建落盘失败、今日三件满员、习惯名称为空等
/// 多轮补上的「如实告知」因此全部失效。
///
/// 方案：每个弹层的 builder 根部挂一个 [SheetMessageHost]（不改布局约束，
/// 消息条以 Stack 顶层浮在弹层内容之上），并把弹层内的 SnackBar 调用
/// 统一换成 [showSheetSnackBar]。该函数：
/// - 找到最近的 host → 在**弹层子树内**渲染内联消息条（可被命中、可读、可关闭）；
/// - 找不到 host（普通页面）→ 原样退回 `ScaffoldMessenger`，行为零变化。
///
/// 这样「告知载体是否可见」由一处收口，后续新增弹层只需挂 host，
/// 不会再把关键失败回执写进弹层背后的 SnackBar。

/// U-1（v3.1.8 审计）：非交互消息条预留的布局高度（含 margin / padding），
/// 使贴底点穿的提示不会视觉覆盖底部主操作按钮。
const double _kBannerReservedHeight = 56;

/// 弹层内消息条的控制器，由 [SheetMessageHost] 注册到 widget 树中。
class SheetMessageScope extends InheritedWidget {
  const SheetMessageScope({
    super.key,
    required this.hostState,
    required this.show,
    required this.enqueue,
    required super.child,
  });

  /// 宿主 State，供进度层收起后 flush 排队消息。
  final SheetMessageHostState hostState;

  /// 立即显示（当前没有更高路由覆盖时）。
  final void Function(
    String message, {
    Duration duration,
    bool isError,
    String? actionLabel,
    VoidCallback? onAction,
  }) show;

  /// P2-2：进度弹层（更高路由）仍在前台时把消息排队，待它退场后由
  /// `_withRestoreProgress` 调 [SheetMessageHostState.flushQueued] 统一显示。
  final void Function(
    String message, {
    Duration duration,
    bool isError,
    String? actionLabel,
    VoidCallback? onAction,
  }) enqueue;

  @override
  bool updateShouldNotify(SheetMessageScope oldWidget) => false;
}

/// [_SheetMessage] 的一条待显示消息。
typedef _QueuedMessage = ({
  String text,
  Duration duration,
  bool isError,
  String? actionLabel,
  VoidCallback? onAction,
});

/// U-3（v3.1.7 审计）：失败 / 校验类文案判定（公开，便于回归测试）。
///
/// 旧实现用 `snackBar.backgroundColor != null` 推断「是否失败」，而全仓
/// SnackBar 几乎从不设置 backgroundColor —— 绝大多数失败提示仍用中性色
/// `inverseSurface`，与 `showSheetMessage(..., isError: true)` 的显式口径
/// 不一致。调用方仍可用 `isError:` 显式覆盖本函数的判定。
bool sheetMessageLooksLikeError(String text) {
  const markers = <String>[
    '失败', '错误', '异常', '无法', '不能', '未保存', '不允许', '损坏',
    '请检查', '请填写', '请输入', '请至少', '请重新', '超出', '已截断',
    '过多', '超限', '上限', '没有', '为空', '已跳过', '不存在', '拒绝',
  ];
  for (final marker in markers) {
    if (text.contains(marker)) return true;
  }
  return false;
}

/// 弹层内消息的唯一展示位。包在弹层内容外层即可，不改变 child 的布局约束。
class SheetMessageHost extends StatefulWidget {
  const SheetMessageHost({super.key, required this.child});

  final Widget child;

  @override
  State<SheetMessageHost> createState() => SheetMessageHostState();
}

class SheetMessageHostState extends State<SheetMessageHost> {
  String? _message;
  bool _isError = false;
  String? _actionLabel;
  VoidCallback? _onAction;
  Timer? _timer;
  final List<_QueuedMessage> _queued = <_QueuedMessage>[];

  /// 查找当前 context 所属弹层的消息宿主（供进度层收起后 flush 用）。
  static SheetMessageHostState? maybeOf(BuildContext context) => context
      .getInheritedWidgetOfExactType<SheetMessageScope>()
      ?.hostState;

  /// 供 [showSheetSnackBar] / [showSheetMessage] 调用；非弹层场景不会走到这里。
  void show(
    String message, {
    Duration duration = const Duration(seconds: 3),
    bool isError = false,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    if (!mounted) return;
    setState(() {
      _message = message;
      _isError = isError;
      _actionLabel = actionLabel;
      _onAction = onAction;
    });
    _timer?.cancel();
    _timer = Timer(duration, () {
      if (mounted) setState(() => _message = null);
    });
  }

  /// 进度层（showDialog 等更高路由）仍在前台时先排队，避免消息条被它盖住。
  void enqueue(
    String message, {
    Duration duration = const Duration(seconds: 3),
    bool isError = false,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    _queued.add((
      text: message,
      duration: duration,
      isError: isError,
      actionLabel: actionLabel,
      onAction: onAction,
    ));
    // P3-2（v3.1.7 审计）：入队本身不触发 rebuild，必须主动调度一次检查。
    // 若此刻已被更高路由覆盖，build 中的 ModalRoute.isCurrent 依赖会在
    // 覆盖退场时重建并再次 flush；两条合起来覆盖所有入队路径。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _queued.isEmpty) return;
      if (ModalRoute.of(context)?.isCurrent ?? true) flushQueued();
    });
  }

  /// 由 `_withRestoreProgress` 在进度弹层收起后调用；多条排队消息取最后一条
  /// （结果页语义上就是「最终结论」，避免连续闪烁覆盖）。
  void flushQueued() {
    if (_queued.isEmpty) return;
    final last = _queued.removeLast();
    _queued.clear();
    if (!mounted) return;
    show(
      last.text,
      duration: last.duration,
      isError: last.isError,
      actionLabel: last.actionLabel,
      onAction: last.onAction,
    );
  }

  void _dismiss() {
    _timer?.cancel();
    if (!mounted) return;
    setState(() => _message = null);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // P3-2（v3.1.7 审计）：普通 AlertDialog / 口令框覆盖弹层时 `_dispatch`
    // 会把消息压进 `_queued`，而旧实现唯一的消费者是 backup_sheet 的进度层
    // flush —— 其它路径的消息一直滞留到 host 销毁被丢弃。这里读取
    // ModalRoute.isCurrent 建立依赖：高路由退场、本弹层重新 current 时
    // Flutter 会 rebuild 本 State，再用 post-frame 统一 flush。
    final routeIsCurrent = ModalRoute.of(context)?.isCurrent ?? true;
    if (_queued.isNotEmpty && routeIsCurrent) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _queued.isEmpty) return;
        if (ModalRoute.of(context)?.isCurrent ?? true) flushQueued();
      });
    }
    final interactive = _actionLabel != null && _onAction != null;
    return SheetMessageScope(
      hostState: this,
      show: show,
      enqueue: enqueue,
      // Stack：消息条是 positioned 子项，不参与 child 的尺寸计算，
      // 因此不会给 bottom sheet 的 SingleChildScrollView 引入无界高度约束。
      // U-2（v3.1.7 审计）：旧实现 `top: 0` 正好压住底部弹层的标题 /
      // 拖拽手柄且拦截点击。改为贴底 + 非交互消息条点穿（自动 3 秒消失，
      // 不留不可点的关闭按钮），既避开顶部控件，也不挡住点击。
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // U-1（v3.1.8 审计）：为**非交互**消息条预留布局高度。旧实现消息条
          // 贴底且 IgnorePointer 点穿，视觉上盖住「保存 / 删除 / 确定」主操作，
          // 用户看不到按钮却可能点到它。预留一段空白后消息条只覆盖该空白区，
          // 点穿不再有误触风险；交互态（带撤销按钮）本就需要点击，不预留。
          Padding(
            padding: EdgeInsets.only(
                bottom: _message != null && !interactive
                    ? _kBannerReservedHeight
                    : 0),
            child: widget.child,
          ),
          if (_message != null)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: IgnorePointer(
                ignoring: !interactive,
                child: _SheetMessageBanner(
                  message: _message!,
                  isError: _isError,
                  actionLabel: _actionLabel,
                  onAction: _onAction,
                  showClose: interactive,
                  onClose: _dismiss,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SheetMessageBanner extends StatelessWidget {
  const _SheetMessageBanner({
    required this.message,
    required this.isError,
    required this.onClose,
    required this.showClose,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final bool isError;
  final String? actionLabel;
  final VoidCallback? onAction;
  final VoidCallback onClose;
  /// U-2（v3.1.7 审计）：点穿态下不展示点不到的关闭按钮。
  final bool showClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = isError ? scheme.errorContainer : scheme.inverseSurface;
    final fg = isError ? scheme.onErrorContainer : scheme.onInverseSurface;
    return Material(
      color: Colors.transparent,
      child: Container(
        key: const Key('sheet-message'),
        margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
          boxShadow: const [BoxShadow(blurRadius: 6, color: Colors.black26)],
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(isError ? Icons.error_outline : Icons.info_outline,
                size: 18, color: fg),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                key: const Key('sheet-message-text'),
                style: TextStyle(fontSize: 13, height: 1.3, color: fg),
              ),
            ),
            if (actionLabel != null && onAction != null)
              TextButton(
                onPressed: onAction,
                style: TextButton.styleFrom(
                  foregroundColor: fg,
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(actionLabel!, style: const TextStyle(fontSize: 12)),
              ),
            if (showClose)
              GestureDetector(
                onTap: onClose,
                child: Icon(Icons.close, size: 16, color: fg),
              ),
          ],
        ),
      ),
    );
  }
}

/// P2-2：进度层期间由「主页面 context」发出的消息（backup_sheet 的恢复/备份
/// 结果提示）同样会被进度 AlertDialog 盖住。这里用全局队列 + 层数开关把它们
/// 延后到进度层收起，由 [flushPendingSheetMessages] 统一在主 Scaffold 显示。
int _progressLayers = 0;
final List<SnackBar> _pendingSnackBars = <SnackBar>[];

/// 进度层计数（由 `_withRestoreProgress` 在 push / pop 时维护）。
void pushSheetProgressLayer() => _progressLayers++;
void popSheetProgressLayer() {
  if (_progressLayers > 0) _progressLayers--;
}

/// P2-4（v3.1.8 审计）：当前是否有长任务进度层（备份 / 恢复）。空闲自动锁
/// 在此期间必须暂停——否则恢复任务仍在后台跑，30 秒后锁屏把进度层弹掉，
/// 结果提示丢失，用户解锁后无从确认恢复是否完成。
bool get sheetProgressActive => _progressLayers > 0;

/// 在进度弹层收起后调用：显示排队期间积累的最后一条结论性提示。
void flushPendingSheetMessages(BuildContext context) {
  if (_pendingSnackBars.isEmpty) return;
  final last = _pendingSnackBars.removeLast();
  _pendingSnackBars.clear();
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(last);
}

/// 宿主 context 已卸载时丢弃排队消息，避免跨页面残留。
void clearPendingSheetMessages() => _pendingSnackBars.clear();

/// 当前弹层是否被更高路由（进度 AlertDialog 等）覆盖。
/// 覆盖期间消息条即便渲染在 bottom sheet 内也看不见，必须排队等待退场。
bool _coveredByHigherRoute(BuildContext context) {
  final route = ModalRoute.of(context);
  return route != null && !route.isCurrent;
}

/// 仅当「确有进度层」且「当前路由被覆盖」时才排队，避免普通 dialog 场景
/// 把消息永久留在队列里。
bool _shouldQueueForProgress(BuildContext context) =>
    _progressLayers > 0 && _coveredByHigherRoute(context);

void _dispatch(
  BuildContext context,
  SheetMessageScope scope,
  String message, {
  required Duration duration,
  required bool isError,
  String? actionLabel,
  VoidCallback? onAction,
}) {
  if (_coveredByHigherRoute(context)) {
    if (_progressLayers > 0) {
      // 统一走进度层队列，收起后由主 Scaffold 显示（比弹层内 banner 更显眼）。
      _pendingSnackBars.add(SnackBar(
        content: Text(message),
        duration: duration,
        action: actionLabel != null && onAction != null
            ? SnackBarAction(label: actionLabel, onPressed: onAction)
            : null,
      ));
      return;
    }
    scope.enqueue(
      message,
      duration: duration,
      isError: isError,
      actionLabel: actionLabel,
      onAction: onAction,
    );
    return;
  }
  scope.show(
    message,
    duration: duration,
    isError: isError,
    actionLabel: actionLabel,
    onAction: onAction,
  );
}

/// 弹层内直接显示一段文字（不需要构造 SnackBar 时的简写）。
void showSheetMessage(
  BuildContext context,
  String message, {
  Duration duration = const Duration(seconds: 3),
  // U-3（v3.1.7 审计）：null = 按文案自动判定；显式传值优先。
  bool? isError,
}) {
  final scope = context.getInheritedWidgetOfExactType<SheetMessageScope>();
  final snack = SnackBar(content: Text(message), duration: duration);
  if (scope == null) {
    if (_shouldQueueForProgress(context)) {
      _pendingSnackBars.add(snack);
    } else {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(snack);
    }
    return;
  }
  _dispatch(context, scope, message,
      duration: duration,
      isError: isError ?? sheetMessageLooksLikeError(message));
}

/// P2-2（v3.1.6 审计）：**替代** `ScaffoldMessenger.of(context).showSnackBar(...)`
/// 的兼容入口。参数仍是原生 [SnackBar]，因此调用点只需换函数名；
/// 命中 [SheetMessageHost] 时把内容渲染成弹层内的可见消息条，
/// 否则原样交给根 ScaffoldMessenger（普通页面行为不变）。
void showSheetSnackBar(BuildContext context, SnackBar snackBar,
    {bool? isError}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final scope = context.getInheritedWidgetOfExactType<SheetMessageScope>();
  if (scope == null) {
    if (_shouldQueueForProgress(context)) {
      _pendingSnackBars.add(snackBar);
    } else {
      messenger?.showSnackBar(snackBar);
    }
    return;
  }
  final content = snackBar.content;
  String? text;
  if (content is Text) {
    text = content.data ?? content.textSpan?.toPlainText();
  }
  if (text == null || text.isEmpty) {
    // 复杂内容不猜语义，退回原生 SnackBar（至少不丢消息）。
    messenger?.showSnackBar(snackBar);
    return;
  }
  final action = snackBar.action;
  _dispatch(
    context,
    scope,
    text,
    duration: snackBar.duration,
    // U-3（v3.1.7 审计）：按文案判定失败 / 校验类提示，显式 isError 优先；
    // 保留 backgroundColor 作为兼容信号（历史调用点确有设色的场合）。
    isError: isError ??
        (sheetMessageLooksLikeError(text) ||
            snackBar.backgroundColor != null),
    actionLabel: action?.label,
    onAction: action?.onPressed,
  );
}
