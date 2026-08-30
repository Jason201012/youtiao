/// 更新链路的信任策略（安全审计 L-01 / L-02 / L-04 / L-13）。
///
/// 前提假设：Gitee 上的 update.json **可能被篡改或作者账号可能被盗**。本文件把
/// 「清单里所有外部可控字符串」的校验集中到一处，任何进入更新链路的 URL / 文本
/// 都必须先过这里：
///
/// - [isValidVersion]：版本号格式白名单（防拼进文件路径）；
/// - [isAllowedApkUrl]：APK 直链首跳必须落在作者发布仓的 releases/download 前缀下；
/// - [isAllowedRedirectTarget]：重定向逐跳只放宽到主机白名单（Gitee 附件会 302 到
///   `attach_files/` 与 `foruda.gitee.com` 等子域，故不能用路径前缀卡死后续跳）；
/// - [isAllowedReleaseUrl]：发行版页面外跳白名单；
/// - [clampReleaseNotes] / [clampShort]：清单文本字段长度上限。
///
/// 所有方法都是纯函数、零依赖，便于单元测试固化（见 test/update_policy_test.dart）。
class UpdatePolicy {
  const UpdatePolicy._();

  /// APK 下载体积硬上限（200 MB）。当前包体约 45 MB，留足余量；
  /// 超过即中止并删除半成品，防止投毒清单把存储写满（L-03）。
  static const int maxApkBytes = 200 * 1024 * 1024;

  /// 版本号最大长度（L-13）。
  static const int maxVersionChars = 32;

  /// 更新说明最大字符数（L-13）。投毒清单可塞入数 MB 文本拖垮更新弹窗。
  static const int maxReleaseNotesChars = 8000;

  /// URL 最大长度（L-13）。
  static const int maxUrlChars = 512;

  /// 手动跟随重定向的最大跳数（L-02）。
  static const int maxRedirects = 5;

  /// 单跳网络超时。
  static const Duration requestTimeout = Duration(seconds: 15);

  /// 版本号白名单：`数字.数字.数字` 开头，后续只允许字母数字与 `. + -`。
  /// 明确拒绝 `/` `\` 与 `..`，杜绝拼进文件路径。
  static final RegExp versionRe = RegExp(r'^\d+\.\d+\.\d+[A-Za-z0-9.+\-]*$');

  /// 作者拥有的发布仓（APK 直链前缀，锁定 owner + repo + 路径）。
  ///
  /// 只校验 host 是不够的：`https://gitee.com/<任意人>/<任意仓>/releases/download/...`
  /// 都会命中 host 白名单，攻击者只需自己注册一个 Gitee 账号上传恶意 APK 即可。
  static const List<String> apkUrlPrefixes = <String>[
    'https://gitee.com/jason1012/youtiao/releases/download/',
    'https://gitee.com/jason1012/youtiao-releases/releases/download/',
    'https://gitee.com/jason1012/youtiao-releases-2/releases/download/',
    'https://gitee.com/jason1012/youtiao-releases-3/releases/download/',
  ];

  /// 发行版页面（releaseUrl）前缀白名单：只允许作者三个发布仓的 releases 页。
  static const List<String> releaseUrlPrefixes = <String>[
    'https://gitee.com/jason1012/youtiao/releases',
    'https://gitee.com/jason1012/youtiao-releases/releases',
    'https://gitee.com/jason1012/youtiao-releases-2/releases',
    'https://gitee.com/jason1012/youtiao-releases-3/releases',
  ];

  /// 主机白名单（含子域）。Gitee 附件下载会 302 到 `foruda.gitee.com` 之类的
  /// 对象存储子域，故不能用「路径前缀」约束后续跳，只能约束主机。
  static const List<String> allowedHosts = <String>[
    'gitee.com',
    'github.com',
    'githubusercontent.com',
  ];

  /// 版本号是否合法（L-01）：非空、长度受限、且匹配 [versionRe]。
  static bool isValidVersion(String v) =>
      v.isNotEmpty && v.length <= maxVersionChars && versionRe.hasMatch(v);

  /// 发行版页面兜底 URL 里的 tag 段净化（L-13）。
  ///
  /// tag 来自清单，会拼进 `…/releases/tag/<tag>`。虽然 URI 的 `..` 段无法把
  /// 浏览器带离 gitee.com（authority 不由 path 决定），但保留任意字符仍会让
  /// 「查看更新详情」跳到一个作者无法预期的页面。这里只留版本号常见字符。
  static final RegExp _tagUnsafeRe = RegExp(r'[^A-Za-z0-9._+\-]');

  /// 净化 tag：去掉非白名单字符后截断到 64 字符；空值返回空串。
  static String sanitizeTag(String? raw) {
    final t = (raw ?? '').trim();
    if (t.isEmpty) return '';
    return clampShort(t.replaceAll(_tagUnsafeRe, ''), max: 64);
  }

  /// 主机是否在白名单内（精确相等或为其子域）。
  static bool isAllowedHost(String host) {
    final h = host.toLowerCase();
    if (h.isEmpty) return false;
    for (final allowed in allowedHosts) {
      if (h == allowed || h.endsWith('.$allowed')) return true;
    }
    return false;
  }

  /// 基础校验：必须是 https、长度受限、主机在白名单内。
  static bool _isHttpsAllowedHost(String url) {
    if (url.isEmpty || url.length > maxUrlChars) return false;
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https') return false;
    return isAllowedHost(uri.host);
  }

  /// APK 直链（首跳）是否允许：在主机白名单之上，额外要求落在作者发布仓的
  /// `releases/download/` 路径前缀下（L-02）。
  static bool isAllowedApkUrl(String url) {
    if (!_isHttpsAllowedHost(url)) return false;
    return apkUrlPrefixes.any(url.startsWith);
  }

  /// 重定向目标是否允许（L-02）：逐跳只校验 https + 主机白名单。
  ///
  /// 实测 Gitee 的跳转链为
  /// `gitee.com/<owner>/<repo>/releases/download/...`
  ///   → `gitee.com/<owner>/<repo>/attach_files/<id>/download/...`
  ///   → `foruda.gitee.com/attach_file/<id>/...?token=...`
  /// 后两跳路径形态由 Gitee 决定，无法用作者前缀约束，因此这里只卡主机，
  /// 但仍能挡住「gitee.com 域内开放重定向 → 任意外部主机」这条利用链。
  static bool isAllowedRedirectTarget(String url) => _isHttpsAllowedHost(url);

  /// 发行版页面是否允许外跳（L-04）。
  static bool isAllowedReleaseUrl(String url) {
    if (!_isHttpsAllowedHost(url)) return false;
    return releaseUrlPrefixes.any(url.startsWith);
  }

  /// 更新说明截断（L-13）：超长直接截断到 [maxReleaseNotesChars]。
  static String clampReleaseNotes(String? raw) {
    if (raw == null || raw.isEmpty) return '';
    if (raw.length <= maxReleaseNotesChars) return raw;
    return raw.substring(0, maxReleaseNotesChars);
  }

  /// 通用短文本截断（版本号 / 标题等），超长截断到 [max]。
  static String clampShort(String? raw, {int max = maxVersionChars}) {
    if (raw == null || raw.isEmpty) return '';
    if (raw.length <= max) return raw;
    return raw.substring(0, max);
  }
}
