import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// 备份口令加密（AES-256-GCM + PBKDF2-HMAC-SHA256）。
///
/// 设计目标：
/// - 纯 Dart、无原生依赖（pointycastle），符合项目「愿意带纯 Dart 库」的先例（lpinyin）；
/// - 两个纯函数 [encrypt]/[decryptEnvelope] 便于单测；
/// - 解密成功后直接喂给既有 [BackupValidator.validate]，校验逻辑零改动；
/// - GCM 认证标签失败（口令错 / 文件被篡改）抛 [BackupDecryptException]，便于 UI 提示。
///
/// 信封结构（与文档「信封结构」一致）：
/// ```json
/// {
///   "format": "youtiao-backup",
///   "v": 3,
///   "encrypted": true,
///   "kdf":  { "alg": "pbkdf2-hmac-sha256", "iterations": 150000, "salt": "<b64 16B>" },
///   "aead": { "alg": "aes-256-gcm",        "iv":   "<b64 12B>", "tag": "<b64 16B>" },
///   "ct":   "<b64 密文>"
/// }
/// ```
/// 明文即现有备份 JSON 的原样字节。

/// 解密失败（口令错误 / 文件损坏 / 结构非法）时抛出，UI 据此提示「口令错误或文件损坏」。
class BackupDecryptException implements Exception {
  final String message;
  const BackupDecryptException(this.message);
  @override
  String toString() => 'BackupDecryptException: $message';
}

/// 口令加密备份的版本号（v3 = 带加密信封的备份）。
const int kEncryptedBackupVersion = 3;

/// PBKDF2 迭代次数（在「暴力破解成本」与「解锁耗时」之间取平衡）。
/// 由 15 万上调至 35 万，贴合 OWASP 现行建议（30 万–60 万），显著抬高本地字典爆破成本。
const int _pbkdf2Iterations = 350000;

/// P1-2：解密时对迭代次数的上下限（不可信输入白名单）。
/// 下限防弱口令被快速爆破；上限防恶意信封用超大迭代次数拖垮 PBKDF2（计算 DoS）。
const int _pbkdf2IterationsMin = 100000;
const int _pbkdf2IterationsMax = 5000000;

/// 信封中各固定长度字段的预期字节数（GCM/AES 标准），用于解密前形态校验。
const int _saltBytes = 16;
const int _ivBytes = 12;
const int _tagBytes = 16;

/// 加密一个明文备份 JSON，返回信封结构 JSON 字符串。
///
/// [json] 为现有备份 JSON 原文字符串；[pass] 为用户口令（丢失即不可恢复，由调用方在 UI 明确告知）。
/// 每次调用使用随机 salt + 随机 iv，因此同一明文多次加密结果不同（抗重放 / 字典攻击）。
String encrypt(String json, String pass) {
  final salt = _secureBytes(16);
  final iv = _secureBytes(12);
  final key = _deriveKey(pass, salt);
  final cipher = GCMBlockCipher(AESEngine());
  // macSize 128 bit = 16 字节 GCM 标签；process 输出 = 密文 + 标签（标签追加在尾部）。
  cipher.init(true, AEADParameters(KeyParameter(key), 128, iv, Uint8List(0)));
  final plain = Uint8List.fromList(utf8.encode(json));
  final out = cipher.process(plain);
  final ct = out.sublist(0, out.length - 16);
  final tag = out.sublist(out.length - 16);
  final envelope = <String, dynamic>{
    'format': 'youtiao-backup',
    'v': kEncryptedBackupVersion,
    'encrypted': true,
    'kdf': {
      'alg': 'pbkdf2-hmac-sha256',
      'iterations': _pbkdf2Iterations,
      'salt': base64.encode(salt),
    },
    'aead': {
      'alg': 'aes-256-gcm',
      'iv': base64.encode(iv),
      'tag': base64.encode(tag),
    },
    'ct': base64.encode(ct),
  };
  return const JsonEncoder.withIndent('  ').convert(envelope);
}

/// 判断一段原始文本是否为本 App 的加密信封（用于导入时分流处理）。
bool isEncryptedEnvelope(String raw) {
  try {
    final data = jsonDecode(raw);
    if (data is! Map) return false;
    return data['encrypted'] == true &&
        data['ct'] is String &&
        data['aead'] is Map &&
        data['kdf'] is Map;
  } catch (_) {
    return false;
  }
}

