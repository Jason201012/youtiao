/// 重复任务「未来 N 天预览」弹层（P0-5，纯离线）。
///
/// 遍历 [Task.occurrencesBetweenIncludingSkipped] 给出未来 30 天（默认）的循环日
/// ——**含已跳过的日子**（P2-2 v2.8.8：用 [Task.occurrencesBetween] 会把 skipDates
/// 过滤掉，已跳过行永不渲染、撤销入口不可达）。
/// 每行支持「标记完成 / 跳过一次 / 撤销跳过 / 移到下一天」四种逐次操作，分别走
/// [TaskProvider.markOccurrenceDone] / [TaskProvider.unmarkOccurrenceDone] /
/// [TaskProvider.skipOccurrence] / [TaskProvider.unskipOccurrence]，均写入
/// [Task.doneDates] / [Task.skipDates]，避免此前 `updateTask(copyWith(status))`
/// 被 `_applyTaskUpdate` 强制回填旧状态而丢失的 100% 无效路径。
///
/// 「移到下一天」额外走 [TaskProvider.rescheduleOnceOccurrence]，把当天加入
/// skipDates 后另建一次性副本落到 newDay，零新概念。
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/widgets/undo_snack_bar.dart';

class OccurrenceSheet {
  static Future<void> show(
    BuildContext context,
    Task task,
    TaskProvider provider,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => _OccurrenceBody(task: task, provider: provider),
    );
  }
}

class _OccurrenceBody extends StatefulWidget {
  final Task task;
  final TaskProvider provider;
  const _OccurrenceBody({required this.task, required this.provider});

  @override
  State<_OccurrenceBody> createState() => _OccurrenceBodyState();
}

class _OccurrenceBodyState extends State<_OccurrenceBody> {
  late Task _task;

  /// P3-6（v2.9.0 审计）：本弹层内「经『移到下一天』触发跳过」的日期集合
  /// （yyyy-MM-dd）。此前该动作只有一条 4 秒 SnackBar 说明，用户错过提示就会以为
  /// 「没移成功」，且 skipDates 里看不出这条跳过来自「移到下一天」。这里在行内留一个
  /// 可视化痕迹（会话级即可，不新增任何持久字段）。
  final Set<String> _deferSkipped = <String>{};

  @override
  void initState() {
    super.initState();
    _task = widget.task;
  }

  void _refresh() {
    final latest = widget.provider.byId(_task.id);
    if (latest != null && mounted) setState(() => _task = latest);
  }

  bool _isDone(DateTime d) => _task.isDoneOn(d);
  bool _isSkipped(DateTime d) => _task.skipDates.contains(Task.ymdKey(d));

