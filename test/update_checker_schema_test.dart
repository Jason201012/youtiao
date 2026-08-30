import 'package:flutter_test/flutter_test.dart';
import 'package:todolist/services/update_checker.dart';

/// 清单 schema 回归测试（S4 / S5 / L-01 / L-04 / L-13）。
/// 锁定：update.json 用 `releaseNotes` 键、兜底 releaseUrl 指向当前 APK 仓。
/// v2.7.8：APK 仓由 youtiao-releases-2 切到 youtiao-releases-3（旧仓附件配额已满），
/// 兜底 URL 必须随仓迁移同步更新，否则「查看更新详情」会指向不存在的 tag 页。
///
/// L-01 / L-04 / L-13：清单属**不可信输入**（Gitee 可能被篡改 / 作者账号可能被盗），
/// 所有字段在解析阶段即被裁剪或丢弃，这里逐条固化该行为。
void main() {
  group('UpdateChecker.parseManifest 清单 schema', () {
    test('releaseNotes 被正确读取（S4 回归：不再读旧的 notes 键）', () {
      final info = UpdateChecker.parseManifest({
        'version': '2.6.7',
        'apkUrl': 'https://gitee.com/jason1012/youtiao-releases-3/releases/download/v2.6.7/app.apk',
        'apkSha256': 'a' * 64,
        'releaseNotes': '本版本修复了若干体验问题。',
      });
      expect(info, isNotNull);
      expect(info!.releaseNotes, '本版本修复了若干体验问题。');
    });

    test('旧 notes 键不会被当作更新说明读取', () {
      final info = UpdateChecker.parseManifest({
        'version': '2.6.7',
        'notes': '这是旧键内容，应当被忽略',
      });
      expect(info, isNotNull);
      expect(info!.releaseNotes, isNull);
    });

    test('缺少 version 时返回 null（调用方据此报错而非崩溃）', () {
      expect(UpdateChecker.parseManifest({'foo': 'bar'}), isNull);
      expect(UpdateChecker.parseManifest(const <String, dynamic>{}), isNull);
    });

    test('releaseUrl 缺省时兜底到 youtiao-releases-3（S5 回归 / v2.7.8 换仓）', () {
      final info = UpdateChecker.parseManifest({'version': '2.6.7'});
      expect(info, isNotNull);
      expect(info!.releaseUrl, contains('youtiao-releases-3'));
      expect(info.releaseUrl, isNot(contains('youtiao-releases/')));
    });

    test('白名单内的 releaseUrl 优先于兜底值', () {
      final info = UpdateChecker.parseManifest({
        'version': '2.6.7',
        'releaseUrl':
            'https://gitee.com/jason1012/youtiao-releases-3/releases/tag/v2.6.7',
      });
      expect(info!.releaseUrl,
          'https://gitee.com/jason1012/youtiao-releases-3/releases/tag/v2.6.7');
    });

    test('L-04：非白名单 releaseUrl 被丢弃，回退到兜底值', () {
      final info = UpdateChecker.parseManifest({
        'version': '2.6.7',
        'releaseUrl': 'https://example.com/evil',
      });
      expect(info, isNotNull);
      expect(info!.releaseUrl, contains('gitee.com/jason1012/youtiao-releases-3'));
    });

    test('tag 缺省时由 version 推导为 v 前缀', () {
      final info = UpdateChecker.parseManifest({'version': '2.6.7'});
      expect(info!.tagName, 'v2.6.7');
    });

    // ===== L-01：version 白名单（防路径穿越）=====
    test('L-01：非法 version 直接拒绝整份清单', () {
      for (final v in <String>[
        '',
        '2.6',
        '../../../files/x',
        '2.6.7/../../evil',
        'v2.6.7', // 不接受 v 前缀
        '2.6.7\nX-Evil: 1', // 不接受换行（防请求头注入）
        'a' * 64, // 超长
      ]) {
        expect(UpdateChecker.parseManifest({'version': v}), isNull,
            reason: 'version=$v 应当被拒绝');
      }
    });

    test('L-01：合法 semver（含预发布 / build 后缀）被接受', () {
      for (final v in <String>['2.6.7', '2.7.0', '2.7.0-beta.1', '2.7.0+build8']) {
        expect(UpdateChecker.parseManifest({'version': v}), isNotNull,
            reason: 'version=$v 应当被接受');
      }
    });

    // ===== L-13：字段长度上限 =====
    test('L-13：超长 releaseNotes 被截断到 8000 字', () {
      final info = UpdateChecker.parseManifest({
        'version': '2.6.7',
        'releaseNotes': 'x' * 20000,
      });
      expect(info!.releaseNotes!.length, 8000);
    });

    test('L-13：tag 中的非版本号字符被剥离', () {
      final info = UpdateChecker.parseManifest({
        'version': '2.6.7',
        'tag': 'v2.6.7/../../evil?a=1#x',
      });
      // 只保留 [A-Za-z0-9._+-]：斜杠、问号、等号、井号全部剥离。
      expect(info!.tagName, 'v2.6.7....evila1x');
      expect(info.tagName, isNot(contains('/')));
      expect(info.tagName, isNot(contains('?')));
    });

    test('L-04：兜底 releaseUrl 因此始终不含路径穿越段', () {
      final info = UpdateChecker.parseManifest({
        'version': '2.6.7',
        'tag': '../../evil',
      });
      expect(info!.releaseUrl, startsWith('https://gitee.com/jason1012/'));
      expect(info.releaseUrl, isNot(contains('../')));
      expect(info.releaseUrl, endsWith('evil'));
    });
  });
}
