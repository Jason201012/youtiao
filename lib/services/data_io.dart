import 'dart:io';
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
    if (await file.exists()) {
      await file.delete();
    }
    await tmp.rename(file.path);
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

  /// 选择 .json 备份文件并返回其文本内容；用户取消选择返回 null。
  static Future<String?> pickJsonFile() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    // file_picker v12 起 pickFiles() 直接返回 List<PlatformFile>，
    // 取消选择时返回空列表（不再返回 null），故按空列表判定取消。
    if (result.isEmpty) return null;
    final path = result.single.path;
    if (path == null) return null;
    return File(path).readAsString();
  }

  /// 选择 .ics 日历文件并返回其文本内容；用户取消选择返回 null。
  /// 用于 iCal 标准格式导入（与系统日历 / 其它待办应用互通）。
  static Future<String?> pickIcsFile() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['ics'],
    );
    if (result.isEmpty) return null;
    final path = result.single.path;
    if (path == null) return null;
    return File(path).readAsString();
  }
}
