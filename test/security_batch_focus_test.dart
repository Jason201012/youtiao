import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:todolist/models/focus_session.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/services/lunar_calendar.dart';
import 'package:todolist/services/task_templates.dart';
import 'package:todolist/state/task_provider.dart';
import 'test_helpers.dart';

/// 在 headless 测试里把 flutter_local_notifications 的 method channel 置为 no-op，
/// 并给 shared_preferences 一个内存实现，避免提醒调度触碰真实插件。
void _installMocks() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useMemoryDatabase();
  SharedPreferencesStorePlatform.instance = InMemorySharedPreferencesStore.empty();
  const ch = MethodChannel('dexterous.com/flutter/local_notifications');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(ch, (call) async => null);
}

/// 用受控的 Task 列表构造 Provider（绕过 load()，避免启动午夜守护定时器）。
Future<TaskProvider> buildWith(List<Task> tasks) async {
  final p = TaskProvider();
  final json = jsonEncode({
    'version': 2,
    'tasks': tasks.map((t) => t.toJson()).toList(),
    'trash': <dynamic>[],
    'notifications_enabled': false,
    'sound_enabled': false,
  });
  await p.restoreFromJson(json);
  return p;
}

Task mk(String id, {String? title, DateTime? due}) => Task(
      id: id,
      title: title ?? 'T$id',
      priority: Priority.medium,
      category: Category.work,
      dueDate: due,
    );