/// 解密加密信封，返回明文备份 JSON 字符串。
///
/// 任何异常（口令错导致 GCM 标签校验失败 / 文件被篡改 / 结构非法）都转为
/// [BackupDecryptException]，UI 统一提示「口令错误或文件损坏」且不清空现有数据。
String decryptEnvelope(String raw, String pass) {
  Map<String, dynamic> env;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const BackupDecryptException('不是有效的加密备份');
    }
    env = decoded;
  } catch (e) {
    if (e is BackupDecryptException) rethrow;
    throw const BackupDecryptException('文件结构非法，无法解析');
  }
  try {
    final kdf = env['kdf'] as Map?;
    final aead = env['aead'] as Map?;
    final ctB64 = env['ct'] as String?;
    if (kdf == null || aead == null || ctB64 == null) {
      throw const BackupDecryptException('文件结构非法，缺少必要字段');
    }
    // P1-2：不可信输入白名单校验（防计算 DoS / 结构越界）。
    // 先校验迭代次数上下限，再校验 salt/iv/tag 的固定长度，任一不合法立即拒绝。
    final iterationsRaw = kdf['iterations'];
    final iterations = (iterationsRaw is num) ? iterationsRaw.toInt() : _pbkdf2Iterations;
    if (iterations < _pbkdf2IterationsMin || iterations > _pbkdf2IterationsMax) {
      throw const BackupDecryptException('迭代次数非法（超出允许范围，疑似恶意备份）');
    }
    final salt = _decodeFixedBytes(kdf['salt'], _saltBytes, 'salt');
    final iv = _decodeFixedBytes(aead['iv'], _ivBytes, 'iv');
    final tag = _decodeFixedBytes(aead['tag'], _tagBytes, 'tag');
    final ct = base64.decode(ctB64);
    final key = _deriveKey(pass, salt, iterations);
    final cipher = GCMBlockCipher(AESEngine());
    // 解密时把密文与标签拼接，doFinal 会校验标签：不一致即抛 InvalidCipherTextException。
    final combined = Uint8List(ct.length + tag.length);
    combined.setRange(0, ct.length, ct);
    combined.setRange(ct.length, combined.length, tag);
    cipher.init(false, AEADParameters(KeyParameter(key), 128, iv, Uint8List(0)));
    final plain = cipher.process(combined);
    return utf8.decode(plain);
  } on BackupDecryptException {
    rethrow;
  } on InvalidCipherTextException {
    throw const BackupDecryptException('口令错误或文件已损坏');
  } catch (e) {
    throw BackupDecryptException('解密失败：$e');
  }
}

/// 解码固定长度字段（salt/iv/tag）：必须存在、为合法 base64，且长度恰好等于
/// [expectedLen]。用于 P1-2 的解密前形态校验，长度异常直接转 [BackupDecryptException]
/// 而非喂给 GCM/PBKDF2 产生不可预期行为。
Uint8List _decodeFixedBytes(dynamic v, int expectedLen, String name) {
  if (v is! String) {
    throw BackupDecryptException('$name 字段缺失或类型非法');
  }
  Uint8List bytes;
  try {
    bytes = base64.decode(v);
  } on Exception {
    throw BackupDecryptException('$name 不是合法的 base64');
  }
  if (bytes.length != expectedLen) {
    throw BackupDecryptException(
        '$name 长度非法（应为 $expectedLen 字节，实际 ${bytes.length}）');
  }
  return bytes;
}

/// 由口令 + salt 经 PBKDF2-HMAC-SHA256 派生 32 字节（256-bit）AES 密钥。
Uint8List _deriveKey(String pass, Uint8List salt, [int iterations = _pbkdf2Iterations]) {
  final kdf = PBKDF2KeyDerivator(HMac(SHA256Digest(), 32));
  kdf.init(Pbkdf2Parameters(salt, iterations, 32));
  return kdf.process(Uint8List.fromList(utf8.encode(pass)));
}

/// 密码学安全随机字节（Fortuna，以 Random.secure 播种）。
Uint8List _secureBytes(int n) {
  final rng = Random.secure();
  final seed = Uint8List(32);
  for (var i = 0; i < seed.length; i++) seed[i] = rng.nextInt(256);
  final fortuna = FortunaRandom()..seed(KeyParameter(seed));
  return fortuna.nextBytes(n);
}
