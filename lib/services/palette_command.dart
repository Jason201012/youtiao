/// P1-6 命令面板的 `/` 前缀命令解析。
///
/// 纯 Dart：不 import 任何 Flutter 包，可在 headless 下直接单测。
///
/// 两类命令：
/// - **导航类**：`/today` `/board` `/calendar` `/focus` `/habit` `/settings`
///   （中英文皆可），等效于点底部 Tab，无副作用；
/// - **动作类**：`/done`，完成首页当前选中的任务。
///
/// ⚠️ 兜底原则（与报告原文的差异）：
/// 报告举例是 `/done 全部`，但命令面板拿不到列表上下文，若把「全部」解释成
/// 「全库所有任务」就是一次高危、难撤销的批量写操作。本实现让 `/done` **只作用于
/// 首页当前选中项**；没有选中时返回提示，绝不擅自扩大作用范围。
/// 真正的「全选后批量完成」应走首页的多选 UI（有明确可见的选中反馈）。
class PaletteCommand {
  PaletteCommand._(this.name, this.arg);

  /// 归一化后的命令名（小写）。
  final String name;

  /// 参数部分（已 trim）；无参数时为空串。
  final String arg;

  /// 导航类命令名 → 目标 Tab 下标。中英文别名都登记，方便快速敲。
  static const Map<String, int> gotoTargets = {
    'today': 0,
    'home': 0,
    '首页': 0,
    'board': 1,
    'kanban': 1,
    '看板': 1,
    'calendar': 2,
    '日历': 2,
    'focus': 3,
    '专注': 3,
    'habit': 4,
    '习惯': 4,
    'settings': 5,
    'setting': 5,
    '设置': 5,
  };

  /// 动作类命令名。
  static const String cmdDone = 'done';

  /// 解析 [raw]。
  /// 返回 `null` 表示「不是命令」，调用方应退回普通关键字搜索。
  ///
  /// 注意：仅输入 `/` 或 `/` 后面只有空白时**仍视为搜索**——否则用户一按下斜杠
  /// 列表就空了，体验很突兀。
  static PaletteCommand? parse(String raw) {
    final s = raw.trim();
    if (!s.startsWith('/')) return null;
    final body = s.substring(1).trim();
    if (body.isEmpty) return null;
    final parts = body.split(RegExp(r'\s+'));
    final name = parts.first.toLowerCase();
    // 参数取第一个空白之后的全部内容并 trim，保留多词参数。
    final arg = body.length > parts.first.length
        ? body.substring(parts.first.length).trim()
        : '';
    return PaletteCommand._(name, arg);
  }

  /// 若为导航类命令，返回目标 Tab 下标；否则 `null`。
  int? get gotoIndex => gotoTargets[name];

  /// 是否为「完成选中项」命令。
  bool get isDone => name == cmdDone;

  /// 是否为已知命令（导航类或动作类）。未知命令交由 UI 提示。
  bool get isKnown => gotoIndex != null || isDone;

  /// 命令的展示名（用于面板标题）。
  String get label {
    if (isDone) return '完成选中项';
    final i = gotoIndex;
    if (i == null) return name;
    return const ['首页', '看板', '日历', '专注', '习惯', '设置'][i];
  }
}
