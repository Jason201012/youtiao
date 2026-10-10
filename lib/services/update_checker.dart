import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pointycastle/export.dart';

import 'package:todolist/services/update_policy.dart';

// F-01：compareVersion / prereleaseOf 已迁入 update_policy.dart（单一真源），
// 此处再导出一次，保证既有 import 方（`import '.../update_checker.dart'`）无需改动。
export 'package:todolist/services/update_policy.dart'
    show compareVersion, prereleaseOf;

/// Gitee 仓库信息。
/// 注意：Gitee 自 2026-08 起对匿名 api/v5 访问统一返回 403，
/// 因此「检查更新」不再调用发行版 API，改为读取仓库内的静态清单文件
/// update.json（通过 gitee 的 raw 文件访问，公开仓库无需鉴权即可读取）。
const String _owner = 'jason1012';
const String _repo = 'youtiao';
const String _manifestUrl =
    'https://gitee.com/$_owner/$_repo/raw/master/update.json';

/// 远端发行版信息封装。
class UpdateInfo {
  final String tagName; // 远端 tag，如 "v2.2.0"
  final String version; // 去掉 v 后的版本，如 "2.2.0"
  final String? releaseName; // 发行版标题
  final String? releaseNotes; // 更新说明 body
  final String? apkUrl; // apk 直链
  final String? releaseUrl; // 发行版页面（html_url）
  final String? apkSha256; // APK 文件 sha256（可选，用于下载后完整性校验）

  const UpdateInfo({
    required this.tagName,
    required this.version,
    this.releaseName,
    this.releaseNotes,
    this.apkUrl,
    this.releaseUrl,
    this.apkSha256,
  });
}

/// 更新检查结果。
class UpdateResult {
  final bool hasUpdate;
  final UpdateInfo? info;
  final String? error;

  const UpdateResult({required this.hasUpdate, this.info, this.error});
}

