import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:todolist/models/task.dart';
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
    /// P1-10：为任务表追加「附件」列（从 [Task.attachments] 派生，不改存储）。
    bool includeAttachments = false,
  }) {
    final excel = Excel.createExcel();
    // 默认 Sheet1 改名成第一张表，避免末尾多出一个空表。
    excel.rename('Sheet1', '任务');
    _fillTaskSheet(excel['任务'], task, includeTrash, includeAttachments);
    _fillFocusSheet(excel['专注记录'], focus);
    _fillHabitSheet(excel['习惯'], habit);
    _fillCheckInSheet(excel['打卡记录'], habit);

    final List<int>? raw = excel.save();
    return Uint8List.fromList(raw ?? const []);
  }

  static void _fillTaskSheet(
      Sheet s, TaskProvider task, bool includeTrash, bool includeAttachments) {
    // P2-6（v2.9.1 审计）：列定义与取值口径统一走 [TaskProvider.taskTableHeaders] /
    // [TaskProvider.taskTableValues]——此前 Excel 与 CSV 各写一份 8 列结构，两处都缺
    // 备注 / 标签 / 子任务 / 开始时间 / 重复规则 / 提醒时刻 / 累计专注，用户把导出的
    // 表格当归档副本时不可逆丢数据，且两份定义随时可能漂移。
    const headers = TaskProvider.taskTableHeaders;
    for (var c = 0; c < headers.length; c++) {
      _set(s, 0, c, headers[c]);
    }
    var r = 1;
    void writeRow(Task t, bool deleted) {
      final values = TaskProvider.taskTableValues(
        t,
        deleted: deleted,
        includeAttachments: includeAttachments,
      );
      for (var c = 0; c < values.length; c++) {
        _set(s, r, c, values[c]);
      }
      r++;
    }

    for (final t in task.tasks) {
      writeRow(t, false);
    }
    if (includeTrash) {
      for (final t in task.trash) {
        writeRow(t, true);
      }
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
    // P2-5（v2.9.3 审计）：与 CSV 共用同一列定义（单一真源，见
    // [HabitProvider.habitExportHeaders]）。此前 Excel 自写一份 8 列表头，
    // v2.9.3 给 CSV 补的「每日目标 / 宽限日」与「累计达标」口径全部缺席，
    // 量化量级在 Excel 副本里整体丢失。
    for (var c = 0; c < HabitProvider.habitExportHeaders.length; c++) {
      _set(s, 0, c, HabitProvider.habitExportHeaders[c]);
    }
    var r = 1;
    for (final h in habit.habits) {
      final cells = habit.habitExportCells(h);
      for (var c = 0; c < cells.length; c++) {
        _set(s, r, c, cells[c]);
      }
      r++;
    }
  }

  static void _fillCheckInSheet(Sheet s, HabitProvider habit) {
    // P2-5：打卡表同样共用 [HabitProvider.checkInExportHeaders]，补「累计量」列
    // （此前只有习惯 + 日期两列，量化习惯「喝了多少」在 Excel 副本不可见）。
    for (var c = 0; c < HabitProvider.checkInExportHeaders.length; c++) {
      _set(s, 0, c, HabitProvider.checkInExportHeaders[c]);
    }
    final titleById = {for (final h in habit.habits) h.id: h.title};
    var r = 1;
    for (final c in habit.checkIns) {
      final cells = habit.checkInExportCells(
        c,
        name: titleById[c.habitId] ?? c.habitId,
      );
      for (var i = 0; i < cells.length; i++) {
        _set(s, r, i, cells[i]);
      }
      r++;
    }
  }

  // ===== PDF =====

  /// 把一张已栅格化的回顾长图（PNG 字节）包成 PDF，便于归档 / 打印。
  ///
  /// 复用 Flutter 引擎渲染（含中文），因此 PDF 内中文正常显示，无需内嵌 CJK 字体。
  /// 页面用 A4 + contain 适配，长图按比例居中，不被拉伸。
  ///
  /// P1-10 多页：第 1 页为回顾长图；[detailPages] 非空时，其每个 PNG（同样由
  /// Flutter 引擎栅格化、含中文）依次作为后续页追加。保持「先栅格化再包 PDF」
  /// 思路，规避 `pdf` 包缺 CJK 字体导致的中文空白问题。
  static Future<Uint8List> buildPeriodReportPdf(
    Uint8List pngBytes, {
    required String title,
    List<Uint8List>? detailPages,
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
    // P1-10：结构化明细页（已栅格化的 PNG，由调用方从回顾文本现渲染）。
    for (final page in detailPages ?? const <Uint8List>[]) {
      final img = pw.MemoryImage(page);
      pdf.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(16),
          build: (context) =>
              pw.Center(child: pw.Image(img, fit: pw.BoxFit.contain)),
        ),
      );
    }
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

  static String _p2(int n) => n.toString().padLeft(2, '0');
}
