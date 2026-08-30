import 'package:flutter_test/flutter_test.dart';
import 'package:todolist/services/update_checker.dart';

/// 清单 schema 回归测试（S4 / S5）。
/// 锁定：update.json 用 `releaseNotes` 键、兜底 releaseUrl 指向当前 APK 仓。
/// v2.7.8：APK 仓由 youtiao-releases-2 切到 youtiao-releases-3（旧仓附件配额已满），
/// 兜底 URL 必须随仓迁移同步更新，否则「查看更新详情」会指向不存在的 tag 页。
void main() {
  group('UpdateChecker.parseManifest 清单 schema', () {
    test('releaseNotes 被正确读取（S4 回归：不再读旧的 notes 键）', () {
      final info = UpdateChecker.parseManifest({
        'version': '2.6.7',
        'apkUrl': 'https://gitee.com/jason1012/youtiao-releases-3/releases/download/v2.6.7/app.apk',
        'apkSha256': 'ABCDEF',
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

    test('显式 releaseUrl 优先于兜底值', () {
      final info = UpdateChecker.parseManifest({
        'version': '2.6.7',
        'releaseUrl': 'https://example.com/custom',
      });
      expect(info!.releaseUrl, 'https://example.com/custom');
    });

    test('tag 缺省时由 version 推导为 v 前缀', () {
      final info = UpdateChecker.parseManifest({'version': '2.6.7'});
      expect(info!.tagName, 'v2.6.7');
    });
  });
}
