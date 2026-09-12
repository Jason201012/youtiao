import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';
import 'package:todolist/models/attachment.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/services/attachment_service.dart';
import 'package:todolist/services/data_io.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/widgets/past_due_guard.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/theme/app_theme.dart';

/// F-6：每月重复的「月内规则」三种互斥模式，与 [TaskParser] 能解析出的形态一一对应。
/// - [day]：固定几号（1..31，溢出月份自动夹到当月最后一天）；
/// - [nthWeekday]：第 N 个周几（第 1~4 个 / 最后一个）；
/// - [fromEnd]：倒数第 N 天（1 = 每月最后一天）。
/// 优先级与 [Task._baseRepeatsOn] 一致：fromEnd > nthWeekday > day。
enum _MonthlyMode { day, nthWeekday, fromEnd }

/// 新建 / 编辑任务弹层（M3 底部 sheet）。
/// 传入 [task] 为编辑模式（预填并调用 updateTask），否则为新建模式（调用 addTask）。
class TaskSheet extends StatefulWidget {
  final Task? task;

  /// 新建模式下的预填草稿（典型来源：快速录入解析出的结果）。
  /// 与 [task] 的区别：[draft] 只把字段填好，保存时仍走新建路径。
  final Task? draft;

  const TaskSheet({super.key, this.task, this.draft, this.inheritedAttachmentSession});

  /// P1-11：从快速录入层（系统分享接收）继承来的附件暂存会话 id。新建任务保存后，
  /// 除本弹层自身的暂存会话外，还要把该会话提升为正式目录；取消保存时也一并清理。
  final String? inheritedAttachmentSession;

  static Future<void> show(BuildContext context,
      {Task? task, Task? draft, String? inheritedAttachmentSession}) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => TaskSheet(
          task: task, draft: draft, inheritedAttachmentSession: inheritedAttachmentSession),
    );
  }

  @override
  State<TaskSheet> createState() => _TaskSheetState();
}

class _TaskSheetState extends State<TaskSheet> {
  final _titleController = TextEditingController();
  final _noteController = TextEditingController();
  final _subtaskController = TextEditingController();
  final _subtaskEditController = TextEditingController();
  Priority _priority = Priority.medium;
  Category _category = Category.work;
  DateTime? _dueDate;

  /// 任务开始时间（可空）。与截止时间并列，用于表达「时间段」类任务（如 14:00-15:00 开会）。
  DateTime? _startDate;

  /// 子任务列表（编辑模式从任务预填）。
  List<SubTask> _subtasks = [];
  int? _editingIndex;

  /// 标签列表（编辑模式从任务预填）。
  List<String> _tags = [];
  final _tagController = TextEditingController();

  /// 重复规则与提醒时刻 / 星期 / 间隔。
  RepeatType _repeat = RepeatType.none;
  // F-7（v2.8.5 审计）：默认提醒时刻统一取共享常量 [kDefaultRepeatMinute]（07:00），
  // 与自然语言快速录入（task_parser）共用同一来源，杜绝两条创建路径默认值漂移。
  TimeOfDay _repeatTime = const TimeOfDay(
      hour: kDefaultRepeatMinute ~/ 60, minute: kDefaultRepeatMinute % 60);
  List<int> _repeatWeekdays = [DateTime.monday];
  int _repeatInterval = 1; // F-10：默认「每 1 天」而非「每 2 天」（与直觉一致）
  DateTime? _repeatAnchor; // interval 锚点，创建时填当天
  DateTime? _repeatUntilDate; // 重复结束日期（date-only，null = 无限循环）

  /// F-6：每月重复的月内规则状态。
  /// 此前弹层选「每月」只能得到「每月 1 号」（[Task.monthlyDay] 默认值），界面上
  /// 既看不到「1 号」也没法改成别的日子；快速录入建的「每月 15 号 / 最后一个周日 /
  /// 每月最后一天」进编辑弹层后同样看不见、改不了（只能靠 copyWith 传 null 侥幸不丢）。
  _MonthlyMode _monthlyMode = _MonthlyMode.day;
  int _monthlyDay = 1; // 1..31
  int _monthlyWeekday = DateTime.monday; // 1..7（周一..周日）
  int _monthlyWeekIndex = 1; // 1..4 = 第 N 个；5 = 最后一个
  int _monthlyFromEnd = 1; // 1 = 每月最后一天

  /// 提醒提前量（分钟）：一次性截止提醒在截止前该分钟数触发（0 = 准时）。
  /// 仅对「不重复」且有截止时间的任务有意义。
  int _reminderOffsetMin = 0;

  // ===== U11：脏数据保护基线（进入编辑时的字段快照）=====
  // 旧实现点 X / 返回键直接关闭——长备注、子任务、附件全丢且无任何提示。
  // 这里记录进入时的基线，[_isDirty] 对比当前值与基线，脏了先弹确认再关。
  String? _baseTitle;
  String? _baseNote;
  DateTime? _baseDue;
  DateTime? _baseStart;
  RepeatType _baseRepeat = RepeatType.none;
  List<String> _baseTags = const [];
  List<SubTask> _baseSubtasks = const [];
  List<AttachmentRef> _baseAttachments = const [];
  bool _basePinned = false;
  int _basePriority = 1; // 1=medium（构造默认）
  int _baseCategory = 0; // 0=work（构造默认）
  String _baseMonthly = ''; // F-6：月内规则基线（见 [_monthlySignature]）

  /// 是否置顶/星标：置顶任务在所属分区内固定排最前。仅编辑模式可切换。
  bool _pinned = false;

  /// 附件列表（编辑模式从任务预填；新建模式逐步添加，保存时一并写入）。
  List<AttachmentRef> _attachments = [];
  // 编辑模式进入时正式目录已有的附件文件名集合；取消保存时用于清理本次新增的孤儿文件。
  Set<String>? _baselineAttachmentFiles;

  /// 新建任务的暂存会话 id：真实 taskId 分配前，附件先落 `attachments/_staging/<_attachmentSession>`，
  /// 保存后由 [AttachmentService.promoteStaging] 提升到正式目录。
  final String _attachmentSession =
      '${DateTime.now().millisecondsSinceEpoch}_${DateTime.now().microsecondsSinceEpoch % 100000}';

  /// 录音状态：true 表示正在录音（显示「停止」按钮）。
  bool _isRecording = false;
  final AudioRecorder _recorder = AudioRecorder();

  /// 是否已成功保存（用于 dispose 时决定是否清理暂存目录）。
  bool _saved = false;

