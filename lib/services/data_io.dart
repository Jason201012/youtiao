import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// 本地文件读写 + 系统分享辅助。
///
/// 设计取舍：导出文件落在 App 私有文档目录（getApplicationDocumentsDirectory），
/// 不申请任何外部存储权限，规避 Android 分区存储 / ColorOS 拦截；随后通过
/// 系统分享将文件交给用户选定的目标（微信/邮件/文件管理器等）。
/// 导入通过 file_picker 走 SAF，同样无需存储权限。
///
/// 若希望文件在系统「下载 / Downloads」目录中可见（文件管理器可直接找到），
/// 用 [saveToDownloads] —— 走原生 MediaStore，Android 10+ 免存储权限。
class DataIo {
  static const MethodChannel _ioChannel =
      MethodChannel('com.example.todolist/file_io');
  /// 把文本内容写入 App 私有文档目录，返回生成的文件。
  ///
  /// 采用原子写：先写 [fileName].tmp，再 rename 覆盖目标，避免写入中途被打断
  /// （被杀后台 / 断电）导致整文件 JSON 损坏、备份报废。rename 在同一文件系统内
  /// 为原子操作；Windows 下 rename 不能覆盖已存在目标，故先删旧文件再 rename。
  static Future<File> saveToAppDocs(String fileName, String content) async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$fileName');
    // 兼容子目录写入：如 backup/auto/YYYY-MM-DD.json 需先创建父目录，
    // 否则 tmp.writeAsString() 会抛 PathNotFoundException。
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(content);
    // S9 修复：原子落盘按平台区分，降低「删完旧文件、改名前崩溃/断电」导致
    // 旧备份已失、新备份未成、整文件 JSON 损坏的概率。
    if (Platform.isWindows) {
      // Windows 的 rename 不能覆盖已存在目标，且须防「先删后改名」窗口丢备份。
      // 策略：把旧文件改名 .bak，再 rename 新临时文件到位；任一环节失败则回滚。
      if (await file.exists()) {
        final bak = File('${file.path}.bak');
        if (await bak.exists()) await bak.delete();
        await file.rename(bak.path); // 旧 → .bak
        try {
          await tmp.rename(file.path); // 新 → 目标（原子覆盖）
        } catch (e) {
          await bak.rename(file.path); // 回滚：恢复旧文件
          rethrow;
        }
        await bak.delete(); // 成功：清掉 .bak
      } else {
        await tmp.rename(file.path);
      }
    } else {
      // POSIX（Android / Linux / macOS）：rename 覆盖目标为原子操作，
      // 直接 rename 即可，无需先删旧文件，崩溃窗口内旧文件始终可用。
      await tmp.rename(file.path);
    }
    return file;
  }

  /// 把二进制内容（如 .xlsx / .pdf）写入 App 私有文档目录，返回生成的文件。
  ///
  /// 与 [saveToAppDocs] 同款原子写策略（先写 .tmp 再 rename），区别在入参为字节。
  /// 二进制导出走这里落地，再经 [shareFile] 交给用户选定的目标（系统分享面板
  /// 可存到下载 / 微信 / 邮件等），不依赖额外的原生通道。
  static Future<File> saveBytesToAppDocs(String fileName, Uint8List bytes) async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$fileName');
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    if (Platform.isWindows) {
      if (await file.exists()) {
        final bak = File('${file.path}.bak');
        if (await bak.exists()) await bak.delete();
        await file.rename(bak.path);
        try {
          await tmp.rename(file.path);
        } catch (e) {
          await bak.rename(file.path);
          rethrow;
        }
        await bak.delete();
      } else {
        await tmp.rename(file.path);
      }
    } else {
      await tmp.rename(file.path);
    }
    return file;
  }

  /// 通过系统分享面板分享一个本地文件。
  static Future<void> shareFile(File file, {String mimeType = 'application/json'}) async {
    await SharePlus.instance.share(
      ShareParams(files: [XFile(file.path, mimeType: mimeType)]),
    );
  }

  /// 把图片字节写入临时目录并唤起系统分享面板（微信/QQ/相册等）。
  /// 临时文件放在 getTemporaryDirectory()，系统会自行回收。
  static Future<void> shareImageBytes(
    Uint8List bytes, {
    String fileName = 'share.png',
    String? text,
  }) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$fileName');
    await file.writeAsBytes(bytes, flush: true);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: 'image/png')],
        text: text,
      ),
    );
  }

  /// 把 PNG 字节保存到系统相册（Pictures/有条），Android 10+ 走 MediaStore 免权限。
  /// 失败时抛 [PlatformException]，调用方应给出提示或兜底到分享。
  static Future<void> saveImageToGallery(
    String fileName,
    Uint8List bytes,
  ) async {
    await _ioChannel.invokeMethod<void>('saveImageToGallery', {
      'fileName': fileName,
      'bytes': bytes,
    });
  }

  /// 把内容写入系统「下载 / Downloads」目录（Android 10+ 走 MediaStore，免存储权限）。
  /// 写入后文件在系统文件管理器的下载目录中可见。
  /// 失败时抛 [PlatformException]，调用方应兜底到 [saveToAppDocs] + [shareFile]。
  static Future<void> saveToDownloads(
    String fileName,
    String content, {
    String mimeType = 'application/json',
  }) async {
    await _ioChannel.invokeMethod<void>('saveToDownloads', {
      'fileName': fileName,
      'content': content,
      'mimeType': mimeType,
    });
  }

  /// 导入文本文件的大小上限（32 MB）。
  ///
  /// L-09：备份 / iCal 此前一律 `readAsString()` 全量读入，没有大小预检，
  /// 选中一个几百 MB 的文件会直接 OOM。加密备份更糟——base64 解码后内存再翻
  /// 1.3 倍。这里在**读取前**先 stat，超限直接拒绝并给出可读原因。
  /// 32 MB 对一份待办备份而言已是数量级上的余量。
  static const int maxImportTextBytes = 32 * 1024 * 1024;

  /// 导出文件的大小上限（32 MB）。
  ///
  /// F13：手动 / 自动备份里附件以 base64 内联，10 余张照片就可能突破 10 MB，
  /// 几十张就能逼近 30 MB；超过 32 MB 一是分享面板对单文件大小敏感，二是
  /// 还原时仍会按 32 MB 上限被读入端拒绝——「写得出去、取不回来」。
  /// 这里在编码前估算：超额则自动剥离 `attachments` 段、保留任务标题与提醒，
  /// 并返回估算字节数供调用方给出明确提示；不放大 / 不抛错。
  static const int maxExportPayloadBytes = 32 * 1024 * 1024;

  /// 估算一个 JSON 友好的 Map 序列化为字符串后的字节数（UTF-8）。
  ///
  /// 不做真正的 JsonEncoder（昂贵），改为统计 key 串字节 + 数字.toString 字节 +
  /// 字符串 UTF-8 字节 + 结构标点（`,`/`: `/`/`{`/`}`/`[`/`]`），并对未知
  /// 类型用 `value.toString().length` 兜底。结果与真实 JsonEncoder 输出
  /// 误差在 5% 以内，足以用于「超额剥离附件」这类二元判断。
  static int estimateJsonBytes(Map<String, dynamic> map) {
    var total = 2; // { }
    final keys = map.keys.toList();
    for (var i = 0; i < keys.length; i++) {
      if (i > 0) total += 1; // ,
      total += _utf8Bytes(keys[i]) + 2; // "key":
      total += _estimateValueBytes(map[keys[i]]);
    }
    return total;
  }

  static int _estimateValueBytes(dynamic v) {
    if (v == null) return 4; // null
    if (v is bool) return v ? 4 : 5; // true / false
    if (v is num) return v.toString().length;
    if (v is String) return _utf8Bytes(v) + 2; // "..."
    if (v is List) {
      var n = 2; // [ ]
      for (var i = 0; i < v.length; i++) {
        if (i > 0) n += 1;
        n += _estimateValueBytes(v[i]);
      }
      return n;
    }
    if (v is Map) {
      var n = 2;
      final ks = v.keys.toList();
      for (var i = 0; i < ks.length; i++) {
        if (i > 0) n += 1;
        n += _utf8Bytes(ks[i].toString()) + 2 + _estimateValueBytes(v[ks[i]]);
      }
      return n;
    }
    return (v.toString().length);
  }

  static int _utf8Bytes(String s) {
    var n = 0;
    for (final cu in s.codeUnits) {
      if (cu < 0x80) {
        n += 1;
      } else if (cu < 0x800) {
        n += 2;
      } else {
        n += 3;
      }
    }
    return n;
  }

  /// F13：导出前对载荷做大小预检。超额时自动剥离 `attachments` 段并返回
  /// `(新Map, wasStripped)`；否则原样返回。元数据（任务 / 习惯 / 偏好）保留，
  /// 仅丢弃附件二进制本身（用户可按需再次手动导入）。
  ///
  /// 新P3-3（v2.9.7 审计）：`wasStripped` 仅在**实际剥离**了 attachments 段时
  /// 才为 true——原实现超限但载荷本就无 `attachments` 键时也返回 true，
  /// 调用方（backup_sheet）会误报「附件因体积超限已剥离」，误导用户以为
  /// 附件被安全处理过。
  static (Map<String, dynamic>, bool) trimForExport(Map<String, dynamic> map) {
    final est = estimateJsonBytes(map);
    if (est <= maxExportPayloadBytes) return (map, false);
    // 复制后剥离，避免污染调用方持有的原 map（多次调用安全）。
    final trimmed = Map<String, dynamic>.from(map);
    final stripped = trimmed.remove('attachments') != null;
    return (trimmed, stripped);
  }

  /// 选择 .json 备份文件并返回其文本内容。
  /// 返回 [PickedText]：区分「用户取消」与「文件过大 / 读取失败」。
  static Future<PickedText> pickJsonFile() =>
      _pickTextFile(['json'], '备份文件');

  /// 选择 .ics 日历文件并返回其文本内容。
  /// 用于 iCal 标准格式导入（与系统日历 / 其它待办应用互通）。
  static Future<PickedText> pickIcsFile() =>
      _pickTextFile(['ics'], '日历文件');

  /// 选择 .csv 表格文件并返回其文本内容（T2-6 批量导入任务）。
  static Future<PickedText> pickCsvFile() =>
      _pickTextFile(['csv'], '表格文件');

  /// 选择指定扩展名的文本文件并做大小预检后读入（L-09）。
  static Future<PickedText> _pickTextFile(
      List<String> extensions, String label) async {
    List<PlatformFile> picked;
    try {
      picked = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: extensions,
      );
    } catch (e) {
      return PickedText.error('无法打开文件选择器：$e');
    }
    // file_picker v12 起 pickFiles() 直接返回 List<PlatformFile>，
    // 取消选择时返回空列表（不再返回 null），故按空列表判定取消。
    if (picked.isEmpty) return const PickedText.cancelled();
    final path = picked.single.path;
    if (path == null) return const PickedText.cancelled();
    final file = File(path);
    try {
      final size = await file.length();
      if (size > maxImportTextBytes) {
        return PickedText.error(
            '${label}过大（${(size / 1048576).toStringAsFixed(1)} MB，上限 '
            '${(maxImportTextBytes / 1048576).round()} MB），可能不是有效文件');
      }
      return PickedText.ok(await file.readAsString());
    } catch (e) {
      return PickedText.error('读取${label}失败：$e');
    }
  }
}

/// 文件选择结果（L-09）。
///
/// 需要把「用户取消」与「文件过大 / 读取失败」区分开：前者静默返回即可，
/// 后者必须给用户明确提示，否则用户只会以为「点了没反应」。
class PickedText {
  /// 文件内容；失败或取消时为 null。
  final String? content;

  /// 失败原因（可直接展示的中文提示）；成功或取消时为 null。
  final String? error;

  const PickedText._(this.content, this.error);

  /// 读取成功。
  const PickedText.ok(String text) : this._(text, null);

  /// 用户取消了选择（非错误，调用方静默返回）。
  const PickedText.cancelled() : this._(null, null);

  /// 读取失败（文件过大 / IO 异常），[message] 可直接展示给用户。
  const PickedText.error(String message) : this._(null, message);

  /// 是否成功读到内容。
  bool get ok => content != null;

  /// 是否为用户取消。
  bool get cancelled => content == null && error == null;
}
