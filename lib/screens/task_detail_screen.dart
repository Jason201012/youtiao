import 'dart:io';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/state/habit_provider.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/widgets/new_task_sheet.dart';
import 'package:todolist/widgets/task_template_sheet.dart';
import 'package:todolist/widgets/occurrence_sheet.dart';
import 'package:todolist/widgets/past_due_guard.dart';
import 'package:just_audio/just_audio.dart';
import 'package:todolist/models/attachment.dart';
import 'package:todolist/services/attachment_service.dart';
import 'package:todolist/services/data_io.dart';

/// 识别备注中的 http(s) 链接并渲染为可点击文本（其余部分保持普通文本）。
///
/// 安全审计 L-12，两处收口：
///
/// 1. **正则收紧**：只认 `http://` / `https://`，域名段限定为常规域名字符，
///    并把中英文句末标点（`.,;:!?)]}"'。，；：！？）】》"` 等）从尾部剥离，
///    避免「参见 https://a.com。」把句号一起吞进 URL；
/// 2. **默认不外跳**：本 App 定位为「除检查更新外不联网」，点击链接会离开本地
///    并由浏览器发起网络请求。默认行为改为**只复制链接并提示**；用户在设置里
///    显式打开「允许打开备注中的链接」后才真正唤起外部浏览器。
class _NoteText extends StatelessWidget {
  final String text;
  final Color color;

  /// 是否允许点击后唤起外部浏览器（跟随设置项 [TaskProvider.allowExternalLinks]）。
  final bool allowExternal;
  const _NoteText({
    required this.text,
    required this.color,
    required this.allowExternal,
  });

  /// 收紧后的 URL 正则：
  /// - `https?://` 开头，不接受其它 scheme（file / javascript / data 等一律不入链）；
  /// - 主体为「非空白且非成对括号/引号」的字符，长度上限 2048，防病态长串卡住布局；
  /// - 末尾不允许落在标点上（由 [_trimTrailingPunct] 二次剥离，正则先行排除）。
  static final RegExp _urlRe = RegExp(
    r'https?://[^\s<>"\x27\\^`{|}]{1,2048}'
    r'(?<![.,;:!?)\]\}。，、；：！？）】》」』”’])',
  );

  /// 剥离 URL 尾部的句末标点（正则的否定环视只挡一次，连续标点需循环剥离）。
  static String _trimTrailingPunct(String s) {
    const tail = '.,;:!?)].,;:!?)]。，、；：！？）】》」』”’"\'';
    var end = s.length;
    while (end > 0 && tail.contains(s[end - 1])) {
      end--;
    }
    return s.substring(0, end);
  }

  @override
  Widget build(BuildContext context) {
    final matches = _urlRe.allMatches(text).toList();
    if (matches.isEmpty) {
      return Text(text, style: TextStyle(fontSize: 14, color: color));
    }
    final spans = <InlineSpan>[];
    int cursor = 0;
    final linkColor = Theme.of(context).colorScheme.primary;
    for (final m in matches) {
      if (m.start > cursor) {
        spans.add(TextSpan(
          text: text.substring(cursor, m.start),
          style: TextStyle(fontSize: 14, color: color),
        ));
      }
      final url = _trimTrailingPunct(text.substring(m.start, m.end));
      spans.add(TextSpan(
        text: url,
        style: TextStyle(fontSize: 14, color: linkColor, decoration: TextDecoration.underline),
        recognizer: TapGestureRecognizer()
          ..onTap = () => _onTapLink(context, url),
      ));
      cursor = m.end;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(
        text: text.substring(cursor),
        style: TextStyle(fontSize: 14, color: color),
      ));
    }
    return RichText(text: TextSpan(children: spans));
  }

  /// 点击链接：未授权外跳时只复制 + 提示，授权后走外部浏览器。
  Future<void> _onTapLink(BuildContext context, String url) async {
    final uri = Uri.tryParse(url);
    // 二次校验 scheme：正则已锚定 http(s)，这里再兜一层，杜绝构造出其它 scheme。
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      _tip(context, '链接无法识别');
      return;
    }
    if (!allowExternal) {
      await Clipboard.setData(ClipboardData(text: url));
      if (context.mounted) {
        _tip(context, '已复制链接（可在设置中允许打开外链）');
      }
      return;
    }
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        if (context.mounted) _tip(context, '没有可打开链接的应用');
      }
    } catch (_) {
      if (context.mounted) _tip(context, '打开链接失败');
    }
  }

  static void _tip(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}

