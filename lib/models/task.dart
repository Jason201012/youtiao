import 'package:flutter/material.dart';
import 'package:lpinyin/lpinyin.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/models/attachment.dart';

/// 任务数据模型（对应设计稿：优先级色条、分类标签、截止日期、子任务、完成态）
enum Priority { high, medium, low }

/// 优先级短名（用于导出 / 标签展示）。
/// 直接作为枚举成员，避免依赖外部 extension 的可见性。
extension PriorityLabel on Priority {
  String get label {
    switch (this) {
      case Priority.high:
        return '高';
      case Priority.medium:
        return '中';
      case Priority.low:
        return '低';
    }
  }
}

enum Category { work, life, study }

/// F-7（v2.8.5 审计）：重复任务「未写时刻」时的默认提醒时刻（07:00，自 00:00 起分钟数）。
///
/// 编辑弹层（new_task_sheet）与自然语言快速录入（task_parser）**必须共用这一常量**：
/// 此前弹层默认 07:00、解析器补 09:00，同样输入「每天」两条创建路径响铃时刻不同。
/// 从根上杜绝再次漂移——改默认值只改这里。
const int kDefaultRepeatMinute = 7 * 60;

/// 重复规则：控制任务在哪些天「循环出现 / 提醒」。
/// - none：一次性任务（不重复）
/// - daily：每天
/// - weekly：每周指定的若干星期（[Task.repeatWeekdays]）
/// - interval：每隔 N 天（[Task.repeatInterval]，以 [Task.repeatAnchor] 为锚点）
/// - weekday：仅工作日（周一至周五）
enum RepeatType { none, daily, weekly, interval, weekday, monthly }

extension RepeatTypeLabel on RepeatType {
  /// 弹层 / 标签上的短名
  String get label {
    switch (this) {
      case RepeatType.none:
        return '不重复';
      case RepeatType.daily:
        return '每天';
      case RepeatType.weekly:
        return '每周';
      case RepeatType.interval:
        return '每隔N天';
      case RepeatType.weekday:
        return '仅工作日';
      case RepeatType.monthly:
        return '每月';
    }
  }
}

extension PriorityColor on Priority {
  /// 返回对应优先级语义色（浅/深由调用方按 brightness 选择）
  Color lightColor() {
    switch (this) {
      case Priority.high:
        return AppColors.lightHigh;
      case Priority.medium:
        return AppColors.lightMedium;
      case Priority.low:
        return AppColors.lightLow;
    }
  }

  Color darkColor() {
    switch (this) {
      case Priority.high:
        return AppColors.darkHigh;
      case Priority.medium:
        return AppColors.darkMedium;
      case Priority.low:
        return AppColors.darkLow;
    }
  }
}

extension CategoryLabel on Category {
  String get label {
    switch (this) {
      case Category.work:
        return '工作';
      case Category.life:
        return '生活';
      case Category.study:
        return '学习';
    }
  }
}

/// 任务状态：待办 / 已完成。
/// 看板页按此分为两列；可在列间拖拽（仅状态泳道），点击卡片进详情，
/// 卡片上的勾选圈负责改状态（U2-4 / P2-7，v2.9.5/v2.9.6 审计）。
enum TaskStatus { todo, done }

extension TaskStatusLabel on TaskStatus {
  String get label {
    switch (this) {
      case TaskStatus.todo:
        return '待办';
      case TaskStatus.done:
        return '已完成';
    }
  }
}

/// 子任务条目：可勾选的细项，用于把一个任务拆成若干步骤并跟踪进度。
/// 纯数据，序列化进 [Task.toJson] 的 `subtasks` 列表，复用任务的 SQLite JSON 存储，无需额外迁移。
class SubTask {
  final String id;
  final String title;
  final bool done;

  const SubTask({required this.id, required this.title, this.done = false});

  SubTask copyWith({String? title, bool? done}) => SubTask(
        id: id,
        title: title ?? this.title,
        done: done ?? this.done,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'done': done,
      };

  factory SubTask.fromJson(Map<String, dynamic> j) => SubTask(
        id: (j['id'] as String?) ?? '',
        title: (j['title'] as String?) ?? '',
        done: (j['done'] as bool?) ?? false,
      );
}

/// 截止时刻的**比较键**归一 —— 排程超期判定、排序比较、首页分区排序、
/// 逾期判定与看板 / 任务行日差文案共用的唯一真源（P3-1，v2.9.5 审计提出、
/// v2.9.6 审计横向推广）。
///
/// 本应用的截止时间有两种存储形态：
/// - **纯日期语义**：「当天 00:00」（模板 `dueInDays` 的产物）或「当天 23:59」
///   （录入侧历史遗留的占位钉法）。这类截止只有「哪一天」的含义，
///   当天内任何时刻完成都算没超期（v2.9.4 P2-5 的结论，必须保留）。
/// - **带具体时刻**：用户显式选了「今天 10:20 截止」。v2.9.4 把它也按日期口径
///   处理，引入同日假阴性——截止 10:20、14:00 才开始做、14:30 结束，整段都晚于
///   截止时刻，却不再提示「预计超过截止」（P3-1）。
///
/// 归一规则：纯日期形态 → date-only；带时刻 → 原样返回。
/// 排序与超期判定都过这里，两侧口径**不会**再漂移。
DateTime dueCompareKey(DateTime due) =>
    dueIsPureDateForm(due) ? _dateOnlyOf(due) : due;

/// 截止是否为「纯日期」存储形态（当天 00:00 / 23:59，判据与 [dueCompareKey]
/// 同源）。超期判定据此选择比较粒度：纯日期按「日」比，带时刻按「时刻」比。
///
/// P3-13（v2.9.6 审计）：`00:00` 分支此前要求 `second == 0` 而 `23:59` 分支
/// 不判秒（`23:59:59` 也算纯日期），判据不对称。统一为**都不判秒**：
/// 00:00:01 是录入 / 序列化链路产生的纯日期形态变体（用户不会主动设 1 秒），
/// 归入按日比较更符合其语义；两侧分支从此对称。
bool dueIsPureDateForm(DateTime due) =>
    (due.hour == 0 && due.minute == 0) || (due.hour == 23 && due.minute == 59);

DateTime _dateOnlyOf(DateTime d) => DateTime(d.year, d.month, d.day);

class Task {
  final String id;
  final String title;
  final Priority priority;
  final Category category;
  final DateTime? dueDate;
  /// 任务开始时间（可空）。用于表达「时间段」任务的起点（如「14:00-15:00 开会」），
  /// 与 [dueDate]（截止时间）并列。序列化为 `startDate`，旧数据缺省为 null（向后兼容）。
  /// 仅作展示与排序语义使用，不参与提醒调度（提醒仍以 [dueDate]/重复规则为准）。
  final DateTime? startDate;
  final TaskStatus status;
  final DateTime? completedAt;

  /// 子任务列表（可勾选细项）。取代旧的 subtaskTotal/subtaskDone 两个整数字段；
  /// 进度由 [subtaskTotal]/[subtaskDone] 派生，保持对外可读语义不变。
  final List<SubTask> subtasks;

  final DateTime? deletedAt;

  /// 是否完成：由 [status] 派生，保持对外只读语义一致。
  bool get done => status == TaskStatus.done;

  /// T1-1：是否带有可用的预计时长（>0）。排程建议与偏差提示统一用这个判定，
  /// 避免各处重复写 `estimateMinutes != null && estimateMinutes! > 0`。
  bool get hasEstimate => estimateMinutes != null && estimateMinutes! > 0;

  /// T1-1：累计专注分钟数（四舍五入）。用于与 [estimateMinutes] 比对偏差。
  int get focusedMinutes => (focusSecTotal / 60).round();

