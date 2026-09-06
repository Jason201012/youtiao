import 'package:flutter_test/flutter_test.dart';
import 'package:todolist/services/update_policy.dart';

/// F-01 回归：更新清单「强制签名」门槛判定矩阵。
///
/// 设计意图（update_checker.check 注释）：声明版本 **≥ 2.8.0** 的正式版清单
/// 必须携带合法 ECDSA 签名，缺签名 / 验签失败一律拒绝；2.8.0 之前的历史版本
/// 维持「可选签名」渐进策略。预发布版本不参与强制。
///
/// 原实现把比较方向写反（`compareVersion(declared,'2.8.0') >= 0`），结果 2.8.2
/// 与所有未来新版本反而不要求签名——攻击者删掉 signature 字段即可绕过 C-2 验签。
/// 本测试把判定收进纯函数 [UpdatePolicy.requiresMandatorySignature] 并固化矩阵。
void main() {
  group('UpdatePolicy.requiresMandatorySignature（F-01 矩阵）', () {
    test('2.7.x 历史版本不强制签名', () {
      for (final v in const ['2.7.8', '2.7.9']) {
        expect(UpdatePolicy.requiresMandatorySignature(v), isFalse,
            reason: 'version=$v 应为可选签名');
      }
    });

    test('2.8.0 起（含当前线上与新版本）必须签名', () {
      for (final v in const ['2.8.0', '2.8.2', '2.9.0', '3.0.0']) {
        expect(UpdatePolicy.requiresMandatorySignature(v), isTrue,
            reason: 'version=$v 必须携带签名');
      }
    });

    test('预发布版本不参与强制（即便 >= 2.8.0）', () {
      expect(UpdatePolicy.requiresMandatorySignature('2.9.0-beta'), isFalse);
      expect(UpdatePolicy.requiresMandatorySignature('3.0.0-rc.1'), isFalse);
    });

    test('形态非法的版本号不强制（交解析阶段拒绝）', () {
      for (final v in const ['', 'abc', '2.8', '../../etc']) {
        expect(UpdatePolicy.requiresMandatorySignature(v), isFalse);
      }
    });
  });

  group('compareVersion 方向语义（F-01 根因）', () {
    // 返回 >0 表示「b 比 a 新」，即 a 越新返回值越小（负）。
    test('2.8.2 比 2.8.0 更新 → 返回负值', () {
      expect(compareVersion('2.8.2', '2.8.0'), lessThan(0));
    });
    test('「a 不早于 2.8.0」应写为 <= 0', () {
      // 这正是 F-01 修复后的判定：requiresMandatorySignature 内部即此比较。
      expect(compareVersion('2.8.2', '2.8.0') <= 0, isTrue);
      expect(compareVersion('2.7.9', '2.8.0') <= 0, isFalse);
    });
  });
}
