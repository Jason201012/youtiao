import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:todolist/services/backup_validator.dart';

/// 备份导入强校验（S3）的纯逻辑单测：无需 flutter / 平台通道，直接覆盖
/// [BackupValidator.validate] 的来源判定、结构体检与失败原因文案。
void main() {
  group('BackupValidator.validate（S3 / P2-7 补测）', () {
    test('空文件被拒', () {
      final r = BackupValidator.validate('');
      expect(r.ok, isFalse);
      expect(r.message, contains('为空'));
    });

    test('合法「有条」备份通过，并报告任务数', () {
      final raw = jsonEncode({
        'app': '有条',
        'version': 3,
        'tasks': [
          {'id': '1', 'title': 'a', 'priority': 'low', 'category': 'life'},
          {'id': '2', 'title': 'b', 'priority': 'medium', 'category': 'work'},
        ],
        'trash': <Map<String, dynamic>>[],
      });
      final r = BackupValidator.validate(raw);
      expect(r.ok, isTrue);
      expect(r.taskCount, 2);
      expect(r.hasTrash, isFalse);
    });

    test('含回收站的备份标记 hasTrash', () {
      final raw = jsonEncode({
        'app': '有条',
        'tasks': [
          {'id': '1', 'title': 'a', 'priority': 'low', 'category': 'life'},
        ],
        'trash': [
          {'id': '2', 'title': 'b', 'priority': 'low', 'category': 'life'},
        ],
      });
      final r = BackupValidator.validate(raw);
      expect(r.ok, isTrue);
      expect(r.hasTrash, isTrue);
    });

    test('非 JSON 被拒', () {
      final r = BackupValidator.validate('这不是json{');
      expect(r.ok, isFalse);
    });

    test('第三方 JSON（无 app 且无 tasks 列表）被拒，防清空数据', () {
      final r = BackupValidator.validate(jsonEncode({'foo': 'bar'}));
      expect(r.ok, isFalse);
      expect(r.message, contains('不是「有条'));
    });

    test('带「有条」标记但 tasks 缺失被拒（P2-2，防空档备份清库）', () {
      // 旧逻辑会放行这类文件并按空备份恢复，把现有任务+回收站全清。
      final r = BackupValidator.validate(jsonEncode({'app': '有条'}));
      expect(r.ok, isFalse);
      expect(r.message, contains('任务列表'));
    });

    test('带「有条」标记但 tasks 非列表被拒（P2-2）', () {
      final r = BackupValidator.validate(jsonEncode({'app': '有条', 'tasks': 'oops'}));
      expect(r.ok, isFalse);
      expect(r.message, contains('任务列表'));
    });

    test('显式空数组 tasks: [] 仍允许（清空恢复的唯一合法路径）', () {
      final r = BackupValidator.validate(jsonEncode({'app': '有条', 'tasks': []}));
      expect(r.ok, isTrue);
      expect(r.taskCount, 0);
    });

    test('顶层非对象被拒', () {
      final r = BackupValidator.validate(jsonEncode([1, 2, 3]));
      expect(r.ok, isFalse);
    });

    test('priority 非字符串被拒', () {
      final raw = jsonEncode({
        'app': '有条',
        'tasks': [
          {'id': '1', 'title': 'a', 'priority': 123, 'category': 'life'},
        ],
      });
      final r = BackupValidator.validate(raw);
      expect(r.ok, isFalse);
      expect(r.message, contains('priority'));
    });

    test('category 非字符串被拒', () {
      final raw = jsonEncode({
        'app': '有条',
        'tasks': [
          {'id': '1', 'title': 'a', 'priority': 'low', 'category': 5},
        ],
      });
      final r = BackupValidator.validate(raw);
      expect(r.ok, isFalse);
      expect(r.message, contains('category'));
    });

    test('trash 非列表被拒', () {
      final raw = jsonEncode({
        'app': '有条',
        'tasks': <Map<String, dynamic>>[],
        'trash': 'notalist',
      });
      final r = BackupValidator.validate(raw);
      expect(r.ok, isFalse);
    });

    test('version 非法（<1）被拒', () {
      final raw = jsonEncode({
        'app': '有条',
        'version': 0,
        'tasks': <Map<String, dynamic>>[],
      });
      final r = BackupValidator.validate(raw);
      expect(r.ok, isFalse);
    });

    test('空任务列表（用户清空全部）也允许', () {
      final raw = jsonEncode({
        'app': '有条',
        'tasks': <Map<String, dynamic>>[],
      });
      final r = BackupValidator.validate(raw);
      expect(r.ok, isTrue);
      expect(r.taskCount, 0);
    });
  });
}
