import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:todolist/models/task.dart';
import 'package:todolist/models/habit.dart';
import 'package:todolist/models/focus_session.dart';
import 'package:todolist/models/checkin.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/state/habit_provider.dart';

/// 本地导出服务：把「有条」的数据/回顾生成为 Excel / PDF。
///
/// 严格离线：不发起任何网络请求，全部在本地内存计算、本地落盘（见 [DataIo]）。
/// - Excel：多表工作簿（任务 / 专注 / 习惯 / 打卡记录），列结构与既有 CSV 导出对齐，
///   中文由 Excel 原生 UTF-8 处理，无需内嵌字体。
/// - PDF：把「回顾长图」已栅格化的 PNG 包成单页 A4 文档。复用 Flutter 引擎渲染
///   （含中文），规避 `pdf` 包缺 CJK 字体导致的中文空白问题。
class ReportExporter {
  // ===== Excel =====

  /// 把完整数据集导出为 .xlsx 字节（任务 / 专注 / 习惯 / 打卡记录 四张表）。
  ///
  /// [includeTrash] 为 true 时，回收站任务也并入「任务」表最后一列标记「是」。
  static Uint8List buildDatasetExcel({
    required TaskProvider task,
    required FocusProvider focus,
    required HabitProvider habit,
    bool includeTrash = false,
  }) {
    final excel = Excel.createExcel();
    // 默认 Sheet1 改名成第一张表，避免末尾多出一个空表。
    excel.rename('Sheet1', '任务');
    _fillTaskSheet(excel['任务'], task, includeTrash);
    _fillFocusSheet(excel['专注记录'], focus);
    _fillHabitSheet(excel['习惯'], habit);
    _fillCheckInSheet(excel['打卡记录'], habit);

    final List<int>? raw = excel.save();
    return Uint8List.fromList(raw ?? const []);
  }

  static void _fillTaskSheet(Sheet s, TaskProvider task, bool includeTrash) {
    const headers = [
      '标题',
      '优先级',
      '分类',
      '截止时间',
      '状态',
      '完成时间',
      '是否已删除',
    ];
    for (var c = 0; c < headers.length; c++) {
      _set(s, 0, c, headers[c]);
    }
    var r = 1;
    void writeRow(Task t, bool deleted) {
      _set(s, r, 0, t.title);
      _set(s, r, 1, t.priority.label);
      _set(s, r, 2, t.category.label);
      _set(s, r, 3, t.dueDate == null ? '' : _fmt(t.dueDate!));
      _set(s, r, 4, t.done ? '已完成' : '未完成');
      _set(s, r, 5, t.completedAt == null ? '' : _fmt(t.completedAt!));
      _set(s, r, 6, deleted ? '是' : '否');
      r++;
    }

    for (final t in task.tasks) writeRow(t, false);
    if (includeTrash) {
      for (final t in task.trash) writeRow(t, true);
    }
  }

  static void _fillFocusSheet(Sheet s, FocusProvider focus) {
    const headers = [
      '日期',
      '开始时间',
      '结束时间',
      '计划时长(分)',
      '实际时长(分)',
      '是否完成',
      '关联任务',
    ];
    for (var c = 0; c < headers.length; c++) {
      _set(s, 0, c, headers[c]);
    }
    var r = 1;
    for (final se in focus.sessions) {
      _set(s, r, 0, _fmtDate(se.startedAt));
      _set(s, r, 1, _fmt(se.startedAt));
      _set(s, r, 2, _fmt(se.endedAt));
      _set(s, r, 3, (se.plannedSec / 60).round());
      _set(s, r, 4, (se.durationSec / 60).toDouble());
      _set(s, r, 5, se.completed ? '是' : '否');
      _set(s, r, 6, se.taskTitle ?? '');
      r++;
    }
  }

  static void _fillHabitSheet(Sheet s, HabitProvider habit) {
    const headers = [
      '习惯',
      '表情',
      '创建时间',
      '当前连续(天)',
      '最长连续(天)',
      '累计打卡',
      '提醒',
      '是否归档',
    ];
    for (var c = 0; c < headers.length; c++) {
      _set(s, 0, c, headers[c]);
    }
    var r = 1;
    for (final h in habit.habits) {
      _set(s, r, 0, h.title);
      _set(s, r, 1, h.emoji);
      _set(s, r, 2, _fmt(h.createdAt));
      _set(s, r, 3, habit.currentStreak(h));
      _set(s, r, 4, habit.longestStreak(h));
      _set(s, r, 5, habit.checkInCount(h));
      _set(s, r, 6, h.reminderMinute == null ? '' : _fmtMinute(h.reminderMinute!));
      _set(s, r, 7, h.archived ? '是' : '否');
      r++;
    }
  }

  static void _fillCheckInSheet(Sheet s, HabitProvider habit) {
    _set(s, 0, 0, '习惯');
    _set(s, 0, 1, '打卡日期');
    final titleById = {for (final h in habit.habits) h.id: h.title};
    var r = 1;
    for (final c in habit.checkIns) {
      final name = titleById[c.habitId] ?? c.habitId;
      _set(s, r, 0, name);
      _set(s, r, 1, CheckIn.dateKey(c.date));
      r++;
    }
  }

  // ===== PDF =====

  /// 把一张已栅格化的回顾长图（PNG 字节）包成单页 PDF，便于归档 / 打印。
  ///
  /// 复用 Flutter 引擎渲染（含中文），因此 PDF 内中文正常显示，无需内嵌 CJK 字体。
  /// 页面用 A4 + contain 适配，长图按比例居中，不被拉伸。
  static Future<Uint8List> buildPeriodReportPdf(
    Uint8List pngBytes, {
    required String title,
  }) async {
    final pdf = pw.Document(title: title, author: '有条');
    final image = pw.MemoryImage(pngBytes);
    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(16),
        build: (context) =>
            pw.Center(child: pw.Image(image, fit: pw.BoxFit.contain)),
      ),
    );
    return pdf.save();
  }

  // ===== 内部工具 =====

  static void _set(Sheet s, int row, int col, Object value) {
    s.cell(CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row)).value =
        TextCellValue(value.toString());
  }

  static String _fmt(DateTime d) =>
      '${d.year}-${_p2(d.month)}-${_p2(d.day)} ${_p2(d.hour)}:${_p2(d.minute)}';

  static String _fmtDate(DateTime d) =>
      '${d.year}-${_p2(d.month)}-${_p2(d.day)}';

  static String _fmtMinute(int m) =>
      '${_p2(m ~/ 60)}:${_p2(m % 60)}';

  static String _p2(int n) => n.toString().padLeft(2, '0');
}