  /// 提前量候选：0（准时）/ 5 / 10 / 15 / 30 / 60 分钟。
  static const List<int> _offsetOptions = [0, 5, 10, 15, 30, 60];
  static String _offsetLabel(int m) => m == 0 ? '准时（不提前）' : '提前 $m 分钟';

  bool get _isEdit => widget.task != null;

  @override
  void initState() {
    super.initState();
    // 编辑模式取原任务，新建模式取草稿（快速录入转入时会带上解析结果）
    final t = widget.task ?? widget.draft;
    if (t != null) {
      _titleController.text = t.title;
      _priority = t.priority;
      _category = t.category;
      _dueDate = t.dueDate;
      _startDate = t.startDate;
      _repeat = t.repeat;
      _repeatWeekdays = List.from(t.repeatWeekdays);
      _repeatInterval = t.repeatInterval;
      _repeatAnchor = t.repeatAnchor;
      _reminderOffsetMin = t.reminderOffsetMin;
      _repeatTime = t.repeatMinute != null
          ? TimeOfDay(hour: t.repeatMinute! ~/ 60, minute: t.repeatMinute! % 60)
          : const TimeOfDay(
              hour: kDefaultRepeatMinute ~/ 60,
              minute: kDefaultRepeatMinute % 60);
      _repeatUntilDate =
          t.repeatUntil != null ? DateTime.parse(t.repeatUntil!) : null;
      // F-6：月内规则预填——按 [Task._baseRepeatsOn] 的优先级（fromEnd > nthWeekday >
      // day）反推当前处于哪种模式，使「每月 15 号 / 最后一个周日 / 每月最后一天」
      // 这类任务在弹层里可见、可改。
      if (t.repeat == RepeatType.monthly) {
        _monthlyDay = t.monthlyDay;
        if (t.monthlyFromEnd > 0) {
          _monthlyMode = _MonthlyMode.fromEnd;
          _monthlyFromEnd = t.monthlyFromEnd;
        } else if (t.monthlyWeekday != null && t.monthlyWeekIndex != null) {
          _monthlyMode = _MonthlyMode.nthWeekday;
          _monthlyWeekday = t.monthlyWeekday!;
          _monthlyWeekIndex = t.monthlyWeekIndex!;
        } else {
          _monthlyMode = _MonthlyMode.day;
        }
      }
      _noteController.text = t.note;
      _subtasks = t.subtasks.map((s) => s.copyWith()).toList();
      _tags = List.from(t.tags);
      _pinned = t.pinned;
      // 编辑模式预填已有附件（新建模式 _attachments 为空，暂存于 _attachmentSession）。
      _attachments = List.from(t.attachments);
      // 记录进入编辑前正式目录的附件文件名集合，供取消保存时清理孤儿。
      _baselineAttachmentFiles = _attachments.map((a) => a.fileName).toSet();
    }
    // U11：记录脏数据比较基线（无论新建/编辑/草稿，未改动即视为干净）。
    _baseTitle = _titleController.text;
    _baseNote = _noteController.text;
    _baseDue = _dueDate;
    _baseStart = _startDate;
    _baseRepeat = _repeat;
    _baseTags = List.from(_tags);
    _baseSubtasks = _subtasks.map((s) => s.copyWith()).toList();
    _baseAttachments = List.from(_attachments);
    _basePinned = _pinned;
    _basePriority = _priority.index;
    _baseCategory = _category.index;
    _baseMonthly = _monthlySignature;
  }

  /// F-6：月内规则的签名，用于脏数据比较（四种字段任一变化即视为已改动）。
  String get _monthlySignature =>
      '${_monthlyMode.name}|$_monthlyDay|$_monthlyWeekday|$_monthlyWeekIndex|$_monthlyFromEnd';

  /// U11：是否有未保存的实质改动（相对进入时的基线）。
  bool get _isDirty {
    if (_titleController.text != _baseTitle) return true;
    if (_noteController.text != _baseNote) return true;
    if (_dueDate != _baseDue) return true;
    if (_startDate != _baseStart) return true;
    if (_repeat != _baseRepeat) return true;
    if (_monthlySignature != _baseMonthly) return true;
    if (_pinned != _basePinned) return true;
    if (_priority.index != _basePriority) return true;
    if (_category.index != _baseCategory) return true;
    if (_tags.length != _baseTags.length) return true;
    for (var i = 0; i < _tags.length && i < _baseTags.length; i++) {
      if (_tags[i] != _baseTags[i]) return true;
    }
    if (_subtasks.length != _baseSubtasks.length) return true;
    if (_attachments.length != _baseAttachments.length) return true;
    return false;
  }