  /// 是否「逾期」：统一口径（看板统计卡、首页「逾期」筛选、分享长图共用）。
  /// 规则：未完成、非重复任务，且截止日期按「天」严格早于今天
  /// （今天到点未做不算逾期）。重复任务不计逾期（v2.2.8 对齐过）。
  ///
  /// P3-1（v2.9.6 审计）：日差判定统一经 [dueCompareKey] 取比较键——本应用
  /// 截止时间有「纯日期（00:00/23:59）」与「带时刻」两种存储形态，逾期判定
  /// 始终按「天」比，但取键路径与排程 / 排序收口到同一真源，未来判据调整
  /// （如 P3-13 的判秒统一）不会再与本处漂移。
  static bool isOverdue(Task t, DateTime now) {
    if (t.done || t.isRepeating || t.dueDate == null) return false;
    final today = DateTime(now.year, now.month, now.day);
    final key = dueCompareKey(t.dueDate!);
    return DateTime(key.year, key.month, key.day).isBefore(today);
  }

  /// 子任务总数（由 [subtasks] 派生）。
  int get subtaskTotal => subtasks.length;

  /// 已勾选的子任务数（由 [subtasks] 派生）。
  int get subtaskDone => subtasks.where((s) => s.done).length;

  /// 重复规则：控制任务在哪些天循环出现 / 提醒。默认 [RepeatType.none]（一次性）。
  final RepeatType repeat;

  /// 每周重复的星期集合，取值 1..7（[DateTime.weekday]：1=周一 … 7=周日）。
  /// 仅当 [repeat]==[RepeatType.weekly] 时有意义。
  final List<int> repeatWeekdays;

  /// 每隔 N 天重复（N≥1）。仅当 [repeat]==[RepeatType.interval] 时有意义。
  /// F-10：默认由 2 改为 1——选「每隔 N 天」时初始显示「每 1 天」（即每天起步），
  /// 与多数人的直觉一致；步进器范围本就允许 1..30。
  final int repeatInterval;

  /// 重复提醒时间，单位「自 00:00 起的分钟数」(0-1439)。
  /// 任意 [repeat]!=none 时都表示「在这一天的该时刻提醒」。
  final int? repeatMinute;

  /// 每隔 N 天规则的锚点日期（date-only）。[repeat]==[RepeatType.interval] 时，
  /// 从这一天起每 N 天一次。创建时由 UI 默认填为当天；旧数据无此字段则回退为「不重复」。
  final DateTime? repeatAnchor;

  /// 跳过的具体日期（yyyy-MM-dd 列表）。跳过 ≠ 完成：
  /// 当天不出现、不打卡、不影响连续天数（统计完成率时也不计为缺勤）。
  /// 旧 JSON 无此字段时缺省为空列表（向后兼容，零迁移）。
  final List<String> skipDates;

  /// 重复结束日期（yyyy-MM-dd，date-only，避免时区问题；null = 无限循环）。
  /// 该日（含）之后不再循环出现、不再排提醒、午夜重置也不再重置它。
  /// 旧 JSON 无此字段时缺省为 null（向后兼容）。「结束重复」即把此字段设为昨天。
  final String? repeatUntil;

  /// P1-4（v2.9.9 审计）：循环暂停窗口的结束日（yyyy-MM-dd，date-only；null = 未暂停）。
  ///
  /// v2.9.2 的暂停实现刻意不加字段、只批量写 [skipDates]，但「暂停态」的派生判定
  /// 只对「每天」规则成立：weekly / monthly / interval 的暂停在非循环日**看不到
  /// 角标、「恢复循环」入口不可达**（P1-4），且无法与「单独跳过某天」区分。现在
  /// [TaskProvider.pauseRepeatsUntil] 在写 skipDates 的同时落本字段（展示 + 判定用，
  /// skipDates 仍是「当天不出现」语义的唯一真源），[TaskProvider.resumeRepeats]
  /// 恢复时清除；到期后由 [pausedUntilDate] 的窗口判定自然失效，无需定时器。
  /// 旧 JSON 无此字段时缺省为 null（向后兼容，零迁移）；旧数据（v2.9.9 及更早
  /// 的暂停）由 [pausedUntilDate] 的回退推导兜底展示。
  final String? pausedUntil;

  /// F7：occurrence 级完成历史（yyyy-MM-dd 列表，date-only）。
  ///
  /// 重复任务的完成记录此前只存在单槽 [completedAt] 里，午夜重置会把昨天（及更早）
  /// 的完成痕迹整体抹掉，导致热力图 / 周报 / 连续打卡天数系统性失真——
  /// 「连续 30 天完成每天喝水」在统计上只算 1 天。
  /// 本字段按「日」沉淀完成记录，午夜重置**不清除**它（只清 status / completedAt）。
  /// 一次性任务也会落一条，便于「完成日」口径统一（统计只读本字段 + [completedAt]）。
  /// 旧 JSON 无此字段时缺省为空列表（向后兼容，零迁移）。
  final List<String> doneDates;

  /// 每月重复的「日」(1-31)。仅当 [repeat]==[RepeatType.monthly] 且 [monthlyWeekday]==null 时有意义，
  /// 表示「每月 N 号」循环（如「每月 15 号交房租」）。溢出月份（如 31 在 2 月）自动夹到当月最后一天。
  /// 旧 JSON 无此字段时缺省为 1（向后兼容，零迁移）。
  final int monthlyDay;

  /// 每月第几个周几（仅 [repeat]==monthly 且不为 null 时有意义）。
  /// [monthlyWeekday] 取值 1..7（周一..周日）；[monthlyWeekIndex] 取值 1..4 表示第 N 个，
  /// 5 表示「最后一个」（如「每月最后一个周日」）。二者同时存在时优先于 [monthlyDay]。
  /// 旧 JSON 无此字段时缺省为 null（向后兼容，零迁移）。
  final int? monthlyWeekday;

  /// 每月第几个周几的「第几」(1..5，5=最后一个)。与 [monthlyWeekday] 配套使用。
  final int? monthlyWeekIndex;

  /// 每月「倒数第 N 天」(P1-9)：0 = 未启用；1 = 每月最后一天，2 = 倒数第二天，3 = 倒数第三天。
  ///
  /// 用于覆盖「月底」这类日期不固定的场景（如「每月最后一天 交房租」），
  /// 这是按月首计数的 [monthlyDay] 无法表达的语义。
  /// 三者同时存在时优先级最高（语义最明确）。旧 JSON 无此字段时缺省为 0（向后兼容，零迁移）。
  final int monthlyFromEnd;

  /// 任务备注 / 解释：对任务的补充说明（链接、思路、细节等），可选，默认空串。
  final String note;

  /// 标签：用户自定义自由文本标签（如「紧急」「会议」），用于搜索与筛选。
  /// 存为字符串列表，序列化为 JSON 的 `tags`；旧数据缺省为空列表（向后兼容）。
  final List<String> tags;

  /// 累计专注时长（秒）：由专注会话回填（见 FocusProvider.onFocusRecorded /
  /// TaskProvider.addFocusSec），用于任务行展示「已专注 X 分钟」。序列化为
  /// [`focusSecTotal`]，旧数据缺省为 0。
  final int focusSecTotal;

  /// 同一分区内的手动排序权重（越小越靠前）。拖拽排序时由 TaskProvider 重算并持久化。
  /// 序列化为 `order`（double），缺省为 0.0。
  final double order;

  /// 提醒提前量（分钟）：一次性「截止提醒」在截止时间之前该分钟数触发（0 = 准时）。
  /// 仅对 [repeat]==none 的任务生效（重复任务有自己的 [repeatMinute] 触发时刻）。
  /// 序列化为 `reminderOffsetMin`，旧数据缺省为 0（向后兼容）。
  final int reminderOffsetMin;

  /// 预计时长（分钟，1..43200 即 30 天）。null = 未预估（零迁移）。
  ///
  /// T1-1：自然语言解析器（[TaskParser]）早已能识别「预计 30 分钟」并产出
  /// `ParsedTask.estimateMinutes`，但 Task 模型此前没有该字段——解析结果在创建任务时
  /// 即被丢弃（只塞进备注文本），用户反复输入却永远不落库。本字段把它提升为结构化真源：
  /// 既供「今日排程建议」（[ScheduleAdvice]）做顺延预估，也供与累计专注时长
  /// （[focusSecTotal]）比对给出「高估 / 低估」偏差提示。
  /// 序列化为 `estimateMinutes`，旧数据缺省为 null（向后兼容，零迁移）。
  final int? estimateMinutes;

