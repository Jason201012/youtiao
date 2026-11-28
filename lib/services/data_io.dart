import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:todolist/state/app_lock_provider.dart';

import 'gbk_codec.dart';

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
  ///
  /// P3-5（v3.1.8 审计）：临时文件带随机后缀。旧实现固定 `<目标>.tmp`，
  /// 「首次开启加密补写」与后台自动备份并发写同名 `.enc.json` 时会共用同一
  /// tmp 路径，互相覆盖/ rename 竞争。随机后缀让并发写入者各写各的临时文件。
  static String _tmpPath(String targetPath) {
    final suffix = Random.secure().nextInt(1 << 32).toRadixString(16);
    return '$targetPath.tmp.$suffix';
  }

  /// P3-5（v3.2.0 审计）：手动备份 / 导出的唯一文件名时间戳。
  ///
  /// 旧实现只到分钟：同一分钟做两次备份（典型「先备份 → 改数据 → 再备份」），
  /// 后一份直接覆盖前一份，用户以为留了两个回滚点。这里加入秒 / 毫秒与
  /// 随机后缀，使同一时刻的连续操作也各自独立。可注入 [at] 便于单测。
  static String uniqueFileStamp([DateTime? at]) {
    final d = at ?? DateTime.now();
    final p = (int n) => n.toString().padLeft(2, '0');
    final rand = Random.secure().nextInt(1 << 20).toRadixString(16).padLeft(5, '0');
    return '${d.year}${p(d.month)}${p(d.day)}-'
        '${p(d.hour)}${p(d.minute)}${p(d.second)}-'
        '${d.millisecond.toString().padLeft(3, '0')}$rand';
  }

  /// P3-5（v3.1.9 审计）：原子写残片（`<目标>.tmp.<hex>`）的识别式。
  static final RegExp _tmpFragment = RegExp(r'\.tmp(\.[0-9a-f]+)?$');

  /// P3-5（v3.1.9 审计）：清理目录内的原子写残片。
  ///
  /// 随机后缀避免了并发共用同一 tmp，但副作用是「每次失败新增一份、不再互相
  /// 覆盖」——写盘失败 / 磁盘满 / 进程被杀留下的 `.tmp.<hex>` 可能包含完整
  /// 明文快照（含附件 base64，数十 MB），此前只由 `backup/auto` 的滚动清理
  /// 顺手删掉，`backup/pre-restore` 与导出目录（App 文档根）无人清理。
  /// 现在每次写入前清扫**目标所在目录**：只认 `.tmp` / `.tmp.<hex>`，且跳过
  /// 最近 1 分钟内修改的文件（可能是另一个写入者正在用的在途临时文件）。
  static Future<void> _sweepTmpFragments(Directory dir) async {
    try {
      if (!await dir.exists()) return;
      final cutoff = DateTime.now().subtract(const Duration(minutes: 1));
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (!_tmpFragment.hasMatch(name)) continue;
        try {
          final stat = await entity.stat();
          if (stat.modified.isAfter(cutoff)) continue;
          await entity.delete();
        } catch (_) {
          // 单文件删除失败（被占用等）不影响其余；也绝不输出文件内容。
        }
      }
    } catch (_) {
      // 清扫失败不阻断写入主流程。
    }
  }

  static Future<File> saveToAppDocs(String fileName, String content) async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$fileName');
    // 兼容子目录写入：如 backup/auto/YYYY-MM-DD.json 需先创建父目录，
    // 否则 tmp.writeAsString() 会抛 PathNotFoundException。
    await file.parent.create(recursive: true);
    // P3-5（v3.1.9 审计）：先清理本目录历史残片（含本次失败前的旧残片）。
    await _sweepTmpFragments(file.parent);
    final tmp = File(_tmpPath(file.path));
    // P3-5（v3.1.9 审计）：`try/finally` 保证任何失败路径都不留残片。旧实现
    // 写入或 rename 抛错时 tmp 原样留在磁盘上，长期累积占用私有目录。
    // 成功 rename 后 tmp 已不存在，下面的删除是幂等收尾。
    try {
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
    } finally {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
    }
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
    // P3-5（v3.1.9 审计）：与文本写同款——先清扫本目录残片，失败必删 tmp。
    await _sweepTmpFragments(file.parent);
    final tmp = File(_tmpPath(file.path)); // P3-5：随机后缀，避免并发写同名 tmp
    try {
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
    } finally {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
    }
  }

  /// 通过系统分享面板分享一个本地文件。
  static Future<void> shareFile(File file, {String mimeType = 'application/json'}) async {
    // U-1：分享面板属于当前操作，返回时豁免一次应用锁重新上锁。
    // N-P3-8（v3.2.1 审计）：分享面板没起来（抛异常）时立即清标记。
    AppLockProvider.markExternalActivity();
    try {
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path, mimeType: mimeType)]),
      );
    } catch (_) {
      AppLockProvider.clearExternalActivity();
      rethrow;
    }
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
    AppLockProvider.markExternalActivity();
    try {
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'image/png')],
          text: text,
        ),
      );
    } catch (_) {
      // N-P3-8（v3.2.1 审计）：同 shareFile，失败即清除豁免。
      AppLockProvider.clearExternalActivity();
      rethrow;
    }
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
  /// 字符串 JSON 转义后字节 + 结构标点（`,`/`: `/`/`{`/`}`/`[`/`]`），并对未知
  /// 类型用 `value.toString().length` 兜底。结果与真实 JsonEncoder 输出
  /// 误差在 5% 以内，足以用于「超额剥离附件」这类二元判断。
  ///
  /// N8（v3.0.9 审计）：字符串改按 **JSON 转义后** 的字节数计（见
  /// [_escapedStringBytes]）——旧实现按原始 UTF-8 字节 + 2 引号计，而
  /// jsonEncode 会把 `"`/`\` 展开成 2 字节、控制字符展开成 6 字节
  /// （`\uXXXX`）：转义密集内容（大量引号 / 反斜杠 / 控制字符）可低估
  /// 数倍，击穿 L12 的 10% 余量 →「估算 ≤ 预算但实际 > 32MB，写得出去
  /// 取不回来」。常规中文 / ASCII 内容不受影响（无转义字符时两法相等）。
  static int estimateJsonBytes(Map<String, dynamic> map) {
    var total = 2; // { }
    final keys = map.keys.toList();
    for (var i = 0; i < keys.length; i++) {
      if (i > 0) total += 1; // ,
      total += _escapedStringBytes(keys[i]) + 1; // "key":（含冒号）
      total += _estimateValueBytes(map[keys[i]]);
    }
    return total;
  }

  static int _estimateValueBytes(dynamic v) {
    if (v == null) return 4; // null
    if (v is bool) return v ? 4 : 5; // true / false
    if (v is num) return v.toString().length;
    if (v is String) return _escapedStringBytes(v); // "..."
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
        n += _escapedStringBytes(ks[i].toString()) + 1 + _estimateValueBytes(v[ks[i]]);
      }
      return n;
    }
    return (v.toString().length);
  }

  /// N8（v3.0.9 审计）：按 **JSON 转义后** 的 UTF-8 字节数估算字符串
  /// （含首尾引号）。Dart `jsonEncode` 的转义规则（dart:convert）：
  /// `"` → `\"`、`\` → `\\`、\b \f \n \r \t → 两字符转义、其余 < 0x20 →
  /// `\uXXXX`（6 字符）；≥ 0x20 的字符按 UTF-8 原长计（代理对各计 3
  /// 字节，合起来正是非 BMP 字符 4 字节 UTF-8 的长度）。
  ///
  /// 旧实现的 `_utf8Bytes(s) + 2`（原始 UTF-8 + 引号）在含转义字符的
  /// 内容上系统性低估——例如 1 MB 纯 `"` 的备注，真实序列化 2 MB，旧法
  /// 估 1 MB：叠加 L12 的 9 折预算仍可越过 32MB 上限，写出还原端必拒的
  /// 备份（F13「写得出去、取不回来」）。本函数封死该缺口；无转义字符时
  /// 与旧法逐位相等（既有常规内容零影响）。
  ///
  /// 同轮顺带修正：key 与冒号此前也只按 `utf8 + 2` 计（注释却写
  /// `"key":`）——每键漏 1 字节，N8 用例的精确对账暴露了它，现补上
  /// （估算与真实序列化在无转义内容上逐位相等）。
  static int _escapedStringBytes(String s) {
    var n = 2; // 前后引号
    for (final cu in s.codeUnits) {
      switch (cu) {
        case 0x22: // "
        case 0x5C: // \
          n += 2;
          break;
        case 0x08: // \b
        case 0x0C: // \f
        case 0x0A: // \n
        case 0x0D: // \r
        case 0x09: // \t
          n += 2;
          break;
        default:
          if (cu < 0x20) {
            n += 6; // \uXXXX
          } else if (cu < 0x80) {
            n += 1;
          } else if (cu < 0x800) {
            n += 2;
          } else {
            n += 3;
          }
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
    // L12（v3.0.8 审计）：预算打 9 折——估算与真实序列化误差 ≤5%（见
    // [estimateJsonBytes]），32MB 边缘「估算 31.9MB、实际 33MB」时会写出一个
    // 读入端（同为 32MB 上限）必然拒绝的备份：「写得出去、取不回来」。留 10%
    // 余量把最坏情况压回限内（超限时走原有的附件剥离逻辑）。
    final budget = (maxExportPayloadBytes * 9 ~/ 10);
    final est = estimateJsonBytes(map);
    if (est <= budget) return (map, false);
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
    AppLockProvider.markExternalActivity();
    try {
      picked = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: extensions,
      );
    } catch (e) {
      // N-P3-8（v3.2.1 审计）：选择器没起来时立即清豁免标记（失败即清除）。
      AppLockProvider.clearExternalActivity();
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
      // P2-3（v2.9.9 审计）：改按字节读取 + BOM/UTF-8/GBK 解码链。此前
      // readAsString() 默认 UTF-8，简体中文 Windows 上 Excel 另存的 GBK CSV
      // 直接抛 FormatException →「读取表格文件失败」，而 Excel 恰是 CSV 导入
      // 主用场景。解码链详见 gbk_codec.dart（严格离线，零依赖）。
      return PickedText.ok(decodeTextFileBytes(await file.readAsBytes()));
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