/// 任务详情页：展示标题 / 备注 / 标签 / 截止重复 / 累计专注 / 子任务勾选，
/// 并提供编辑、开始专注、删除操作。数据通过 [TaskProvider.byId] 实时读取，
/// 子任务勾选与完成态即时反映到列表。
class TaskDetailScreen extends StatelessWidget {
  final String taskId;
  const TaskDetailScreen({super.key, required this.taskId});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TaskProvider>();
    final task = provider.byId(taskId);
    final ext = appColors(context);
    final onBg = Theme.of(context).colorScheme.onBackground;
    final primary = Theme.of(context).colorScheme.primary;

    if (task == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('任务详情')),
        body: const Center(child: Text('任务不存在或已删除')),
      );
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final priorityColor = task.done
        ? ext.meta
        : (isDark ? task.priority.darkColor() : task.priority.lightColor());
    // U1-1（v2.9.1 审计）：今天是否真的是该任务的循环日（忽略「已跳过」）。
    // 非循环日点「本次跳过」会向 skipDates 塞一个当天无意义的日期——当时看不出问题，
    // 但日后规则改成覆盖该日时会被永久静默跳过，且用户被「已跳过今天这一次」的
    // 成功文案误导（假成功）。这里据此禁用按钮并改文案。
    final canSkipToday = task.isRepeating && task.occursOnIgnoringSkip(DateTime.now());

    return Scaffold(
      appBar: AppBar(
        title: const Text('任务详情'),
        actions: [
          IconButton(
            icon: const Icon(Symbols.edit),
            tooltip: '编辑',
            onPressed: () => TaskSheet.show(context, task: task),
          ),
          IconButton(
            icon: const Icon(Symbols.playlist_add),
            tooltip: '另存为模板',
            onPressed: () => TaskTemplateSheet.saveTaskAsTemplate(context, task),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppColors.pagePadX),
        children: [
          // 标题卡：优先级色条 + 勾选框 + 标题
          _Card(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 4,
                  height: 46,
                  margin: const EdgeInsets.only(right: 12, top: 2),
                  decoration: BoxDecoration(
                    color: priorityColor,
                    borderRadius: BorderRadius.circular(AppColors.ringBarRadius),
                  ),
                ),
                GestureDetector(
                  onTap: () => provider.toggleDone(task.id),
                  child: Container(
                    width: 24,
                    height: 24,
                    margin: const EdgeInsets.only(right: 12, top: 2),
                    decoration: BoxDecoration(
                      color: task.done ? primary : Colors.transparent,
                      shape: BoxShape.circle,
                      border: Border.all(color: ext.meta),
                    ),
                    child: task.done
                        ? const Icon(Symbols.check, size: 16, color: Colors.white)
                        : null,
                  ),
                ),
                Expanded(
                  child: Text(
                    task.title.isNotEmpty ? task.title : '(无标题)',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: task.done ? ext.meta : onBg,
                      decoration: task.done
                          ? TextDecoration.lineThrough
                          : null,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // 备注
          if (task.note.isNotEmpty) ...[
            const SizedBox(height: AppColors.contentGap),
            _Card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _Label('备注'),
                  const SizedBox(height: 6),
                  // L-12：外链默认不外跳，跟随设置项「允许打开备注中的链接」。
                  _NoteText(
                    text: task.note,
                    color: onBg,
                    allowExternal: provider.allowExternalLinks,
                  ),
                ],
              ),
            ),
          ],

          // 标签
          if (task.tags.isNotEmpty) ...[
            const SizedBox(height: AppColors.contentGap),
            _Card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _Label('标签'),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: task.tags
                        .where((t) => t.isNotEmpty)
                        .map((tag) => Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: ext.chip,
                                borderRadius:
                                    BorderRadius.circular(AppColors.chipRadius),
                              ),
                              child: Text('#$tag',
                                  style:
                                      TextStyle(fontSize: 12, color: ext.meta)),
                            ))
                        .toList(),
                  ),
                ],
              ),
            ),
          ],

          // 截止 / 重复 / 累计专注
          const SizedBox(height: AppColors.contentGap),
          _Card(
            child: Column(
              children: [
                _RowItem(
                    icon: Symbols.event, label: '截止', value: _dueLabel(task.dueDate)),
                if (task.startDate != null)
                  _RowItem(
                      icon: Symbols.event_available,
                      label: '开始',
                      value: _dueLabel(task.startDate)),
                if (task.isRepeating)
                  _RowItem(
                      icon: Symbols.repeat,
                      label: '重复',
                      value: task.repeatFull),
                _RowItem(
                    icon: Symbols.timer,
                    label: '累计专注',
                    value: _focusLabel(task.focusSecTotal)),
              ],
            ),
          ),

          // 重复管理（仅重复任务）：本次跳过 / 结束重复 / 仅此一次改期
          //
          // U1-1（v2.9.1 审计）：已「结束重复」的任务（[Task.repeatEnded] 为 true，
          // [Task.isRepeating] 仍为 true）不再展示整块操作区——它已没有任何未来循环日，
          // 跳过 / 改期 / 预览三者都是空操作，摆在那里只会让用户点出「假成功」。
          if (task.isRepeating && !task.repeatEnded) ...[
            const SizedBox(height: AppColors.contentGap),
            _Card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _Label('重复管理'),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        // U1-1（v2.9.1 审计）：非循环日（如「每周一」的任务在周三打开）
                        // 时禁用并改文案——旧实现点了照样弹「已跳过今天这一次」，实际只往
                        // skipDates 塞了一个当天无意义的日期，属假成功；而日后把规则改到
                        // 覆盖该日时，会被这条陈旧记录永久静默跳过。
                        onPressed: canSkipToday
                            ? () {
                                // P2-2（v2.8.8 审计）：本次跳过此前点击即关页、无确认亦无撤销，
                                // 误触后当天该次循环彻底消失（列表不出现、提醒不响）且当天
                                // 无法恢复，只能等 occurrence 滚动过期被清掉——对纯本地无云端的
                                // 待办应用是一条明确的交互死路。这里补 SnackBar 撤销入口
                                // （unskipOccurrence 与 skipOccurrence 严格互逆、同样重排提醒）。
                                // 先取 messenger：pop 之后本页 context 已失效，须在 pop 前捕获。
                                final messenger = ScaffoldMessenger.of(context);
                                provider.skipOccurrence(task.id);
                                Navigator.pop(context);
                                messenger
                                  ..hideCurrentSnackBar()
                                  ..showSnackBar(
                                    SnackBar(
                                      // U1（v2.9.0 审计）：撤销窗口由 5 秒延长到 10 秒——误触后
                                      // 若先做了别的操作（弹窗 / 切页），撤销入口即消失，只能去
                                      // occurrence 预览手动撤销；文案同时给出该常驻路径，与弹层的
                                      // 「撤销跳过」入口联动（两处走同一个 unskipOccurrence）。
                                      // U3-2（v2.9.1 审计）：撤销入口在任务行的重复标签上是
                                      // **点按**（chip 的 onTap），长按反而会进多选——原文案
                                      // 写「长按」属指错路，这里改正。
                                      content: const Text('已跳过今天这一次（可点按任务行的重复标签，'
                                          '在「未来循环日预览」中撤销）'),
                                      duration: const Duration(seconds: 10),
                                      action: SnackBarAction(
                                        label: '撤销',
                                        onPressed: () =>
                                            provider.unskipOccurrence(task.id),
                                      ),
                                    ),
                                  );
                              }
                            : null,
                        icon: const Icon(Symbols.skip_next, size: 18),
                        label: Text(canSkipToday ? '本次跳过' : '今天不是循环日'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () async {
                          // F-3（v2.8.5 审计）：旧文案承诺「今天起不再出现」，实际任务
                          // 却因 dueDate 被清空落进首页「今天」分区（说谎式 UI）。
                          // 改为双动作：结果与用户意图直接对齐——
                          // 「结束并标记完成」= 停止循环 + 计入今日完成，落「已完成」区；
                          // 「结束并保留待办」= 停止循环 + 保留在今天待办中，由用户处置。
                          final action = await showDialog<String>(
                            context: context,
                            builder: (c) => AlertDialog(
                              title: const Text('结束重复'),
                              content: const Text(
                                  '将停止该任务在此之后的循环，历史不受影响。'),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(c, 'cancel'),
                                  child: const Text('取消'),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.pop(c, 'keep'),
                                  child: const Text('结束并保留待办'),
                                ),
                                FilledButton(
                                  onPressed: () => Navigator.pop(c, 'done'),
                                  child: const Text('结束并标记完成'),
                                ),
                              ],
                            ),
                          );
                          if (action == 'keep') {
                            provider.endRepeat(task.id);
                            if (context.mounted) Navigator.pop(context);
                          } else if (action == 'done') {
                            provider.endRepeat(task.id, markDone: true);
                            if (context.mounted) Navigator.pop(context);
                          }
                        },
                        icon: const Icon(Symbols.event_busy, size: 18),
                        label: const Text('结束重复'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () async {
                          // U2-2（v2.9.1 审计）：下面 pop 与提示都发生在 await 之后，
                          // 而本页 pop 后 BuildContext 即失效——先（await 之前）把
                          // Navigator / ScaffoldMessenger 取下来，避免跨异步间隙使用
                          // BuildContext（也避免 analyzer 的 use_build_context 提示）。
                          final navigator = Navigator.of(context);
                          final messenger = ScaffoldMessenger.of(context);
                          final picked = await showDatePicker(
                            context: context,
                            initialDate:
                                DateTime.now().add(const Duration(days: 1)),
                            firstDate: DateTime.now(),
                            lastDate:
                                DateTime.now().add(const Duration(days: 365)),
                          );
                          if (picked != null) {
                            final dayLabel = '${picked.month}月${picked.day}日';
                            // P3-3（v2.9.1 审计）：目标日 == 今天时 provider 为**无操作**
                            // （旧实现会 skip 今天 + 新建一条 dueDate=今天的副本，同日出现
                            // 两条任务且副本提醒已过、静默不响）。这里提前拦下并如实反馈。
                            if (Task.isSameDay(picked, DateTime.now())) {
                              if (context.mounted) navigator.pop();
                              messenger
                                ..hideCurrentSnackBar()
                                ..showSnackBar(const SnackBar(
                                  content: Text('目标日就是今天，本次改期无变化'),
                                  duration: Duration(seconds: 4),
                                ));
                              return;
                            }
                            // F-2（v2.8.5 审计）：目标日副本提醒时刻已过 → 提前预演提示
                            // 「提醒不会触发」，与新建/编辑弹层、批量顺延的
                            // [PastDueGuard] 口径一致（此前该入口是少数没接上的入口）。
                            // 改期到今天且原 repeatMinute 时刻已过时，副本不会响。
                            final src = provider.byId(task.id);
                            final hhmm = src?.repeatMinute;
                            final h = hhmm != null
                                ? hhmm ~/ 60
                                : (src?.dueDate?.hour ?? 9);
                            final m = hhmm != null
                                ? hhmm % 60
                                : (src?.dueDate?.minute ?? 0);
                            final when = DateTime(
                                picked.year, picked.month, picked.day, h, m);
                            if (when.isBefore(DateTime.now())) {
                              final ok = await PastDueGuard.confirm(
                                context,
                                count: 1,
                                detail:
                                    '目标日（${picked.month}/${picked.day} '
                                    '${h.toString().padLeft(2, '0')}:'
                                    '${m.toString().padLeft(2, '0')}）的提醒时刻'
                                    '已早于当前时刻，改期后提醒将不会触发。\n\n仍要改期吗？',
                              );
                              if (!ok) return;
                            }
                            final copy =
                                provider.rescheduleOnceOccurrence(task.id, picked);
                            if (context.mounted) navigator.pop();
                            messenger
                              ..hideCurrentSnackBar()
                              ..showSnackBar(SnackBar(
                                // U2-2：目标日本身就是循环日时 provider 只跳过本次、
                                // 不建副本（返回 null）——必须说清，否则用户找不到副本。
                                content: Text(copy == null
                                    ? '已跳过今天这一次：$dayLabel 本身是循环日，由原循环覆盖，未新建副本'
                                    : '已改期至 $dayLabel（已新建一次性副本）'),
                                duration: const Duration(seconds: 8),
                              ));
                          }
                        },
                        icon: const Icon(Symbols.edit_calendar, size: 18),
                        label: const Text('仅此一次改期'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () {
                          OccurrenceSheet.show(context, task, provider);
                        },
                        icon: const Icon(Symbols.calendar_month, size: 18),
                        label: const Text('未来30天预览'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],

          // 子任务
          if (task.subtasks.isNotEmpty) ...[
            const SizedBox(height: AppColors.contentGap),
            _Card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const _Label('子任务'),
                      const Spacer(),
                      Text('${task.subtaskDone}/${task.subtaskTotal}',
                          style: TextStyle(fontSize: 13, color: ext.meta)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                    value: task.subtaskTotal == 0
                        ? 0
                        : task.subtaskDone / task.subtaskTotal,
                    minHeight: 4,
                    backgroundColor: ext.track,
                    valueColor: AlwaysStoppedAnimation<Color>(ext.accent),
                    borderRadius: BorderRadius.circular(2),
                  ),
                  const SizedBox(height: 4),
                  for (final s in task.subtasks)
                    _SubTile(
                      sub: s,
                      onChanged: (_) => provider.toggleSubTask(task.id, s.id),
                    ),
                ],
              ),
            ),
          ],

          // 附件（P0-1）：图片 / 录音 / 文件，全程本地不联网，不触发任何网络请求。
          // 与编辑页一致：图片缩略图点击全屏预览、录音内联播放、其它文件经系统分享打开。
          if (task.attachments.isNotEmpty) ...[
            const SizedBox(height: AppColors.contentGap),
            _Card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const _Label('附件'),
                      const Spacer(),
                      Text('${task.attachments.length}',
                          style: TextStyle(fontSize: 13, color: ext.meta)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  for (final ref in task.attachments)
                    _AttachmentTile(taskId: task.id, ref: ref),
                ],
              ),
            ),
          ],

          const SizedBox(height: 24),

          // 开始专注
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () {
                context.read<FocusProvider>().requestTask(task.id, task.title);
                Navigator.pop(context);
              },
              icon: const Icon(Symbols.timer),
              label: const Text('开始专注'),
            ),
          ),
          const SizedBox(height: 12),

          // 转为习惯（S5）：把当前任务一键转为日常习惯，并询问是否删除原任务（走回收站可撤销）。
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => _convertToHabit(context, task),
              icon: const Icon(Symbols.repeat),
              label: const Text('转为习惯'),
            ),
          ),
          const SizedBox(height: 12),

          // 删除（带二次确认，避免误删）
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () async {
                final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('删除任务'),
                        // U3-1（v2.9.1 审计）：原文案「此操作可在任务列表滑动删除后撤销」
                        // 表述绕且指错路径——详情页删除走的是 provider.deleteTask（入回收站），
                        // 本页 pop 后**不会**展示撤销 SnackBar（那条入口在首页滑删流程里）。
                        // 改为如实说明去向与恢复路径。
                        content: const Text('确认删除该任务？将移入回收站，'
                            '可在「设置 → 回收站」中恢复。'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('取消'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text('删除'),
                          ),
                        ],
                      ),
                    ) ??
                    false;
                if (!confirmed) return;
                provider.deleteTask(task.id);
                if (context.mounted) Navigator.pop(context);
              },
              icon: const Icon(Symbols.delete),
              label: const Text('删除'),
            ),
          ),
        ],
      ),
    );
  }
}

