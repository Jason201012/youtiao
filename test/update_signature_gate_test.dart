import 'package:flutter_test/flutter_test.dart';
import 'package:todolist/services/update_policy.dart';

/// 更新清单「强制签名」门槛判定。
///
/// 演进：
/// - F-01：原实现把比较方向写反（`compareVersion(declared,'2.8.0') >= 0`），结果 2.8.2
///   与所有未来新版本反而不要求签名——攻击者删掉 signature 字段即可绕过 C-2 验签。
///   当时把判定收进纯函数 [UpdatePolicy.requiresMandatorySignature] 并由本文件固化矩阵。
/// - P3-1（v2.9.0 审计）：门槛与**本地版本**取并集，避免清单自报版本被改小后降级。
/// - P2-7 / P3-14（v2.9.1 审计）：门槛退化为**无条件强制**，两条绕过面一并封死——
///   ① 「自报版本 < 2.8.0 时接受无签名清单」的渐进兼容尾巴；
///   ② 「预发布形态整体豁免」。
///   现在不论版本与形态，缺签名 / 验签失败一律拒绝（清单签名是更新链路唯一的
///   「来源可信」锚；`apkSha256` 由同一份清单自带，只证明文件与清单一致）。
void main() {
  group('UpdatePolicy.requiresMandatorySignature（P2-7 / P3-14：无条件强制）', () {
    test('任何版本都强制签名（含 2.8.0 之前的历史版本）', () {
      for (final v in const ['2.7.8', '2.7.9', '2.8.0', '2.8.2', '2.9.0', '3.0.0']) {
        expect(UpdatePolicy.requiresMandatorySignature(v), isTrue,
            reason: 'version=$v 必须携带签名');
      }
    });

    test('预发布版本同样强制（P3-14 关闭豁免）', () {
      expect(UpdatePolicy.requiresMandatorySignature('2.9.0-beta'), isTrue);
      expect(UpdatePolicy.requiresMandatorySignature('3.0.0-rc.1'), isTrue);
    });

    test('形态非法的版本号也返回 true（不再靠形态短路，缺签名由 check() 明确拒绝）', () {
      for (final v in const ['', 'abc', '2.8', '../../etc']) {
        expect(UpdatePolicy.requiresMandatorySignature(v), isTrue);
      }
    });
  });

  group('compareVersion 方向语义（F-01 根因）', () {
    // 返回 >0 表示「b 比 a 新」，即 a 越新返回值越小（负）。
    test('2.8.2 比 2.8.0 更新 → 返回负值', () {
      expect(compareVersion('2.8.2', '2.8.0'), lessThan(0));
    });
    test('「a 不早于 2.8.0」应写为 <= 0（历史门槛口径，保留作对照）', () {
      expect(compareVersion('2.8.2', '2.8.0') <= 0, isTrue);
      expect(compareVersion('2.7.9', '2.8.0') <= 0, isFalse);
    });
  });
}
