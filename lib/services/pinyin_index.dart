import 'package:lpinyin/lpinyin.dart';

/// A4（v3.1.1 功能增强）：标题拼音索引（首字母 + 全拼）的**单一真源**。
///
/// 此前只有 `Task.computePinyinInitials` 一处实现（首字母）；A4 新增全拼后
/// 抽到本服务，供 Task / Habit 两个模型共用，避免两套 CJK 过滤与多音字
/// 口径各自漂移（下一轮审计的同型「不横向推广」缺口）。
///
/// 口径（与 v2.x 以来的首字母实现逐位一致）：
/// - 仅取 CJK 统一汉字区（含扩展 A）的拼音；字母 / 数字 / 标点一律忽略——
///   避免英文标题里的字母串被拼音路径误命中（搜 "abc" 不应命中中文标题）。
/// - 输出小写、无分隔；空标题 / 纯非汉字标题返回空串（搜索侧空串跳过）。
/// - 全拼用 `getPinyinE`（缺字以空串兜底、不抛异常）：lpinyin 的 `getPinyin`
///   遇生僻字会抛 [PinyinException]，绝不能用在新建 / 编辑 / 恢复主路径。
class PinyinIndex {
  PinyinIndex._();

  /// 拼音首字母串。如「整理周会纪要」→ "zlzhjy"。
  static String initials(String title) {
    if (title.isEmpty) return '';
    final buf = StringBuffer();
    for (final rune in title.runes) {
      if (!_isCjk(rune)) continue;
      final ch = String.fromCharCode(rune);
      // getShortPinyin 对单字返回首字母（「整」→ "z"）；getFirstWordPinyin
      // 返回完整拼音（「整」→ "zheng"），不能用于首字母。
      final py = PinyinHelper.getShortPinyin(ch);
      if (py.isNotEmpty) buf.write(py.toLowerCase());
    }
    return buf.toString();
  }

  /// 拼音全拼串（小写、无分隔）。如「整理周会纪要」→ "zhenglizhouhuijiyao"。
  static String full(String title) {
    if (title.isEmpty) return '';
    final buf = StringBuffer();
    for (final rune in title.runes) {
      if (!_isCjk(rune)) continue;
      final ch = String.fromCharCode(rune);
      buf.write(PinyinHelper.getPinyinE(ch, separator: '', defPinyin: ''));
    }
    return buf.toString().toLowerCase();
  }

  /// 是否为「纯字母查询」（a-z，已小写化）。全拼匹配仅在纯字母 ≥2 位时启用，
  /// 与报告 A4 的「长度阈值/边界用例」验收一致。
  static bool isAlphaQuery(String q) => q.isNotEmpty && _alpha.hasMatch(q);

  static final RegExp _alpha = RegExp(r'^[a-z]+$');

  /// 判断码点是否落在常用汉字区（CJK Unified Ideographs + 扩展 A）。
  static bool _isCjk(int rune) =>
      (rune >= 0x4E00 && rune <= 0x9FFF) || // 基本汉字
      (rune >= 0x3400 && rune <= 0x4DBF); // 扩展 A
}