/// 应用内更新检测：拉取 Gitee 最新发行版并与本地版本比较。
class UpdateChecker {
  /// 拉取 Gitee 最新发行版并判断是否比本地新。
  /// [localVersion] 不传则自动读 PackageInfo。
  static Future<UpdateResult> check({String? localVersion}) async {
    String local;
    try {
      local = localVersion ?? (await PackageInfo.fromPlatform()).version;
    } catch (_) {
      return const UpdateResult(hasUpdate: false, error: '无法读取本地版本');
    }

    try {
      // P3-12（v2.9.1 审计）：默认 Client 会自动跟随重定向且**不校验目标主机**，
      // 与 APK 下载器（[UpdatePolicy.isAllowedRedirectTarget] 的逐跳白名单）不对称。
      // 这里对「最终落地 URL」补一道主机白名单校验：清单只可能托管在作者使用的
      // 代码托管域上，302 到其它主机即视为链路被劫持/重定向链被控。
      // （内容签名仍是最终兜底——本道校验的价值在于「早失败、少一次不可信抓取」。）
      final client = http.Client();
      final http.Response resp;
      try {
        resp = await client
            .get(
              Uri.parse(_manifestUrl),
              headers: {'User-Agent': 'youtiao-update-checker'},
            )
            .timeout(const Duration(seconds: 8));
      } finally {
        client.close();
      }
      final landed = resp.request?.url;
      if (landed != null && !UpdatePolicy.isAllowedHost(landed.host)) {
        return const UpdateResult(
            hasUpdate: false, error: '更新清单被重定向到非白名单主机（已拒绝）');
      }
      if (resp.statusCode != 200) {
        return UpdateResult(hasUpdate: false, error: 'HTTP ${resp.statusCode}');
      }
      final Map<String, dynamic> data = jsonDecode(resp.body);
      // F12：从 v2.8.0 起，update.json 的 ECDSA 签名升级为强约束——
      // 只要**本机版本**或清单自报版本达到 2.8.0（不含预发布），`signature` 字段即
      // 必填且必须通过内置公钥校验；缺签名 / 验签失败一律拒绝，避免「沿用未签名旧清单
      // 蒙混过关」（P3-1 起门槛以本地版本为准，见下方 requireSig 注释）。
      // v2.8.0 之前的历史版本维持「可选签名」的渐进策略。
      //
      // P3-13（v2.9.1 审计）：字段读取一律走 [_str] 容错——`as String?` 在清单把
      // version / signature 写成数字（JSON 里 `2.9.2` 极易被写成裸数字）时抛 TypeError，
      // 虽被外层 catch 兜成「拒绝」，却绕过了这里「缺失签名」的明确拒绝分支，
      // 用户只看到一句无上下文的类型错误。
      final declaredVer = _str(data['version']).trim();
      final sig = _str(data['signature']).trim();
      // F-01 修复：判定收进 [UpdatePolicy.requiresMandatorySignature] 纯函数。
      // 原实现在调用点写 `compareVersion(declaredVer, '2.8.0') >= 0`，方向恰好颠倒
      // （compareVersion 返回 >0 表示「参数 b 更新」），结果 2.8.2 及未来所有新版本
      // 反而不强制签名——攻击者删掉 signature 字段即可绕过本轮刚上线的 C-2 验签。
      //
      // P3-1（v2.9.0 审计）：门槛必须**以本地版本为准**（并与清单自报版本取并集）。
      // 旧口径只看「清单自报的 version」，而该字段正由不可信侧提供：把 version 改小
      // （如 2.5.0）再删掉 signature，即可让 requireSig 退化为 false 静默跳过验签
      // （虽不会下发旧版，但**压住修复推送**使安全问题无法到达设备）。加入
      // `requiresMandatorySignature(local)` 后，任何装在 2.8.0+ 设备上的 App 面对
      // 缺失签名的清单一律拒绝——攻击者无法再靠自报版本把门槛降下去。
      //
      // P2-7 / P3-14（v2.9.1 审计）：门槛已退化为**无条件强制**（见
      // [UpdatePolicy.requiresMandatorySignature]）——「本地与清单自报版本均 < 2.8.0
      // 时接受无签名清单」的渐进尾巴与「预发布形态豁免」两条路一并封死。
      // apkSha256 由同一份清单自带，只证明「文件与清单一致」，证明不了「来源可信」，
      // 因此清单签名是唯一可信锚：缺失即拒绝，不再提供「风险自担」的安装兜底。
      final requireSig = UpdatePolicy.requiresMandatorySignature(local) ||
          UpdatePolicy.requiresMandatorySignature(declaredVer);
      if (requireSig && sig.isEmpty) {
        return const UpdateResult(
            hasUpdate: false, error: '更新清单必须携带签名（缺失，已拒绝）');
      }
      // C-2（更新链路签名校验）：若清单携带 `signature` 字段，则强校验其 ECDSA-P256 签名，
      // 确保清单确实来自开发者私钥、未被篡改（即便 Gitee 账户或 TLS 被攻破也无法伪造）。
      if (sig.isNotEmpty) {
        final signable = Map<String, dynamic>.from(data)..remove('signature');
        final ok = _verifyUpdateSignature(
            utf8.encode(_canonicalJson(signable)), sig);
        if (!ok) {
          return const UpdateResult(
              hasUpdate: false,
              error: 'update.json 签名校验失败（可能被篡改，已拒绝）');
        }
      }
      // 解析与版本比较逻辑抽到 [_parse]，便于单元测试固化清单 schema（见 S4/S5）。
      final info = parseManifest(data);
      if (info == null) {
        return const UpdateResult(hasUpdate: false, error: '清单缺少 version 字段');
      }
      final has = compareVersion(local, info.version) > 0;
      return UpdateResult(hasUpdate: has, info: has ? info : null);
    } catch (e) {
      return UpdateResult(hasUpdate: false, error: e.toString());
    }
  }