  /// U11：统一关闭入口——有未保存改动时先弹确认，避免长备注/子任务误丢。
  /// 返回 true 表示应真正关闭。对话框与场景解耦，供 PopScope / X 按钮共用。
  Future<bool> _confirmDiscardIfDirty() async {
    if (!_isDirty || _saved) return true;
    final leave = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('放弃未保存的修改？'),
        content: const Text('本次输入尚未保存，关闭将丢失这些改动。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('继续编辑'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(d, true),
            child: const Text('放弃并关闭'),
          ),
        ],
      ),
    );
    return leave == true;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _noteController.dispose();
    _subtaskController.dispose();
    _subtaskEditController.dispose();
    _tagController.dispose();
    // P0-1：未保存时清理无意义附件文件，避免孤儿占用空间。
    if (!_saved) {
      if (_isEdit) {
        // 编辑模式：本次会话新增的附件已落正式目录，但元数据未回写，
        // 清理之使正式目录回到进入编辑前的状态。
        AttachmentService.pruneOrphans(
            widget.task!.id, _baselineAttachmentFiles ?? const {});
      } else {
        // 新建模式：暂存目录整体清理（含 P1-11 继承的分享附件暂存会话）。
        AttachmentService.removeStaging(_attachmentSession);
        if (widget.inheritedAttachmentSession != null) {
          AttachmentService.removeStaging(widget.inheritedAttachmentSession!);
        }
      }
    }
    super.dispose();
  }

  String _formatDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  String _formatTime(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  String _formatTimeOfDay(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  /// 星期序号（1=周一 … 7=周日）→ 中文单字，供「每月第 N 个周几」选择器使用。
  static String _weekdayName(int wd) =>
      const ['一', '二', '三', '四', '五', '六', '日'][(wd - 1).clamp(0, 6)];

  /// F-6：通用步进器行（提炼自「每隔 N 天」原有实现，视觉语言保持一致）。
  /// 内部调 [setState] 后用 [onChanged] 写回调用方字段，故调用方只需赋值。
  Widget _repeatStepper({
    required String prefix,
    required String suffix,
    required int value,
    required int min,
    required int max,
    required ValueChanged<int> onChanged,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final ext = appColors(context);
    Widget roundBtn(IconData icon, int next) => IconButton(
          onPressed: () => setState(() => onChanged(next.clamp(min, max))),
          icon: Icon(icon, size: 18, color: scheme.onSurface),
          style: IconButton.styleFrom(
            backgroundColor: ext.chip,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            padding: const EdgeInsets.all(8),
          ),
        );
    return Row(
      children: [
        Text(prefix, style: TextStyle(color: ext.meta, fontSize: 15)),
        roundBtn(Symbols.remove, value - 1),
        Container(
          width: 36,
          alignment: Alignment.center,
          child: Text('$value',
              style: TextStyle(
                  color: scheme.onSurface,
                  fontSize: 16,
                  fontWeight: FontWeight.w600)),
        ),
        roundBtn(Symbols.add, value + 1),
        Expanded(
          child: Text(suffix,
              style: TextStyle(color: ext.meta, fontSize: 15),
              overflow: TextOverflow.ellipsis),
        ),
      ],
    );
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _dueDate ?? now,
      firstDate: now.subtract(const Duration(days: 365)),
      lastDate: now.add(const Duration(days: 365 * 5)),
    );
    if (picked != null) {
      // F-4/F-5：重复任务不再把截止时间钉成所选日期 23:59。
      // 旧约定把 dueDate 当成「重复窗口结束日」复用，制造了一串连带缺陷：
      // 次日即「已过期」（提醒门槛失灵）、改期副本钉在 23:59、结束后掉进逾期分区。
      // 重复是否继续、何时结束统一由「结束日期」（repeatUntil）表达，
      // 截止时间恢复其本义（用户真正想要的时刻）。
      final int h = _dueDate?.hour ?? 9;
      final int m = _dueDate?.minute ?? 0;
      setState(() => _dueDate = DateTime(picked.year, picked.month, picked.day, h, m));
    }
  }

  /// 重复规则变化。F-4/F-5：**不再**顺手把 [Task.dueDate] 钉成「当天 23:59」——
  /// 该约定是把 dueDate 复用为「重复窗口」的历史包袱，会造成「次日即过期 → 提醒永久
  /// 静默」「改期副本 23:59 提醒」「结束后落入逾期分区」三处连带缺陷。
  /// 重复任务是否继续、何时结束由 [_repeatUntilDate]（→ `repeatUntil`）表达，
  /// 提醒时刻由 [_repeatTime]（→ `repeatMinute`）表达，与截止时间互不干扰。
  void _onRepeatChanged(RepeatType v) {
    setState(() => _repeat = v);
  }

  /// 选择开始日期：默认今天；保留既有时间或默认 09:00。
  Future<void> _pickStartDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _startDate ?? now,
      firstDate: now.subtract(const Duration(days: 365)),
      lastDate: now.add(const Duration(days: 365 * 5)),
    );
    if (picked != null) {
      final int h = _startDate?.hour ?? 9;
      final int m = _startDate?.minute ?? 0;
      setState(() =>
          _startDate = DateTime(picked.year, picked.month, picked.day, h, m));
    }
  }

  /// 选择开始时间：需先选开始日期。
  Future<void> _pickStartTime() async {
    if (_startDate == null) return; // 需先选日期
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_startDate!),
      helpText: '选择开始时间',
    );
    if (picked != null) {
      setState(() => _startDate = DateTime(
        _startDate!.year,
        _startDate!.month,
        _startDate!.day,
        picked.hour,
        picked.minute,
      ));
    }
  }

  Future<void> _pickTime() async {
    if (_dueDate == null) return; // 需先选日期
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_dueDate!),
      helpText: '选择提醒时间',
    );
    if (picked != null) {
      setState(() => _dueDate = DateTime(
        _dueDate!.year,
        _dueDate!.month,
        _dueDate!.day,
        picked.hour,
        picked.minute,
      ));
    }
  }

  Future<void> _pickRepeatTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _repeatTime,
      helpText: '选择提醒时间',
    );
    if (picked != null) setState(() => _repeatTime = picked);
  }

  Future<void> _pickRepeatUntil() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _repeatUntilDate ??
          DateTime.now().add(const Duration(days: 30)),
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 3650)),
      helpText: '选择重复结束日期（含当日仍循环，之后停止）',
    );
    if (picked != null) setState(() => _repeatUntilDate = picked);
  }

  /// yyyy-MM-dd（date-only），与 [Task.repeatUntil] 存储格式一致。
  String _ymd(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  void _addSubtask() {
    final title = _subtaskController.text.trim();
    if (title.isEmpty) return;
    setState(() {
      _subtasks.add(SubTask(
        id: '${DateTime.now().millisecondsSinceEpoch}_${_subtasks.length}',
        title: title,
      ));
      _subtaskController.clear();
    });
  }

  /// 添加标签：回车或加号触发；[raw] 非空时用于「已有标签」快捷添加。
  void _addTag({String? raw}) {
    final tag = (raw ?? _tagController.text).trim();
    if (tag.isEmpty) return;
    if (_tags.contains(tag)) {
      _tagController.clear();
      return;
    }
    setState(() {
      _tags.add(tag);
      _tagController.clear();
    });
  }

  void _removeTag(String tag) {
    setState(() => _tags.remove(tag));
  }

  /// 供快捷添加的「已有标签」（全库标签中尚未被本任务使用的）。
  List<String> _suggestedTags(TaskProvider provider) =>
      provider.allTags.where((t) => !_tags.contains(t)).toList();

  void _removeSubtask(int i) {
    setState(() {
      _subtasks.removeAt(i);
      if (_editingIndex == i) {
        _editingIndex = null;
        _subtaskEditController.clear();
      } else if (_editingIndex != null && _editingIndex! > i) {
        _editingIndex = _editingIndex! - 1;
      }
    });
  }

  void _toggleSubtask(int i, bool? v) {
    setState(() => _subtasks[i] = _subtasks[i].copyWith(done: v ?? false));
  }

  void _startEditSubtask(int i) {
    _editingIndex = i;
    _subtaskEditController.text = _subtasks[i].title;
    setState(() {});
  }

  void _commitEditSubtask(int i) {
    final title = _subtaskEditController.text.trim();
    setState(() {
      if (title.isNotEmpty) {
        _subtasks[i] = _subtasks[i].copyWith(title: title);
      }
      _editingIndex = null;
      _subtaskEditController.clear();
    });
  }

  // ===== 附件（P0-1，全程本地、不联网）=====

  /// 计算附件落盘目录：编辑模式用正式目录（taskId 已知），新建模式用暂存目录。
  Future<Directory> _targetDir() async {
    if (_isEdit) return AttachmentService.dirFor(widget.task!.id);
    return AttachmentService.stagingDir(_attachmentSession);
  }

  /// 把已选文件（XFile）导入为附件并加入列表。
  Future<void> _importPicked(XFile picked, AttachmentType type,
      {String? mimeType}) async {
    try {
      final dir = await _targetDir();
      final ref = await AttachmentService.importFile(
        parentDir: dir,
        src: File(picked.path),
        type: type,
        mimeType: mimeType ?? picked.mimeType,
      );
      setState(() => _attachments.add(ref));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('添加附件失败：$e')));
      }
    }
  }

  /// 从相册选图片（插图）。
  /// C-1 修复：显式 requestFullMetadata=false 走系统 Photo Picker，
  /// 不再依赖 READ_MEDIA_IMAGES 权限（移除该权限后可降低隐私合规审计面）。
  /// 注：相机路径本就不读媒体库，同样显式关闭 full metadata 以求一致。
  Future<void> _addImage() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      requestFullMetadata: false,
    );
    if (picked != null) await _importPicked(picked, AttachmentType.image);
  }

  /// 拍照（相机）。
  Future<void> _takePhoto() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.camera,
      requestFullMetadata: false,
    );
    if (picked != null) await _importPicked(picked, AttachmentType.image);
  }

  /// 从本地文件系统选任意文件（文档 / 图片 / 音频等），按扩展名粗判类型。
  Future<void> _addFile() async {
    final result = await FilePicker.pickFiles();
    if (result == null || result.isEmpty) return;
    final f = result.single;
    if (f.path == null) return;
    // file_picker 12 / platform_interface 3.x 的 PlatformFile 已移除 .extension getter，
    // 改为从文件名自行解析扩展名（不含点）。
    final rawName = f.name;
    final dot = rawName.lastIndexOf('.');
    final ext = dot >= 0 ? rawName.substring(dot + 1).toLowerCase() : '';
    final type = ['m4a', 'mp3', 'wav', 'aac', 'ogg', 'amr'].contains(ext)
        ? AttachmentType.audio
        : ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'].contains(ext)
            ? AttachmentType.image
            : AttachmentType.file;
    try {
      final dir = await _targetDir();
      final ref = await AttachmentService.importFile(
        parentDir: dir,
        src: File(f.path!),
        type: type,
        // file_picker 12 的 PlatformFile 已移除 .mimeType getter；
        // AttachmentService.importFile 会按源文件原名自动派生扩展名，故此处传 null。
        mimeType: null,
      );
      setState(() => _attachments.add(ref));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('添加附件失败：$e')));
      }
    }
  }

  /// 开始 / 停止录音（本地语音备忘）。实时录音落盘到目标目录。
  Future<void> _toggleRecording() async {
    if (_isRecording) {
      final path = await _recorder.stop();
      setState(() => _isRecording = false);
      if (path != null) {
        final file = File(path);
        if (await file.exists()) {
          final dir = await _targetDir();
          final ref = await AttachmentService.importFile(
            parentDir: dir,
            src: file,
            type: AttachmentType.audio,
            mimeType: 'audio/m4a',
          );
          setState(() => _attachments.add(ref));
          // 录音原始文件（voice_*.m4a）已复制为带时间戳前缀的规范化附件，
          // 删除原始文件，避免产生不在元数据列表里的孤儿。
          try {
            await file.delete();
          } catch (_) {
            // 原始文件删除失败不影响已落库的规范化附件。
          }
        }
      }
      return;
    }
    // 开始前检查麦克风权限。
    if (!await _recorder.hasPermission()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('需要麦克风权限才能录音')),
        );
      }
      return;
    }
    final dir = await _targetDir();
    final path =
        '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _recorder.start(const RecordConfig(), path: path);
    setState(() => _isRecording = true);
  }

  /// 删除某附件：同步删除磁盘文件（编辑模式正式目录 / 新建模式暂存目录）。
  Future<void> _removeAttachment(int i) async {
    final ref = _attachments[i];
    setState(() => _attachments.removeAt(i));
    try {
      final dir = await _targetDir();
      final file = File('${dir.path}/${ref.fileName}');
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 文件删除失败不阻断（元数据已从列表移除）。
    }
  }

  /// 在编辑页内预览 / 打开附件：图片全屏预览、音频 / 文件经系统分享。
  Future<void> _openAttachment(AttachmentRef ref) async {
    final dir = await _targetDir();
    final file = File('${dir.path}/${ref.fileName}');
    if (!await file.exists()) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('附件文件不存在')));
      }
      return;
    }
    if (ref.type == AttachmentType.image) {
      if (mounted) {
        await showDialog(context: context, builder: (_) => Dialog(child: Image.file(file)));
      }
    } else {
      await DataIo.shareFile(file,
          mimeType: ref.mimeType ?? 'application/octet-stream');
    }
  }

  /// 附件区块 UI：四个添加入口 + 已添加附件的 chip 列表。
  Widget _buildAttachments() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _AttachSourceChip(icon: Symbols.image, label: '图片', onTap: _addImage),
            _AttachSourceChip(
                icon: Symbols.photo_camera, label: '拍照', onTap: _takePhoto),
            _AttachSourceChip(
                icon: Symbols.folder_open, label: '文件', onTap: _addFile),
            _AttachSourceChip(
              icon: Symbols.mic,
              label: _isRecording ? '停止录音' : '录音',
              onTap: _toggleRecording,
              recording: _isRecording,
            ),
          ],
        ),
        if (_attachments.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var i = 0; i < _attachments.length; i++)
                  _AttachmentChip(
                    ref: _attachments[i],
                    onRemove: () => _removeAttachment(i),
                    onOpen: () => _openAttachment(_attachments[i]),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Future<void> _save() async {
    final title = _titleController.text.trim();
    if (title.isEmpty) return;
    // U12：可设过去时间但无任何提示 = 提醒静默失效（15:00 建「今天 09:00」，
    // 保存成功却永不响铃——对提醒类 App 是信任级伤害）。一次性任务且截止时刻已过
    // 时，先提示「提醒不会触发」，由用户决定是否仍要保存（补录历史仍可能有意）。
    final now = DateTime.now();
    // U12 / P3-5：可设过去时间但无任何提示 = 提醒静默失效（15:00 建「今天 09:00」，
    // 保存成功却永不响铃——对提醒类 App 是信任级伤害）。判定与弹窗统一走
    // [PastDueGuard]，与批量改期 / 逾期区「顺延到今天」等入口保持同一口径。
    if (_repeat == RepeatType.none && _dueDate != null && _dueDate!.isBefore(now)) {
      final continueAnyway = await PastDueGuard.confirm(
        context,
        count: 1,
        detail: '所选截止时间（${_formatDate(_dueDate!)} ${_formatTime(_dueDate!)}）'
            '已早于当前时刻，保存后提醒将不会触发。\n\n仍要保存吗？',
      );
      if (!continueAnyway) return;
    }
    final provider = Provider.of<TaskProvider>(context, listen: false);
    final repeatMinute =
        _repeat != RepeatType.none ? _repeatTime.hour * 60 + _repeatTime.minute : null;
    // 每隔 N 天：创建时把锚点设为当天（date-only），保证从今天起每 N 天循环。
    final anchor = (_repeat == RepeatType.interval && !_isEdit)
        ? DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day)
        : _repeatAnchor;
    final weekdays = _repeat == RepeatType.weekly
        ? (_repeatWeekdays.isNotEmpty ? List<int>.from(_repeatWeekdays) : [DateTime.monday])
        : const <int>[];
    // F-6：月内规则显式回传（两种保存路径都要传全四个字段）。
    // 编辑路径尤其要让「从『第 N 个周几 / 倒数第 N 天』改回『固定几号』」能清空旧规则——
    // [Task.copyWith] 的 monthlyWeekday / monthlyWeekIndex 已改用 _kKeep 哨兵
    // （F-9），显式传 null 才会真正清空，否则旧规则会盖住 monthlyDay。
    final monthlyDay = _repeat == RepeatType.monthly && _monthlyMode == _MonthlyMode.day
        ? _monthlyDay
        : 1;
    final monthlyWeekday =
        _repeat == RepeatType.monthly && _monthlyMode == _MonthlyMode.nthWeekday
            ? _monthlyWeekday
            : null;
    final monthlyWeekIndex =
        _repeat == RepeatType.monthly && _monthlyMode == _MonthlyMode.nthWeekday
            ? _monthlyWeekIndex
            : null;
    final monthlyFromEnd =
        _repeat == RepeatType.monthly && _monthlyMode == _MonthlyMode.fromEnd
            ? _monthlyFromEnd
            : 0;
    // P2-3 / F-6：脏字段归一化统一收在 [Task.normalizedRepeatFields]（纯函数、可单测）——
    // 「切回不重复 / 切到其它重复类型 / 清空截止时间」后残留的 repeatUntil /
    // repeatInterval / reminderOffsetMin / 月内规则会被清掉，避免污染备份导出与
    // 「未来 30 天预览」，也避免 TaskProvider 的 remindersChanged 判定被无害残留误触发重排。
    if (_isEdit) {
      provider.updateTask(widget.task!.copyWith(
        title: title,
        priority: _priority,
        category: _category,
        dueDate: _dueDate,
        startDate: _startDate,
        repeat: _repeat,
        repeatWeekdays: weekdays,
        repeatInterval: _repeatInterval,
        repeatMinute: repeatMinute,
        repeatAnchor: anchor,
        repeatUntil: _repeatUntilDate != null ? _ymd(_repeatUntilDate!) : null,
        monthlyDay: monthlyDay,
        monthlyWeekday: monthlyWeekday,
        monthlyWeekIndex: monthlyWeekIndex,
        monthlyFromEnd: monthlyFromEnd,
        note: _noteController.text.trim(),
        tags: List.from(_tags),
        subtasks: List.from(_subtasks),
        reminderOffsetMin: _reminderOffsetMin,
        pinned: _pinned,
        attachments: List.from(_attachments),
      ).normalizedRepeatFields());
    } else {
      final created = provider.addTask(Task(
        id: '',
        title: title,
        priority: _priority,
        category: _category,
        dueDate: _dueDate,
        startDate: _startDate,
        repeat: _repeat,
        repeatWeekdays: weekdays,
        repeatInterval: _repeatInterval,
        repeatMinute: repeatMinute,
        repeatAnchor: anchor,
        repeatUntil: _repeatUntilDate != null ? _ymd(_repeatUntilDate!) : null,
        monthlyDay: monthlyDay,
        monthlyWeekday: monthlyWeekday,
        monthlyWeekIndex: monthlyWeekIndex,
        monthlyFromEnd: monthlyFromEnd,
        note: _noteController.text.trim(),
        tags: List.from(_tags),
        subtasks: List.from(_subtasks),
        reminderOffsetMin: _reminderOffsetMin,
        pinned: _pinned,
        attachments: List.from(_attachments),
      ).normalizedRepeatFields());
      // P0-1：新建任务拿到真实 id 后，把暂存目录提升为正式目录（文件随之归位）。
      // P1-11：同时提升从快速录入层继承的分享附件暂存会话。
      await AttachmentService.promoteStaging(_attachmentSession, created.id);
      if (widget.inheritedAttachmentSession != null) {
        await AttachmentService.promoteStaging(
            widget.inheritedAttachmentSession!, created.id);
      }
    }
    _saved = true;
    if (!mounted) return;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ext = appColors(context);
    final provider = Provider.of<TaskProvider>(context, listen: false);
    final canSave = _titleController.text.trim().isNotEmpty;
    // U11：拦截系统返回键（Android back / 桌面 Esc 等）——脏数据时先弹确认。
    return PopScope(
      canPop: !_isDirty || _saved,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final leave = await _confirmDiscardIfDirty();
        if (leave && mounted) Navigator.pop(context);
      },
      child: Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height -
            MediaQuery.of(context).viewInsets.bottom -
            12,
      ),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          AppColors.pagePadX,
          20,
          AppColors.pagePadX,
          MediaQuery.of(context).padding.bottom + 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
          // 标题栏
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_isEdit ? '编辑任务' : '新建任务',
                  style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: scheme.onSurface)),
              IconButton(
                icon: Icon(Symbols.close, color: ext.meta),
                // U11：脏数据时先弹确认，不再无提示直接关闭。
                onPressed: () async {
                  final leave = await _confirmDiscardIfDirty();
                  if (leave && mounted) Navigator.pop(context);
                },
              ),
            ],
          ),
          const SizedBox(height: 12),
          // 标题输入
          TextField(
            controller: _titleController,
            autofocus: true,
            textInputAction: TextInputAction.done,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: '任务标题',
              hintStyle: TextStyle(color: ext.meta),
              filled: true,
              fillColor: ext.chip,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppColors.chipRadius),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            ),
            style: TextStyle(color: scheme.onSurface, fontSize: 16),
          ),
          const SizedBox(height: 18),
          // 置顶开关（仅编辑模式）：把任务钉在所属分区顶部，常驻高频可见。
          if (_isEdit)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: InkWell(
                onTap: () => setState(() => _pinned = !_pinned),
                borderRadius: BorderRadius.circular(AppColors.chipRadius),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Icon(Symbols.star,
                          size: 22,
                          color: _pinned ? scheme.primary : ext.meta),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(
                          '置顶 / 星标',
                          style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                              color: scheme.onSurface),
                        ),
                      ),
                      Switch(
                        value: _pinned,
                        onChanged: (v) => setState(() => _pinned = v),
                        activeColor: scheme.primary,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          // 备注
          _SectionLabel('备注'),
          const SizedBox(height: 8),
          TextField(
            controller: _noteController,
            maxLines: 4,
            minLines: 2,
            textInputAction: TextInputAction.newline,
            decoration: InputDecoration(
              hintText: '补充说明、链接、思路…（可选）',
              hintStyle: TextStyle(color: ext.meta),
              filled: true,
              fillColor: ext.chip,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppColors.chipRadius),
                borderSide: BorderSide.none,
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            ),
            style: TextStyle(color: scheme.onSurface, fontSize: 15),
          ),
          const SizedBox(height: 18),
          // 附件（P0-1）：图片 / 拍照 / 本地文件 / 录音，全程本地不联网。
          _SectionLabel('附件'),
          const SizedBox(height: 8),
          _buildAttachments(),
          const SizedBox(height: 18),
          // 子任务
          _SectionLabel('子任务'),
          const SizedBox(height: 8),
          // 添加输入行
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _subtaskController,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _addSubtask(),
                  decoration: InputDecoration(
                    hintText: '添加子任务，回车确认',
                    hintStyle: TextStyle(color: ext.meta),
                    filled: true,
                    fillColor: ext.chip,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppColors.chipRadius),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  ),
                  style: TextStyle(color: scheme.onSurface, fontSize: 15),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: _addSubtask,
                icon: const Icon(Symbols.add),
                style: IconButton.styleFrom(
                  backgroundColor: scheme.primary,
                  foregroundColor: scheme.onPrimary,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
          if (_subtasks.isNotEmpty)
            ..._subtasks.asMap().entries.map((entry) {
              final i = entry.key;
              final s = entry.value;
              return Container(
                margin: const EdgeInsets.only(top: 8),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: ext.chip,
                  borderRadius: BorderRadius.circular(AppColors.chipRadius),
                ),
                child: Row(
                  children: [
                    Checkbox(
                      value: s.done,
                      onChanged: (v) => _toggleSubtask(i, v),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: _editingIndex == i
                          ? TextField(
                              controller: _subtaskEditController,
                              autofocus: true,
                              onSubmitted: (_) => _commitEditSubtask(i),
                              decoration: const InputDecoration(
                                border: InputBorder.none,
                                isCollapsed: true,
                                contentPadding: EdgeInsets.zero,
                              ),
                              style: TextStyle(
                                  color: scheme.onSurface, fontSize: 15),
                            )
                          : GestureDetector(
                              onTap: () => _startEditSubtask(i),
                              child: Text(
                                s.title,
                                style: TextStyle(
                                  fontSize: 15,
                                  color: s.done ? ext.meta : scheme.onSurface,
                                  decoration: s.done
                                      ? TextDecoration.lineThrough
                                      : null,
                                ),
                              ),
                            ),
                    ),
                    IconButton(
                      onPressed: () => _removeSubtask(i),
                      icon: Icon(Symbols.close, size: 18, color: ext.meta),
                      style: IconButton.styleFrom(
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        padding: EdgeInsets.zero,
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
          const SizedBox(height: 18),
          // 标签
          _SectionLabel('标签'),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _tagController,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _addTag(),
                  decoration: InputDecoration(
                    hintText: '添加标签，回车确认（如 紧急、会议）',
                    hintStyle: TextStyle(color: ext.meta),
                    filled: true,
                    fillColor: ext.chip,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppColors.chipRadius),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  ),
                  style: TextStyle(color: scheme.onSurface, fontSize: 15),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: _addTag,
                icon: const Icon(Symbols.add),
                style: IconButton.styleFrom(
                  backgroundColor: scheme.primary,
                  foregroundColor: scheme.onPrimary,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
          if (_tags.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: _tags
                    .map((tag) => Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: ext.chip,
                            borderRadius: BorderRadius.circular(AppColors.chipRadius),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text('#$tag',
                                  style: TextStyle(fontSize: 13, color: ext.meta)),
                              const SizedBox(width: 4),
                              GestureDetector(
                                onTap: () => _removeTag(tag),
                                child: Icon(Symbols.close, size: 16, color: ext.meta),
                              ),
                            ],
                          ),
                        ))
                    .toList(),
              ),
            ),
          if (_suggestedTags(provider).isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: _suggestedTags(provider)
                    .map((tag) => GestureDetector(
                          onTap: () => _addTag(raw: tag),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: ext.chip.withOpacity(0.6),
                              borderRadius: BorderRadius.circular(AppColors.chipRadius),
                            ),
                            child: Text('+#$tag',
                                style: TextStyle(fontSize: 13, color: ext.meta)),
                          ),
                        ))
                    .toList(),
              ),
            ),
          const SizedBox(height: 18),
          // 优先级
          _SectionLabel('优先级'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _PriorityChip(
                label: '高',
                dot: ext.high,
                selected: _priority == Priority.high,
                onTap: () => setState(() => _priority = Priority.high),
              ),
              _PriorityChip(
                label: '中',
                dot: ext.medium,
                selected: _priority == Priority.medium,
                onTap: () => setState(() => _priority = Priority.medium),
              ),
              _PriorityChip(
                label: '低',
                dot: ext.low,
                selected: _priority == Priority.low,
                onTap: () => setState(() => _priority = Priority.low),
              ),
            ],
          ),
          const SizedBox(height: 18),
          // 分类
          _SectionLabel('分类'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _CategoryChip(
                label: '工作',
                selected: _category == Category.work,
                onTap: () => setState(() => _category = Category.work),
              ),
              _CategoryChip(
                label: '生活',
                selected: _category == Category.life,
                onTap: () => setState(() => _category = Category.life),
              ),
              _CategoryChip(
                label: '学习',
                selected: _category == Category.study,
                onTap: () => setState(() => _category = Category.study),
              ),
            ],
          ),
          const SizedBox(height: 18),
          // 截止日期
          _SectionLabel('截止日期'),
          const SizedBox(height: 8),
          GestureDetector(
            onTap: _pickDate,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: ext.chip,
                borderRadius: BorderRadius.circular(AppColors.chipRadius),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _dueDate == null ? '选择日期（可选）' : _formatDate(_dueDate!),
                    style: TextStyle(
                      color: _dueDate == null ? ext.meta : scheme.onSurface,
                      fontSize: 16,
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // U11：选定的日期可一键清除（此前只有选取没有清除）。
                      if (_dueDate != null)
                        GestureDetector(
                          onTap: () => setState(() => _dueDate = null),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 4),
                            child: Icon(Symbols.close,
                                size: 16, color: ext.meta),
                          ),
                        ),
                      Icon(Symbols.calendar_month, size: 20, color: ext.meta),
                    ],
                  ),
                ],
              ),
            ),
          ),
          // 开始时间（可空）：与截止日期并列，表达「时间段」任务（如 14:00-15:00 开会）。
          const SizedBox(height: 18),
          _SectionLabel('开始时间'),
          const SizedBox(height: 8),
          GestureDetector(
            onTap: _pickStartDate,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: ext.chip,
                borderRadius: BorderRadius.circular(AppColors.chipRadius),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _startDate == null ? '选择日期（可选）' : _formatDate(_startDate!),
                    style: TextStyle(
                      color: _startDate == null ? ext.meta : scheme.onSurface,
                      fontSize: 16,
                    ),
                  ),
                  Icon(Symbols.event_available, size: 20, color: ext.meta),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: _startDate == null ? null : _pickStartTime,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: ext.chip,
                borderRadius: BorderRadius.circular(AppColors.chipRadius),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _startDate == null ? '请先选择日期' : _formatTime(_startDate!),
                    style: TextStyle(
                      color: _startDate == null ? ext.meta : scheme.onSurface,
                      fontSize: 16,
                    ),
                  ),
                  Icon(Symbols.schedule, size: 20, color: ext.meta),
                ],
              ),
            ),
          ),
          // 一次性任务：显示「截止时间」与「提醒提前量」。
          // F-9（v2.8.5 审计）：旧注释「重复任务：截止时间固定为 23:59」已过时——
          // 该 23:59 约定在 v2.8.5（F-4/F-5）废除。重复任务不显示本区块：
          // 其提醒由「重复提醒时刻」（repeatMinute）驱动，且 F-1 起调度层
          // 不再为重复任务挂一次性截止提醒，截止时间与其提醒完全解耦。
          if (_repeat == RepeatType.none) ...[
            const SizedBox(height: 18),
            _SectionLabel('截止时间'),
            const SizedBox(height: 8),
            GestureDetector(
              onTap: _dueDate == null ? null : _pickTime,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                  color: ext.chip,
                  borderRadius: BorderRadius.circular(AppColors.chipRadius),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _dueDate == null ? '请先选择日期' : _formatTime(_dueDate!),
                      style: TextStyle(
                        color: _dueDate == null ? ext.meta : scheme.onSurface,
                        fontSize: 16,
                      ),
                    ),
                    Icon(Symbols.schedule, size: 20, color: ext.meta),
                  ],
                ),
              ),
            ),
            // 提醒提前量：仅对「不重复 + 有截止时间」的任务生效。
            if (_dueDate != null) ...[
              const SizedBox(height: 12),
              _SectionLabel('提醒提前量'),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: ext.chip,
                  borderRadius: BorderRadius.circular(AppColors.chipRadius),
                ),
                child: DropdownButton<int>(
                  value: _reminderOffsetMin,
                  isExpanded: true,
                  underline: const SizedBox(),
                  icon: Icon(Symbols.arrow_drop_down, color: ext.meta),
                  items: [
                    for (final m in _offsetOptions)
                      DropdownMenuItem(
                        value: m,
                        child: Text(_offsetLabel(m),
                            style: TextStyle(
                                color: scheme.onSurface, fontSize: 15)),
                      ),
                  ],
                  onChanged: (v) =>
                      setState(() => _reminderOffsetMin = v ?? 0),
                ),
              ),
            ],
          ],
          const SizedBox(height: 18),
          // 重复规则
          _SectionLabel('重复'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _PriorityChip(
                label: '不重复',
                selected: _repeat == RepeatType.none,
                onTap: () => _onRepeatChanged(RepeatType.none),
              ),
              _PriorityChip(
                label: '每天',
                selected: _repeat == RepeatType.daily,
                onTap: () => _onRepeatChanged(RepeatType.daily),
              ),
              _PriorityChip(
                label: '每周',
                selected: _repeat == RepeatType.weekly,
                onTap: () => _onRepeatChanged(RepeatType.weekly),
              ),
              _PriorityChip(
                label: '每隔N天',
                selected: _repeat == RepeatType.interval,
                onTap: () => _onRepeatChanged(RepeatType.interval),
              ),
              _PriorityChip(
                label: '仅工作日',
                selected: _repeat == RepeatType.weekday,
                onTap: () => _onRepeatChanged(RepeatType.weekday),
              ),
              // P2-6：补「每月」chip——之前只暴露「每月重复」靠解析或编辑旧任务，
              // 用户若从未碰过旧任务就找不到入口。
              _PriorityChip(
                label: '每月',
                selected: _repeat == RepeatType.monthly,
                onTap: () => _onRepeatChanged(RepeatType.monthly),
              ),
            ],
          ),
          // 每周：选择星期（可多选）
          if (_repeat == RepeatType.weekly) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (var d = 1; d <= 7; d++)
                  _PriorityChip(
                    label: ['一', '二', '三', '四', '五', '六', '日'][d - 1],
                    selected: _repeatWeekdays.contains(d),
                    onTap: () => setState(() {
                      if (_repeatWeekdays.contains(d)) {
                        if (_repeatWeekdays.length > 1) _repeatWeekdays.remove(d);
                      } else {
                        _repeatWeekdays.add(d);
                      }
                    }),
                  ),
              ],
            ),
          ],
          // 每隔 N 天：间隔步进
          if (_repeat == RepeatType.interval) ...[
            const SizedBox(height: 12),
            _repeatStepper(
              prefix: '每',
              suffix: '天',
              value: _repeatInterval,
              min: 1,
              max: 30,
              onChanged: (v) => _repeatInterval = v,
            ),
          ],
          // F-6：每月：月内规则（固定几号 / 第 N 个周几 / 倒数第 N 天）。
          // 此前弹层选「每月」既看不到、也改不了月内规则，只能得到「每月 1 号」，
          // 而解析器本就能表达「每月 15 号 / 每月最后一个周日 / 每月最后一天」，
          // 两条创建路径能力不对等。
          if (_repeat == RepeatType.monthly) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _PriorityChip(
                  label: '每月几号',
                  selected: _monthlyMode == _MonthlyMode.day,
                  onTap: () => setState(() => _monthlyMode = _MonthlyMode.day),
                ),
                _PriorityChip(
                  label: '第几个周几',
                  selected: _monthlyMode == _MonthlyMode.nthWeekday,
                  onTap: () =>
                      setState(() => _monthlyMode = _MonthlyMode.nthWeekday),
                ),
                _PriorityChip(
                  label: '倒数第几天',
                  selected: _monthlyMode == _MonthlyMode.fromEnd,
                  onTap: () => setState(() => _monthlyMode = _MonthlyMode.fromEnd),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_monthlyMode == _MonthlyMode.day)
              _repeatStepper(
                prefix: '每月',
                suffix: '号（小月自动顺延到月末）',
                value: _monthlyDay,
                min: 1,
                max: 31,
                onChanged: (v) => _monthlyDay = v,
              ),
            if (_monthlyMode == _MonthlyMode.nthWeekday) ...[
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final idx in const [1, 2, 3, 4, 5])
                    _PriorityChip(
                      label: idx == 5 ? '最后' : '第 $idx 个',
                      selected: _monthlyWeekIndex == idx,
                      onTap: () => setState(() => _monthlyWeekIndex = idx),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (var d = 1; d <= 7; d++)
                    _PriorityChip(
                      label: '周${_weekdayName(d)}',
                      selected: _monthlyWeekday == d,
                      onTap: () => setState(() => _monthlyWeekday = d),
                    ),
                ],
              ),
            ],
            if (_monthlyMode == _MonthlyMode.fromEnd)
              _repeatStepper(
                prefix: '倒数第',
                suffix: _monthlyFromEnd == 1 ? '天（即每月最后一天）' : '天',
                value: _monthlyFromEnd,
                min: 1,
                max: 10,
                onChanged: (v) => _monthlyFromEnd = v,
              ),
          ],
          const SizedBox(height: 12),
          // 提醒时间（任意重复类型都有）
          if (_repeat != RepeatType.none)
            GestureDetector(
              onTap: _pickRepeatTime,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                  color: ext.chip,
                  borderRadius: BorderRadius.circular(AppColors.chipRadius),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _formatTimeOfDay(_repeatTime),
                      style: TextStyle(color: scheme.onSurface, fontSize: 16),
                    ),
                    Icon(Symbols.schedule, size: 20, color: ext.meta),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 12),
          // 重复结束日期（可选）：到期后停止循环；点选即设，再点「清除」可清空。
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: _pickRepeatUntil,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    decoration: BoxDecoration(
                      color: ext.chip,
                      borderRadius:
                          BorderRadius.circular(AppColors.chipRadius),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          _repeatUntilDate == null
                              ? '无结束日期（无限循环）'
                              : '结束于 ${_ymd(_repeatUntilDate!)}',
                          style: TextStyle(
                            color: scheme.onSurface, fontSize: 15,
                            fontWeight: _repeatUntilDate == null
                                ? FontWeight.normal
                                : FontWeight.w600,
                          ),
                        ),
                        Icon(Symbols.event_busy, size: 20, color: ext.meta),
                      ],
                    ),
                  ),
                ),
              ),
              if (_repeatUntilDate != null)
                IconButton(
                  onPressed: () => setState(() => _repeatUntilDate = null),
                  icon: const Icon(Symbols.close),
                  tooltip: '清除结束日期',
                ),
            ],
          ),
          const SizedBox(height: 18),
          // 保存
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: canSave
                  ? () async {
                      await _save();
                    }
                  : null,
              child: Text(_isEdit ? '保存修改' : '保存'),
            ),
          ),
        ],
      ),
      ), // Container
      ), // PopScope
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel(this.label);
  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    return Text(label,
        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: ext.meta));
  }
}

