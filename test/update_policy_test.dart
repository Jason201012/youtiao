import 'package:flutter_test/flutter_test.dart';
import 'package:todolist/services/update_policy.dart';

/// 更新链路信任策略回归测试（L-01 / L-02 / L-04 / L-13）。
///
/// 威胁模型：Gitee 上的 update.json 属**不可信输入**（平台可能被入侵、
/// 作者账号可能被盗、CDN 可能被劫持）。本文件固化「清单里每个外部可控字段」
/// 的放行/拒绝行为——任何一条被放松，都意味着攻击者能重新控制下载地址。
void main() {
  group('UpdatePolicy.isValidVersion（L-01）', () {
    test('接受标准 semver 与常见后缀', () {
      for (final v in <String>[
        '2.7.8',
        '10.20.30',
        '2.7.0-beta.1',
        '2.7.0+build8',
        '2.7.0-rc.1+b2',
      ]) {
        expect(UpdatePolicy.isValidVersion(v), isTrue, reason: v);
      }
    });

    test('拒绝路径穿越 / 非法形态', () {
      for (final v in <String>[
        '',
        '2.7',
        'v2.7.8',
        '../../../files/x',
        '2.7.8/../../evil',
        '2.7.8\\evil',
        '2.7.8\r\nX-Injected: 1',
        'a' * 64,
      ]) {
        expect(UpdatePolicy.isValidVersion(v), isFalse, reason: v);
      }
    });
  });

  group('UpdatePolicy.isAllowedApkUrl（L-02）', () {
    test('放行作者发布仓的 releases/download 直链', () {
      for (final u in <String>[
        'https://gitee.com/jason1012/youtiao/releases/download/v2.7.8/a.apk',
        'https://gitee.com/jason1012/youtiao-releases-2/releases/download/v2.7.7/a.apk',
        'https://gitee.com/jason1012/youtiao-releases-3/releases/download/v2.7.8/app-release-2.7.8-arm64.apk',
      ]) {
        expect(UpdatePolicy.isAllowedApkUrl(u), isTrue, reason: u);
      }
    });

    test('同主机但他人仓库的直链被拒绝（只校验 host 是不够的）', () {
      expect(
        UpdatePolicy.isAllowedApkUrl(
            'https://gitee.com/attacker/evil/releases/download/v1/evil.apk'),
        isFalse,
      );
      // 作者仓库下的非 download 路径同样拒绝（如 wiki / raw 附件）
      expect(
        UpdatePolicy.isAllowedApkUrl(
            'https://gitee.com/jason1012/youtiao/raw/master/evil.apk'),
        isFalse,
      );
    });

    test('http / 其它主机 / 非 https scheme 一律拒绝', () {
      for (final u in <String>[
        'http://gitee.com/jason1012/youtiao-releases-3/releases/download/v1/a.apk',
        'https://evil.com/jason1012/youtiao-releases-3/releases/download/v1/a.apk',
        // 形似白名单域的子域（gitee.com.evil.com）不能命中
        'https://gitee.com.evil.com/jason1012/youtiao/releases/download/v1/a.apk',
        'file:///sdcard/evil.apk',
        '',
        'a' * 600,
      ]) {
        expect(UpdatePolicy.isAllowedApkUrl(u), isFalse, reason: u);
      }
    });
  });

  group('UpdatePolicy.isAllowedRedirectTarget（L-02）', () {
    test('放行 Gitee 对象存储子域（附件下载会 302 到这里）', () {
      expect(
        UpdatePolicy.isAllowedRedirectTarget(
            'https://foruda.gitee.com/attach_file/123/download/x.apk?token=t'),
        isTrue,
      );
      expect(
        UpdatePolicy.isAllowedRedirectTarget(
            'https://gitee.com/jason1012/youtiao-releases-3/attach_files/1/download/x.apk'),
        isTrue,
      );
    });

    test('域内开放重定向到外部主机被拒绝', () {
      expect(
        UpdatePolicy.isAllowedRedirectTarget('https://evil.com/steal.apk'),
        isFalse,
      );
      expect(
        UpdatePolicy.isAllowedRedirectTarget('http://gitee.com/plaintext'),
        isFalse,
      );
    });
  });

  group('UpdatePolicy.isAllowedReleaseUrl（L-04）', () {
    test('放行作者发布仓的 releases 页面', () {
      for (final u in <String>[
        'https://gitee.com/jason1012/youtiao/releases',
        'https://gitee.com/jason1012/youtiao-releases-3/releases/tag/v2.7.8',
      ]) {
        expect(UpdatePolicy.isAllowedReleaseUrl(u), isTrue, reason: u);
      }
    });

    test('钓鱼页 / 他人仓库页被拒绝', () {
      for (final u in <String>[
        'https://gitee.com/attacker/evil/releases',
        'https://youtiao-update.example.com/releases',
        'http://gitee.com/jason1012/youtiao/releases',
      ]) {
        expect(UpdatePolicy.isAllowedReleaseUrl(u), isFalse, reason: u);
      }
    });
  });

  group('UpdatePolicy.sanitizeTag（L-13）', () {
    test('剥离非版本号字符并截断', () {
      expect(UpdatePolicy.sanitizeTag('../../evil?a=1'), '....evila1');
      expect(UpdatePolicy.sanitizeTag('  v2.7.8  '), 'v2.7.8');
      expect(UpdatePolicy.sanitizeTag(null), '');
      expect(UpdatePolicy.sanitizeTag('x' * 200).length, 64);
    });
  });

  group('UpdatePolicy.clamp*（L-13）', () {
    test('releaseNotes 截断到 8000 字', () {
      expect(UpdatePolicy.clampReleaseNotes('y' * 10000).length, 8000);
      expect(UpdatePolicy.clampReleaseNotes(null), '');
      expect(UpdatePolicy.clampReleaseNotes('短说明'), '短说明');
    });

    test('clampShort 按给定上限截断', () {
      expect(UpdatePolicy.clampShort('1234567890', max: 4), '1234');
      expect(UpdatePolicy.clampShort(null), '');
    });
  });

  group('UpdatePolicy 体积上限（L-03）', () {
    test('APK 硬上限为 200MB，当前包体留有余量', () {
      expect(UpdatePolicy.maxApkBytes, 200 * 1024 * 1024);
      // 当前 v2.7.8 包体约 42.5MB，上限至少是其 4 倍，避免误杀未来版本。
      expect(UpdatePolicy.maxApkBytes, greaterThan(4 * 45 * 1024 * 1024));
    });
  });
}
