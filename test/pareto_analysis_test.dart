import 'package:flutter_test/flutter_test.dart';
import 'package:todolist/services/pareto_analysis.dart';

void main() {
  group('ParetoResult.compute', () {
    test('空数据返回 hasData=false', () {
      final p = ParetoResult.compute([]);
      expect(p.hasData, isFalse);
      expect(p.items, isEmpty);
      expect(p.total, 0);
      expect(p.vitalFewCount, 0);
      expect(p.isDominant, isFalse);
    });

    test('全部为 0 的条目被忽略，hasData=false', () {
      final p = ParetoResult.compute([
        ('A', 0),
        ('B', 0),
      ]);
      expect(p.hasData, isFalse);
    });

    test('单一非零项即占 100%，vitalFew=1 且 isDominant', () {
      final p = ParetoResult.compute([('工作', 1000)]);
      expect(p.hasData, isTrue);
      expect(p.total, 1000);
      expect(p.items.length, 1);
      expect(p.items.first.share, 1.0);
      expect(p.items.first.cumulative, 1.0);
      expect(p.vitalFewCount, 1);
      expect(p.vitalFewShare, 1.0);
      expect(p.isDominant, isTrue);
    });

    test('经典 80/20：两项各半时 vitalFew 覆盖到达 80% 的切点', () {
      final p = ParetoResult.compute([
        ('A', 800),
        ('B', 200),
      ]);
      expect(p.items.first.label, 'A');
      expect(p.items.first.share, closeTo(0.8, 1e-9));
      expect(p.items.first.cumulative, closeTo(0.8, 1e-9));
      expect(p.items[1].cumulative, 1.0);
      // A 单项已达 80% → vitalFew=1
      expect(p.vitalFewCount, 1);
      expect(p.vitalFewShare, closeTo(0.8, 1e-9));
      expect(p.isDominant, isTrue);
    });

    test('三项递减时 vitalFew 取「跨过 80% 的最小项数」', () {
      // 50% + 30% + 20%：累计 50 → 80 → 100，跨过 80 在第二项
      final p = ParetoResult.compute([
        ('A', 50),
        ('B', 30),
        ('C', 20),
      ]);
      expect(p.items.map((e) => e.label).toList(), ['A', 'B', 'C']);
      expect(p.items[0].cumulative, closeTo(0.5, 1e-9));
      expect(p.items[1].cumulative, closeTo(0.8, 1e-9));
      expect(p.vitalFewCount, 2);
      expect(p.vitalFewShare, closeTo(0.8, 1e-9));
      expect(p.isDominant, isFalse);
    });

    test('均很小时 vitalFew 退化为全部项', () {
      // 34+33+33：累计 34→67→100，始终未到 80 直到最后一项
      final p = ParetoResult.compute([
        ('A', 34),
        ('B', 33),
        ('C', 33),
      ]);
      expect(p.vitalFewCount, 3);
      expect(p.vitalFewShare, 1.0);
    });

    test('支持自定义阈值（如 0.5）', () {
      final p = ParetoResult.compute([
        ('A', 40),
        ('B', 30),
        ('C', 30),
      ], threshold: 0.5);
      // A 单项 40% < 50%，需 +B（累计 70%）才跨过 50% → vitalFew=2
      expect(p.vitalFewCount, 2);
      expect(p.vitalFewShare, closeTo(0.7, 1e-9));
    });

    test('负/零项被剔除，不影响排序与占比', () {
      final p = ParetoResult.compute([
        ('A', 100),
        ('B', 0),
        ('C', -5),
        ('D', 25),
      ]);
      expect(p.items.map((e) => e.label).toList(), ['A', 'D']);
      expect(p.total, 125);
      expect(p.items.first.share, closeTo(0.8, 1e-9));
    });
  });
}
