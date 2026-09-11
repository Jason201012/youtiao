import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:todolist/services/update_checker.dart';

/// P2-2 回归：update.json 的规范化（canonical）JSON 与发版脚本必须逐字节一致。
///
/// 验签链路：App 侧「去掉 signature → 规范化 → UTF-8 字节 → ECDSA 校验」，发版侧
/// Python 用 `json.dumps(..., sort_keys=True, separators=(',',':'), ensure_ascii=False)`
/// 产出同一份字节。两边**只要有一个字节不同，验签就必然失败**。
///
/// 原实现按 `s.codeUnits` 迭代：代理对（emoji / 生僻字）被拆成两个孤立代理，各自
/// `String.fromCharCode` 后 `utf8.encode` 变成 U+FFFD（EF BF BD），与 Python 输出的
/// 真实 UTF-8 字节不符 → 某个版本的 releaseNotes 里一旦出现 emoji，该版本所有用户的
/// 「检查更新」都会被拒收。本文件把这个契约钉死。
void main() {
  group('canonicalUpdateJson（P2-2）', () {
    test('emoji 按 code point 转写，UTF-8 字节与 Python ensure_ascii=False 一致', () {
      final s = canonicalUpdateJson(<String, dynamic>{
        'releaseNotes': '修复 🔥 崩溃',
      });
      expect(s, '{"releaseNotes":"修复 🔥 崩溃"}');
      final bytes = utf8.encode(s);
      // 🔥 = U+1F525 → F0 9F 94 A5
      expect(
        _containsSubsequence(bytes, const [0xF0, 0x9F, 0x94, 0xA5]),
        isTrue,
        reason: 'emoji 必须编码为真实 UTF-8 四字节序列',
      );
      // 旧实现的产物：两个 U+FFFD（EF BF BD）
      expect(
        _containsSubsequence(bytes, const [0xEF, 0xBF, 0xBD]),
        isFalse,
        reason: '不得出现替换字符（说明代理对被拆散）',
      );
    });

    test('非 BMP 汉字（CJK 扩展 B）不被拆散', () {
      // 𠮷 = U+20BB7 → F0 A0 AE B7
      final s = canonicalUpdateJson(<String, dynamic>{'name': '𠮷'});
      final bytes = utf8.encode(s);
      expect(_containsSubsequence(bytes, const [0xF0, 0xA0, 0xAE, 0xB7]), isTrue);
      expect(bytes.contains(0xEF), isFalse);
    });

    test('从 JSON 文本解析（含 emoji）后规范化，仍与原文 UTF-8 字节一致', () {
      // 模拟 App 实际路径：先 jsonDecode 清单文本，再对「去 signature」的对象规范化。
      // 只要两侧都是真实 UTF-8 原文，字节必须完全相同。
      const raw = '{"name":"有条 🔥","version":"2.8.3"}';
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final canonical = canonicalUpdateJson(decoded);
      expect(utf8.encode(canonical), utf8.encode(raw));
    });

    test('键按字典序排序、分隔符紧凑（对齐 Python sort_keys/separators）', () {
      final s = canonicalUpdateJson(<String, dynamic>{
        'version': '2.8.3',
        'apkUrl': 'https://example.com/a.apk',
        'nested': <String, dynamic>{'b': 1, 'a': 2},
        'list': <dynamic>[1, 'x', true, null],
      });
      expect(
        s,
        '{"apkUrl":"https://example.com/a.apk","list":[1,"x",true,null],'
        '"nested":{"a":2,"b":1},"version":"2.8.3"}',
      );
    });

    test('控制字符按 Python 风格转义，常规字符原样输出', () {
      final s = canonicalUpdateJson(<String, dynamic>{
        'v': 'a"b\\c\nd\te\u0001',
      });
      expect(s, r'{"v":"a\"b\\c\nd\te\u0001"}');
    });
  });
}

/// [bytes] 中是否按顺序出现过 [sub]（允许中间夹杂其它字节）。
bool _containsSubsequence(List<int> bytes, List<int> sub) {
  if (sub.isEmpty) return true;
  var i = 0;
  for (final b in bytes) {
    if (b == sub[i]) {
      i++;
      if (i == sub.length) return true;
    }
  }
  return false;
}