/// 把任务一键转为习惯（S5）。
///
/// 逻辑：用任务标题建一条「每天」打卡的习惯（emoji 用默认✅，强调色用品牌色，
/// 不携带提醒时间——让用户后续在习惯页自行设置提醒时机，避免误打扰）。
/// 建完后询问是否删除原任务：选「删除」则走 deleteTask（进回收站、可撤销），
/// 不选则保留任务（用户可同时保留任务与习惯，互不影响）。
Future<void> _convertToHabit(BuildContext context, Task task) async {
  final habit = context.read<HabitProvider>();
  // 习惯默认「每天」打卡（weekdays 空=每天），emoji✅，品牌色，无提醒。
  final brandColor = Theme.of(context).colorScheme.primary.value;
  await habit.addHabit(
    title: task.title,
    emoji: '✅',
    colorValue: brandColor,
    weekdays: const [], // 空=每天
    reminderMinute: null, // 不自动提醒，用户后续自行设置
  );

  if (!context.mounted) return;
  // 询问是否删除原任务（默认保留，避免误删）。选「删除」才进回收站（可撤销）。
  final remove = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('已转为习惯'),
      content: const Text('已把该任务创建为「每天」打卡的习惯。是否同时删除原任务？（删除后可在回收站撤销）'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('保留任务'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('删除任务'),
        ),
      ],
    ),
  );
  if (remove == true) {
    context.read<TaskProvider>().deleteTask(task.id);
  }
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已转为习惯（可在「习惯」页设置提醒）')),
    );
    Navigator.pop(context);
  }
}