class _PriorityChip extends StatelessWidget {
  final String label;
  final Color? dot;
  final bool selected;
  final VoidCallback onTap;
  const _PriorityChip({
    required this.label,
    this.dot,
    required this.selected,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ChoiceChip(
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot != null) ...[
            Container(width: 8, height: 8, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
            const SizedBox(width: 6),
          ],
          Text(label),
        ],
      ),
      selected: selected,
      onSelected: (_) => onTap(),
      showCheckmark: false,
      selectedColor: scheme.primary,
      labelStyle: TextStyle(
        color: selected ? scheme.onPrimary : scheme.onSurface,
        fontSize: 14,
      ),
      backgroundColor: appColors(context).chip,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppColors.chipRadius)),
      side: BorderSide.none,
    );
  }
}

class _CategoryChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _CategoryChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
      showCheckmark: false,
      selectedColor: scheme.primary,
      labelStyle: TextStyle(
        color: selected ? scheme.onPrimary : scheme.onSurface,
        fontSize: 14,
      ),
      backgroundColor: appColors(context).chip,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppColors.chipRadius)),
      side: BorderSide.none,
    );
  }
}

/// 附件添加入口（图片 / 拍照 / 文件 / 录音）。
class _AttachSourceChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool recording;
  const _AttachSourceChip({
    required this.icon,
    required this.label,
    required this.onTap,
    this.recording = false,
  });
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ext = appColors(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppColors.chipRadius),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: recording ? scheme.primary : ext.chip,
          borderRadius: BorderRadius.circular(AppColors.chipRadius),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: recording ? scheme.onPrimary : ext.meta),
            const SizedBox(width: 6),
            Text(label,
                style: TextStyle(
                    fontSize: 13,
                    color: recording ? scheme.onPrimary : scheme.onSurface)),
          ],
        ),
      ),
    );
  }
}

