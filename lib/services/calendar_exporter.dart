import 'package:add_2_calendar/add_2_calendar.dart';
import 'package:todolist/models/focus_session.dart';

/// 把一次专注会话写入**系统日历**（add_2_calendar 会在首次调用时自动请求权限）。
/// 仅当用户在设置中开启「专注结束记入系统日历」后，由 [FocusProvider] 在专注
/// 结束时调用；失败（权限拒绝 / 平台不支持）由调用方静默吞掉，不影响专注记录本身。
Future<void> exportFocusToSystemCalendar(FocusSession s) async {
  final title = s.taskTitle == null
      ? '专注 ${_fmt(s.durationSec)}'
      : '专注 · ${s.taskTitle}';
  final event = Event(
    title: title,
    description: s.completed ? '已完成一个番茄钟' : '专注记录',
    startDate: s.startedAt,
    endDate: s.endedAt,
    allDay: false,
  );
  await Add2Calendar.addEvent2Cal(event);
}

String _fmt(int totalSec) {
  final m = totalSec ~/ 60;
  final sec = totalSec % 60;
  return '${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
}