/// 详情页统一卡片容器。
class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});
  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(AppColors.cardRadius),
        ),
        child: child,
      );
}

/// 分区小标题。
class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);
  @override
  Widget build(BuildContext context) => Text(
        text,
        style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: appColors(context).meta),
      );
}

/// 一行（图标 + 标签 + 值）。
class _RowItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _RowItem(
      {required this.icon, required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 18, color: ext.meta),
          const SizedBox(width: 10),
          Text(label, style: TextStyle(fontSize: 13, color: ext.meta)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              style: TextStyle(fontSize: 14, color: Theme.of(context).colorScheme.onBackground),
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }
}

/// 子任务勾选项。
class _SubTile extends StatelessWidget {
  final SubTask sub;
  final ValueChanged<bool?> onChanged;
  const _SubTile({required this.sub, required this.onChanged});
  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    return InkWell(
      onTap: () => onChanged(!sub.done),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Icon(
              sub.done ? Symbols.check_circle : Symbols.circle,
              size: 20,
              color: sub.done ? ext.accent : ext.meta,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                sub.title,
                style: TextStyle(
                  fontSize: 14,
                  color: sub.done
                      ? ext.meta
                      : Theme.of(context).colorScheme.onBackground,
                  decoration: sub.done ? TextDecoration.lineThrough : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _dueLabel(DateTime? due) {
  if (due == null) return '无截止';
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final d = DateTime(due.year, due.month, due.day);
  final diff = d.difference(today).inDays;
  final time =
      ' ${due.hour.toString().padLeft(2, '0')}:${due.minute.toString().padLeft(2, '0')}';
  if (diff == 0) return '今天$time';
  if (diff == 1) return '明天$time';
  if (diff == -1) return '昨天$time';
  if (diff < 0) return '已逾期$time';
  return '${due.month}月${due.day}日$time';
}

String _focusLabel(int sec) {
  final m = (sec / 60).round();
  if (m < 60) return '$m分钟';
  final h = m ~/ 60;
  final mm = m % 60;
  return mm == 0 ? '${h}小时' : '${h}小时$mm分';
}

/// 详情页附件条目（P0-1）：图片缩略图点击全屏预览（可缩放）、录音内联播放 / 停止、
/// 其它文件经系统分享打开。音频播放用 just_audio 的 [AudioPlayer]，其生命周期随本组件释放
/// （dispose 时 dispose，避免后台持续占用音频通道）。所有文件均位于 App 私有目录，不联网。
class _AttachmentTile extends StatefulWidget {
  final String taskId;
  final AttachmentRef ref;
  const _AttachmentTile({required this.taskId, required this.ref});

  @override
  State<_AttachmentTile> createState() => _AttachmentTileState();
}

class _AttachmentTileState extends State<_AttachmentTile> {
  final AudioPlayer _player = AudioPlayer();
  bool _playing = false;
  bool _loading = false;
  // 播放状态流订阅：仅在播放期间持有，dispose 时取消，避免悬挂监听。
  StreamSubscription<PlayerState>? _sub;
  // 附件实体文件在 App 私有目录（attachments/<taskId>/<fileName>），不存绝对路径。
  late final Future<File> _fileFuture;

  @override
  void initState() {
    super.initState();
    _fileFuture = AttachmentService.fileFor(widget.taskId, widget.ref);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _player.dispose();
    super.dispose();
  }

  Future<void> _onTap() async {
    final ref = widget.ref;
    final file = await _fileFuture;
    if (!await file.exists()) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('附件文件不存在')));
      }
      return;
    }
    if (ref.type == AttachmentType.image) {
      // 图片全屏预览：Dialog + InteractiveViewer 支持双指缩放（本地文件，不联网）。
      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (_) => Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: const EdgeInsets.all(12),
            child: InteractiveViewer(child: Image.file(file, fit: BoxFit.contain)),
          ),
        );
      }
    } else if (ref.type == AttachmentType.audio) {
      // 录音：首次点击播放，播放中点击停止；播放结束自动复位按钮态。
      if (_playing) {
        _sub?.cancel();
        _sub = null;
        await _player.stop();
        if (mounted) setState(() => _playing = false);
        return;
      }
      if (mounted) setState(() => _loading = true);
      try {
        // 取消上一次可能残留的订阅，避免「停止后再播」场景下的重复监听 / 泄漏。
        _sub?.cancel();
        _sub = null;
        await _player.setFilePath(file.path);
        await _player.play();
        if (mounted) setState(() => _playing = true);
        _sub = _player.playerStateStream.listen((s) {
          if (s.processingState == ProcessingState.completed) {
            if (mounted) setState(() => _playing = false);
          }
        });
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('播放失败：$e')));
        }
      } finally {
        if (mounted) setState(() => _loading = false);
      }
    } else {
      // 其它文件：经系统分享面板选择对应 App 打开（不联网）。
      await DataIo.shareFile(
          file, mimeType: ref.mimeType ?? 'application/octet-stream');
    }
  }

  IconData _icon() {
    switch (widget.ref.type) {
      case AttachmentType.image:
        return Symbols.image;
      case AttachmentType.audio:
        return _playing ? Symbols.stop : Symbols.graphic_eq;
      case AttachmentType.file:
        return Symbols.description;
    }
  }

  /// 录音时长 mm:ss（仅音频有意义）。
  String _durationLabel(int ms) {
    final s = (ms / 1000).round();
    final m = s ~/ 60;
    final ss = s % 60;
    return '$m:${ss.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final ref = widget.ref;
    final ext = appColors(context);
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: _loading ? null : _onTap,
      borderRadius: BorderRadius.circular(AppColors.chipRadius),
      child: Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: ext.chip,
          borderRadius: BorderRadius.circular(AppColors.chipRadius),
        ),
        child: Row(
          children: [
            if (ref.type == AttachmentType.image)
              // 图片缩略图预览（本地文件，不联网）。
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: FutureBuilder<File>(
                  future: _fileFuture,
                  builder: (ctx, snap) {
                    if (snap.hasData && snap.data!.existsSync()) {
                      return Image.file(
                        snap.data!,
                        width: 40,
                        height: 40,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) =>
                            Icon(Symbols.image, size: 24, color: ext.meta),
                      );
                    }
                    return Icon(Symbols.image, size: 24, color: ext.meta);
                  },
                ),
              )
            else
              Icon(_icon(), size: 22, color: ext.meta),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(ref.fileName,
                      style: TextStyle(fontSize: 14, color: scheme.onSurface),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(
                    <String>[
                      ref.type.label,
                      ref.sizeLabel,
                      if (ref.type == AttachmentType.audio && ref.durationMs != null)
                        _durationLabel(ref.durationMs!),
                    ].join(' · '),
                    style: TextStyle(fontSize: 12, color: ext.meta),
                  ),
                ],
              ),
            ),
            if (ref.type == AttachmentType.audio && _loading)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
      ),
    );
  }
}