/// 已添加附件的 chip：图标 + 类型·体积 + 删除；点击预览 / 打开。
class _AttachmentChip extends StatelessWidget {
  final AttachmentRef ref;
  final VoidCallback onRemove;
  final VoidCallback onOpen;
  const _AttachmentChip({
    required this.ref,
    required this.onRemove,
    required this.onOpen,
  });
  IconData _typeIcon(AttachmentType t) {
    switch (t) {
      case AttachmentType.image:
        return Symbols.image;
      case AttachmentType.audio:
        return Symbols.graphic_eq;
      case AttachmentType.file:
        return Symbols.description;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ext = appColors(context);
    return InkWell(
      onTap: onOpen,
      borderRadius: BorderRadius.circular(AppColors.chipRadius),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: ext.chip,
          borderRadius: BorderRadius.circular(AppColors.chipRadius),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_typeIcon(ref.type), size: 18, color: ext.meta),
            const SizedBox(width: 6),
            Text('${ref.type.label} · ${ref.sizeLabel}',
                style: TextStyle(fontSize: 13, color: scheme.onSurface)),
            const SizedBox(width: 4),
            GestureDetector(
              onTap: onRemove,
              child: Icon(Symbols.close, size: 16, color: ext.meta),
            ),
          ],
        ),
      ),
    );
  }
}
