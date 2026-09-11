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
/// 显式本地时区无关的纯函数集合，见文件头说明。
class UpdatePolicy {
  const UpdatePolicy._();

  /// F-01：「强制签名」的最低清单版本。
  ///
  /// 声明版本不早于此值的**正式版**清单必须携带合法 ECDSA-P256 签名（[signature] 字段），
  /// 缺签名 / 验签失败一律拒绝；此前的历史版本维持「可选签名」的渐进策略。
  static const String signatureRequiredSinceVersion = '2.8.0';

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

  /// F-14：单次下载的**总时长**上限（10 分钟）。
  ///
  /// 此前只有「块间 15 秒超时」（`Stream.timeout` 每次收到数据就重置），
  /// 慢速 drip 攻击（每 10 秒喂几字节）可以让一次下载无限拖下去，长期占着
  /// 磁盘写入与连接。这里再按墙钟卡一道总闸。
  static const Duration maxDownloadDuration = Duration(minutes: 10);

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

  /// F-01：清单声明版本是否**必须**携带合法签名。
  ///
  /// 判定口径（与 `update_checker.check` 的设计意图一致）：
  /// - 版本号形态非法 → false（形态校验由解析阶段拒绝，不额外加码）；
  /// - 预发布版本（2.9.0-beta）→ false，不参与强制（内部测试包不必签名）；
  /// - 声明版本 **不早于** [signatureRequiredSinceVersion] → true。
  ///
  /// ⚠️ 陷阱（本函数存在的全部理由）：[compareVersion] 的返回方向是
  /// 「>0 表示 b 比 a 新」，即 **a 越新、返回值越小（负）**。判断
  /// 「a 不早于 2.8.0」因此应写成 `<= 0`。写成 `>= 0` 会让 2.8.2 及所有
  /// 未来新版本**反而不要求签名**，攻击者删掉 signature 字段即可绕过验签。
  /// 这里把语义收进单一纯函数并由 `update_signature_gate_test.dart` 固化，
  /// 避免比较方向再次散落到调用点。
  static bool requiresMandatorySignature(String declaredVersion) {
    final v = declaredVersion.trim();
    if (!isValidVersion(v)) return false;
    if (prereleaseOf(v) != null) return false;
    return compareVersion(v, signatureRequiredSinceVersion) <= 0;
  }

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

  /// 重定向目标是否允许（L-02 / F-14）。
  ///
  /// 实测 Gitee 的跳转链为
  /// `gitee.com/<owner>/<repo>/releases/download/...`
  ///   → `gitee.com/<owner>/<repo>/attach_files/<id>/download/...`
  ///   → `foruda.gitee.com/attach_file/<id>/...?token=...`
  ///
  /// F-14 修复：原实现是「逐跳只校验 https + 主机白名单」，而主机白名单比 APK 前缀
  /// 白名单宽得多（还含 github.com / githubusercontent.com）——只要首跳落在作者仓、
  /// 之后 302 到 github 上**任意仓库**的资产都放行，纵深防御在这里开了口子。
  /// 现在除了主机，还要求路径落在下面两类形态之一，其余一律拒绝：
  ///  1. 作者发布仓自身的路径（`/jason1012/...`，含 releases/download 与 attach_files）；
  ///  2. 对象存储附件的固定路径形态（`/attach_file(s)/...`，**且主机为 gitee 系**）。
  /// 这样「从作者 URL 跳到 github 任意仓库资产」这条链被彻底切断
  /// （APK 实际只在 Gitee，不影响正常下载）。
  static bool isAllowedRedirectTarget(String url) {
    if (!_isHttpsAllowedHost(url)) return false;
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final path = uri.path;
    // 1) 作者发布仓路径（gitee.com/jason1012/... 下的 releases / attach_files）
    if (uri.host == 'gitee.com' && path.startsWith('/jason1012/')) return true;
    // 2) 附件对象存储直链（foruda.gitee.com/attach_file/... 等）。
    // P3-3：此前分支 2 只校验路径前缀、**不校验主机**，主机白名单内的任意主机
    // （github.com / githubusercontent.com）只要路径写成 `/attach_files/...` 即放行，
    // 等于给 F-14 的纵深防御留了个组合口子（`https://github.com/attach_files/...`）。
    // 实测附件 CDN 只会落在 gitee 系域（含 foruda.gitee.com 等子域），故一并限定主机。
    if (_isGiteeHost(uri.host) &&
        (path.startsWith('/attach_files/') || path.startsWith('/attach_file/'))) {
      return true;
    }
    return false;
  }

  /// 主机是否属于 gitee 系（`gitee.com` 或其子域，如 `foruda.gitee.com`）。
  static bool _isGiteeHost(String host) {
    final h = host.toLowerCase();
    return h == 'gitee.com' || h.endsWith('.gitee.com');
  }

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

/// 比较两个语义化版本号。
/// 返回 >0 表示 [b] 比 [a] 新（即 [a] 旧），<0 表示 [a] 更新，0 相等。
/// 支持 "2.1.2" 与 "v2.2.0" 混用（自动去 v 前缀），段数不足补 0。
///
/// ⚠️ 方向务必记牢：**a 越新，返回值越小**。判断「a 不早于 X」应写 `<= 0`
/// （见 [UpdatePolicy.requiresMandatorySignature]，F-01 曾在这里写反）。
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
  final preA = prereleaseOf(a);
  final preB = prereleaseOf(b);
  if (preA == null && preB == null) return 0; // 均为正式版且数值相等
  if (preA == null) return -1; // a 是正式版（更高），b 是预发布 → a 更新 → <0
  if (preB == null) return 1; // b 是正式版（更高）→ b 更新 → >0
  return _comparePrerelease(preA, preB);
}

/// 提取版本串中的预发布后缀（不含前导 '-'），如 "2.5.7-beta" → "beta"；
/// 无预发布则返回 null（正式版）。
String? prereleaseOf(String v) {
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
