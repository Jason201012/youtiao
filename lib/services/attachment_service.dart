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

  // ===== 安全与资源上限（P1-1 / P2-3 / P2-9）=====
  /// 单个附件最大体积：备份/还原时跳过超大附件，防止 OOM 或生成超大备份文件。
  static const int maxAttachmentBytes = 50 * 1024 * 1024; // 50 MB
  /// 单任务最多包含的附件数量：备份时超出部分跳过，避免备份无限膨胀。
  static const int maxAttachmentsPerTask = 20;
  /// 还原时整体附件反序列化体积上限：超过则停止继续还原，避免耗尽存储。
  static const int maxRestoreAttachmentsBytes = 200 * 1024 * 1024; // 200 MB
  /// 导入源文件大小上限：超过则拒绝落盘（防本地超大文件滥用）。
  static const int maxImportFileBytes = 200 * 1024 * 1024; // 200 MB
  /// 暂存目录残留的最大存活时长（超过则启动清理时删除）。
  static const Duration staleStagingMaxAge = Duration(hours: 24);

  /// 路径段白名单：仅允许字母数字、点、下划线、连字符；禁止空串、`.`、`..`，
  /// 以及任何含 `/`、`\` 或 `..` 的串——彻底杜绝路径穿越（CWE-22 / CWE-23）。
  /// taskId 与 fileName 均可能来自不可信备份文件，任何落盘/读取前必须先过此关。
  static bool _isSafeSegment(String s) {
    if (s.isEmpty || s.length > 128) return false;
    if (s == '.' || s == '..') return false;
    if (s.contains('..') || s.contains('/') || s.contains('\\')) return false;
    return RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(s);
  }

  /// 把经过白名单校验的文件名拼到目录内，返回绝对 [File]；并在拼装后断言结果
  /// 确实落在 [dir] 之内（双重防护，与 S8 canonicalPath 思路一致）。不安全则抛 [ArgumentError]。
  static File _safeFileFor(Directory dir, String fileName) {
    if (!_isSafeSegment(fileName)) {
      throw ArgumentError('非法附件文件名：$fileName');
    }
    final absDir = dir.absolute.path;
    final file = File('$absDir${Platform.pathSeparator}$fileName');
    final absFile = file.absolute.path;
    if (!absFile.startsWith('$absDir${Platform.pathSeparator}')) {
      throw ArgumentError('附件路径越过目录边界：$fileName');
    }
    return file;
  }

  /// 某任务的附件目录（若不存在则创建）。
  /// [taskId] 必须为白名单安全段（调用方传入的应是 DB 内可信 id；还原路径已先行净化）。
  static Future<Directory> dirFor(String taskId) async {
    if (!_isSafeSegment(taskId)) {
      throw ArgumentError('非法任务 id：$taskId');
    }
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

  /// P2-9：启动兜底清理。扫描 `_staging` 下各临时目录，删除修改时间超过
  /// [staleStagingMaxAge] 的残留（App 在编辑弹层中途被杀会留下未清理的暂存目录）。
  /// 调用方（main.dart 启动阶段）应包在 try/catch 内，失败不阻断启动。
  static Future<void> cleanupStaleStaging() async {
    try {
      final base = await _base();
      final staging =
          Directory('${base.path}/$_attachmentsDirName/$_stagingDirName');
      if (!await staging.exists()) return;
      final cutoff = DateTime.now().subtract(staleStagingMaxAge);
      await for (final e in staging.list()) {
        if (e is! Directory) continue;
        try {
          final stat = await e.stat();
          if (stat.modified.isBefore(cutoff)) {
            await e.delete(recursive: true);
          }
        } catch (_) {
          // 单目录清理失败跳过。
        }
      }
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
    // M1（v3.0.8 审计）：扩展名取自源文件名最后一个点之后，未过白名单——
    // 「报告.pdf（扫描版）」会产出 `.pdf（扫描版）`，下游 fileFor / collectBlobs /
    // restoreBlobs 全部拒绝该名字，文件已落盘却永久不可用（详情页点按抛
    /// ArgumentError 且无兜底）。此处与 [_isSafeSegment] 同口径净化，非法扩展名
    /// 回退到 mime 推断或留空。
    var ext = original.contains('.')
        ? '.${original.split('.').last}'
        : (mimeType != null ? _extFromMime(mimeType) : '');
    if (ext.length > 1 && !_isSafeSegment(ext.substring(1))) {
      ext = mimeType != null ? _extFromMime(mimeType) : '';
    }
    final stamp =
        '${DateTime.now().millisecondsSinceEpoch}_${_randomInt(1000, 9999)}';
    final name = '$stamp$ext';
    // P2-3：导入源文件大小上限，超出直接拒绝（防本地超大文件被当作附件落盘）。
    // 调用方（new_task_sheet）已用 try/catch 包裹，会向用户提示「添加附件失败」。
    final srcSize = await src.length();
    if (srcSize > maxImportFileBytes) {
      throw ArgumentError(
          '附件过大（上限 ${(maxImportFileBytes / (1024 * 1024)).round()} MB）');
    }
    final target = File('${parentDir.path}/$name');
    final tmp = File('${target.path}.tmp');
    // L-09：改为**流式复制**，内存占用降为单个 chunk。
    // 原实现 `writeAsBytes(await src.readAsBytes())` 会把上限内（200 MB）的附件
    // 一次性读进内存，低内存机型上足以 OOM。复制过程中再累计一次熔断，
    // 防止 stat 拿到的大小与实际字节流不一致（如来源是个管道 / 伪文件）。
    var copied = 0;
    IOSink? sink;
    try {
      sink = tmp.openWrite();
      await for (final chunk in src.openRead()) {
        copied += chunk.length;
        if (copied > maxImportFileBytes) {
          throw ArgumentError(
              '附件过大（上限 ${(maxImportFileBytes / (1024 * 1024)).round()} MB）');
        }
        sink.add(chunk);
      }
      await sink.flush();
      await sink.close();
      sink = null;
    } catch (e) {
      // 复制中断：关掉 sink 并清掉半截 .tmp，避免残留长期占用私有目录。
      try {
        await sink?.close();
      } catch (_) {}
      await _deleteQuietly(tmp);
      rethrow;
    }
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

  /// P1-11：系统分享接收的附件导入。原生侧已把 content URI 的二进制流复制进应用私有
  /// 缓存目录（[localPath]，离线、不联网），本方法把它二次复制进本次分享专用的暂存目录
  /// [sessionId]，返回规范化后的 [AttachmentRef]（文件名带毫秒时间戳前缀，落盘逻辑复用
  /// [importFile]）。复制完成后立即删除原生侧的临时缓存文件与空目录，避免私有缓存膨胀。
  /// 类型预检在原生侧完成，[type]/[mimeType] 由调用方按来源传入；大小预检复用 [maxImportFileBytes]
  /// （[importFile] 内部执行，超限直接抛 [ArgumentError]，由分享入口 try/catch 静默降级）。
  static Future<AttachmentRef> importSharedFile({
    required String localPath,
    required String sessionId,
    required AttachmentType type,
    String? mimeType,
    int? durationMs,
  }) async {
    final src = File(localPath);
    try {
      final dir = await stagingDir(sessionId);
      return await importFile(
        parentDir: dir,
        src: src,
        type: type,
        mimeType: mimeType,
        durationMs: durationMs,
      );
    } finally {
      // 无论导入成功与否，原生侧写入的临时缓存文件与空目录都要清理（读取即消费）。
      try {
        await src.delete();
      } catch (_) {}
      try {
        await src.parent.delete();
      } catch (_) {}
    }
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
  /// fileName 来自 DB（可信，由 [importFile] 生成），仍走白名单 + 前缀断言双重防护。
  static Future<File> fileFor(String taskId, AttachmentRef ref) async {
    final dir = await dirFor(taskId);
    return _safeFileFor(dir, ref.fileName);
  }

  /// 收集备份所需的附件二进制：遍历任务列表，把每个附件文件读为 base64 内联进
  /// 返回的 Map（key=taskId，value=附件列表 [{ref, data}]）。
  /// 全程本地、不联网；文件缺失的附件自动跳过，不阻断备份。
  ///
  /// P2-9：把「被跳过的条目数」附加在 Map 的 `__skipped` 键（不是真实 taskId），
  /// 调用方可读取后给用户提示；该键不影响正常的备份结构，导入侧
  /// [restoreBlobs] 会识别并忽略。
  static Future<Map<String, dynamic>> collectBlobs(List<Task> tasks) async {
    final out = <String, dynamic>{};
    var skippedSize = 0; // 超单附件上限被跳过
    var skippedCount = 0; // 超单任务上限 / 非法名 / 缺失文件被跳过
    for (final t in tasks) {
      if (t.attachments.isEmpty) continue;
      // 防御：DB 内的 taskId 应为白名单安全段，异常则跳过该任务避免污染备份。
      if (!_isSafeSegment(t.id)) {
        skippedCount += t.attachments.length;
        continue;
      }
      final items = <Map<String, dynamic>>[];
      var count = 0;
      for (final ref in t.attachments) {
        // P2-3：单任务附件数量上限，超出停止收集（避免备份无限膨胀）。
        if (count >= maxAttachmentsPerTask) {
          skippedCount++;
          continue;
        }
        if (!_isSafeSegment(ref.fileName)) {
          skippedCount++;
          continue; // 文件名非法跳过（正常不会发生）
        }
        try {
          final file = await fileFor(t.id, ref);
          if (!await file.exists()) {
            skippedCount++;
            continue;
          }
          final bytes = await file.readAsBytes();
          // P2-3：单附件体积上限，超出跳过（防 OOM / 生成超大备份），不阻断整体备份。
          if (bytes.length > maxAttachmentBytes) {
            skippedSize++;
            continue;
          }
          items.add({
            'ref': ref.toJson(),
            'data': base64.encode(bytes),
          });
          count++;
        } catch (_) {
          // 单文件读取失败不阻断整体备份。
          skippedCount++;
        }
      }
      if (items.isNotEmpty) out[t.id] = items;
    }
    // P2-9：写回统计（独立键，导入侧会被忽略）。
    out['__skipped'] = {
      'oversize': skippedSize,
      'missingOrInvalid': skippedCount,
    };
    return out;
  }

  /// 从备份还原附件二进制：写入 `attachments/<taskId>/<fileName>`。
  /// [data] 为 [collectBlobs] 产出的结构（来自不可信备份文件）。
  /// 任何段非法 / 超体积 / 超数量都直接跳过或停止，绝不抛、绝不越界落盘。P1-1 / P2-3。
  ///
  /// P2-9：跳过条目计数（oversize / missing / 非法名等）累加到 [stats]，调用方
  /// 可在恢复完成后展示给用户。`__skipped` 键（collectBlobs 写入的统计段）会
  /// 被识别并跳过——避免被当作真实 taskId 处理。
  static Future<RestoreBlobsStats> restoreBlobs(Map<String, dynamic>? data) async {
    final stats = RestoreBlobsStats();
    if (data == null) return stats;
    var totalBytes = 0;
    for (final entry in data.entries) {
      final taskId = entry.key;
      // P2-9：忽略统计段。
      if (taskId == '__skipped') continue;
      final list = entry.value;
      if (list is! List) continue;
      // P1-1：taskId 来自不可信备份，先做白名单净化；非法直接跳过该任务。
      if (!_isSafeSegment(taskId)) {
        stats.skipped++;
        continue;
      }
      final dir = await dirFor(taskId);
      var count = 0;
      for (final item in list) {
        if (item is! Map) {
          stats.skipped++;
          continue;
        }
        if (count >= maxAttachmentsPerTask) {
          stats.skipped++;
          continue; // P2-3：单任务数量上限
        }
        final refJson = item['ref'];
        final dataB64 = item['data'];
        if (refJson is! Map || dataB64 is! String) {
          stats.skipped++;
          continue;
        }
        try {
          final ref = AttachmentRef.fromJson(Map<String, dynamic>.from(refJson));
          // P1-1：fileName 来自不可信备份，净化 + 前缀断言（不安全跳过，不落盘）。
          if (!_isSafeSegment(ref.fileName)) {
            stats.skipped++;
            continue;
          }
          final bytes = base64.decode(dataB64);
          // P2-3：单附件体积上限，超出跳过（防存储被恶意备份耗尽）。
          if (bytes.length > maxAttachmentBytes) {
            stats.oversize++;
            count++;
            continue;
          }
          totalBytes += bytes.length;
          // P2-3：整体反序列化体积上限，超出停止后续还原（避免耗尽存储）。
          if (totalBytes > maxRestoreAttachmentsBytes) {
            stats.truncated = true;
            break;
          }
          final file = _safeFileFor(dir, ref.fileName);
          final tmp = File('${file.path}.tmp');
          await tmp.writeAsBytes(bytes, flush: true);
          await tmp.rename(file.path);
          count++;
        } catch (_) {
          // 单文件还原失败跳过，不破坏其余附件 / 任务。
          stats.skipped++;
        }
      }
    }
    return stats;
  }

/// P0-2：全量扫描附件目录，返回每个 taskId 目录下的全部文件清单。
/// key 为 taskId；`_staging` 下的 session 残留以 taskId='' 单列。
/// 纯文件 IO，不读取任务元数据；大目录分块异步遍历，避免卡 UI。
/// 沿用 [_isSafeSegment] 白名单防护：非白名单目录直接跳过，不越界读取。
static Future<Map<String, List<AttachmentFileEntry>>> scanAll() async {
    final base = await _base();
    final root = Directory('${base.path}/$_attachmentsDirName');
    final map = <String, List<AttachmentFileEntry>>{};
    if (!await root.exists()) return map;
    await for (final e in root.list()) {
      if (e is! Directory) continue;
      final name = e.path.split(Platform.pathSeparator).last;
      if (name == _stagingDirName) {
        // staging 残留：每个 session 一个子目录（或极少数直接散落的文件）。
        final stagingEntries = <AttachmentFileEntry>[];
        await for (final sub in (e as Directory).list()) {
          final sessionName = sub.path.split(Platform.pathSeparator).last;
          if (sub is Directory) {
            await for (final f in sub.list()) {
              if (f is File) {
                final stat = await f.stat();
                stagingEntries.add(AttachmentFileEntry(
                  taskId: '',
                  fileName:
                      '$sessionName/${f.path.split(Platform.pathSeparator).last}',
                  sizeBytes: stat.size,
                  modifiedAt: stat.modified,
                  file: f,
                ));
              }
            }
          } else if (sub is File) {
            final stat = await sub.stat();
            stagingEntries.add(AttachmentFileEntry(
              taskId: '',
              fileName: sessionName,
              sizeBytes: stat.size,
              modifiedAt: stat.modified,
              file: sub,
            ));
          }
        }
        if (stagingEntries.isNotEmpty) map[''] = stagingEntries;
      } else {
        if (!_isSafeSegment(name)) continue; // 防御：非白名单目录跳过
        final entries = <AttachmentFileEntry>[];
        await for (final f in (e as Directory).list()) {
          if (f is File) {
            final stat = await f.stat();
            entries.add(AttachmentFileEntry(
              taskId: name,
              fileName: f.path.split(Platform.pathSeparator).last,
              sizeBytes: stat.size,
              modifiedAt: stat.modified,
              file: f,
            ));
          }
        }
        map[name] = entries;
      }
    }
    return map;
  }

  /// P0-2：删除单个附件的实体文件（任务附件目录内，经白名单 + 前缀断言防护）。
  /// 仅删除文件，不更新任务元数据——调用方需同步 [TaskProvider.updateTask] 落库。
  static Future<void> deleteAttachmentFile(String taskId, String fileName) async {
    try {
      final dir = await dirFor(taskId);
      final file = _safeFileFor(dir, fileName);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 删除失败（文件已不存在等）不阻断主流程。
    }
  }

  /// 计算某目录下的总字节数（递归），用于预告「清理无主文件」可释放的空间。
  static Future<int> _dirSize(Directory dir) async {
    var total = 0;
    try {
      await for (final e in dir.list(recursive: true)) {
        if (e is File) total += await e.length();
      }
    } catch (_) {}
    return total;
  }

  /// 清理计划：收集需要删除的孤儿文件、整目录孤儿、过期 staging 残留（不实际删除）。
  /// [tasks] 应传入**全部**仍保有元数据的任务（含回收站），避免把「暂存于回收站、
  /// 尚未永久删除」的任务附件误判为孤儿而删除。
  static Future<_OrphanPlan> _planOrphans(List<Task> tasks) async {
    final known = <String, Set<String>>{};
    for (final t in tasks) {
      // 安全（P2-A）：同 id 时取**并集**而非覆盖。早期写法 `known[t.id] = {...}` 会让
      // 后一条任务顶掉前一条的附件集合，使较早任务的附件被误判为无主文件——用户执行
      // 一次「清理无主文件」就会误删真实附件。
      known.putIfAbsent(t.id, () => <String>{})
          .addAll(t.attachments.map((a) => a.fileName));
    }
    final plan = _OrphanPlan();
    final base = await _base();
    final root = Directory('${base.path}/$_attachmentsDirName');
    if (!await root.exists()) return plan;
    await for (final e in root.list()) {
      if (e is! Directory) continue;
      final name = e.path.split(Platform.pathSeparator).last;
      if (name == _stagingDirName) {
        // 删除超过 [staleStagingMaxAge] 的 session 残留目录。
        await for (final sub in (e as Directory).list()) {
          if (sub is! Directory) continue;
          try {
            final stat = await sub.stat();
            if (stat.modified
                .isBefore(DateTime.now().subtract(staleStagingMaxAge))) {
              plan.staleStaging.add(sub);
              plan.bytes += await _dirSize(sub);
            }
          } catch (_) {}
        }
      } else if (_isSafeSegment(name)) {
        final keep = known[name];
        if (keep == null) {
          // 整个任务目录已无对应元数据（任务被永久删除但目录残留）→ 整目录清理。
          try {
            plan.bytes += await _dirSize(e as Directory);
            plan.orphanDirs.add(e as Directory);
          } catch (_) {}
        } else {
          await for (final f in (e as Directory).list()) {
            if (f is File &&
                !keep.contains(f.path.split(Platform.pathSeparator).last)) {
              plan.files.add(f);
              try {
                plan.bytes += await f.length();
              } catch (_) {}
            }
          }
        }
      }
    }
    return plan;
  }

  /// P0-2：执行「清理无主文件」——删除磁盘上存在、但不在任何任务 attachments 元数据中的
  /// 文件，以及 `_staging` 下超过 [staleStagingMaxAge] 的残留 session 目录。
  /// 返回释放的总字节数。删除沿用私有目录内的安全删除，绝不触碰外部存储。
  static Future<int> deleteOrphans(List<Task> tasks) async {
    final plan = await _planOrphans(tasks);
    for (final f in plan.files) {
      try {
        await f.delete();
      } catch (_) {}
    }
    for (final d in plan.orphanDirs) {
      try {
        await d.delete(recursive: true);
      } catch (_) {}
    }
    for (final d in plan.staleStaging) {
      try {
        await d.delete(recursive: true);
      } catch (_) {}
    }
    return plan.bytes;
  }

  /// P0-2：预览「清理无主文件」可释放的字节数（不实际删除，供删除前确认展示）。
  static Future<int> previewOrphansBytes(List<Task> tasks) async {
    final plan = await _planOrphans(tasks);
    return plan.bytes;
  }

  /// P2-2（v3.0.2 审计）：启动兜底——只清理「整目录孤儿」并返回删除的目录数。
  ///
  /// 背景：原生午夜路径（MidnightResetReceiver.cleanupTrashSqlite）自 v2.8.6 起
  /// 才接线 cleanupExpiredTrashResources 删附件目录；此前（或该路径再漏接时）被
  /// 原生删掉 trash 记录的任务，其附件目录在 Dart 侧已无任何记录可见，正常清理
  /// 路径永久错过、无限累积。本方法按「目录名不在 [tasks]（含回收站）中」判定
  /// 整目录孤儿并递归删除，防同类漏接再次沉淀。
  ///
  /// 目录层级口径（防再次漂移）：与全文件访问器一致——经 [_base()]
  /// （`<docs>/attachments`）再拼一段 [_attachmentsDirName]，即扫描
  /// **`<docs>/attachments/attachments/`**（双层嵌套，自 v2.6.9 起从未变过）。
  ///
  /// 与 [deleteOrphans] 的语义边界：这里**只删整目录孤儿**（任务记录已不存在，
  /// 删了绝无误伤）；「任务还在、元数据缺文件」的文件级无主文件仍属「清理无主
  /// 文件」的显式语义，须用户在设置页确认后执行，不在启动时静默处理。
  /// `_staging` 残留由既有链路（[staleStagingMaxAge]）管理，此处不碰。
  /// 全部异常吞掉（启动兜底绝不阻断主流程），失败项留给手动清理兜底。
  static Future<int> deleteOrphanTaskDirs(List<Task> tasks) async {
    var removed = 0;
    try {
      final known = tasks.map((t) => t.id).toSet();
      final base = await _base();
      final root = Directory('${base.path}/$_attachmentsDirName');
      if (!await root.exists()) return 0;
      await for (final e in root.list()) {
        if (e is! Directory) continue;
        final name = e.path.split(Platform.pathSeparator).last;
        if (name == _stagingDirName) continue; // staging 归既有链路管
        if (!_isSafeSegment(name)) continue; // 防御：非白名单目录不动
        if (known.contains(name)) continue; // 任务记录仍在（含回收站）→ 保留
        try {
          await e.delete(recursive: true);
          removed++;
        } catch (_) {
          // 单目录删除失败不阻断其余扫描。
        }
      }
    } catch (_) {
      // path_provider 不可用 / 目录枚举失败：启动兜底静默放弃。
    }
    return removed;
  }

  /// 按 MIME 推导一个兜底扩展名（仅当源文件无扩展名时使用）。
  static String _extFromMime(String mime) {
    if (mime.startsWith('image/')) return '.${mime.split('/').last}';
    if (mime.startsWith('audio/')) return '.m4a';
    if (mime.startsWith('video/')) return '.mp4';
    return '';
  }

  /// 静默删除：清理半截 .tmp / 失效缓存时用，失败不影响主流程。
  static Future<void> _deleteQuietly(FileSystemEntity e) async {
    try {
      if (await e.exists()) await e.delete(recursive: true);
    } catch (_) {
      // 忽略：清理失败不是致命错误
    }
  }

  static int _randomInt(int min, int max) =>
      min + Random().nextInt(max - min + 1);
}

/// P2-9：附件恢复统计。
///
/// 区分三类跳过原因：
/// - `oversize`：单附件超过 [maxAttachmentBytes]，仅跳过该条、不算入整批；
/// - `skipped`：非法 / 缺失 / 解析失败 等其它原因；
/// - `truncated`：整体反序列化体积超过 [maxRestoreAttachmentsBytes]，触发了整批提前终止。
class RestoreBlobsStats {
  int oversize = 0;
  int skipped = 0;
  bool truncated = false;
  /// P3-6（v3.0.8 审计）：任务侧备份恢复的整体落盘结果——`restoreFromJson`
  /// 此前 `await _persist()` 但丢弃结果，UI 只消费附件统计，「已恢复」可能在
  /// 任务未落库时上报（重启后恢复条目全部蒸发）。由 TaskProvider.restoreFromJson
  /// 写入，backup_sheet 并入恢复结果的 failures 通道。
  bool persisted = true;
  int get total => oversize + skipped;
  bool get hasSkipped => total > 0 || truncated;

  /// 给 UI 用的简短文案（中文）。无跳过时返回 null。
  String? summary() {
    if (!hasSkipped) return null;
    final parts = <String>[];
    if (oversize > 0) parts.add('$oversize 个附件因单文件过大被跳过');
    if (skipped > 0) parts.add('$skipped 个附件因缺失 / 非法被跳过');
    if (truncated) parts.add('剩余附件因备份过大被截断');
    return '附件恢复：${parts.join('；')}';
  }
}

/// P2-9：附件收集统计（collectBlobs 返回的 Map 中 `__skipped` 键结构）。
class CollectBlobsStats {
  final int oversize;
  final int missingOrInvalid;
  const CollectBlobsStats({this.oversize = 0, this.missingOrInvalid = 0});
  bool get hasSkipped => oversize > 0 || missingOrInvalid > 0;
  String? summary() {
    if (!hasSkipped) return null;
    final parts = <String>[];
    if (oversize > 0) parts.add('$oversize 个附件因单文件过大未打包');
    if (missingOrInvalid > 0) {
      parts.add('$missingOrInvalid 个附件因缺失 / 非法未打包');
    }
    return parts.join('；');
  }
}

/// P2-9：从 collectBlobs 的 Map 中读出 [CollectBlobsStats]，无则返回零值。
CollectBlobsStats readCollectStats(Map<String, dynamic> blobs) {
  final raw = blobs['__skipped'];
  if (raw is! Map) return const CollectBlobsStats();
  int n(dynamic v) => (v is num) ? v.toInt() : 0;
  return CollectBlobsStats(
    oversize: n(raw['oversize']),
    missingOrInvalid: n(raw['missingOrInvalid']),
  );
}

/// 扫描得到的单个附件实体（仅文件 IO 信息，不含任务元数据）。
/// [taskId] 为 '' 时表示 `_staging` 暂存残留，而非某个具体任务。
class AttachmentFileEntry {
  final String taskId;
  final String fileName;
  final int sizeBytes;
  final DateTime modifiedAt;
  final File file;
  const AttachmentFileEntry({
    required this.taskId,
    required this.fileName,
    required this.sizeBytes,
    required this.modifiedAt,
    required this.file,
  });
}

/// 「清理无主文件」的内部计划：待删的文件级孤儿、整目录孤儿、过期 staging 残留，
/// 以及预估可释放字节数。由 [AttachmentService._planOrphans] 填充，
/// [AttachmentService.deleteOrphans] / [AttachmentService.previewOrphansBytes] 复用。
class _OrphanPlan {
  final List<File> files = [];
  final List<Directory> orphanDirs = [];
  final List<Directory> staleStaging = [];
  int bytes = 0;
}
