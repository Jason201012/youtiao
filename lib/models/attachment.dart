import 'dart:convert';

/// 附件类型：图片（插图 / 拍照）、录音（本地语音备忘）、文件（任意本地文件）。
///
/// 三者全部落盘于 App 私有目录，**不联网、不上传**，符合「严格离线」定位
/// （见《功能建议报告》P0-1）。拍照 / 录音所需原生能力由 `image_picker` /
/// `record` 提供，均在运行时请求权限。
enum AttachmentType { image, audio, file }

extension AttachmentTypeLabel on AttachmentType {
  /// 弹层 / 标签上的短名。
  String get label {
    switch (this) {
      case AttachmentType.image:
        return '图片';
      case AttachmentType.audio:
        return '录音';
      case AttachmentType.file:
        return '文件';
    }
  }

  /// 列表 / 详情页展示用的 Material Symbols 图标名。
  String get icon {
    switch (this) {
      case AttachmentType.image:
        return 'image';
      case AttachmentType.audio:
        return 'graphic_eq';
      case AttachmentType.file:
        return 'description';
    }
  }
}

/// 任务附件引用（元数据）。
///
/// 二进制文件本身存于 `appApplicationDocumentsDirectory()/attachments/<taskId>/<fileName>`，
/// 本对象只记录其元数据（类型 / 文件名 / 大小 / 时长 / 创建时间），随 [Task] 的 JSON
/// 一起持久化到 SQLite；备份时由 [AttachmentService] 把二进制一并打包进加密信封。
///
/// 设计要点：**不保存绝对路径**，路径在运行时由 `attachments/<taskId>/` 拼出，
/// 因此换机 / 恢复后只要把文件放回该目录即可命中，避免绝对路径失效。
class AttachmentRef {
  final String id;
  final AttachmentType type;

  /// 文件名（含扩展名），唯一标识该附件在 `attachments/<taskId>/` 下的实体。
  /// 带时间戳前缀以避免同目录内重名覆盖。
  final String fileName;

  final int sizeBytes;

  /// MIME 类型（如 image/png、audio/m4a），用于系统分享 / 预览时选择处理器。
  final String? mimeType;

  /// 录音时长（毫秒），仅音频类型有意义；其余为 null。
  final int? durationMs;

  final DateTime createdAt;

  const AttachmentRef({
    required this.id,
    required this.type,
    required this.fileName,
    required this.sizeBytes,
    this.mimeType,
    this.durationMs,
    required this.createdAt,
  });

  AttachmentRef copyWith({
    String? id,
    AttachmentType? type,
    String? fileName,
    int? sizeBytes,
    String? mimeType,
    int? durationMs,
    DateTime? createdAt,
  }) =>
      AttachmentRef(
        id: id ?? this.id,
        type: type ?? this.type,
        fileName: fileName ?? this.fileName,
        sizeBytes: sizeBytes ?? this.sizeBytes,
        // S6 风格容错：durationMs 仅在创建时设置，copyWith 默认保留旧值。
        mimeType: mimeType ?? this.mimeType,
        durationMs: durationMs ?? this.durationMs,
        createdAt: createdAt ?? this.createdAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.name,
        'fileName': fileName,
        'sizeBytes': sizeBytes,
        if (mimeType != null) 'mimeType': mimeType,
        if (durationMs != null) 'durationMs': durationMs,
        'createdAt': createdAt.toIso8601String(),
      };

  /// 从 JSON 反序列化（兼容旧版无 attachments 字段的备份，以及个别字段缺省）。
  factory AttachmentRef.fromJson(Map<String, dynamic> j) {
    final typeStr = j['type'] as String?;
    final AttachmentType type;
    if (typeStr != null) {
      type = AttachmentType.values.firstWhere(
        (e) => e.name == typeStr,
        orElse: () => AttachmentType.file,
      );
    } else {
      // 旧数据无 type：按扩展名粗略推断，缺省归为 file。
      type = AttachmentType.file;
    }
    return AttachmentRef(
      id: (j['id'] as String?) ?? '',
      type: type,
      fileName: (j['fileName'] as String?) ?? '',
      sizeBytes: (j['sizeBytes'] as int?) ?? 0,
      mimeType: j['mimeType'] as String?,
      durationMs: j['durationMs'] as int?,
      // 缺 createdAt 回退当前时间，避免解析抛异常（与 Task.fromJson 口径一致）。
      createdAt: j['createdAt'] == null
          ? DateTime.now()
          : DateTime.parse(j['createdAt'] as String),
    );
  }

  /// 人类可读体积（如 1.2 MB / 340 KB）。
  String get sizeLabel {
    if (sizeBytes < 1024) return '$sizeBytes B';
    final kb = sizeBytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
    return '${(mb / 1024).toStringAsFixed(1)} GB';
  }
}
