import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Gitee 仓库信息（发行版 API）。
const String _owner = 'jason1012';
const String _repo = 'youtiao';
const String _releasesLatestUrl =
    'https://gitee.com/api/v3/repos/$_owner/$_repo/releases/latest';

/// 远端发行版信息封装。
class UpdateInfo {
  final String tagName; // 远端 tag，如 "v2.2.0"
  final String version; // 去掉 v 后的版本，如 "2.2.0"
  final String? releaseName; // 发行版标题
  final String? releaseNotes; // 更新说明 body
  final String? apkUrl; // apk 直链
  final String? releaseUrl; // 发行版页面（html_url）

  const UpdateInfo({
    required this.tagName,
    required this.version,
    this.releaseName,
    this.releaseNotes,
    this.apkUrl,
    this.releaseUrl,
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
int compareVersion(String a, String b) {
  final pa = a.replaceAll(RegExp(r'^v'), '').split('.').map(int.parse).toList();
  final pb = b.replaceAll(RegExp(r'^v'), '').split('.').map(int.parse).toList();
  final n = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < n; i++) {
    final la = i < pa.length ? pa[i] : 0;
    final lb = i < pb.length ? pb[i] : 0;
    if (la != lb) return lb.compareTo(la); // b 大则 >0
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
            Uri.parse(_releasesLatestUrl),
            headers: {'User-Agent': 'youtiao-update-checker'},
          )
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) {
        return UpdateResult(hasUpdate: false, error: 'HTTP ${resp.statusCode}');
      }
      final Map<String, dynamic> data = jsonDecode(resp.body);
      final tag = (data['tag_name'] as String?) ?? '';
      final version = tag.replaceAll(RegExp(r'^v'), '');

      // 在 assets 里找 apk 直链。
      String? apkUrl;
      final assets = data['assets'];
      if (assets is List) {
        for (final a in assets) {
          final name = (a['name'] as String? ?? '').toLowerCase();
          if (name.endsWith('.apk')) {
            apkUrl = a['browser_download_url'] as String?;
            break;
          }
        }
      }

      final info = UpdateInfo(
        tagName: tag,
        version: version,
        releaseName: data['name'] as String?,
        releaseNotes: data['body'] as String?,
        apkUrl: apkUrl,
        releaseUrl: data['html_url'] as String?,
      );
      final has = compareVersion(local, version) > 0;
      return UpdateResult(hasUpdate: has, info: has ? info : null);
    } catch (e) {
      return UpdateResult(hasUpdate: false, error: e.toString());
    }
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
