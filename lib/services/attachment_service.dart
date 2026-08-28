import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';
import 'package:todolist/models/attachment.dart';
import 'package:todolist/models/task.dart';

/// 附件文件管理（全程本地、不联网）。
///
/// 所有附件二进制存于 App 私有文档目录：
///   - 正式：`getApplicationDocumentsDirectory()/attachments/<taskId>/<fileName>`
///   - 暂存：`.../attachments/_staging/<sessionId>/<fileName>`
///     （新建任务、真实 id 尚未分配时先用会话 id 占位，保存后再 [promoteStaging] 提升）
///
/// 仅管理文件落盘与读取；附件元数据（[AttachmentRef]）随 [Task] 一同存于 SQLite。
/// 备份时由 [collectBlobs] 把二进制读为 base64 内联进加密信封，还原时由 [restoreBlobs]
/// 写回正式目录——整个链路不触发任何网络请求。
class AttachmentService {
  static const String _attachmentsDirName = 'attachments';
  static const String _stagingDirName = '_staging';

  /// 某任务的附件目录（若不存在则创建）。
  static Future<Directory> dirFor(String taskId) async {
    final base = await _base();
    final dir = Directory('${base.path}/$_attachmentsDirName/$taskId');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// 新建任务的暂存目录（id 尚未分配，先用会话 id 占位）。
  static Future<Directory> stagingDir(String sessionId) async {
    final base = await _base();
    final dir = Directory(
        '${base.path}/$_attachmentsDirName/$_stagingDirName/$sessionId');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// 删除暂存目录（新建任务取消 / 保存后残留清理用）。
  static Future<void> removeStaging(String sessionId) async {
    try {
      final base = await _base();
      final dir = Directory(
          '${base.path}/$_attachmentsDirName/$_stagingDirName/$sessionId');
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      // 清理失败不阻断主流程。
    }
  }

  static Future<Directory> _base() async {
    final dir = await getApplicationDocumentsDirectory();
    final base = Directory('${dir.path}/$_attachmentsDirName');
    if (!await base.exists()) await base.create(recursive: true);
    return base;
  }

  /// 把用户选中的源文件复制进目标目录，返回其 [AttachmentRef] 元数据。
  ///
  /// [parentDir] 为已创建的目标目录（正式或暂存）；[type] 由调用方按来源判定；
  /// 文件名带毫秒时间戳前缀以避免同目录内重名覆盖。复制采用「先写 .tmp 再 rename」
  /// 原子策略（与 [DataIo] 一致），避免写入中途打断产生半截文件。
  static Future<AttachmentRef> importFile({
    required Directory parentDir,
    required File src,
    required AttachmentType type,
    String? mimeType,
    int? durationMs,
  }) async {
    final original = src.path.split(Platform.pathSeparator).last;
    final ext = original.contains('.')
        ? '.${original.split('.').last}'
        : (mimeType != null ? _extFromMime(mimeType) : '');
    final stamp =
        '${DateTime.now().millisecondsSinceEpoch}_${_randomInt(1000, 9999)}';
    final name = '$stamp$ext';
    final target = File('${parentDir.path}/$name');
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsBytes(await src.readAsBytes(), flush: true);
    await tmp.rename(target.path); // 同文件系统内原子覆盖
    final size = await target.length();
    return AttachmentRef(
      id: stamp,
      type: type,
      fileName: name,
      sizeBytes: size,
      mimeType: mimeType,
      durationMs: durationMs,
      createdAt: DateTime.now(),
    );
  }

  /// 删除某任务的附件目录（彻底删除任务 / 清空回收站时调用）。
  static Future<void> removeDir(String taskId) async {
    try {
      final base = await _base();
      final dir = Directory('${base.path}/$_attachmentsDirName/$taskId');
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      // 清理失败不应阻断删除主流程（下次启动仍可忽略）。
    }
  }

  /// 编辑模式取消保存时调用：删除正式目录下、不在 [keep] 集合中的文件，
  /// 清理本次会话新增但未落库的附件孤儿（[keep] 为进入编辑前的附件文件名集合）。
  static Future<void> pruneOrphans(String taskId, Set<String> keep) async {
    try {
      final dir = await dirFor(taskId);
      if (!await dir.exists()) return;
      await for (final e in dir.list()) {
        if (e is File) {
          final name = e.path.split(Platform.pathSeparator).last;
          if (!keep.contains(name)) {
            try {
              await e.delete();
            } catch (_) {
              // 单文件删除失败跳过，不阻断整体清理。
            }
          }
        }
      }
    } catch (_) {
      // 清理失败不阻断主流程。
    }
  }

  /// 把暂存目录提升为正式目录（新建任务拿到真实 id 后调用）。
  ///
  /// 极端情况下正式目录已存在则并入而非覆盖，避免丢失已有附件。
  static Future<void> promoteStaging(String sessionId, String taskId) async {
    final base = await _base();
    final staging = Directory(
        '${base.path}/$_attachmentsDirName/$_stagingDirName/$sessionId');
    if (!await staging.exists()) return;
    final dest = Directory('${base.path}/$_attachmentsDirName/$taskId');
    if (await dest.exists()) {
      await for (final e in staging.list()) {
        if (e is File) {
          final name = e.path.split(Platform.pathSeparator).last;
          await e.rename('${dest.path}/$name');
        }
      }
      await staging.delete(recursive: true);
    } else {
      await staging.rename(dest.path);
    }
  }

  /// 附件实体文件（运行时由 taskId + fileName 拼出，不存绝对路径）。
  static Future<File> fileFor(String taskId, AttachmentRef ref) async {
    final dir = await dirFor(taskId);
    return File('${dir.path}/${ref.fileName}');
  }

  /// 收集备份所需的附件二进制：遍历任务列表，把每个附件文件读为 base64 内联进
  /// 返回的 Map（key=taskId，value=附件列表 [{ref, data}]）。
  /// 全程本地、不联网；文件缺失的附件自动跳过，不阻断备份。
  static Future<Map<String, dynamic>> collectBlobs(List<Task> tasks) async {
    final out = <String, dynamic>{};
    for (final t in tasks) {
      if (t.attachments.isEmpty) continue;
      final items = <Map<String, dynamic>>[];
      for (final ref in t.attachments) {
        try {
          final file = await fileFor(t.id, ref);
          if (!await file.exists()) continue;
          final bytes = await file.readAsBytes();
          items.add({
            'ref': ref.toJson(),
            'data': base64.encode(bytes),
          });
        } catch (_) {
          // 单文件读取失败不阻断整体备份。
        }
      }
      if (items.isNotEmpty) out[t.id] = items;
    }
    return out;
  }

  /// 从备份还原附件二进制：写入 `attachments/<taskId>/<fileName>`。
  /// [data] 为 [collectBlobs] 产出的结构；缺省 / 非法直接跳过，不抛。
  static Future<void> restoreBlobs(Map<String, dynamic>? data) async {
    if (data == null) return;
    for (final entry in data.entries) {
      final taskId = entry.key;
      final list = entry.value;
      if (list is! List) continue;
      final dir = await dirFor(taskId);
      for (final item in list) {
        if (item is! Map) continue;
        final refJson = item['ref'];
        final dataB64 = item['data'];
        if (refJson is! Map || dataB64 is! String) continue;
        try {
          final ref = AttachmentRef.fromJson(Map<String, dynamic>.from(refJson));
          final bytes = base64.decode(dataB64);
          final file = File('${dir.path}/${ref.fileName}');
          final tmp = File('${file.path}.tmp');
          await tmp.writeAsBytes(bytes, flush: true);
          await tmp.rename(file.path);
        } catch (_) {
          // 单文件还原失败跳过，不破坏其余附件 / 任务。
        }
      }
    }
  }

  /// 按 MIME 推导一个兜底扩展名（仅当源文件无扩展名时使用）。
  static String _extFromMime(String mime) {
    if (mime.startsWith('image/')) return '.${mime.split('/').last}';
    if (mime.startsWith('audio/')) return '.m4a';
    if (mime.startsWith('video/')) return '.mp4';
    return '';
  }

  static int _randomInt(int min, int max) =>
      min + Random().nextInt(max - min + 1);
}
