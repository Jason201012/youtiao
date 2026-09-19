/// CSV / 表格导出共用的单元格转义（S11 / F-11）。
///
/// 背景：导出的 CSV 会被 Excel / WPS / 数字表格直接打开，而以 `=` `+` `-` `@`
/// 开头的单元格会被当成**公式执行**（DDE / HYPERLINK 一类的注入载体，
/// 任务标题来自用户输入或 iCal 导入，属不可信内容）。
///
/// OWASP 建议的双重处理，这里都做：
///  1. 转义双引号（`"` → `""`，CSV 标准转义）；
///  2. 若**去掉前导空白 / Tab / 回车 / 双引号后的首个有效字符**是公式引导符，
///     前置一个单引号强制按文本处理。
///
/// F-11 修复：此前只判断 `v[0]`（首字符），`"  =1+1"`、`"\t=cmd|..."`、
/// `"\r=..."` 这类「前导空白后接公式」的情形会被漏掉——Excel 会先吃掉空白
/// 仍按公式解析。现在先剥掉前导空白与控制字符再判定，单引号也补在**最前面**
/// （否则 `' \t=...` 依然可能被当作公式）。
///
/// P3-5（v2.9.0 审计）：判定必须在**转义前**的原始值上做，且把前导双引号一并视为
/// 可忽略字符。此前先做 `"` → `""` 替换、再扫首个有效字符，于是 `"=evil"` 的首字符
/// 变成了 `"`（非引导符）而不补单引号——各写出行把字段包在 `"` 里，最终落盘为
/// `"""=evil"""` / `""=evil"`：宽容的解析器会把前导 `""` 当成「空串 + 尾随内容」，
/// 还原出的单元格首字符又变回 `=`，公式照样执行。现在按「原始值去前导空白与引号后
/// 的首字符」判定（单元格解析后的内容恒等于原始值，故这是唯一的正确判定面）。
/// P3-8（v2.9.1 审计）：剥离集补上 **BOM（U+FEFF）** 与非断行空格等 Unicode 空白。
/// 此前只剥离 ASCII 空白 / 控制字符，`\uFEFF=evil`、`\u00A0=1+1` 这类
/// 「Unicode 空白 + 公式引导符」的取值拿不到补单引号——与「前导空白全覆盖」的
/// 注释不符。BOM 尤其现实：CSV 自身以 U+FEFF 开头（见导出侧的 UTF-8 BOM），
/// 用户在 Excel 里复制粘贴首列单元格时极易把它带进标题。
/// P2-5（v2.9.1 审计）：CSV 文件的 UTF-8 BOM 前缀（U+FEFF）。
///
/// 简体中文 Windows 上的 Excel / WPS 在没有 BOM 时按系统 ANSI（GBK）解码，
/// 中文列名与内容**全量乱码**——导出功能形同失效。BOM 只加在 CSV：Markdown / JSON
/// 加 BOM 反而会污染正文与解析（JSON.parse 会因首字符非 `{` 直接失败）。
const String kUtf8Bom = '\uFEFF';

/// 给 [content] 补 UTF-8 BOM（已带则不重复补）。CSV 导出在**拼接完整文件后**调用，
/// 保证 BOM 落在整个文件的第一字节。
String withUtf8Bom(String content) =>
    content.startsWith(kUtf8Bom) ? content : '$kUtf8Bom$content';

String csvCell(String raw) {
  final escaped = raw.replaceAll('"', '""');
  // 判定面 = 原始值（见上方说明），只剥「前导」的空白 / 控制字符 / 双引号。
  var i = 0;
  while (i < raw.length) {
    final c = raw.codeUnitAt(i);
    // 空格 / \t / \r / \n / \f / \v / "（引号可能被解析器当作引号引导符吃掉）
    // + U+FEFF（BOM / 零宽不换行空格）/ U+00A0（NBSP）/ U+1680 / U+2000-U+200A /
    //   U+2028 / U+2029 / U+202F / U+205F / U+3000（全角空格）。
    if (c == 0x20 || c == 0x09 || c == 0x0d || c == 0x0a || c == 0x0c ||
        c == 0x0b || c == 0x22 || c == 0xfeff || c == 0xa0 || c == 0x1680 ||
        (c >= 0x2000 && c <= 0x200a) || c == 0x2028 || c == 0x2029 ||
        c == 0x202f || c == 0x205f || c == 0x3000) {
      i++;
      continue;
    }
    break;
  }
  if (i >= raw.length) return escaped;
  const triggers = <int>{0x3d /* = */, 0x2b /* + */, 0x2d /* - */, 0x40 /* @ */};
  if (triggers.contains(raw.codeUnitAt(i))) return "'$escaped";
  return escaped;
}