void main() {
  setUpAll(_installMocks);

  // ==================================================================
  // P1-A：用户模板导入 id 路径穿越
  // ==================================================================
  group('P1-A 模板 id 净化（CWE-22）', () {
    test('isSafeTemplateId 拒绝路径穿越与非法字符', () {
      expect(isSafeTemplateId('abc123'), isTrue);
      expect(isSafeTemplateId('tpl_1.2-3'), isTrue);
      // 审计报告里的真实攻击串
      expect(isSafeTemplateId('../../backup/auto/2026-08-28'), isFalse);
      expect(isSafeTemplateId('../user/xxx'), isFalse);
      expect(isSafeTemplateId('..'), isFalse);
      expect(isSafeTemplateId('.'), isFalse);
      expect(isSafeTemplateId(''), isFalse);
      expect(isSafeTemplateId('a/b'), isFalse);
      expect(isSafeTemplateId(r'a\b'), isFalse);
      expect(isSafeTemplateId('a' * 129), isFalse, reason: '长度上限 128');
      expect(isSafeTemplateId('..hidden'), isFalse, reason: '含 .. 段');
    });

    test('sanitizeTemplateId 对非法 id 返回新的安全 id（永不抛错）', () {
      expect(sanitizeTemplateId('good-id_1'), 'good-id_1');
      final a = sanitizeTemplateId('../../etc/passwd');
      final b = sanitizeTemplateId('../../etc/passwd');
      expect(isSafeTemplateId(a), isTrue);
      expect(isSafeTemplateId(b), isTrue);
      expect(sanitizeTemplateId(null), isNotNull);
      expect(isSafeTemplateId(sanitizeTemplateId(null)), isTrue);
    });

    test('UserTemplate.fromJson 净化外部 id', () {
      final t = UserTemplate.fromJson({
        'id': '../../backup/auto/2026-08-28',
        'name': '恶意模板',
        'items': [
          {'title': 'x', 'category': 'life', 'priority': 'low'},
        ],
      });
      expect(isSafeTemplateId(t.id), isTrue,
          reason: '反序列化后 id 必须可直接用作文件名');
      expect(t.id, isNot(contains('/')));
      expect(t.id, isNot(contains('..')));
      expect(t.name, '恶意模板');
      expect(t.items.length, 1);
    });

    test('UserTemplate.fromImportedJson 无条件重新分配 id', () {
      final raw = {
        'id': 'some_legit_looking_id',
        'name': '外部模板',
        'items': [
          {'title': 'x'},
        ],
      };
      final imported = UserTemplate.fromImportedJson(raw);
      final viaJson = UserTemplate.fromJson(raw);
      expect(imported.id, isNot(viaJson.id),
          reason: '导入入口应丢弃外部 id，与只读入口区分开');
      expect(isSafeTemplateId(imported.id), isTrue);
    });

    test('模板项数量受 maxItems 上限约束', () {
      final items = List.generate(
          UserTemplateStore.maxItems + 50,
          (i) => {'title': 'item$i'}).toList();
      final t = UserTemplate.fromImportedJson({'name': '超大', 'items': items});
      expect(t.items.length, UserTemplateStore.maxItems);
    });
  });

  // ==================================================================
  // P2-A：iCal 导入 id 治理
  // ==================================================================
  group('P2-A iCal 导入 id 治理', () {
    test('覆盖模式下 id 撞上不相关真实任务时改为新增，绝不改写原任务', () async {
      // 用户已有的真实任务 id=9
      final real = mk('9', title: '我的真实任务', due: DateTime(2026, 9, 1, 9));
      final p = await buildWith([real]);

      // 恶意 .ics：UID 恰好也是 9，但内容完全不同
      final evil = mk('9', title: '钓鱼内容', due: DateTime(2026, 12, 25, 9));
      final res = await Future.value(await p.importDedup([evil], ['9@youtiao'],
          overwrite: true));

      expect(res.overwritten, 0, reason: '指纹不一致，不应覆盖真实任务');
      expect(res.added, 1, reason: '应作为新任务导入');
      final stillReal = p.byId('9');
      expect(stillReal, isNotNull);
      expect(stillReal!.title, '我的真实任务', reason: '原任务内容必须原封不动');
      // 新增的那条拿到了新 id，与原任务不冲突
      final added = p.tasks.firstWhere((t) => t.title == '钓鱼内容');
      expect(added.id, isNot('9'));
    });

    test('id 与指纹都一致时，覆盖模式照常更新（不回归正常幂等导入）', () async {
      final real = mk('9', title: '同一条', due: DateTime(2026, 9, 1, 9));
      final p = await buildWith([real]);

      final same = mk('9', title: '同一条', due: DateTime(2026, 9, 1, 9));
      final res = await Future.value(
          await p.importDedup([same], ['9@youtiao'], overwrite: true));

      expect(res.overwritten, 1);
      expect(res.added, 0);
      expect(p.tasks.length, 1);
    });

    test('超大外部 id 不会让后续新建任务 id 碰撞', () async {
      final p = await buildWith([mk('8', title: '存在的')]);
      // 外部 .ics 塞一个超大 id
      await Future.value(await p.importDedup(
        [mk('999999', title: '外部任务')],
        ['999999@youtiao'],
      ));
      // P2-2（v3.0.7 审计）：addTask 异步化（落盘失败返回 null 并回滚内存）。
      final a = (await p.addTask(mk('', title: 'A')))!;
      final b = (await p.addTask(mk('', title: 'B')))!;
      expect(a.id, isNot(b.id), reason: '新建任务 id 必须互不相同');
      expect(p.tasks.where((t) => t.id == a.id).length, 1);
      expect(p.tasks.where((t) => t.id == b.id).length, 1);
    });

    test('导入后 _recomputeIdSeq 生效：新 id 不与任何现存 id 重复', () async {
      final p = await buildWith([mk('8', title: 'x')]);
      await Future.value(await p.importDedup(
        [mk('42', title: '外部'), mk('77', title: '外部2')],
        ['42@youtiao', '77@youtiao'],
      ));
      // P2-2（v3.0.7 审计）：addTask 异步化。
      final fresh = (await p.addTask(mk('', title: '新建')))!;
      final ids = p.tasks.map((t) => t.id).toList();
      expect(ids.where((i) => i == fresh.id).length, 1);
      expect(fresh.id, isNot('42'));
      expect(fresh.id, isNot('77'));
    });
  });

  // ==================================================================
  // P0-1 / P0-2：批量编辑与一键顺延
  // ==================================================================
  group('P0-1/P0-2 批量操作', () {
    test('batchUpdate 逐条应用变换并返回条数', () async {
      final a = mk('1', title: 'A', due: DateTime(2026, 9, 1, 9));
      final b = mk('2', title: 'B', due: DateTime(2026, 9, 2, 9));
      final p = await buildWith([a, b]);

      // P2-2（v3.0.7 审计）：batchUpdate 异步化并透传落盘结果。
      final n = await p.batchUpdate(['1', '2'], (t) => t.copyWith(pinned: true));
      expect(n, 2);
      expect(p.byId('1')!.pinned, isTrue);
      expect(p.byId('2')!.pinned, isTrue);

      // 未命中的 id 静默跳过，不影响返回值
      final m = await p.batchUpdate(['1', '不存在的id'], (t) => t);
      expect(m, 1);
    });

    test('batchUpdate 空列表安全返回 0', () async {
      final p = await buildWith([mk('1')]);
      expect(await p.batchUpdate([], (t) => t.copyWith(pinned: true)), 0);
    });

    test('postponeTo 平移截止日期并保留原时刻', () async {
      final old = mk('1', title: 'A', due: DateTime(2020, 1, 1, 14, 30));
      final p = await buildWith([old]);
      final target = DateTime(2026, 8, 30);
      final n = await p.postponeTo(['1'], target);
      expect(n, 1);
      final d = p.byId('1')!.dueDate!;
      expect(d.year, 2026);
      expect(d.month, 8);
      expect(d.day, 30);
      expect(d.hour, 14, reason: '时刻应保留');
      expect(d.minute, 30);
    });

    test('postponeTo 跳过无截止日期的任务（不凭空造截止日）', () async {
      final t = mk('1', title: '无截止');
      final p = await buildWith([t]);
      // P2-2（v3.0.7 审计）：postponeTo 异步化并透传落盘结果。
      expect(await p.postponeTo(['1'], DateTime(2026, 8, 30)), 1); // 仍计入"已处理"
      expect(p.byId('1')!.dueDate, isNull, reason: '不应给无截止任务硬塞日期');
    });

    test('批量改优先级 / 分类 / 追加标签', () async {
      final a = mk('1', title: 'A');
      final b = mk('2', title: 'B');
      final p = await buildWith([a, b]);
      await p.batchUpdate(['1', '2'], (t) => t.copyWith(
            priority: Priority.high,
            category: Category.study,
            tags: {...t.tags, '工作'}.toList(),
          ));
      for (final id in ['1', '2']) {
        final t = p.byId(id)!;
        expect(t.priority, Priority.high);
        expect(t.category, Category.study);
        expect(t.tags, contains('工作'));
      }
    });
  });

  // ==================================================================
  // P0-4：专注中断计数
  // ==================================================================
  group('P0-4 FocusSession.interruptCount', () {
    test('默认 0，且 JSON 往返保持一致', () {
      final s = FocusSession(
        id: 'f1',
        plannedSec: 1500,
        durationSec: 1500,
        completed: true,
        startedAt: DateTime(2026, 8, 28, 9),
        endedAt: DateTime(2026, 8, 28, 9, 25),
      );
      expect(s.interruptCount, 0);
      final back = FocusSession.fromJson(s.toJson());
      expect(back.interruptCount, 0);

      final s2 = FocusSession(
        id: s.id,
        plannedSec: s.plannedSec,
        durationSec: s.durationSec,
        completed: s.completed,
        interruptCount: 3,
        startedAt: s.startedAt,
        endedAt: s.endedAt,
      );
      expect(s2.interruptCount, 3);
      expect(FocusSession.fromJson(s2.toJson()).interruptCount, 3);
    });

    test('旧数据（无 interruptCount 字段）反序列化为 0', () {
      final j = {
        'id': 'f1',
        'plannedSec': 1500,
        'durationSec': 1500,
        'completed': true,
        'phase': 'focus',
        'startedAt': '2026-08-28T09:00:00.000',
        'endedAt': '2026-08-28T09:25:00.000',
      };
      expect(FocusSession.fromJson(j).interruptCount, 0,
          reason: '向后兼容，零迁移');
    });
  });

  // ==================================================================
  // P0-3：农历标注（展示层纯函数）
  // ==================================================================
  group('P0-3 lunarLabelOf', () {
    test('常见日期均能算出非空标注，且不抛异常', () {
      for (var d = 1; d <= 28; d++) {
        final label = lunarLabelOf(DateTime(2026, 8, d));
        expect(label.text, isNotEmpty);
      }
    });

    test('极端日期不崩溃（库不支持的年份静默降级）', () {
      expect(() => lunarLabelOf(DateTime(1899, 1, 1)), returnsNormally);
      expect(() => lunarLabelOf(DateTime(2101, 12, 31)), returnsNormally);
    });

    test('清明节被识别为节气（强调展示）', () {
      final label = lunarLabelOf(DateTime(2026, 4, 5));
      expect(label.isFestival, isTrue);
      expect(label.text, isNotEmpty);
    });
  });
}
