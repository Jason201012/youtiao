import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:todolist/models/attachment.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/services/attachment_service.dart';
import 'package:todolist/services/backup_validator.dart';
import 'package:todolist/services/data_io.dart';
import 'package:todolist/services/local_database.dart';
import 'package:todolist/services/notification_service.dart';
import 'package:todolist/services/task_import_service.dart';
import 'package:todolist/services/task_templates.dart';
import 'package:todolist/state/task_provider.dart';

import 'test_helpers.dart';

/// v3.0.9 审计修复轮（《youtiao-分析报告-第11轮》N1-N13 新发现）回归测试。
/// 每条修复至少一个「能区分修与未修」的用例；不落用例的项见文件尾说明。
///
/// 覆盖清单：
/// - **N1** 附件 mime 兜底扩展名复检（`image/svg+xml` 不再产出 `.svg+xml`；
///   尾点源文件名不再产出尾点文件名）；
/// - **N3** CSV 截断误报边界（恰 500 条有效任务 + 回收站/空标题行不报截断；
///   第 501 条有效任务仍截断）；
/// - **N4** 校验器补 user_templates 段形态体检（非列表 / 非对象条目拒绝）；
/// - **N5** exportAllForBackup 收集失败信号（目录枚举失败 failed=true，
///   与「真的没有模板」可区分）；
/// - **N7** user_templates 恢复下沉 restoreFromJson（同 id 覆盖 + 合并语义 +
///   统计经 RestoreBlobsStats 透出；无该段时不清模板）；
/// - **N9** archiveTag prefs 写失败回滚内存（界面即事实）；
/// - **N10** 回收站到期清理落盘失败回滚内存（不再「重启复活且无提示」）；
/// - **N12** clearSampleTasks 一并清撤销缓冲（残留横幅不再复活示例任务）；
/// - **H1 补齐** 上轮未达规格的真实往返：collectAttachmentBlobs 真实产物 →
///   jsonEncode → BackupValidator.validate 必须通过；
/// - **N8** estimateJsonBytes 按 JSON 转义后字节估算（转义密集内容不再低估）。
///
/// 不落用例：
/// - **N2 口令对话框 dispose 前取值 / N11 模板套用失败停留 / N13 录音 stop/dispose
///   串接**——均为 State 私有字段 / 私有方法的调用时序修复（dispose 与 await
///   的先后、Navigator.pop 的分支、whenComplete 串接），FakeAsync 下无法稳定
///   构造「对话框已弹出 / 落盘失败 / 平台通道异常」窗口（v3.0.7 P3-4 同判），
///   以代码顺序推演交付；
/// - **N6 / N14 / N15 / N17 / N18 / L15 / N16**——注释 / 文档 / 文案 / 发版
///   脚本层修正，无运行时行为（N16 为本轮如实记载的已知 RFC 偏差，行为未改），
///   不落用例；
/// - **N5 的备份侧消费**（_doBackup snackbar / _writeAutoBackup 错误栏）——
///   widget 私有流程与设置页错误栏渲染，以本文件的 failed 信号契约护住。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useMemoryDatabase();

  // 记录型通知插件 mock：除返回 null 外，把全部方法调用留档。
  final notifCalls = <MethodCall>[];
  const notifCh = MethodChannel('dexterous.com/flutter/local_notifications');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(notifCh, (call) async {
    notifCalls.add(call);
    return null;
  });
  const secureCh =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureCh, (call) async => null);

  setUp(() {
    // 🔴 内存库是同进程共享单例：每个用例前必须重置 DB + prefs。
    LocalDatabase.resetMemoryForTest();
    LocalDatabase.testUseMemory = true;
    SharedPreferencesStorePlatform.instance =
        InMemorySharedPreferencesStore.empty();
    notifCalls.clear();
    NotificationService.instance.enabled = true;
  });

  // ── 脚手架 ────────────────────────────────────────────────────────

  /// 用受控列表构造 TaskProvider（restoreFromJson 绕过 load()，不起午夜守护）。
  Future<TaskProvider> buildWith(
    List<Task> tasks, {
    List<Task>? trash,
  }) async {
    final p = TaskProvider();
    final json = jsonEncode({
      'version': 2,
      'tasks': tasks.map((t) => t.toJson()).toList(),
      'trash': (trash ?? const <Task>[]).map((t) => t.toJson()).toList(),
      'notifications_enabled': false,
      'sound_enabled': false,
    });
    await p.restoreFromJson(json);
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    return p;
  }

  /// 最小一次性任务工厂。
  Task mk({
    String id = '',
    String title = '任务',
    DateTime? due,
    TaskStatus status = TaskStatus.todo,
  }) =>
      Task(
        id: id,
        title: title,
        priority: Priority.medium,
        category: Category.work,
        dueDate: due,
        status: status,
      );

  // ══════════════════════════════════════════════════════════════════
  // N1：附件 mime 兜底扩展名复检
  // ══════════════════════════════════════════════════════════════════

  group('N1 附件 mime 兜底 ext 复检（v3.0.9 审计）', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('youtiao_n1_att');
    });
    tearDown(() async {
      if (await tmp.exists()) {
        await tmp.delete(recursive: true);
      }
    });

    /// 写一个源文件并调用 importFile，返回落盘文件名。
    Future<String> importNamed(
        String srcName, String? mime, List<int> bytes) async {
      final src = File('${tmp.path}/$srcName');
      await src.writeAsBytes(bytes);
      final ref = await AttachmentService.importFile(
        parentDir: tmp,
        src: src,
        type: AttachmentType.file,
        mimeType: mime,
      );
      return ref.fileName;
    }

    test('无扩展名源文件 + image/svg+xml：不再产出含 + 的非法扩展名', () async {
      final name = await importNamed('noext', 'image/svg+xml', [1, 2, 3]);
      // 旧实现：_extFromMime('image/svg+xml') → '.svg+xml'（+ 不在白名单），
      // 落盘后 fileFor / collectBlobs / restoreBlobs 全部拒绝该名字——
      // 「落盘即永久不可用附件」（M1 同型复发路径）。
      expect(name, matches(RegExp(r'^\d+_\d+$')),
          reason: 'N1：不安全兜底 ext 置空串，文件名只剩时间戳前缀');
      expect(name.contains('+'), isFalse);
    });

    test('尾点源文件名（note.）：不再产出尾点文件名', () async {
      final name = await importNamed('note.', null, [1, 2, 3]);
      // 旧实现：ext='.'（长度 1 不被首轮净化覆盖）→ 文件名以 '.' 结尾，
      // Windows 桌面端语义脆弱。
      expect(name.endsWith('.'), isFalse,
          reason: 'N1：ext=`.` 一并置空');
      expect(name, matches(RegExp(r'^\d+_\d+$')));
    });

    test('正常路径不受影响：源扩展名保留；audio/video mime 兜底仍可用', () async {
      expect(await importNamed('a.txt', null, [1]), matches(RegExp(r'^\d+_\d+\.txt$')));
      expect(await importNamed('photo.PNG', null, [1]),
          matches(RegExp(r'^\d+_\d+\.PNG$')));
      expect(await importNamed('noext2', 'audio/x-m4a', [1]),
          matches(RegExp(r'^\d+_\d+\.m4a$')));
      expect(await importNamed('noext3', 'video/quicktime', [1]),
          matches(RegExp(r'^\d+_\d+\.mp4$')));
      // image/png 子类型安全 → 兜底 ext 正常保留。
      expect(await importNamed('noext4', 'image/png', [1]),
          matches(RegExp(r'^\d+_\d+\.png$')));
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // N3：CSV 截断误报边界
  // ══════════════════════════════════════════════════════════════════

  group('N3 CSV 截断判定移到产出任务之前（v3.0.9 审计）', () {
    /// 组一份带完整列头的 CSV：[validCount] 条有效任务 + [tail] 行尾部
    /// （回收站 / 空标题，均不产出任务）。
    String csvWith(int validCount, List<String> tail) {
      final sb = StringBuffer()
        ..writeln('标题,截止,优先级,分类,标签,备注,预计,状态,完成时间,是否已删除');
      for (var i = 0; i < validCount; i++) {
        sb.writeln('任务$i,,,,,,,todo,,否');
      }
      for (final row in tail) {
        sb.writeln(row);
      }
      return sb.toString();
    }

    test('恰 500 条有效任务 + 回收站/空标题行：不误报截断', () {
      final r = parseTasksCsv(csvWith(500, [
        '回收甲,,,,,,,,,是', // 回收站行（第 10 列=是）：不产出任务
        '回收乙,,,,,,,,,是',
        ',,,,,,,todo,,否', // 空标题行：不产出任务（计入 errors）
      ]));
      expect(r.tasks.length, 500);
      // 旧实现在循环顶部判上限：第 501 行（回收站）到达即 break 并置
      // truncated=true——「尾批未导入」提示失实。
      expect(r.truncated, isFalse,
          reason: 'N3：不产出任务的行不再触发截断误报');
      expect(r.skippedDeleted, 2);
      expect(r.errors.length, 1, reason: '空标题行仍如实计入 errors');
    });

    test('第 501 条有效任务：截断仍然生效（上限语义不放松）', () {
      final r = parseTasksCsv(csvWith(501, const []));
      expect(r.tasks.length, 500);
      expect(r.truncated, isTrue,
          reason: 'M5 上限保持：真会产出第 501 条任务时才截断');
    });

    test('上限之后混排无效行：截断以「下一有效行」为准', () {
      final r = parseTasksCsv(csvWith(500, [
        '回收丙,,,,,,,,,是', // 无效行：不截断
        ',,,,,,,todo,,否', // 空标题：不截断
        '有效第501条,,,,,,,todo,,否', // 首个有效行 → 截断
        '有效第502条,,,,,,,todo,,否',
      ]));
      expect(r.tasks.length, 500);
      expect(r.truncated, isTrue);
      expect(r.skippedDeleted, 1);
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // N4：校验器补 user_templates 段体检
  // ══════════════════════════════════════════════════════════════════

  group('N4 校验器 user_templates 段体检（v3.0.9 审计）', () {
    String rawWith(dynamic templates) => jsonEncode({
          'app': '有条',
          'version': 3,
          'tasks': <Map<String, dynamic>>[],
          'user_templates': templates,
        });

    test('合法 user_templates 列表通过', () {
      final r = BackupValidator.validate(rawWith([
        {'id': 'tpl1', 'name': '晨间例行', 'items': <Map<String, dynamic>>[]},
      ]));
      expect(r.ok, isTrue);
    });

    test('user_templates 非列表 → 拒绝', () {
      final r = BackupValidator.validate(rawWith('not-a-list'));
      expect(r.ok, isFalse);
      expect(r.message, contains('用户模板'));
    });

    test('user_templates 含非对象条目 → 拒绝', () {
      final r = BackupValidator.validate(rawWith([123, 'x']));
      expect(r.ok, isFalse);
      expect(r.message, contains('用户模板'),
          reason: 'M8 同口径：脏条目在校验层拦截，不带入恢复');
    });

    test('无 user_templates 段的老备份不受影响', () {
      final r = BackupValidator.validate(jsonEncode({
        'app': '有条',
        'version': 3,
        'tasks': <Map<String, dynamic>>[],
      }));
      expect(r.ok, isTrue, reason: '老备份缺字段视为合法（零迁移）');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // N5：exportAllForBackup 收集失败信号
  // ══════════════════════════════════════════════════════════════════

  group('N5 exportAllForBackup 失败信号（v3.0.9 审计）', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('youtiao_n5_tpl');
      PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    });
    tearDown(() async {
      if (await tmp.exists()) {
        await tmp.delete(recursive: true);
      }
    });

    test('正常收集：failed=false；空库 = 真的没有模板', () async {
      var r = await UserTemplateStore.exportAllForBackup();
      expect(r.templates, isEmpty);
      expect(r.failed, isFalse, reason: '空库与失败可区分');

      await UserTemplateStore.save(UserTemplate(id: 'tpl1', name: '晨间例行'));
      r = await UserTemplateStore.exportAllForBackup();
      expect(r.templates.length, 1);
      expect(r.failed, isFalse);
    });

    test('目录枚举失败：failed=true（旧实现静默返回空列表）', () async {
      // 把 templates/user 占成一个普通文件：_dir() 认为目录已存在，
      // listSync 抛错 → loadAllWithBroken 的 catch 置 failed=true。
      await File('${tmp.path}/templates/user').create(recursive: true);
      final r = await UserTemplateStore.exportAllForBackup();
      expect(r.templates, isEmpty);
      expect(r.failed, isTrue,
          reason: 'N5：备份里 user_templates 恒空的根因被透出，调用方可提示');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // N7：user_templates 恢复下沉 restoreFromJson
  // ══════════════════════════════════════════════════════════════════

  group('N7 模板恢复下沉 restoreFromJson（v3.0.9 审计）', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('youtiao_n7_tpl');
      PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    });
    tearDown(() async {
      if (await tmp.exists()) {
        await tmp.delete(recursive: true);
      }
    });

    test('备份含 user_templates：同 id 覆盖 + 合并语义 + 统计透出', () async {
      await UserTemplateStore.save(UserTemplate(id: 'tplA', name: '本地名'));
      await UserTemplateStore.save(UserTemplate(id: 'tplB', name: '保留我'));
      final p = await buildWith([]);

      final stats = await p.restoreFromJson(jsonEncode({
        'version': 2,
        'tasks': <Map<String, dynamic>>[],
        'trash': <Map<String, dynamic>>[],
        'notifications_enabled': false,
        'sound_enabled': false,
        'user_templates': [
          {'id': 'tplA', 'name': '备份名', 'items': <Map<String, dynamic>>[]},
          'bad-entry', // 坏条目：跳过不阻断
        ],
      }));

      // 旧实现：restoreFromJson 完全不看 user_templates 段——只有 backup_sheet
      // 两个 UI 入口接线，新增恢复入口即静默丢模板（H1 同型缺口）。
      expect(stats.templatesTotal, 2);
      expect(stats.templatesRestored, 1);
      expect(stats.templatesFailed, 1);

      final all = await UserTemplateStore.loadAll();
      expect(all.firstWhere((t) => t.id == 'tplA').name, '备份名',
          reason: 'N7：同 id 覆盖（备份内的修改生效）');
      expect(all.firstWhere((t) => t.id == 'tplB').name, '保留我',
          reason: 'N6：合并语义——备份外模板不被删');
    });

    test('无 user_templates 段：统计为 0 且不清本地模板', () async {
      await UserTemplateStore.save(UserTemplate(id: 'tplA', name: '本地名'));
      final p = await buildWith([]);
      final stats = await p.restoreFromJson(jsonEncode({
        'version': 2,
        'tasks': <Map<String, dynamic>>[],
        'trash': <Map<String, dynamic>>[],
        'notifications_enabled': false,
        'sound_enabled': false,
      }));
      expect(stats.templatesTotal, 0, reason: '老备份无该段 → 不提示');
      expect(stats.templatesFailed, 0);
      final all = await UserTemplateStore.loadAll();
      expect(all.single.name, '本地名',
          reason: '无该段 = 不动模板（不是「清空」）');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // N9：archiveTag prefs 写失败回滚内存
  // ══════════════════════════════════════════════════════════════════

  group('N9 archiveTag prefs 失败回滚内存（v3.0.9 审计）', () {
    test('prefs 写失败 → false + 内存回滚（界面即事实）', () async {
      final p = await buildWith([mk(id: '9201').copyWith(tags: ['工作'])]);
      // 先成功归档一次（走正常 in-memory prefs）。
      expect(await p.archiveTag('工作'), isTrue);
      expect(p.archivedTags, contains('工作'));

      // 注入 prefs 写失败（StringList 写抛错）。
      final healthy = SharedPreferencesStorePlatform.instance;
      SharedPreferencesStorePlatform.instance =
          _FailingStringListPrefsStore(healthy);
      late final bool ok;
      try {
        ok = await p.archiveTag('新标签');
      } finally {
        SharedPreferencesStorePlatform.instance = healthy;
      }
      expect(ok, isFalse, reason: 'prefs 失败如实上报');
      // 旧实现：notifyListeners 已把「已归档」显示出来，写盘失败却不回滚——
      // 界面显示已归档、重启回退；且失败提示「继续其它操作会自动一并保存」
      // 对纯 prefs 态不成立（归档集合不经过任务表 _persist）。
      expect(p.archivedTags, isNot(contains('新标签')),
          reason: 'N9：失败回滚内存，界面即事实');
      expect(p.archivedTags, contains('工作'),
          reason: '已成功归档的状态不受影响');

      // 恢复健康 prefs 后可重试成功。
      expect(await p.archiveTag('新标签'), isTrue);
      expect(p.archivedTags, contains('新标签'));
    });

    test('unarchiveTag prefs 写失败同样回滚', () async {
      final p = await buildWith([]);
      // 归档两个标签：取消其中一个后集合仍非空 → 走 setStringList 写路径
      // （删最后一个归档标签走的是 prefs.remove，注入不命中，故用两标签场景）。
      expect(await p.archiveTag('甲'), isTrue);
      expect(await p.archiveTag('乙'), isTrue);
      final healthy = SharedPreferencesStorePlatform.instance;
      SharedPreferencesStorePlatform.instance =
          _FailingStringListPrefsStore(healthy);
      late final bool ok;
      try {
        ok = await p.unarchiveTag('甲');
      } finally {
        SharedPreferencesStorePlatform.instance = healthy;
      }
      expect(ok, isFalse);
      expect(p.archivedTags, contains('甲'),
          reason: 'N9：取消归档失败 → 归档态回滚（仍在筛选过滤中）');
      expect(p.archivedTags, contains('乙'));
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // N10：回收站到期清理落盘失败回滚内存
  // ══════════════════════════════════════════════════════════════════

  group('N10 回收站到期清理落盘失败回滚（v3.0.9 审计）', () {
    test('DB 异常 → 条目不回滚消失；恢复库后二次清理生效', () async {
      final expired = mk(id: '9301').copyWith(
          deletedAt: DateTime.now().subtract(const Duration(days: 31)));
      final p = await buildWith([], trash: [expired]);
      expect(p.trash.length, 1);

      // 改保留期触发 _cleanupTrashIfNeeded(persist: true)，DB 异常下
      // _persist 返回 false。
      LocalDatabase.testUseMemory = false;
      try {
        await p.setTrashRetentionDays(7);
      } finally {
        LocalDatabase.testUseMemory = true;
      }
      // 旧实现：_trash.removeWhere 已生效、通知已撤、文件保留，但条目重启
      // 复活且全程无提示（与 _removeManyAs / addTasksForTemplateApply 的
      // 失败回滚纪律不一致）。
      expect(p.trash.length, 1,
          reason: 'N10：落盘失败回滚内存——清理不生效，下次启动/午夜路径重试');
      expect(p.trash.single.id, '9301');

      // 恢复库后再触发一次（30 天规则下 31 天前删除仍过期）→ 真正清理。
      await p.setTrashRetentionDays(30);
      expect(p.trash, isEmpty, reason: '库恢复后清理生效并落盘');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // N12：clearSampleTasks 清撤销缓冲
  // ══════════════════════════════════════════════════════════════════

  group('N12 clearSampleTasks 清撤销缓冲（v3.0.9 审计）', () {
    test('删示例任务 → 从零开始 → 残留撤销横幅不再复活任务', () async {
      final p = await buildWith([mk(id: '1'), mk(id: '2')]);
      final del = await p.deleteTaskAs('1');
      expect(del.$1, isNot(0), reason: '删除缓冲已登记 batchId');
      expect(p.tasks.any((t) => t.id == '1'), isFalse);

      expect(await p.clearSampleTasks(), isTrue);

      // 旧实现只清 _tasks/_trash：引导前 10 秒内删过示例任务 →
      // 「从零开始」→ 点残留横幅撤销 → 示例任务复活进「空库」且提醒已撤
      //（幽灵行）。
      final u = await p.undoDelete(del.$1);
      expect(u.applied, isFalse, reason: 'N12：撤销缓冲已随清空示例一并清除');
      expect(p.tasks, isEmpty, reason: '示例任务不因残留横幅复活');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // H1 补齐：真实往返（collectBlobs 产物 → jsonEncode → validate）
  // ══════════════════════════════════════════════════════════════════

  group('H1 真实往返：collectAttachmentBlobs 产物必须过自产校验器', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('youtiao_h1_rt');
      PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    });
    tearDown(() async {
      if (await tmp.exists()) {
        await tmp.delete(recursive: true);
      }
    });

    test('落盘真实附件 → collectBlobs → 整包 validate ok', () async {
      // 第 10 轮 H1 测试只用手工 jsonEncode 构造的 attachments 形态；
      // 本轮补真实产物往返：collectBlobs 改动统计段结构时此用例会变红。
      final src = File('${tmp.path}/src.png')
        ..writeAsBytesSync(List<int>.filled(96, 7));
      final dir = await AttachmentService.dirFor('77');
      final ref = await AttachmentService.importFile(
        parentDir: dir,
        src: src,
        type: AttachmentType.image,
        mimeType: 'image/png',
      );
      final task = mk(id: '77').copyWith(attachments: [ref]);
      final p = await buildWith([task]);

      final blobs = await p.collectAttachmentBlobs(false);
      expect(blobs.keys, contains('__skipped'),
          reason: '真实产物含统计段（H1 豁免的对象）');
      expect((blobs['77'] as List).length, 1);
      expect((blobs['77'] as List).first['data'], isA<String>());

      final raw = jsonEncode({
        'app': '有条',
        'version': 3,
        'tasks': [task.toJson()],
        'trash': <Map<String, dynamic>>[],
        'attachments': blobs,
      });
      final r = BackupValidator.validate(raw);
      expect(r.ok, isTrue,
          reason: 'H1：App 自产备份必须过自产校验器（闭环不断裂）');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // N8：estimateJsonBytes 按 JSON 转义后字节估算
  // ══════════════════════════════════════════════════════════════════

  group('N8 estimateJsonBytes 转义感知（v3.0.9 审计）', () {
    int actualBytes(Map<String, dynamic> m) =>
        utf8.encode(const JsonEncoder().convert(m)).length;

    test('转义密集内容：估算 ≥ 实际（旧实现按原始字节计，低估约一半）', () {
      final heavy = {'note': '"' * 1000};
      final actual = actualBytes(heavy);
      // 旧实现：1 MB 纯引号估 ~1 MB，实际序列化 ~2 MB——叠加 L12 的 9 折
      // 预算仍可越过 32MB 上限，写出还原端必拒的备份。
      expect(DataIo.estimateJsonBytes(heavy), greaterThanOrEqualTo(actual),
          reason: 'N8：转义后估算不再低于实际');
      expect(DataIo.estimateJsonBytes(heavy), lessThanOrEqualTo(actual),
          reason: '估算紧贴实际（转义规则逐字符对齐）');
    });

    test('控制字符同样计入转义膨胀', () {
      final heavy = {'note': '\n' * 100};
      final actual = actualBytes(heavy); // 每个 \n 序列化为 2 字符
      expect(DataIo.estimateJsonBytes(heavy), actual);
    });

    test('无转义内容：估算与实际逐位相等（常规内容零回归）', () {
      final plain = {
        'a': 'b',
        'c': '中文备注',
        'n': 42,
        'list': ['x', 'y'],
      };
      expect(DataIo.estimateJsonBytes(plain), actualBytes(plain),
          reason: 'L12 的 9 折预算在此基础上继续有效');
    });
  });
}

class _FakePathProvider extends PathProviderPlatform {
  final String docsPath;
  _FakePathProvider(this.docsPath);
  @override
  Future<String?> getApplicationDocumentsPath() async => docsPath;
}

/// N9 测试注入：StringList 写抛错（模拟 SharedPreferences 落盘失败），
/// 其余读写委托给健康 store。`_store` 是活取的 static getter，替换
/// `SharedPreferencesStorePlatform.instance` 即对后续写入生效。
class _FailingStringListPrefsStore extends SharedPreferencesStorePlatform {
  final SharedPreferencesStorePlatform _delegate;
  _FailingStringListPrefsStore(this._delegate);
  @override
  Future<bool> remove(String key) => _delegate.remove(key);
  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (valueType == 'StringList') {
      throw Exception('N9 测试注入：prefs 写失败');
    }
    return _delegate.setValue(valueType, key, value);
  }
  @override
  Future<bool> clear() => _delegate.clear();
  @override
  Future<Map<String, Object>> getAll() => _delegate.getAll();
}
