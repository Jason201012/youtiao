// P2-3（v2.9.9 审计）：GBK/CP936 解码器 + 文本文件字节解码入口。
//
// 简体中文 Windows 上 Excel 另存的 CSV 常为 GBK 且无 BOM，此前
// `readAsString()`（默认 UTF-8）直接抛 FormatException →「读取表格文件失败」，
// 而「Excel 导出的表格」正是 CSV 导入的主用场景。本文件提供零依赖纯 Dart
// 解码链：优先按 BOM 识别 UTF-8/UTF-16，无 BOM 时先按严格 UTF-8 尝试，
// 失败再回退 GBK 查表（表在 gbk_table.dart，由 Python 按 bytes.decode('gbk')
// 生成，勿手改）。全程无网络、无第三方依赖，符合严格离线红线。

import 'dart:convert';

import 'gbk_table.dart';

/// GBK/CP936 字节流 → 字符串（宽松口径：无效序列替换 U+FFFD，绝不抛异常）。
///
/// 规则（与 Windows CP936 对齐）：
/// - `0x00..0x7F`：单字节 ASCII；
/// - `0x80`：单字节 €（U+20AC，CP936 扩展）；
/// - `0x81..0xFE` 后随 `0x40..0xFE`（跳过 0x7F）：双字节，查 [kGbkTable]
///   （索引公式见表头注释）；无效槽位（表内 U+0000）→ U+FFFD；
/// - 其余（孤立尾字节、trail 越界）：消耗 1 字节，替换 U+FFFD。
String decodeGbkBytes(List<int> bytes) {
  final table = kGbkTable;
  final sb = StringBuffer();
  var i = 0;
  final n = bytes.length;
  while (i < n) {
    final b = bytes[i];
    if (b < 0x80) {
      sb.writeCharCode(b);
      i++;
      continue;
    }
    if (b == 0x80) {
      sb.writeCharCode(0x20AC); // €
      i++;
      continue;
    }
    if (b >= 0x81 && b <= 0xFE && i + 1 < n) {
      final t = bytes[i + 1];
      if (t >= 0x40 && t <= 0xFE && t != 0x7F) {
        final ch = table.codeUnitAt(
            (b - 0x81) * 190 + (t - 0x40 - (t > 0x7F ? 1 : 0)));
        sb.writeCharCode(ch == 0 ? 0xFFFD : ch);
        i += 2;
        continue;
      }
    }
    // 无效序列：消耗 1 字节并替换 U+FFFD（宽松语义，对齐 libdart allowMalformed）。
    sb.writeCharCode(0xFFFD);
    i++;
  }
  return sb.toString();
}

/// 文本文件字节 → 字符串：BOM 探测 → 严格 UTF-8 → GBK 回退。
///
/// 顺序取舍：
/// 1. UTF-8 BOM（EF BB BF）/ UTF-16 LE|BE BOM（FF FE / FE FF）→ 按对应编码
///    解码（BOM 是最可靠的自描述信号；UTF-16 出现在 Excel「Unicode 文本」
///    导出场景，手工解码避免引入 charset_converter 类依赖）；
/// 2. 无 BOM：先按**严格** UTF-8 尝试（现代导出主流；GBK 双字节序列几乎必然
///    不是合法 UTF-8，非法即刻抛 FormatException 回退，不会产出 mojibake）；
/// 3. 回退 GBK（简体中文 Windows Excel 另存 CSV 的实际编码）。
String decodeTextFileBytes(List<int> bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    return utf8.decode(bytes.sublist(3), allowMalformed: true);
  }
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    return _decodeUtf16(bytes.sublist(2), littleEndian: true);
  }
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    return _decodeUtf16(bytes.sublist(2), littleEndian: false);
  }
  try {
    return utf8.decode(bytes); // 严格模式：非法序列抛 FormatException
  } on FormatException {
    // 回退 GBK。
  }
  return decodeGbkBytes(bytes);
}

/// 手工 UTF-16 解码（含代理对；尾部孤字节 / 孤立代理 → U+FFFD）。
String _decodeUtf16(List<int> bytes, {required bool littleEndian}) {
  final sb = StringBuffer();
  var i = 0;
  final n = bytes.length;
  while (i + 1 < n) {
    final lo = littleEndian ? bytes[i] : bytes[i + 1];
    final hi = littleEndian ? bytes[i + 1] : bytes[i];
    final unit = (hi << 8) | lo;
    i += 2;
    if (unit >= 0xDC00 && unit <= 0xDFFF) {
      sb.writeCharCode(0xFFFD); // 孤立低位代理
      continue;
    }
    if (unit >= 0xD800 && unit <= 0xDBFF) {
      if (i + 1 < n) {
        final lo2 = littleEndian ? bytes[i] : bytes[i + 1];
        final hi2 = littleEndian ? bytes[i + 1] : bytes[i];
        final unit2 = (hi2 << 8) | lo2;
        if (unit2 >= 0xDC00 && unit2 <= 0xDFFF) {
          sb.writeCharCode(
              0x10000 + ((unit - 0xD800) << 10) + (unit2 - 0xDC00));
          i += 2;
          continue;
        }
      }
      sb.writeCharCode(0xFFFD); // 高位代理无有效后续
      continue;
    }
    sb.writeCharCode(unit);
  }
  if (i < n) sb.writeCharCode(0xFFFD); // 尾部孤字节
  return sb.toString();
}
