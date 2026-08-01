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
  static Future<File> saveToAppDocs(String fileName, String content) async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$fileName');
    await file.writeAsString(content);
    return file;
  }

  /// 通过系统分享面板分享一个本地文件。
  static Future<void> shareFile(File file, {String mimeType = 'application/json'}) async {
    await Share.shareXFiles([XFile(file.path, mimeType: mimeType)]);
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
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (result == null || result.files.isEmpty) return null;
    final path = result.files.single.path;
    if (path == null) return null;
    return File(path).readAsString();
  }
}