  /// 将 Gitee 上的 update.json 反序列化为 [UpdateInfo]。
  /// 清单 schema 约定（与发版脚本 _publish_v266.py 对齐）：
  ///   version / apkUrl / apkSha256 / releaseNotes 为必填或可选；
  ///   releaseUrl 缺省时兜底到 youtiao-releases-3（v2.7.8 起的新 APK 仓）。
  /// 解析失败（缺 version）返回 null。
  static UpdateInfo? parseManifest(Map<String, dynamic> data) {
    final version = _str(data['version']).trim();
    // L-01：version 会被拼进下载文件名（`updates/app-release-v<version>.apk`），
    // 未做格式白名单时，取值为 `../../../files/x` 一类即可在应用沙箱内任意落文件。
    // 这里强制「数字.数字.数字」开头的 semver 形态，非法版本号一律拒绝整份清单。
    if (!UpdatePolicy.isValidVersion(version)) return null;
    // L-13：tag 会拼进兜底的 releaseUrl，先净化字符集再截断（防跳到非预期页面）。
    final rawTag = _str(data['tag']);
    final tag = UpdatePolicy.sanitizeTag(rawTag.isEmpty ? 'v$version' : rawTag);
    // P2-7 加固：apkUrl 仅信任 https（明文 http 视为被篡改/不安全，拒绝直链）。
    final rawUrl = _str(data['apkUrl']);
    final apkUrl = (rawUrl.isNotEmpty &&
            rawUrl.length <= UpdatePolicy.maxUrlChars &&
            rawUrl.startsWith('https://'))
        ? rawUrl
        : null;
    // P2-7 加固：apkSha256 仅接受 64 位小写十六进制；形态非法则丢弃（不信任），
    // 避免拼接/误用畸形哈希。真正的「独立签名信任锚」为 update.json 的 ECDSA 签名
    // （见 [UpdateChecker.check] 的强制验签）。
    final rawSha = _str(data['apkSha256']);
    final apkSha256 = _isSha256Hex(rawSha) ? rawSha : null;
    // L-04：releaseUrl 会直接外跳浏览器，必须过白名单（作者发布仓的 releases 页），
    // 否则投毒清单可把用户引到钓鱼页。非法值直接丢弃，UI 侧按「无下载页」处理。
    final rawReleaseUrl = _str(data['releaseUrl']);
    final releaseUrl = (rawReleaseUrl.isNotEmpty &&
            UpdatePolicy.isAllowedReleaseUrl(rawReleaseUrl))
        ? rawReleaseUrl
        : null;
    return UpdateInfo(
      tagName: tag,
      version: version,
      releaseName: UpdatePolicy.clampShort(_str(data['name'])),
      // S4 修复：以现网 update.json 的 releaseNotes 为准（不再读旧的 notes 键）。
      // L-13：截断到 8000 字，防投毒清单塞入数 MB 文本拖垮更新弹窗。
      // L-13：非空才截断；清单缺省 releaseNotes 时保持 null（消费方据此隐藏该区）。
      releaseNotes: data['releaseNotes'] == null
          ? null
          : UpdatePolicy.clampReleaseNotes(_str(data['releaseNotes'])),
      apkUrl: apkUrl,
      // v2.7.8：APK 仓切到 youtiao-releases-3（releases-2 附件配额已满）。
      // 优先取清单里的 releaseUrl（服务端可随时换仓而无需改 App），兜底值仅用于
      // 旧版清单缺少该键时——换仓时必须同步更新这里，否则「查看更新详情」会 404。
      // P3-4（v3.0.4 审计）：兜底同步切 releases-4——v3.0.1 起 APK 仓已迁
      // youtiao-releases-4（releases-3 附件配额满，只读保留），apkUrl 白名单
      // （update_policy）已收口 releases-4，兜底 releaseUrl 与之保持一致。
      releaseUrl: releaseUrl ??
          'https://gitee.com/jason1012/youtiao-releases-4/releases/tag/$tag',
      apkSha256: apkSha256,
    );
  }

