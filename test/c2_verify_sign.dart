// 独立验证：用 update_checker.dart 中「逐字节一致」的算法与公钥常量，
// 对仓库内已签名的 update.json 做验签。证明 App 端真实逻辑会接受该签名。
//
// 注意：本文件将生产函数的实现「原样」复制于此，以便在不引入 Flutter 依赖的前提下
// 直接调用。请勿在生产代码中引用本文件。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

// ---- 以下为 update_checker.dart 原样复制 ----
const List<int> _updateSignPubKey = <int>[
  4, 225, 57, 64, 208, 41, 72, 167, 120, 190, 72, 152, 218, 51, 245, 41,
  229, 196, 238, 185, 31, 19, 200, 227, 37, 190, 167, 250, 187, 212, 216, 171,
  3, 140, 73, 54, 57, 68, 22, 105, 69, 41, 166, 33, 70, 252, 31, 162,
  130, 91, 79, 221, 17, 190, 234, 12, 76, 108, 182, 65, 224, 148, 252, 211, 177,
];

bool _verifyUpdateSignature(List<int> payload, String b64Sig) {
  try {
    final raw = base64Decode(b64Sig);
    if (raw.length != 64) return false;
    final r = _bytesToBigInt(raw.sublist(0, 32));
    final s = _bytesToBigInt(raw.sublist(32, 64));
    final domain = ECDomainParameters('secp256r1');
    final q = domain.curve.decodePoint(Uint8List.fromList(_updateSignPubKey));
    if (q == null) return false;
    final pubKey = ECPublicKey(q, domain);
    final signer = ECDSASigner(SHA256Digest());
    signer.init(false, PublicKeyParameter<ECPublicKey>(pubKey));
    return signer.verifySignature(Uint8List.fromList(payload), ECSignature(r, s));
  } catch (_) {
    return false;
  }
}

BigInt _bytesToBigInt(List<int> bytes) {
  BigInt result = BigInt.zero;
  for (final b in bytes) {
    result = (result << 8) | BigInt.from(b & 0xff);
  }
  return result;
}

String _canonicalJson(dynamic value) {
  final sb = StringBuffer();
  _writeCanonical(value, sb);
  return sb.toString();
}

void _writeCanonical(dynamic v, StringBuffer sb) {
  if (v is Map) {
    sb.write('{');
    final keys = v.keys.cast<String>().toList()..sort();
    for (var i = 0; i < keys.length; i++) {
      if (i > 0) sb.write(',');
      _writeJsonString(keys[i], sb);
      sb.write(':');
      _writeCanonical(v[keys[i]], sb);
    }
    sb.write('}');
  } else if (v is List) {
    sb.write('[');
    for (var i = 0; i < v.length; i++) {
      if (i > 0) sb.write(',');
      _writeCanonical(v[i], sb);
    }
    sb.write(']');
  } else if (v is String) {
    _writeJsonString(v, sb);
  } else if (v is num) {
    sb.write(v.toString());
  } else if (v is bool) {
    sb.write(v ? 'true' : 'false');
  } else if (v == null) {
    sb.write('null');
  } else {
    sb.write(jsonEncode(v));
  }
}

void _writeJsonString(String s, StringBuffer sb) {
  sb.write('"');
  // P2-2：必须按 code point（runes）而非 UTF-16 code unit 迭代。用 `s.codeUnits`
  // 会把 emoji 的代理对拆成两个孤立代理，`utf8.encode` 阶段各自变成 U+FFFD，
  // 与 App 侧 / Python 发版侧的字节不一致 → 本校验脚本会误报验签失败。
  for (final ch in s.runes) {
    switch (ch) {
      case 0x22:
        sb.write(r'\"');
        continue;
      case 0x5c:
        sb.write(r'\\');
        continue;
      case 0x0a:
        sb.write(r'\n');
        continue;
      case 0x0d:
        sb.write(r'\r');
        continue;
      case 0x09:
        sb.write(r'\t');
        continue;
      case 0x08:
        sb.write(r'\b');
        continue;
      case 0x0c:
        sb.write(r'\f');
        continue;
      default:
        if (ch < 0x20) {
          sb.write('\\u${ch.toRadixString(16).padLeft(4, '0')}');
        } else if (ch <= 0xFFFF) {
          sb.write(String.fromCharCode(ch));
        } else {
          // 非 BMP：显式展开为 UTF-16 代理对，保证 UTF-8 字节与发版侧一致。
          final v = ch - 0x10000;
          sb.write(String.fromCharCodes(<int>[
            0xD800 + (v >> 10),
            0xDC00 + (v & 0x3FF),
          ]));
        }
    }
  }
  sb.write('"');
}
// ---- 复制结束 ----

void main() {
  final file = File('update.json');
  if (!file.existsSync()) {
    print('SKIP: 未找到 update.json');
    return;
  }
  final obj = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final sig = obj['signature'] as String;
  final signable = <String, dynamic>{}..addAll(obj)..remove('signature');
  final payload = utf8.encode(_canonicalJson(signable));
  final ok = _verifyUpdateSignature(payload, sig);
  print(ok ? 'VERIFY_OK: update.json 签名被 App 端真实逻辑接受'
           : 'VERIFY_FAIL: 签名未被接受');
  if (!ok) throw StateError('签名验签失败');
}
