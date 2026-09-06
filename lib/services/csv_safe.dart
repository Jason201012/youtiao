/// CSV / 表格导出共用的单元格转义（S11 / F-11）。
///
/// 背景：导出的 CSV 会被 Excel / WPS / 数字表格直接打开，而以 `=` `+` `-` `@`
/// 开头的单元格会被当成**公式执行**（DDE / HYPERLINK 一类的注入载体，
/// 任务标题来自用户输入或 iCal 导入，属不可信内容）。
///
/// OWASP 建议的双重处理，这里都做：
///  1. 转义双引号（`"` → `""`，CSV 标准转义）；
///  2. 若**去掉前导空白 / Tab / 回车后的首个有效字符**是公式引导符，
///     前置一个单引号强制按文本处理。
///
/// F-11 修复：此前只判断 `v[0]`（首字符），`"  =1+1"`、`"\t=cmd|..."`、
/// `"\r=..."` 这类「前导空白后接公式」的情形会被漏掉——Excel 会先吃掉空白
/// 仍按公式解析。现在先剥掉前导空白与控制字符再判定，单引号也补在**最前面**
/// （否则 `' \t=...` 依然可能被当作公式）。
String csvCell(String raw) {
  final v = raw.replaceAll('"', '""');
  var i = 0;
  // 只剥「前导」的空白与控制字符：Excel 解析公式时会忽略它们。
  while (i < v.length) {
    final c = v.codeUnitAt(i);
    // 空格 / \t / \r / \n / \f / \v
    if (c == 0x20 || c == 0x09 || c == 0x0d || c == 0x0a || c == 0x0c ||
        c == 0x0b) {
      i++;
      continue;
    }
    break;
  }
  if (i >= v.length) return v;
  const triggers = <int>{0x3d /* = */, 0x2b /* + */, 0x2d /* - */, 0x40 /* @ */};
  if (triggers.contains(v.codeUnitAt(i))) return "'$v";
  return v;
}