  /// P3-13（v2.9.1 审计）：清单字段的**容错读取**。
  ///
  /// 原实现一律 `as String?`，清单里任何字段写成 JSON 数字 / 布尔（例如 `"version": 2.9.2`
  /// 少了引号）都会抛 TypeError，被外层 catch 兜成一句无上下文的错误——既绕过了
  /// 「缺失签名」的明确拒绝分支，也让用户无法判断清单到底哪里坏了。统一 `toString()`
  /// 后，形态问题交由各自的校验器（版本白名单 / base64 解码 / 哈希形态）判定并给出
  /// 具体拒绝理由。
  static String _str(dynamic v) => v == null ? '' : v.toString();

  /// P2-7：校验 apkSha256 是否为合法的 64 位小写十六进制串（SHA-256 标准形态）。
  /// 仅接受 0-9 与 a-f，拒绝大写/非十六进制/长度异常，避免被畸形哈希误导。
  static bool _isSha256Hex(String s) {
    if (s.length != 64) return false;
    for (final c in s.codeUnits) {
      final ok = (c >= 0x30 && c <= 0x39) || // 0-9
          (c >= 0x61 && c <= 0x66); // a-f（小写）
      if (!ok) return false;
    }
    return true;
  }

  /// 是否应自动弹窗：每天最多一次（跨进程也生效）。
  static Future<bool> shouldAutoPrompt() async {
    final prefs = await SharedPreferences.getInstance();
    final today = DateTime.now().toIso8601String().substring(0, 10);
    final last = prefs.getString('update_last_auto_check');
    return last != today;
  }

  /// 记录今天已自动检查过。
  static Future<void> markAutoChecked() async {
    final prefs = await SharedPreferences.getInstance();
    final today = DateTime.now().toIso8601String().substring(0, 10);
    await prefs.setString('update_last_auto_check', today);
  }

  /// 用户选择跳过的版本（该版本不再自动提示）。
  static Future<String?> getSkipVersion() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('update_skip_version');
  }

  static Future<void> setSkipVersion(String v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('update_skip_version', v);
  }
}

/// ============================================================
/// C-2：更新清单（update.json）独立签名校验
/// ============================================================
/// 内置 ECDSA P-256 公钥（uncompressed 65 字节，含 0x04 前缀）。
///
/// 设计要点：用**非对称**公钥而非对称密钥——即便 APK 被逆向，攻击者也只能拿到公钥，
/// 无法伪造签名（私钥仅存在于发版机，绝不进仓库 / 不进 App）。这与 P1-1 的密钥库思路一致：
/// 「校验锚」放在客户端、签名权留在服务端。
///
/// 私钥生成与签名见仓库 `_sign_update.py`；公钥轮换需同步改此处与发版脚本。
/// 校验失败一律视为被篡改并拒收清单（见 [UpdateChecker.check]）。
const List<int> _updateSignPubKey = <int>[
  4, 225, 57, 64, 208, 41, 72, 167, 120, 190, 72, 152, 218, 51, 245, 41,
  229, 196, 238, 185, 31, 19, 200, 227, 37, 190, 167, 250, 187, 212, 216, 171,
  3, 140, 73, 54, 57, 68, 22, 105, 69, 41, 166, 33, 70, 252, 31, 162,
  130, 91, 79, 221, 17, 190, 234, 12, 76, 108, 182, 65, 224, 148, 252, 211, 177,
];

