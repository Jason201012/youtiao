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
      // P3-3（v2.9.5 审计）：改用 [TaskProvider.taskTableCells]——数值列
      // （预计时长 / 累计专注）回传 int，经 [_set] 写入真正的数值单元格，
      // 可求和 / 排序 / 透视。此前取 `taskTableValues`（全 String），
      // P3-6 修好了专注 / 习惯 / 打卡三表，任务表是最后一个漏网点。
      final values = TaskProvider.taskTableCells(
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
    // P3-11（v2.9.5 审计）：表头与取值改走 [FocusProvider.focusExportHeaders] /
    // [FocusProvider.focusExportCells] 单一真源——此前与 `exportCsv` 各写一份，
    // 任何加列动作都要记得改两处，漏一边就静默漂移。
    for (var c = 0; c < FocusProvider.focusExportHeaders.length; c++) {
      _set(s, 0, c, FocusProvider.focusExportHeaders[c]);
    }
    var r = 1;
    for (final se in focus.sessions) {
      final cells = focus.focusExportCells(se);
      for (var c = 0; c < cells.length; c++) {
        _set(s, r, c, cells[c]);
      }
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

  // P3-11（v2.9.5 审计）：旧的 `_fmt` / `_fmtDate` / `_p2` 已随专注表改走
  // FocusProvider 的单元格真源而整体删除（此前注释说不再使用却漏删函数体，
  // 触发 unused_element）；若后续新增手写列再按需恢复。

  /// P3-6（v2.9.4 审计）：按值类型写入单元格，而不是一律 `toString()`。
  ///
  /// 此前 [_set] 对所有值都写 `TextCellValue(value.toString())`，于是 Excel 里
  /// **每一个**数字都是文本：单元格左上角带绿色三角、「求和」得到 0、排序按
  /// 字符串比（「10」排在「9」前面）。用户拿这份导出做二次统计时必须先手工
  /// 「转换为数字」——一份声称是数据表的文件却不能被当数据表用。
  ///
  /// 现在按类型分派到 excel 包的原生值类型：
  /// - [int] → [IntCellValue]（Excel 里是真正的整数，可求和）；
  /// - [double] → [DoubleCellValue]（专注时长这类带小数的量）；
  /// - 其余（含 [bool]、日期的**字符串**形态如 `2026-09-19 08:30`）→ 文本。
  ///
  /// 刻意**不**把日期字符串改成 DateCellValue：这些列是
  /// `yyyy-MM-dd HH:mm` 的复合文本，转成日期会丢「时分」语义或引入时区解释，
  /// 反而制造新的歧义。
  /// P3-11（v2.9.6 审计）：原 [DateTime] 分支已删——P3-3（v2.9.5）改造后
  /// `taskTableCells` 等四张表真源全部产出结构化标量，再无任何表产出
  /// [DateTime]，该分支为死代码。
  static void _set(Sheet s, int row, int col, Object value) {
    final cell =
        s.cell(CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row));
    if (value is int) {
      cell.value = IntCellValue(value);
    } else if (value is double) {
      cell.value = DoubleCellValue(value);
    } else {
      cell.value = TextCellValue(value.toString());
    }
  }
}