  /// 是否置顶/星标：置顶任务在所属分区内固定排最前（优先于手动 [order]），
  /// 用于把高频/重要任务常驻列表顶部。序列化为 `pinned`，缺省 false（向后兼容，零迁移）。
  final bool pinned;

  /// 标题拼音首字母串（如「整理周会纪要」→ "zhenglizhouhuijiyao"），用于「拼音首字母搜索」。
  /// 由 [computePinyinInitials] 在新建/编辑任务时计算并落库，旧数据缺省为空串（向后兼容，零迁移）。
  /// 搜索时与标题一起做包含匹配（见 [GlobalSearch._matchesTask]）。
  /// 注意：此为派生字段，[copyWith] 默认保留旧值，调用方无需每次重算。
  final String pinyinInitials;

  /// 本地最后更新时间（UTC）。用于本地增量持久化/备份的排序与去重依据，
  /// 不参与联网（纯离线）。序列化为 `updatedAt`，旧数据缺省为 null（向后兼容）。
  final DateTime? updatedAt;

  /// 任务附件引用列表（图片 / 录音 / 文件）。元数据随 Task 持久化到 SQLite，
  /// 二进制文件存于 App 私有 `attachments/<taskId>/` 目录，全程本地、不联网。
  /// 旧 JSON 无此字段时缺省为空列表（向后兼容，零迁移）。
  final List<AttachmentRef> attachments;

  const Task({
    required this.id,
    required this.title,
    required     this.priority,
    required this.category,
    this.dueDate,
    this.startDate,
    this.status = TaskStatus.todo,
    this.completedAt,
    this.subtasks = const [],
    this.deletedAt,
    this.repeat = RepeatType.none,
    this.repeatWeekdays = const [],
    this.repeatInterval = 1,
    this.repeatMinute,
    this.repeatAnchor,
    this.skipDates = const [],
    this.repeatUntil,
    this.pausedUntil,
    this.doneDates = const [],
    this.monthlyDay = 1,
    this.monthlyWeekday,
    this.monthlyWeekIndex,
    this.monthlyFromEnd = 0,
    this.note = '',
    this.tags = const [],
    this.focusSecTotal = 0,
    this.order = 0.0,
    this.reminderOffsetMin = 0,
    this.estimateMinutes,
    this.pinned = false,
    this.pinyinInitials = '',
    this.updatedAt,
    this.attachments = const [],
  });

  // 哨兵：区分"未传该参数（保留旧值）"与"显式传 null（清空该字段）"。
  // 否则 copyWith(dueDate: null) 会被 `?? this.dueDate` 误判为"保留旧值"，
  // 导致取消完成/恢复/清空截止时间等意图清空的操作实际无效。
  static const Object _kKeep = Object();

  Task copyWith({
    String? id,
    String? title,
    Priority? priority,
    Category? category,
    Object? dueDate = _kKeep,
    Object? startDate = _kKeep,
    TaskStatus? status,
    Object? completedAt = _kKeep,
    List<SubTask>? subtasks,
    Object? deletedAt = _kKeep,
    RepeatType? repeat,
    List<int>? repeatWeekdays,
    int? repeatInterval,
    Object? repeatMinute = _kKeep,
    Object? repeatAnchor = _kKeep,
    List<String>? skipDates,
    Object? repeatUntil = _kKeep,
    // P1-4（v2.9.9 审计）：暂停窗口字段必须能「显式清空」——resumeRepeats 要写
    // null 清除；`?? this.pausedUntil` 会把它误判成保留旧值。
    Object? pausedUntil = _kKeep,
    List<String>? doneDates,
    int? monthlyDay,
    // F-9：monthlyWeekday / monthlyWeekIndex 也必须能「显式清空」。
    // 二者此前用 `monthlyWeekday ?? this.monthlyWeekday`，传 null 会被当成「保留旧值」，
    // 于是「第 N 个周几」永远改不回「固定几号」模式（旧规则清不掉，会盖住 monthlyDay）。
    Object? monthlyWeekday = _kKeep,
    Object? monthlyWeekIndex = _kKeep,
    int? monthlyFromEnd,
    String? note,
    List<String>? tags,
    int? focusSecTotal,
    double? order,
    int? reminderOffsetMin,
    // T1-1：可空字段，必须能「显式清空」——`estimateMinutes ?? this.estimateMinutes`
    // 会把 `copyWith(estimateMinutes: null)` 误判成「保留旧值」，用户永远删不掉预估。
    Object? estimateMinutes = _kKeep,
    bool? pinned,
    String? pinyinInitials,
    Object? updatedAt = _kKeep,
    List<AttachmentRef>? attachments,
  }) =>
      Task(
        id: id ?? this.id,
        title: title ?? this.title,
        priority: priority ?? this.priority,
        category: category ?? this.category,
        dueDate: dueDate == _kKeep ? this.dueDate : dueDate as DateTime?,
        startDate: startDate == _kKeep ? this.startDate : startDate as DateTime?,
        status: status ?? this.status,
        completedAt:
            completedAt == _kKeep ? this.completedAt : completedAt as DateTime?,
        subtasks: subtasks ?? this.subtasks,
        deletedAt: deletedAt == _kKeep ? this.deletedAt : deletedAt as DateTime?,
        repeat: repeat ?? this.repeat,
        repeatWeekdays: repeatWeekdays ?? this.repeatWeekdays,
        repeatInterval: repeatInterval ?? this.repeatInterval,
        repeatMinute:
            repeatMinute == _kKeep ? this.repeatMinute : repeatMinute as int?,
        repeatAnchor: repeatAnchor == _kKeep
            ? this.repeatAnchor
            : repeatAnchor as DateTime?,
        skipDates: skipDates ?? this.skipDates,
        repeatUntil:
            repeatUntil == _kKeep ? this.repeatUntil : repeatUntil as String?,
        pausedUntil:
            pausedUntil == _kKeep ? this.pausedUntil : pausedUntil as String?,
        doneDates: doneDates ?? this.doneDates,
        monthlyDay: monthlyDay ?? this.monthlyDay,
        monthlyWeekday: monthlyWeekday == _kKeep
            ? this.monthlyWeekday
            : monthlyWeekday as int?,
        monthlyWeekIndex: monthlyWeekIndex == _kKeep
            ? this.monthlyWeekIndex
            : monthlyWeekIndex as int?,
        monthlyFromEnd: monthlyFromEnd ?? this.monthlyFromEnd,
        note: note ?? this.note,
        tags: tags ?? this.tags,
        focusSecTotal: focusSecTotal ?? this.focusSecTotal,
        order: order ?? this.order,
        reminderOffsetMin: reminderOffsetMin ?? this.reminderOffsetMin,
        estimateMinutes: estimateMinutes == _kKeep
            ? this.estimateMinutes
            : estimateMinutes as int?,
        pinned: pinned ?? this.pinned,
        pinyinInitials: pinyinInitials ?? this.pinyinInitials,
        updatedAt: updatedAt == _kKeep ? this.updatedAt : updatedAt as DateTime?,
        attachments: attachments ?? this.attachments,
      );