/// 校验 update.json 的 ECDSA-P256 签名。
///
/// [payload] 为「去除 signature 字段后、规范化（排序键、紧凑分隔符、UTF-8 原文）」的清单字节，
/// [b64Sig] 为 base64 编码的 64 字节原始签名（r 高 32 字节 ‖ s 低 32 字节，大端）。
/// 任何异常（长度不符、解码失败、点非法、签名不匹配）均返回 false，绝不吞掉失败而放行。
bool _verifyUpdateSignature(List<int> payload, String b64Sig) {
  try {
    final raw = base64Decode(b64Sig);
    if (raw.length != 64) return false; // 非压缩 P-256 签名固定 64 字节
    final r = _bytesToBigInt(raw.sublist(0, 32));
    final s = _bytesToBigInt(raw.sublist(32, 64));
    final domain = ECDomainParameters('secp256r1');
    final q = domain.curve.decodePoint(Uint8List.fromList(_updateSignPubKey));
    if (q == null) return false;
    final pubKey = ECPublicKey(q, domain);
    final signer = ECDSASigner(SHA256Digest()); // 内部会先对 payload 做 SHA-256
    signer.init(false, PublicKeyParameter<ECPublicKey>(pubKey));
    return signer.verifySignature(Uint8List.fromList(payload), ECSignature(r, s));
  } catch (_) {
    return false;
  }
}

/// 大端字节序列 → BigInt。
BigInt _bytesToBigInt(List<int> bytes) {
  BigInt result = BigInt.zero;
  for (final b in bytes) {
    result = (result << 8) | BigInt.from(b & 0xff);
  }
  return result;
}

/// 生成与发版脚本（Python `json.dumps(..., sort_keys=True, separators=(',',':'),
/// ensure_ascii=False)`）逐字节对齐的规范化 JSON。
///
/// 双方必须对「待签名内容」有一致字节视图，否则验签永远失败。这里手动实现
/// 「按键排序 + 紧凑分隔符 + UTF-8 原文」，与 Python 默认行为严格对齐。
String _canonicalJson(dynamic value) {
  final sb = StringBuffer();
  _writeCanonical(value, sb);
  return sb.toString();
}

/// P2-2：规范化 JSON 的**公开只读入口**，仅供单测 / 发版自检使用。
///
/// 对外暴露的唯一理由：canonical 字节「与发版脚本（Python `json.dumps(...,
/// ensure_ascii=False)`）逐字节一致」是验签能否通过的全部契约，必须有测试把它钉死
/// （尤其是 emoji / 生僻字等非 BMP 字符——曾因按 UTF-16 code unit 迭代而被拆成
/// 孤立代理、编码为 U+FFFD，导致含 emoji 的 releaseNotes 全量验签失败）。
/// 业务代码请勿调用，清单校验内部已直接使用 [_canonicalJson]。
String canonicalUpdateJson(dynamic value) => _canonicalJson(value);

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
    sb.write(jsonEncode(v)); // 兜底，正常清单不会走到
  }
}

/// 与 Python json.dumps 默认转义规则对齐：转义 `"` `\` 与 C0 控制字符，其余原样（UTF-8）。
///
/// P2-2：必须按 **code point（runes）** 而不是 UTF-16 code unit 迭代。
/// 原实现用 `s.codeUnits`，代理对（如 🔥 = 0xD83D + 0xDD25）被拆成两个**孤立代理**
/// 分别 `String.fromCharCode`，两者都不构成合法字符，`utf8.encode` 阶段会各自变成
/// U+FFFD 替换字符（3 字节 EF BF BD），与发版侧 `json.dumps(ensure_ascii=False)` 输出的
/// 真实 UTF-8 字节（F0 9F 94 A5）不一致 → canonical 字节不同 → 验签必然失败。
/// 一旦某版 releaseNotes / name 里出现 emoji，该版本所有用户的「检查更新」都会被拒。
void _writeJsonString(String s, StringBuffer sb) {
  sb.write('"');
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
          // 非 BMP（emoji / 生僻字）：显式展开为 UTF-16 代理对，不依赖
          // String.fromCharCode 对超 BMP 入参的处理细节，保证 utf8.encode 得到
          // 与 Python ensure_ascii=False 逐字节一致的真实 UTF-8 编码。
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
