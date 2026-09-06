import 'package:flutter_test/flutter_test.dart';
import 'package:todolist/services/csv_safe.dart';

/// F-11 回归：CSV 公式注入防护。
///
/// Excel / WPS 打开 CSV 时，以 `=` `+` `-` `@` 开头的单元格会被当作公式执行
/// （DDE / HYPERLINK 注入载体）。OWASP 还指出攻击可加前导空白 / Tab / 回车来绕过
/// 仅看 `v[0]` 的判定——本测试覆盖这些边界。
void main() {
  test('以公式引导符开头的单元格被前置单引号', () {
    expect(csvCell('=HYPERLINK("evil")'), startsWith("'"));
    expect(csvCell('+1+1'), startsWith("'"));
    expect(csvCell('-2'), startsWith("'"));
    expect(csvCell('@SUM(1)'), startsWith("'"));
  });

  test('前导空白 / Tab / 回车后的公式仍被拦截（F-11 关键）', () {
    expect(csvCell('   =1+1'), startsWith("'"));
    expect(csvCell('\t=cmd|"/c calc"!A1'), startsWith("'"));
    expect(csvCell('\r=1+1'), startsWith("'"));
    expect(csvCell(' \t\r@evil'), startsWith("'"));
  });

  test('普通文本（含中文、正常日期）不被误伤', () {
    expect(csvCell('买菜'), '买菜');
    expect(csvCell('2026-09-06 任务'), '2026-09-06 任务');
    expect(csvCell('已完成'), '已完成');
    expect(csvCell(''), '');
  });

  test('双引号被正确转义', () {
    expect(csvCell('a"b'), 'a""b');
    expect(csvCell('"=evil"'), '"\'\'=evil""');
  });
}