  /// 序列化为 JSON（用于 shared_preferences 持久化）
  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'priority': priority.name,
        'category': category.name,
        'dueDate': dueDate?.toIso8601String(),
        'startDate': startDate?.toIso8601String(),
        'status': status.name,
        'done': done, // 保留旧字段，兼容历史备份/读取
        'completedAt': completedAt?.toIso8601String(),
        'subtasks': subtasks.map((s) => s.toJson()).toList(),
        'deletedAt': deletedAt?.toIso8601String(),
        'repeat': repeat.name,
        'repeatWeekdays': repeatWeekdays,
        'repeatInterval': repeatInterval,
        'repeatMinute': repeatMinute,
        'repeatAnchor': repeatAnchor?.toIso8601String(),
        'skipDates': skipDates,
        'repeatUntil': repeatUntil,
        'pausedUntil': pausedUntil,
        'doneDates': doneDates,
        'monthlyDay': monthlyDay,
        'monthlyWeekday': monthlyWeekday,
        'monthlyWeekIndex': monthlyWeekIndex,
        'monthlyFromEnd': monthlyFromEnd,
        'note': note,
        'tags': tags,
        'focusSecTotal': focusSecTotal,
        'order': order,
        'reminderOffsetMin': reminderOffsetMin,
        'estimateMinutes': estimateMinutes,
        'pinned': pinned,
        'pinyinInitials': pinyinInitials,
        'updatedAt': updatedAt?.toIso8601String(),
        'attachments': attachments.map((a) => a.toJson()).toList(),
      };

  /// 从 JSON 反序列化（兼容旧版仅含 [done] 布尔的备份，以及 v1.9.4 之前
  /// 用 [dailyReminder] 布尔表达的「每天」任务）。
  factory Task.fromJson(Map<String, dynamic> j) {
    // 旧数据兼容：没有 repeat 字段时，dailyReminder=true 视作「每天」。
    final repeatStr = j['repeat'] as String?;
    final RepeatType repeat;
    if (repeatStr != null) {
      repeat = RepeatType.values.firstWhere(
        (e) => e.name == repeatStr,
        orElse: () => RepeatType.none,
      );
    } else {
      repeat = (j['dailyReminder'] as bool? ?? false)
          ? RepeatType.daily
          : RepeatType.none;
    }
    final wdRaw = j['repeatWeekdays'];
    final List<int> weekdays = wdRaw is List
        ? (wdRaw.whereType<int>().where((d) => d >= 1 && d <= 7).toSet().toList()
          ..sort())
        : const <int>[];
    final tagsRaw = j['tags'];
    final List<String> tags = tagsRaw is List
        ? tagsRaw.whereType<String>().toList()
        : const <String>[];
    // P0-1：附件原始列表（向后兼容：旧备份无此字段时缺省空列表）。
    final attRaw = j['attachments'];
    return Task(
      // S6 修复：id 缺省时回退空串而非抛异常（配合备份校验兜底，避免恢复直接崩）。
      id: (j['id'] as String?) ?? '',
      title: (j['title'] as String?) ?? '',
      // S6 修复：枚举字段容错——未知值/缺省回退到默认优先级/分类，
      // 与 repeat 既有的 asNameMap 容错口径一致，避免"非法枚举"备份恢复时整体失败。
      priority: _parsePriority(j['priority']),
      category: _parseCategory(j['category']),
      dueDate:
          j['dueDate'] == null ? null : DateTime.parse(j['dueDate'] as String),
      startDate:
          j['startDate'] == null ? null : DateTime.parse(j['startDate'] as String),
      status: _parseStatus(j['status'] as String?, j['done'] as bool?),
      completedAt: j['completedAt'] == null
          ? null
          : DateTime.parse(j['completedAt'] as String),
      subtasks: _parseSubtasks(j['subtasks']),
      deletedAt: j['deletedAt'] == null
          ? null
          : DateTime.parse(j['deletedAt'] as String),
      repeat: repeat,
      repeatWeekdays: weekdays,
      // F-8：数值字段统一范围夹取。备份是显式的「不可信输入」入口（可被手改 /
      // 来自他人 / 传输损坏），越界值此前被原样接受：
      // - repeatMinute=9999 → 卡片显示成「每天 166:39」这类不存在的时刻；
      // - monthlyWeekday=9 → _monthlyNthWeekday 永不命中，任务成为
      //   「永不出现、永不提醒」的哑任务，用户几乎无法自查；
      // - repeatInterval=0 / 负数 → 调度侧除零或死循环风险。
      // 夹取口径与 UI 层取值边界（弹层步进器 / 选择器）完全对齐。
      repeatInterval: _clampInt(j['repeatInterval'], 1, 365, 1),
      repeatMinute: _clampIntOrNull(
          j['repeatMinute'] ?? j['dailyReminderMinute'], 0, 1439),
      repeatAnchor: j['repeatAnchor'] == null
          ? null
          : DateTime.parse(j['repeatAnchor'] as String),
      skipDates: _parseSkipDates(j['skipDates']),
      // F-8（v2.8.5 审计）：repeatUntil 合法性校验。非法串（旧版本/手改备份）此前
      // 被原样接受，repeatsOn 内 _parseYmd 回退 1970 → isRepeatEnded 恒真，
      // 任务被悄悄当成「早已结束」（不再循环、不再提醒、掉出重复分区），用户
      // 无从知晓。这里对格式非法的串统一**清空**（视为无限循环）——比「视为
      // 已结束」更安全：最坏情况是多循环/多提醒，而不是静默杀死仍在用的任务。
      repeatUntil: _sanitizeRepeatUntil(j['repeatUntil']),
      // P1-4（v2.9.9 审计）：暂停窗口字段。备份是不可信输入，非法串（旧版本 /
      // 手改）统一清空为「未暂停」——与 repeatUntil 的「清空比视为已结束安全」
      // 同一取向：最坏情况是暂停态丢失（可重新暂停），而不是凭空判为暂停中。
      pausedUntil: _sanitizeYmd(j['pausedUntil']),
      doneDates: _parseSkipDates(j['doneDates']),
      monthlyDay: _clampInt(j['monthlyDay'], 1, 31, 1),
      monthlyWeekday: _clampIntOrNull(j['monthlyWeekday'], 1, 7),
      monthlyWeekIndex: _clampIntOrNull(j['monthlyWeekIndex'], 1, 5),
      monthlyFromEnd: _clampInt(j['monthlyFromEnd'], 0, 31, 0),
      note: j['note'] as String? ?? '',
      tags: tags,
      focusSecTotal: _clampInt(j['focusSecTotal'], 0, 1 << 40, 0),
      order: (j['order'] as num?)?.toDouble() ?? 0.0,
      reminderOffsetMin: _clampInt(j['reminderOffsetMin'], 0, 7 * 24 * 60, 0),
      // T1-1：预估时长范围夹取（1..43200 分钟 = 30 天），与解析器
      // （task_parser 的 `mins > 30 * 24 * 60` 兜底）保持同一区间；
      // 备份是显式不可信输入，越界值（0 / 负数 / 天文数字）一律视为「无预估」。
      estimateMinutes: _clampIntOrNull(j['estimateMinutes'], 1, 30 * 24 * 60),
      pinned: j['pinned'] as bool? ?? false,
      pinyinInitials: j['pinyinInitials'] as String? ?? '',
      updatedAt: j['updatedAt'] == null
          ? null
          : DateTime.parse(j['updatedAt'] as String),
      // P0-1：附件列表（向后兼容：旧备份无 attachments 字段时缺省空列表）。
      attachments: attRaw is List
          ? attRaw
              .whereType<Map>()
              .map((e) => AttachmentRef.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : const <AttachmentRef>[],
    );
  }

  /// 解析任务状态，兼容历史数据：
  /// - 旧版「进行中(doing)」状态统一归并为「待办(todo)」（v2.0.6 起移除 doing 概念）；
  /// - 未知字符串回退到旧的 [done] 布尔字段。
  static TaskStatus _parseStatus(String? s, bool? done) {
    if (s == 'done') return TaskStatus.done;
    if (s == 'todo' || s == 'doing' || s == null) return TaskStatus.todo;
    return (done ?? false) ? TaskStatus.done : TaskStatus.todo;
  }

  /// S6 修复：优先级字段容错解析。未知字符串 / null 回退 [Priority.medium]，
  /// 与 [RepeatType] 既有的 [asNameMap] 容错口径一致，避免非法备份恢复时整体崩溃。
  static Priority _parsePriority(dynamic v) {
    if (v is String) {
      final p = Priority.values.asNameMap()[v];
      if (p != null) return p;
    }
    return Priority.medium;
  }

  /// S6 修复：分类字段容错解析。未知字符串 / null 回退 [Category.life]。
  static Category _parseCategory(dynamic v) {
    if (v is String) {
      final c = Category.values.asNameMap()[v];
      if (c != null) return c;
    }
    return Category.life;
  }

  /// 解析子任务列表；旧数据无 `subtasks` 字段时回退为空列表（向后兼容）。
  static List<SubTask> _parseSubtasks(dynamic raw) {
    if (raw is! List) return const <SubTask>[];
    final out = <SubTask>[];
    for (final e in raw) {
      if (e is Map) {
        out.add(SubTask.fromJson(Map<String, dynamic>.from(e)));
      }
    }
    return out;
  }

  /// 判断 [day]（任意时刻，内部按日期归一化）是否为该任务的「循环日」。
  /// 在 [_baseRepeatsOn] 的基础上叠加两段通用判定：
  ///  1) [repeatUntil]（结束日期）：超过该日（不含当日）不再循环；
  ///  2) [skipDates]（跳过日期）：命中当天的「跳过一次」则当天不出现、不打卡。
  /// 与 android/.../MidnightResetReceiver.kt 的 isRecurrenceToday 保持两侧同步。
  bool repeatsOn(DateTime day) {
    // F-08 修复：把「date-only」契约收进函数内部。
    // 此前直接用传入的 [day] 与零点日期比较，若调用方传了带时分的 DateTime.now()，
    // 「结束日当天 00:00 之后」就会被误判为已结束，与注释承诺的「含当日」矛盾
    // （[isRepeatEnded] 内部做了归一化，这里却没有，属"靠调用方约定维持的正确"）。
    // 与 android/.../MidnightResetReceiver.kt 的 isRecurrenceToday（按 yyyy-MM-dd 判定）
    // 口径一致。
    final d = DateTime(day.year, day.month, day.day);
    // B1：跳过一次（今天在 skipDates 列表里 → 不出现、不打卡、不影响连续天数）。
    return _repeatsOnIgnoringSkip(d) && !skipDates.contains(_ymd(d));
  }

  /// 「纯日历」判定的**公开只读入口**（不含 [skipDates]，其余与 [repeatsOn] 一致）。
  ///
  /// P3-2（v2.9.0 审计）：occurrence 预览的「今天是否仍是循环日」判定需要忽略跳过
  /// ——已跳过的日子必须仍然可见（否则撤销入口不可达，v2.8.8 P2-2 定的口径），
  /// 而 `occurrencesBetween` 会被 `repeatsOn` 的 skip 段滤掉。此前该判定只在模型内部
  /// 可达，UI 侧无法复用，只能借助整段窗口列表绕行；这里开放为公开方法。
  bool occursOnIgnoringSkip(DateTime day) => _repeatsOnIgnoringSkip(day);

  /// U3（v2.9.0 审计）：是否为「已结束重复」的退场任务——重复规则字段仍在
  /// （[isRepeating] 为 true）但 [repeatUntil] 已早于今天，即不会再产生任何循环日。
  ///
  /// [TaskProvider.endRepeat] 保留 [repeat] 字段、只用 `repeatUntil=昨天` 表达退场，
  /// 于是卡片此前仍按重复样式显示（如「每天 07:00 至 09/17」），而任务其实已被清空
  /// dueDate 落进「今天」分区且不再提醒——用户会误以为「结束重复」是删除。此派生标记
  /// 供 UI 打一次性角标「已结束重复」，零 schema 变更（纯推导，旧数据自动生效）。
  bool get repeatEnded {
    if (!isRepeating) return false;
    final u = repeatUntil;
    if (u == null) return false;
    final now = DateTime.now();
    return _parseYmd(u).isBefore(DateTime(now.year, now.month, now.day));
  }

  /// T2-5（v2.9.2 功能增强）：任务当前是否处于「暂停循环」态。
  ///
  /// P1-4（v2.9.9 审计）：旧判据要求「今天本身是循环日且被跳过」，对
  /// weekly / monthly / interval 全部失效——暂停后非循环日看不到角标、
  /// 「恢复循环」入口时隐时现。现以显式 [pausedUntil] 窗口为准（今天 ≤ 窗口
  /// 终点即暂停中，与今天是否循环日无关）；无字段的旧数据回退旧判据，保证
  /// 升级不回退。单独的「跳过一次」不写 [pausedUntil]，不会命中本判定。
  bool get pausedToday => pausedUntilDate != null;

  /// T2-5：暂停区间的结束日（date-only，含当天）；非暂停态返回 null。
  ///
  /// P1-4（v2.9.9 审计）：优先读显式 [pausedUntil]——窗口已过（< 今天）自然
  /// 失效返回 null；窗口晚于 [repeatUntil] 时被夹到 repeatUntil（P3-3：暂停
  /// 「直到」晚于重复结束日不再夸大展示，写入侧 [TaskProvider.pauseRepeatsUntil]
  /// 同步夹取）。无字段（旧数据 / 单独「跳过今天」）时回退旧「从今天起连续
  /// 被跳过的循环日」推导：单独跳过的孤立未来日不撑长区间，超过一年
  /// （滚动窗口量级）按封顶处理，防御手改备份写入超长列表时的死循环。
  ///
  /// P2-4（v3.0.0 审计）：回退推导从「要求今天本身是被跳过的循环日」改为
  /// **扫未来 N 天内被跳过的循环日取最大者**——旧口径要求「今天 ∈ 循环日 ∧
  /// 今天被跳过」，v2.9.9 及更早对 weekly/monthly/interval 任务执行的暂停，
  /// 在非循环日查看时回退恒 null：角标与「恢复循环」入口同时消失（不可见、
  /// 不可恢复）；且在循环日恢复时旧推导把窗口压缩为「当天」，只清一个键、
  /// 未来循环日全部残留。新口径下窗口终点 = 未来最后一个被跳过的循环日，
  /// [TaskProvider.resumeRepeats] 据此清 [今天, 终点] 内全部键（与 v2.9.8
  /// 「清今天及以后」的旧恢复口径等价，但不误伤窗口外的过去历史记录）。
  /// 已知取舍：孤立的单次「跳过某天」（无窗口语义）也会呈现暂停角标——
  /// 旧数据无显式字段无法区分，可恢复的误显远优于不可见/不可恢复。
  DateTime? get pausedUntilDate {
    // P3-11（v3.0.0 审计）：暂停窗口只对重复任务有语义——重复任务被编辑为
    // 「不重复」后字段残留（或手改备份写入）时，显式分支会照常返回窗口终点，
    // 非重复任务误显「已暂停至 M/d」角标且没有任何清除入口。在推导入口统一
    // 守卫：非重复任务恒非暂停态。
    if (!isRepeating) return null;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final f = _parseYmdOrNull(pausedUntil);
    if (f != null) {
      if (f.isBefore(today)) return null; // 窗口已过：自然恢复
      // P3-3（v2.9.9 审计）：重复早于窗口终点结束 → 以重复结束日为准。
      final u = repeatUntil == null ? null : _parseYmd(repeatUntil!);
      if (u != null && u.isBefore(f)) {
        return u.isBefore(today) ? null : u;
      }
      return f;
    }
    // —— 旧数据回退推导（v2.9.9 及更早的暂停 / 单独「跳过今天」）——
    if (!isRepeating || repeatEnded) return null;
    // P3-11（v3.0.0 审计）：非重复任务不应持有该字段（编辑切「不重复」/
    // 结束重复时已清）；此处为回退推导入口，repeatEnded 已排除退场任务。
    // P3-2（v3.0.1 审计）早退：推导窗口终点只能来自「被跳过的循环日」，
    // skipDates 为空时结果恒为 null——无跳过记录的重复任务此前每次构建
    // 行 / 角标都全量扫 3 年（1098 天），列表 / 看板任务多时是可避免的
    // 重复计算。语义与逐位等价（空列表时循环体一次都不命中）。
    if (skipDates.isEmpty) return null;
    // P2-4 扫描窗上限与「暂停直到」选择器上限一致（3 年）。
    DateTime? last;
    for (var i = 0; i <= 366 * 3; i++) {
      final d = DateTime(today.year, today.month, today.day + i);
      if (occursOnIgnoringSkip(d) && skipDates.contains(ymdKey(d))) last = d;
    }
    return last;
  }

  /// P3-2（v3.0.1 审计）：暂停展示信息一次性取齐——`(end: 终点, derived: 是否
  /// 回退推导)`；非暂停态返回 null。
  ///
  /// 回退推导态（无显式 [pausedUntil] 字段，窗口终点 = 未来最后一个被跳过的
  /// 循环日）语义实为「跳过」而非「暂停」——UI 据此区分文案（「已跳过至 M/d」
  /// vs「已暂停至 M/d」），不再把「经未来循环日预览提前跳过某天」（未发生
  /// 任何暂停）误呈现为暂停态；「恢复循环」按钮的实际效果（撤销该次跳过）
  /// 与文案口径随之对齐。UI 侧应改用本 getter 替代「判空 + 取值」分次调用
  /// [pausedUntilDate]——推导态每次调用都全量扫 3 年，分次调用成倍放大。
  ({DateTime end, bool derived})? get pauseDisplay {
    final end = pausedUntilDate;
    if (end == null) return null;
    // 显式字段存在（含已过窗口被上面的分支消化）→ 非推导态；[pausedUntil]
    // 由 fromJson 的 _sanitizeYmd 保证「要么 null、要么合法 yyyy-MM-dd」，
    // 不存在「有值但不可解析」的中间态，故直接按裸字段判空即可。
    return (end: end, derived: pausedUntil == null);
  }

  /// [repeatsOn] 的「纯日历」判定：重复规则 + 结束日期，**不含** [skipDates]。
  ///
  /// P2-2（v2.8.8 审计）：把 skip 一段拆出来，供「未来循环日预览」复用——已跳过的
  /// 日子必须仍然可见，否则用户在 UI 上没有任何「撤销跳过」的入口（跳过是不可逆死路）。
  /// 与 [repeatsOn] 共用同一份规则与结束日期判定，避免两处口径漂移。
  bool _repeatsOnIgnoringSkip(DateTime day) {
    final d = DateTime(day.year, day.month, day.day);
    // B2：结束日期（含当日仍生效，故用 isAfter 排除次日及之后）。
    final u = repeatUntil;
    if (u != null && d.isAfter(_parseYmd(u))) return false;
    // 原 switch 逻辑原样搬入 _baseRepeatsOn，避免散改进多个分支。
    return _baseRepeatsOn(d);
  }

  /// repeatsOn 的「纯规则」核心（不含 until / skip 两段通用判定），便于两侧同步维护。
  bool _baseRepeatsOn(DateTime day) {
    switch (repeat) {
      case RepeatType.none:
        return false;
      case RepeatType.daily:
        return true;
      case RepeatType.weekday:
        final w = day.weekday;
        return w >= DateTime.monday && w <= DateTime.friday;
      case RepeatType.weekly:
        return repeatWeekdays.contains(day.weekday);
      case RepeatType.interval:
        final a = repeatAnchor;
        if (a == null) return false;
        final ad = DateTime(a.year, a.month, a.day);
        final d = DateTime(day.year, day.month, day.day);
        // P3-4（v2.9.1 审计）：按「日历日」求差，不能用本地时间的绝对时距。
        // `d.difference(ad).inDays` 返回的是绝对时长：区间内若跨夏令时切换（某天 23 小时
        // 或 25 小时），7 个自然日会被算成 6 天 23 小时 → inDays = 6，相位整体错位（此后
        // 每隔 N 天的落点集体偏移一天）。中国时区无 DST 故线上未暴露，属时区健壮性缺口。
        // 改用 UTC 零点求差：UTC 无夏令时，差值恒等于自然日数。
        final diff = DateTime.utc(d.year, d.month, d.day)
            .difference(DateTime.utc(ad.year, ad.month, ad.day))
            .inDays;
        if (diff < 0) return false;
        final n = repeatInterval < 1 ? 1 : repeatInterval;
        return diff % n == 0;
      case RepeatType.monthly:
        // 「倒数第 N 天」语义最明确，优先级最高（P1-9）
        if (monthlyFromEnd > 0) {
          return day.day == _monthlyFromEndTarget(day.year, day.month, monthlyFromEnd);
        }
        if (monthlyWeekday != null && monthlyWeekIndex != null) {
          return _monthlyNthWeekday(day, monthlyWeekday!, monthlyWeekIndex!);
        }
        return day.day == _monthlyDayTarget(day.year, day.month, monthlyDay);
    }
  }

  /// 每月第 N 个周几 是否命中 [day]；[idx] 1..4 为第几个，5 为「最后一个」。
  static bool _monthlyNthWeekday(DateTime day, int wd, int idx) {
    if (day.weekday != wd) return false;
    final occ = ((day.day - 1) ~/ 7) + 1; // 该星期在本月是第几个
    if (idx >= 1 && idx <= 4) return occ == idx;
    if (idx == 5) {
      final dim = DateTime(day.year, day.month + 1, 0).day; // 当月天数
      return day.day + 7 > dim; // 再加 7 天将跨月 → 即本月最后一个
    }
    return false;
  }

  /// 每月 X 号在 [y] 年 [m] 月对应的「日」(1-28/29/30/31)；溢出则夹到当月最后一天。
  static int _monthlyDayTarget(int y, int m, int day) {
    final dim = DateTime(y, m + 1, 0).day;
    return day.clamp(1, dim);
  }

  /// 每月倒数第 [n] 天对应的「日」；[n] 为 1 即当月最后一天（P1-9）。
  /// 小月会自动前移（如倒数第 3 天在 2 月 = 26/27 号），n 超出月长时夹到 1 号。
  static int _monthlyFromEndTarget(int y, int m, int n) {
    final dim = DateTime(y, m + 1, 0).day;
    return (dim - n + 1).clamp(1, dim);
  }

  /// yyyy-MM-dd 形式的日期串（date-only，与时区无关，便于 skipDates 精确匹配）。
  static String _ymd(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// 解析 yyyy-MM-dd 串为 DateTime（date-only，当天 00:00）；非法串回退为 1970-01-01（保证比较安全不抛）。
  static DateTime _parseYmd(String s) {
    final parts = s.split('-');
    if (parts.length != 3) return DateTime(1970, 1, 1);
    final y = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final d = int.tryParse(parts[2]);
    if (y == null || m == null || d == null) return DateTime(1970, 1, 1);
    return DateTime(y, m, d);
  }

  /// 解析 skipDates 字段（兼容旧备份缺省 / 形态错误，缺省回退为空列表）。
  static List<String> _parseSkipDates(dynamic raw) {
    if (raw is! List) return const <String>[];
    return raw.whereType<String>().toList();
  }

  /// P1-4（v2.9.9 审计）：yyyy-MM-dd 形态守卫——仅当串严格匹配该形态时返回原样，
  /// 否则 null。供 [pausedUntil] 的反序列化使用（非法输入一律视为「未暂停」）。
  static String? _sanitizeYmd(dynamic raw) {
    if (raw is! String) return null;
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(raw)) return null;
    return raw;
  }

  /// [pausedUntil] 的运行时解析（date-only）；形态非法返回 null。
  static DateTime? _parseYmdOrNull(String? s) {
    final clean = _sanitizeYmd(s);
    return clean == null ? null : _parseYmd(clean);
  }

  /// F-8（v2.8.5 审计）：校验 [repeatUntil] 是否为合法的 yyyy-MM-dd 串。
  /// 合法原样返回；null / 非串 / 长度不对 / 数值越界等非法形态返回 null
  /// （由 [Task.fromJson] 兜底为「无限循环」，不再经 _parseYmd 回退 1970 被
  /// 悄悄判定为「早已结束」）。注意 `DateTime(y,m,d)` 会把 2 月 30 日归一化到
  /// 3 月，这里只做「字段可解析」校验，宽容此类软性错误。
  static String? _sanitizeRepeatUntil(dynamic v) {
    if (v is! String || v.length != 10) return null;
    final parts = v.split('-');
    if (parts.length != 3) return null;
    final y = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final d = int.tryParse(parts[2]);
    if (y == null || m == null || d == null) return null;
    if (y < 1970 || y > 9999 || m < 1 || m > 12 || d < 1 || d > 31) return null;
    return v;
  }

  /// F-8：把一个 JSON 数值夹取到 [min, max]；非数值或越界返回 null。
  /// 供「可空 + 有合法区间」的字段使用（repeatMinute / monthlyWeekday / …）。
  static int? _clampIntOrNull(dynamic v, int min, int max) {
    if (v is! num) return null;
    final n = v.toInt();
    if (n < min || n > max) return null;
    return n;
  }

  /// F-8：把一个 JSON 数值夹取到 [min, max]；非数值或越界回退 [fallback]。
  static int _clampInt(dynamic v, int min, int max, int fallback) =>
      _clampIntOrNull(v, min, max) ?? fallback;

  /// 新P3-4（v2.9.7 审计）：公开的 JSON 数值夹取助手——供 TemplateItem.fromJson
  /// 等外部解析器与 [Task.fromJson] 保持同一口径（含类型校验：非 num / 越界
  /// 一律回退 [fallback]，不再裸 `as int?` 硬转型中断整份模板加载）。
  static int clampIntJson(dynamic v, int min, int max, int fallback) =>
      _clampInt(v, min, max, fallback);

  /// P3-3（v3.0.1 审计）：可空字段的公开 JSON 夹取助手（[clampIntJson] 的
  /// 可空版，同 [Task._clampIntOrNull] 口径）——非 num / 越界返回 null
  /// （=「未设置」），供 TemplateItem.fromJson 的 monthlyWeekday /
  /// monthlyWeekIndex / repeatMinute / dueInDays 等可空字段与 [Task.fromJson]
  /// 同源，不再裸 `as int?` 硬转型。
  static int? clampIntOrNullJson(dynamic v, int min, int max) =>
      _clampIntOrNull(v, min, max);

  /// P3-1（v3.0.2 审计）：[repeatUntil] 净化的公开版（[_sanitizeRepeatUntil]
  /// 同口径）——合法 yyyy-MM-dd 原样返回；null / 非串 / 长度不对 / 数值越界
  /// 一律返回 null（=「无限循环」）。供 TemplateItem.fromJson 等外部解析面
  /// 复用：模板 JSON 是不可信输入，非法串若原样透传，会在 repeatsOn 内被
  /// _parseYmd 回退 1970 → isRepeatEnded 恒真 → 套用产出的任务被静默视为
  /// 「已结束」（不再循环不再提醒），与 F-8 在备份路径修掉的缺陷同型。
  static String? sanitizeRepeatUntilJson(dynamic v) => _sanitizeRepeatUntil(v);

  /// F-7：历史日期列表（[doneDates] / [skipDates]）的滚动保留窗口（天）。
  ///
  /// 二者此前只增不清、无上限：一个使用数年的「每天」任务会累积上千条字符串，
  /// 全部内联在该任务 JSON 里，而每次勾选都要整库全量序列化 → 写放大。
  /// 统计侧只会回溯「本期 / 本月 / 连续段 / 近 7 日」这些有界窗口，
  /// 保留 ~400 天（> 一年热力图）足够，且对 streak 的语义无影响。
  static const int historyRetentionDays = 400;

  /// F-7：把 date-only 串列表裁剪到「最近 [keepDays] 天（含今天）」，去重并升序。
  /// 返回 null 表示无需改动（调用方可跳过写回，避免无谓的 copyWith 与落盘）。
  static List<String>? pruneHistory(
    List<String> dates,
    DateTime now, {
    int keepDays = historyRetentionDays,
  }) {
    if (dates.isEmpty) return null;
    final today = DateTime(now.year, now.month, now.day);
    final cutoff = _ymd(today.subtract(Duration(days: keepDays)));
    final kept = <String>{};
    var changed = false;
    for (final s in dates) {
      // 长度校验顺带丢掉形态非法的脏串（历史版本 / 手改备份可能写入）。
      if (s.length == 10 && s.compareTo(cutoff) >= 0) {
        if (!kept.add(s)) changed = true; // 原有重复项 → 需要写回
      } else {
        changed = true; // 过期项 / 脏串 → 需要写回
      }
    }
    if (!changed) return null;
    return kept.toList()..sort();
  }

  /// 未来 N 天内「循环命中」的日期序列（date-only，含 [start] 当日）。
  /// 纯函数、无副作用，便于单测；命中判定复用 [repeatsOn]（已含 repeatUntil / skipDates）。
  /// [days] 扫描窗口（默认 30 天）；[limit] 返回条数上限（默认 60，防止每隔1天等极端规则下列表过长）。
  List<DateTime> occurrencesBetween(DateTime start, {int days = 30, int limit = 60}) {
    final out = <DateTime>[];
    final s = DateTime(start.year, start.month, start.day);
    for (var i = 0; i < days && out.length < limit; i++) {
      final d = DateTime(s.year, s.month, s.day + i);
      if (repeatsOn(d)) out.add(d);
    }
    return out;
  }

  /// 与 [occurrencesBetween] 同窗口，但**保留**已跳过的日子（`skipDates` 命中项）。
  ///
  /// P2-2（v2.8.8 审计）：[occurrencesBetween] 复用 [repeatsOn]，而 [repeatsOn] 会
  /// 排除 `skipDates` —— 于是「未来循环日预览」里的已跳过行永远渲染不出来
  /// （`_isSkipped` 恒为 false、`已跳过` 文案与撤销入口均为不可达死代码），用户
  /// 跳过某一天后在 UI 上彻底看不到它，也就无从撤销。这里给出「不排除跳过」的窗口，
  /// 让预览列表能显示「已跳过」并提供撤销；其余判定与 [occurrencesBetween] 完全一致。
  List<DateTime> occurrencesBetweenIncludingSkipped(
    DateTime start, {
    int days = 30,
    int limit = 60,
  }) {
    final out = <DateTime>[];
    final s = DateTime(start.year, start.month, start.day);
    for (var i = 0; i < days && out.length < limit; i++) {
      final d = DateTime(s.year, s.month, s.day + i);
      if (_repeatsOnIgnoringSkip(d)) out.add(d);
    }
    return out;
  }

  /// yyyy-MM-dd 串（对外复用 [repeatsOn] 的 skipDates 匹配键）。
  static String ymdKey(DateTime d) => _ymd(d);

  /// 两个日期是否同年月日（date-only 比较）。
  static bool isSameDay(DateTime a, DateTime b) => _ymd(a) == _ymd(b);

  /// 重复规则的人类可读摘要（不含时间）。如「每天」「工作日」「每周 一、三」「每2天」。
  String get repeatSummary {
    switch (repeat) {
      case RepeatType.none:
        return '';
      case RepeatType.daily:
        return '每天';
      case RepeatType.weekday:
        return '工作日';
      case RepeatType.weekly:
        const names = ['一', '二', '三', '四', '五', '六', '日'];
        final days = repeatWeekdays
            .where((d) => d >= 1 && d <= 7)
            .map((d) => names[d - 1])
            .join('、');
        return days.isEmpty ? '每周' : '每周 $days';
      case RepeatType.interval:
        return '每${repeatInterval < 1 ? 1 : repeatInterval}天';
      case RepeatType.monthly:
        if (monthlyFromEnd > 0) {
          return monthlyFromEnd == 1 ? '每月最后一天' : '每月倒数第$monthlyFromEnd天';
        }
        if (monthlyWeekday != null && monthlyWeekIndex != null) {
          const names = ['一', '二', '三', '四', '五', '六', '日'];
          final w = names[(monthlyWeekday! - 1).clamp(0, 6)];
          final idxLabel = monthlyWeekIndex == 5 ? '最后' : '第$monthlyWeekIndex个';
          return '每月$idxLabel周$w';
        }
        return '每月${monthlyDay}号';
    }
  }

  /// 完整重复描述（含提醒时间，如「每天 07:00」）；无重复返回空串。
  String get repeatFull {
    if (repeat == RepeatType.none) return '';
    final base = repeatSummary;
    if (repeatMinute == null) return base;
    final hh = (repeatMinute! ~/ 60).toString().padLeft(2, '0');
    final mm = (repeatMinute! % 60).toString().padLeft(2, '0');
    // 结束日期：仅展示月-日（年通常即今年），让卡片「每天 07:00 至 08-31」一目了然。
    final until =
        repeatUntil == null ? '' : ' 至 ${repeatUntil!.substring(5).replaceFirst('-', '/')}';
    return '$base $hh:$mm$until';
  }

  /// 是否为「重复任务」（任意规则）。
  bool get isRepeating => repeat != RepeatType.none;

  /// P2-3：归一化**与当前形态不相容的残留字段**，返回一个新任务（纯函数、无副作用）。
  ///
  /// 编辑弹层里用户可以把「每隔 3 天」改回「不重复」、把截止时间清空，而底层字段
  /// （repeatUntil / repeatInterval / reminderOffsetMin）此前会被无条件写回旧值，
  /// 留下脏数据：污染备份导出与「未来 30 天预览」，并让 TaskProvider 的
  /// `remindersChanged` 判定把这些无害残留误判成「提醒变了」而触发无谓重排。
  ///
  /// 清理规则（只清**确定不生效**的字段，不清任何会改变行为的字段）：
  /// - [repeatUntil]：仅 [isRepeating] 时有意义（[repeatsOn] / 通知排程 / .ics 导出
  ///   都只在重复分支读它）；
  /// - [repeatInterval]：仅 [RepeatType.interval] 时有意义（.ics 与通知排程同）；
  /// - [reminderOffsetMin]：无 [dueDate] 时不生效——`_scheduleRemindersFor` 根本不会
  ///   为无截止任务挂一次性截止提醒。
  /// - F-6/F-9：月内规则（[monthlyDay] / [monthlyWeekday] / [monthlyWeekIndex] /
  ///   [monthlyFromEnd]）仅在 [RepeatType.monthly] 时有意义。切到其它重复类型后残留
  ///   会污染「未来 30 天预览」与备份导出，并让「每月 15 号 → 每天 → 又改回每月」
  ///   意外沿用 15 号（用户预期是回到默认的 1 号）。
  ///
  /// ⚠️ 刻意**不**清理 [repeatAnchor]：它对非 interval 类型完全惰性，保留旧值可让
  /// 「每隔 N 天 → 每天 → 又改回每隔 N 天」沿用原相位锚点，而非被 null 兜底重置成当天。
  ///
  /// 旧数据（该字段缺省）经此方法后仍是缺省值，零迁移成本。
  Task normalizedRepeatFields() {
    final isMonthly = repeat == RepeatType.monthly;
    return copyWith(
      repeatUntil: isRepeating ? repeatUntil : null,
      repeatInterval: repeat == RepeatType.interval ? repeatInterval : 1,
      reminderOffsetMin: dueDate != null ? reminderOffsetMin : 0,
      monthlyDay: isMonthly ? monthlyDay : 1,
      monthlyWeekday: isMonthly ? monthlyWeekday : null,
      monthlyWeekIndex: isMonthly ? monthlyWeekIndex : null,
      monthlyFromEnd: isMonthly ? monthlyFromEnd : 0,
    );
  }

  /// F7：某「日」是否已有完成记录（occurrence 级，date-only）。
  /// 已完成的一次性任务以 [completedAt] 为准，重复任务的历史沉淀在 [doneDates]。
  bool isDoneOn(DateTime day) {
    if (doneDates.contains(_ymd(day))) return true;
    return done && completedAt != null && isSameDay(completedAt!, day);
  }

  /// P2-1（v3.1.0 审计）：该任务的全部「完成事件日」（date-only 集合）。
  ///
  /// 完成类统计（周报 / 月报 / 年报 / 成就 / 看板趋势）的**行级单一真源**：
  /// 一次性任务 = [completedAt] 所在日（当前仍 done 时）；重复任务 = [doneDates]
  /// 的全部历史落点。此前这些统计直读 `completedAt` 单槽，而重复任务的
  /// completedAt 会在午夜重置时被清空——「连续 3 天完成每天喝水」在周报 /
  /// 成就里一次都算不上，与 occurrence 级的周目标（weeklyCompletedCount）
  /// 同屏打架。本集合与 [completionDayCounts]（TaskProvider，聚合版）口径一致。
  Set<DateTime> get completionEventDays {
    final set = <DateTime>{};
    for (final k in doneDates) {
      // 解析口径与 TaskProvider._parseYmdSafe 对齐（P2-1 同源约束）：
      // 严格逐字段校验（m 1..12 / d 1..31），脏串一律跳过——若沿用
      // _parseYmdOrNull 的「只查形态」，'2026-13-40' 会被 DateTime 构造器
      // 归一化成 2027 年的日期，污染跨年区间的完成统计。
      final parts = k.split('-');
      if (parts.length != 3) continue;
      final y = int.tryParse(parts[0]);
      final m = int.tryParse(parts[1]);
      final d = int.tryParse(parts[2]);
      if (y == null || m == null || d == null) continue;
      if (y < 1970 || y > 9999 || m < 1 || m > 12 || d < 1 || d > 31) continue;
      set.add(DateTime(y, m, d));
    }
    if (done && completedAt != null) {
      final c = completedAt!;
      set.add(DateTime(c.year, c.month, c.day));
    }
    return set;
  }

  /// F3 / P2-1：重复是否已结束（[repeatUntil] 严格早于 [now] 所在日）。
  ///
  /// 「结束重复」把 [repeatUntil] 设为昨天，此后：首页「重复」分区不再收录它
  /// （回落到日期分区）、提醒不再调度、午夜重置不再重置它。此前该判定只写在
  /// interval 分支，daily/weekly/monthly 一旦重排就死灰复燃。
  bool isRepeatEnded(DateTime now) {
    final u = repeatUntil;
    if (u == null) return false;
    return DateTime(now.year, now.month, now.day).isAfter(_parseYmd(u));
  }

  /// 计算标题的拼音首字母串（小写，不含空格）。如「整理」→ "zl"、「整理周会纪要」→ "zlzhjy"。
  /// 依赖 [PinyinHelper]（lpinyin），纯 Dart、无平台调用；非汉字字符（数字/英文/标点）跳过，
  /// 仅取每个汉字的拼音首字母拼接。空标题返回空串。
  /// 用于「拼音首字母搜索」（A1）：搜 "zl" 可命中「整理」，搜 "zz" 可命中「整理周…」。
  static String computePinyinInitials(String title) {
    if (title.isEmpty) return '';
    final buf = StringBuffer();
    for (final rune in title.runes) {
      final ch = String.fromCharCode(rune);
      // 仅对 CJK 统一汉字区（含扩展 A）取拼音首字母；其余（字母/数字/符号）忽略，
      // 避免英文/数字干扰首字母匹配（搜 "abc" 不应被中文标题里的字母串命中）。
      if (_isCjk(rune)) {
        // lpinyin 2.x：getShortPinyin 对单字返回其拼音首字母（小写，如「整」→ "z"）；
        // 注意 getFirstWordPinyin 返回的是完整拼音（「整」→ "zheng"），不能用于首字母搜索。
        final py = PinyinHelper.getShortPinyin(ch);
        if (py.isNotEmpty) buf.write(py.toLowerCase());
      }
    }
    return buf.toString();
  }

  /// 判断码点是否落在常用汉字区（CJK Unified Ideographs + 扩展 A）。
  static bool _isCjk(int rune) =>
      (rune >= 0x4E00 && rune <= 0x9FFF) || // 基本汉字
      (rune >= 0x3400 && rune <= 0x4DBF); // 扩展 A
}