  /// F-10：今天的 date-only 值，用于区分「未来循环日」（只可跳过 / 改期）。
  DateTime get _today {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  /// P3-2（v2.9.0 审计）：该重复的提醒时刻（[Task.repeatMinute]）在今天是否已过去。
  /// 无提醒时刻（repeatMinute 为 null）时不存在「已过」概念，恒为 false。
  bool get _todayReminderPassed {
    final m = _task.repeatMinute;
    if (m == null) return false;
    final n = DateTime.now();
    return n.hour * 60 + n.minute > m;
  }

  /// P3-2（v2.9.0 审计）：预览窗口的起点。
  ///
  /// 窗口此前恒从「今天」起算（`occurrencesBetweenIncludingSkipped(DateTime.now())`），
  /// 于是「每天 07:00」在上午 10 点打开时，今天仍排第一行、仍可「标记完成 / 移到下
  /// 一天」，但此刻提醒早已响过（或不应再响）——文案「未来 30 天共 N 个循环日」与事实
  /// 不符，且对今天是否仍可操作没有任何提示。
  ///
  /// 修正：**今天仍是循环日 + 提醒时刻已过 + 今天既未跳过也未完成** 时，窗口自明天起算；
  /// 其余情况（已跳过 / 已完成 / 无提醒时刻）保留今天——已跳过的行必须仍可撤销
  /// （v2.8.8 P2-2 定的口径），不能因为「提醒已过」把撤销入口藏掉。
  DateTime get _windowStart {
    if (!_task.occursOnIgnoringSkip(_today)) return _today;
    if (_isSkipped(_today) || _isDone(_today)) return _today;
    if (!_todayReminderPassed) return _today;
    return _today.add(const Duration(days: 1));
  }

  void _markDone(DateTime d) {
    // F1：之前 `updateTask(copyWith(status:done))` 路径被 _applyTaskUpdate 强制
    // 回填旧 status，写入静默丢失、UI 无变化。这里走 provider 显式 occurrence
    // 入口，等价于 toggleDone：doneDates 落点 + 重排提醒。
    if (_isDone(d)) {
      widget.provider.unmarkOccurrenceDone(_task.id, d);
    } else {
      widget.provider.markOccurrenceDone(_task.id, d);
    }
    _refresh();
  }

  void _skip(DateTime d, {bool defer = false}) {
    // P2-2：所有重复类型都走 provider.skipOccurrence（内部已统一重排提醒），
    // 不再用 updateTask 写 skipDates，避免 reminder 链路与列表标记脱节。
    if (_isSkipped(d)) return;
    if (defer) {
      // 「移到下一天」= 把当前 occurrence 跳过 + 在新日期另落一次性副本。
      // F-2（v2.8.5 审计）：若 newDay 本身就是循环日，provider 只会 skip 本次、
      // **不建副本**（返回 null）——否则目标日循环提醒 + 副本一次性提醒双响，
      // 且循环完成后副本仍挂着。文案与撤销动作据此分支。
      final newDay = d.add(const Duration(days: 1));
      final copy = widget.provider.rescheduleOnceOccurrence(
        _task.id,
        newDay,
        origDay: d,
      );
      // P3-6：给被跳过的这一天留一个会话级痕迹（行内文案会显示跳过来源）。
      _deferSkipped.add(Task.ymdKey(d));
      _refresh();
      if (context.mounted) {
        final dayLabel =
            '${newDay.month.toString().padLeft(2, '0')}-${newDay.day.toString().padLeft(2, '0')}';
        // P3-2（v2.9.6 审计）：迁入 `widgets/undo_snack_bar.dart` 唯一实现——
        // 本分支此前是内联 SnackBar（`kUndoWindow` 时长但**无超时提示**、
        // 文案未插秒数），同族「撤销」第 3 套实现。注释曾称「复合撤销语义上
        // 无法套用唯一实现的简单形态」不成立：复合动作本就是任意闭包，
        // 迁入后自动获得秒数插值与「窗口超时已结束」提示。
        // P3-5（v2.9.5 审计）：本分支的撤销是**复合**的（删副本 + 取消跳过）。
        showUndoSnackBar(
          context,
          content: undoContent(copy == null
              ? '已移到 $dayLabel（该日本就是循环日，由原循环覆盖，无需另建副本）'
              : '已移到 $dayLabel（已新建一次性副本）'),
          onUndo: () async {
            // P2-1（v2.8.8）：撤销必须**双向**还原——① 按 service 返回的副本 id
            // 精确移除那座一次性副本（原实现按「标题 + 日期」反查，同名任务
            // 同一天改期时会误删另一个真实任务；而且误用了只作用于回收站的
            // permanentDelete，副本其实一直留在活动列表里，「撤销」形同虚设）；
            // ② 把原日从 skipDates 移除，否则撤销后原日仍显示「已跳过」，
            // UI 对用户说谎。两个动作均幂等。
            // 新P3-8（v2.9.7 审计）：返回**真实结果**——源任务在 10 秒窗口内
            // 被他处删除时（byId == null），副本清理与「取消跳过」都无从谈起
            // （unskipOccurrence 对不存在的源任务静默 no-op），不能谎报成功。
            if (widget.provider.byId(_task.id) == null) return false;
            if (copy != null) {
              widget.provider.discardTask(copy.id);
            }
            widget.provider.unskipOccurrence(_task.id, day: d);
            _deferSkipped.remove(Task.ymdKey(d));
            _refresh();
            return true;
          },
        );
      }
      return;
    }
    // U2-5（v2.9.4 审计）：非 defer 分支（纯「跳过这一次」）此前是
    // `skipOccurrence` + `_refresh()` 就结束——**无确认、无撤销**，
    // 而同一语义在任务详情页（`task_detail_screen.dart` 的「跳过今天这一次」）
    // 已有 10 秒撤销。同一个动作在两个入口给出两种保护力度，是明确的不对等：
    // 用户从弹层误触后，当天该次循环彻底消失（列表不出现、提醒不响），
    // 只能手动去「未来循环日预览」里撤销。
    //
    // 现在两处对齐：同样 10 秒窗口 + unskipOccurrence 严格互逆 + 同样重排提醒。
    // 文案里给出常驻撤销路径（点按任务行的重复标签 → 预览 → 撤销跳过），
    // 窗口错过也不至于无路可走。
    //
    // U2-4 / P3-10：不再 `hideCurrentSnackBar()`——`ScaffoldMessenger` 自带
    // 队列，主动 hide 等于亲手丢掉前一条撤销机会。
    widget.provider.skipOccurrence(_task.id, day: d);
    _refresh();
    final dayLabel = '${d.month}月${d.day}日';
    // P3-5（v2.9.5 审计）：改走唯一实现——补上「窗口超时已结束」提示，
    // 并彻底删掉此前散落各处的 `kUndoWindow` / 秒数插值（避免下一轮再漂移）。
    showUndoSnackBar(
      context,
      content: undoContent('已跳过 $dayLabel 这一次'),
      onUndo: () async {
        // 新P3-8（v2.9.7 审计）：源任务已被他处删除时返回 false（见 defer 分支注）。
        if (widget.provider.byId(_task.id) == null) return false;
        widget.provider.unskipOccurrence(_task.id, day: d);
        _deferSkipped.remove(Task.ymdKey(d));
        _refresh();
        return true;
      },
    );
  }

  /// P2-2（v2.8.8 审计）：撤销某一天的跳过（与 [_skip] 严格互逆）。
  ///
  /// 此前 [TaskProvider.unskipOccurrence] 唯一 UI 调用点是「移到下一天」的 SnackBar
  /// 撤销，已跳过的日子在弹层里只有「跳过一次」（幂等 no-op）与「移到下一天」，
  /// 用户无法仅撤销跳过、只能走间接路径。这里给它一个独立入口。
  void _unskip(DateTime d) {
    if (!_isSkipped(d)) return; // 未跳过，幂等
    widget.provider.unskipOccurrence(_task.id, day: d);
    // P3-6：撤销后不再有「经『移到下一天』跳过」的痕迹。
    _deferSkipped.remove(Task.ymdKey(d));
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    // P2-2（v2.8.8 审计）：必须用「不排除跳过」的窗口——否则 `skipDates` 命中的
    // 日子被 `repeatsOn` 过滤掉、已跳过行永不渲染，用户跳过一次后在本弹层既看不到
    // 也无法撤销（`skipped` 分支此前是不可达死代码）。
    // P3-2（v2.9.0 审计）：起点改走 [_windowStart]——今天提醒时刻已过时不再把今天
    // 当作可操作的循环日。
    final start = _windowStart;
    final occ = _task.occurrencesBetweenIncludingSkipped(start);
    final skippedCount = occ.where(_isSkipped).length;
    final todayIgnored = start.isAfter(_today);
    final weekdayNames = ['一', '二', '三', '四', '五', '六', '日'];
    return DraggableScrollableSheet(
      initialChildSize: 0.8,
      maxChildSize: 0.95,
      minChildSize: 0.5,
      expand: false,
      builder: (_, scroll) => Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Text('未来循环日预览',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
                '「${_task.title}」· 未来 30 天共 ${occ.length} 个循环日'
                '${skippedCount > 0 ? '（含 $skippedCount 个已跳过）' : ''}'
                // P3-2：今天提醒时刻已过时如实说明窗口口径，避免「今天怎么不见了」。
                '${todayIgnored ? '（今天的提醒时刻已过，自明天起算）' : ''}',
                style: const TextStyle(fontSize: 13, color: Colors.grey)),
          ),
          const Divider(height: 1),
          Expanded(
            child: occ.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('未来 30 天内没有循环日（可能已到结束日期）。',
                          style: TextStyle(color: Colors.grey)),
                    ),
                  )
                : ListView.builder(
                    controller: scroll,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: occ.length,
                    itemBuilder: (_, i) {
                      final d = occ[i];
                      final done = _isDone(d);
                      final skipped = _isSkipped(d);
                      final wd = weekdayNames[(d.weekday - 1).clamp(0, 6)];
                      // F-10：未来循环日**不允许**「标记完成」（预打卡）——那样
                      // 列表显示「已完成」而当天提醒照样响，语义自相矛盾。
                      // 未来日期只提供「跳过一次 / 移到下一天」（都不涉及完成态）。
                      // 例外：该日若**已经**被标记完成（旧版本遗留的预打卡数据），
                      // 仍允许「标记未完成」把脏数据清掉，否则用户无从撤销。
                      final isFuture = d.isAfter(_today);
                      // P3-3（v2.9.0 审计）：已跳过的日子不再提供「标记完成」——两者是
                      // 互斥状态，此前同日可先后进入 `skipDates` 与 `doneDates`（双态并存），
                      // 撤销跳过后今天仍被 `isDoneOn` 判为已完成、提醒不回弹，用户会困惑
                      // 「撤销了怎么还是不响」。菜单按状态互斥：已跳过 → 仅「撤销跳过」。
                      final canToggleDone = (!isFuture || done) && !skipped;
                      final isToday = Task.isSameDay(d, _today);
                      // P3-6：提示这一天的跳过来自「移到下一天」。
                      final deferred = _deferSkipped.contains(Task.ymdKey(d));
                      // U16：完成态原硬编码 Colors.green，深色主题下刺眼且与
                      // App 语义色脱节；改主色（与全局完成勾选一致）。
                      final doneColor = Theme.of(context).colorScheme.primary;
                      // P3-2：今天若仍显示（已跳过 / 已完成 / 无提醒时刻），提醒时刻已过
                      // 时如实标注，避免用户误以为「今天还能再操作一次」。
                      final todayPassed = isToday && _todayReminderPassed;
                      return ListTile(
                        leading: Icon(
                          done
                              ? Symbols.check_circle
                              : skipped
                                  ? Symbols.block
                                  : Symbols.repeat,
                          color: done
                              ? doneColor
                              : skipped
                                  ? Colors.grey
                                  : Theme.of(context).colorScheme.primary,
                        ),
                        title: Text(
                          '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} 周$wd',
                        ),
                        subtitle: Text(
                          done
                              ? '已完成'
                              : skipped
                                  ? (deferred
                                      ? '已跳过（经「移到下一天」）'
                                      : '已跳过')
                                  : isFuture
                                      ? '待处理（未来只可跳过 / 改期）'
                                      : todayPassed
                                          ? '待处理（提醒时刻已过）'
                                          : '待处理',
                          style: TextStyle(
                            color:
                                done ? doneColor : skipped ? Colors.grey : null,
                          ),
                        ),
                        trailing: PopupMenuButton<String>(
                          onSelected: (v) {
                            if (v == 'done') _markDone(d);
                            if (v == 'skip') _skip(d);
                            if (v == 'unskip') _unskip(d);
                            if (v == 'defer') _skip(d, defer: true);
                          },
                          // P3-2：文案随实例状态动态化——已完成实例此前仍标「标记完成」，
                          // 点下去实际是取消完成，语义与行为相反。
                          // P2-2（v2.8.8 审计）：已跳过的日子此前仍显示「跳过一次」
                          // （幂等 no-op，UI 说谎）与「移到下一天」（`_skip` 首行的
                          // `_isSkipped` 早退使其同样无效），且全程没有任何「撤销跳过」
                          // 入口。这里按状态互斥重排菜单：
                          // - 未跳过 → 「跳过一次 / 移到下一天」；
                          // - 已跳过 → 「撤销跳过」（走 unskipOccurrence，内部重排提醒），
                          //   不再展示两个必然 no-op 的项。
                          itemBuilder: (_) => [
                            if (canToggleDone)
                              PopupMenuItem(
                                  value: 'done',
                                  child: Text(done ? '标记未完成' : '标记完成')),
                            if (skipped)
                              const PopupMenuItem(
                                  value: 'unskip', child: Text('撤销跳过'))
                            else ...[
                              const PopupMenuItem(
                                  value: 'skip', child: Text('跳过一次')),
                              const PopupMenuItem(
                                  value: 'defer', child: Text('移到下一天')),
                            ],
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
