import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

/// 比较两个语义化版本号。
/// 返回 >0 表示 [b] 比 [a] 新（即 [a] 旧），<0 表示 [a] 更新，0 相等。
/// 支持 "2.1.2" 与 "v2.2.0" 混用（自动去 v 前缀），段数不足补 0。
///
/// S8 修复：按 semver 正确处理预发布版本。此前对每一段先截断非数字后缀再比，
/// 导致 "2.5.7-beta" 与 "2.5.7" 数值部分相同被判相等，装了 beta 的用户收不到
/// 同号正式版推送。现规则：数值段相同且一方带预发布后缀、另一方为正式版时，
/// **正式版更高**（预发布 < 正式版），符合 semver 2.0.0 规范。
int compareVersion(String a, String b) {
  List<int> parseVer(String v) => v
      .replaceAll(RegExp(r'^v'), '')
      .split('.')
      .map((s) {
        final digits = s.split(RegExp(r'[^0-9]')).first;
        return int.tryParse(digits.isEmpty ? '0' : digits) ?? 0;
      })
      .toList();
  final pa = parseVer(a);
  final pb = parseVer(b);
  final n = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < n; i++) {
    final la = i < pa.length ? pa[i] : 0;
    final lb = i < pb.length ? pb[i] : 0;
    if (la != lb) return lb.compareTo(la); // b 大则 >0
  }
  // 数值段完全相同：比较预发布后缀。semver 规定「带预发布的版本低于同号正式版」。
  final preA = _prerelease(a);
  final preB = _prerelease(b);
  if (preA == null && preB == null) return 0; // 均为正式版且数值相等
  if (preA == null) return -1; // a 是正式版（更高），b 是预发布 → a 更新 → <0
  if (preB == null) return 1; // b 是正式版（更高）→ b 更新 → >0
  return _comparePrerelease(preA, preB);
}

/// 提取版本串中的预发布后缀（不含前导 '-'），如 "2.5.7-beta" → "beta"；
/// 无预发布则返回 null（正式版）。
String? _prerelease(String v) {
  final cleaned = v.replaceAll(RegExp(r'^v'), '');
  final idx = cleaned.indexOf('-');
  if (idx < 0) return null;
  final p = cleaned.substring(idx + 1);
  return p.isEmpty ? null : p;
}

/// 按 semver 比较两段预发布标识符（点分、数字优先于字母、缺段者更低）。
int _comparePrerelease(String a, String b) {
  final aa = a.split('.');
  final bb = b.split('.');
  final n = aa.length > bb.length ? aa.length : bb.length;
  for (var i = 0; i < n; i++) {
    if (i >= aa.length) return -1; // a 较短 → a 更低
    if (i >= bb.length) return 1; // b 较短 → b 更低
    final x = aa[i];
    final y = bb[i];
    final xn = int.tryParse(x);
    final yn = int.tryParse(y);
    if (xn != null && yn != null) {
      if (xn != yn) return xn.compareTo(yn);
    } else if (xn != null) {
      return -1; // 数字标识符 < 字母标识符（semver）
    } else if (yn != null) {
      return 1;
    } else {
      if (x != y) return x.compareTo(y);
    }
  }
  return 0;
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
      final resp = await http
          .get(
            Uri.parse(_manifestUrl),
            headers: {'User-Agent': 'youtiao-update-checker'},
          )
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) {
        return UpdateResult(hasUpdate: false, error: 'HTTP ${resp.statusCode}');
      }
      final Map<String, dynamic> data = jsonDecode(resp.body);
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
    final version = (data['version'] as String? ?? '').toString().trim();
    if (version.isEmpty) return null;
    final tag = (data['tag'] as String? ?? 'v$version').toString().trim();
    // P2-7 加固：apkUrl 仅信任 https（明文 http 视为被篡改/不安全，拒绝直链）。
    final rawUrl = data['apkUrl'] as String?;
    final apkUrl =
        (rawUrl != null && rawUrl.startsWith('https://')) ? rawUrl : null;
    // P2-7 加固：apkSha256 仅接受 64 位小写十六进制；形态非法则丢弃（不信任），
    // 避免拼接/误用畸形哈希。真正的「独立签名信任锚」为远期项——需在 App 内预置
    // 公钥、并由发版脚本对 update.json 做签名，届时把签名校验接在这里。
    final rawSha = data['apkSha256'] as String?;
    final apkSha256 = (rawSha != null && _isSha256Hex(rawSha)) ? rawSha : null;
    return UpdateInfo(
      tagName: tag,
      version: version,
      releaseName: data['name'] as String?,
      // S4 修复：以现网 update.json 的 releaseNotes 为准（不再读旧的 notes 键）。
      releaseNotes: data['releaseNotes'] as String?,
      apkUrl: apkUrl,
      // v2.7.8：APK 仓切到 youtiao-releases-3（releases-2 附件配额已满）。
      // 优先取清单里的 releaseUrl（服务端可随时换仓而无需改 App），兜底值仅用于
      // 旧版清单缺少该键时——换仓时必须同步更新这里，否则「查看更新详情」会 404。
      releaseUrl: data['releaseUrl'] as String? ??
          'https://gitee.com/jason1012/youtiao-releases-3/releases/tag/$tag',
      apkSha256: apkSha256,
    );
  }

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
