import 'package:flutter_test/flutter_test.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/services/task_parser.dart';

/// F-04 回归：自然语言快速录入「每天…」但没写时刻，必须补一个默认 repeatMinute，
/// 否则重复提醒根本不会排程（生成「哑重复任务」）。
///
/// 时间基准与 task_parser_test 一致：2026-08-09 10:00（周日）。
final _base = DateTime(2026, 8, 9, 10, 0);

ParsedTask _p(String input) => TaskParser.parse(input, now: _base);

void main() {
  group('快速录入重复任务补默认提醒时刻（F-04）', () {
    test('「每天喝水」无时刻 → repeatMinute 非 null', () {
      final r = _p('每天喝水');
      expect(r.repeat, RepeatType.daily);
      expect(r.repeatMinute, isNotNull);
      // 默认时刻与仅给日期时的默认小时一致（9:00 → 540 分）。
      expect(r.repeatMinute, 9 * 60);
    });

    test('「每周一开会」无时刻 → repeatMinute 非 null', () {
      final r = _p('每周一开会');
      expect(r.repeat, RepeatType.weekly);
      expect(r.repeatMinute, isNotNull);
    });

    test('写了时刻则严格采用解析到的时刻', () {
      final r = _p('每天 8:30 背单词');
      expect(r.repeat, RepeatType.daily);
      expect(r.repeatMinute, 8 * 60 + 30);
    });

    test('非重复任务不带时刻时 repeatMinute 为 null（不应误补）', () {
      final r = _p('买菜');
      expect(r.repeat, RepeatType.none);
      expect(r.repeatMinute, isNull);
    });
  });
}
