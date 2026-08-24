import 'package:flutter_test/flutter_test.dart';
import 'package:todolist/models/task.dart';

/// 固化 P1-1 修复：之前误用 [PinyinHelper.getFirstWordPinyin]（返回全拼「zhengli」），
/// 导致「拼音首字母搜索」退化为全拼子串匹配、跨字首字母（搜 "zz" 命中「整理周…」）失效。
/// 修复后改用 [PinyinHelper.getShortPinyin]，这里用单测把行为钉死，避免再次回退。
void main() {
  group('Task.computePinyinInitials（A1 / P1-1 修复固化）', () {
    test('「整理」→ "zl"（首字母，非全拼）', () {
      expect(Task.computePinyinInitials('整理'), 'zl');
    });

    test('「整理周会纪要」→ "zlzhjy"（逐字首字母）', () {
      expect(Task.computePinyinInitials('整理周会纪要'), 'zlzhjy');
    });

    test('单字「整」→ "z"', () {
      expect(Task.computePinyinInitials('整'), 'z');
    });

    test('空标题返回空串', () {
      expect(Task.computePinyinInitials(''), '');
    });

    test('非汉字（英文/数字）被跳过，仅取汉字首字母', () {
      // 搜 "abc" 不应被中文标题里的字母串命中；首字母只来自汉字。
      expect(Task.computePinyinInitials('abc整理'), 'zl');
      expect(Task.computePinyinInitials('整理123'), 'zl');
    });

    test('跨字首字母匹配：结果绝不包含全拼（回归 P1-1）', () {
      // 修复前存的是全拼「zhengli…」，"zz" 无法命中；修复后应为 "zlz"。
      final initials = Task.computePinyinInitials('整理周');
      expect(initials, 'zlz');
      // 强调：首字母串里不能出现完整拼音片段（否则说明又退回 getFirstWordPinyin）。
      expect(initials.contains('zheng'), isFalse);
      expect(initials.contains('li'), isFalse);
    });
  });
}
