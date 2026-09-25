import 'package:flutter/material.dart';
import 'package:todolist/services/app_log.dart';
import 'package:todolist/models/habit.dart';
import 'package:todolist/models/checkin.dart';
import 'package:todolist/services/habit_migration.dart';
import 'package:todolist/services/local_database.dart';
import 'package:todolist/services/notification_service.dart';
import 'package:todolist/services/csv_safe.dart';

/// 习惯 / 打卡的状态层：管理习惯列表、每日打卡记录、连续天数统计与持久化。
///
/// 与 TaskProvider / FocusProvider 解耦，仅依赖 [LocalDatabase] 的 habits /
/// check_ins 两张表（整段 JSON 存储）。所有统计在内存中基于打卡日期集合计算，
/// 逻辑单纯、易测。
class HabitProvider extends ChangeNotifier {
  /// 进程内单例引用（由 main 在构造后写入），供 TaskProvider 自动备份等场景安全取用。
  /// 取前请判空（[instanceOrNull]）；测试/未初始化时为 null。
  static HabitProvider? _instance;
  static HabitProvider? get instanceOrNull => _instance;
  final List<Habit> _habits = [];
  final List<CheckIn> _checkIns = [];

  /// 进程内自增序号，叠加到习惯 id 上，避免同一毫秒内连续建习惯时 id 撞车
  /// （撞 id 会导致 _memHabits 按 id 存 Map 时后者覆盖前者，静默丢习惯，
  /// 且两个习惯对象的打卡会串号）。与 [NotificationService._habitSlotOf] 用
  /// hashCode 折叠无关，改 id 格式不影响通知槽位映射。
  static int _habitSeq = 0;

  /// 全部习惯（含归档）。UI 可按需过滤。
  List<Habit> get habits => List.unmodifiable(_habits);

  /// 全部打卡记录（导出 Excel 的「打卡记录」表使用，避免直接暴露内部可变列表）。
  List<CheckIn> get checkIns => List.unmodifiable(_checkIns);

  /// 未归档的习惯（首页/今日列表展示用）。
  List<Habit> get activeHabits =>
      _habits.where((h) => !h.archived).toList();

  /// 按 id 查找习惯，找不到返回 null（通知稍后提醒等场景用）。
  Habit? byId(String id) {
    for (final h in _habits) {
      if (h.id == id) return h;
    }
    return null;
  }

  Future<void> load() async {
    _instance = this; // 注册单例，供自动备份等场景安全取用
    try {
      final db = LocalDatabase.instance;
      // 内存后端（测试）无需打开真实 SQLite；仅在生产（非内存）模式确保建表。
      if (!LocalDatabase.testUseMemory) {
        await db.db;
      }
      _habits
        ..clear()
        ..addAll(await db.loadHabits());
      _checkIns
        ..clear()
        ..addAll(await db.loadCheckIns());
    } catch (e, stack) {
      AppLog.d('HabitProvider 加载失败（习惯/打卡暂不可用）：$e\n$stack');
      _habits.clear();
      _checkIns.clear();
    }
    notifyListeners();
  }

  /// 新建习惯（自动生成 id 与时间戳）。
  Future<void> addHabit({
    required String title,
    required String emoji,
    required int colorValue,
    required List<int> weekdays,
    int? reminderMinute,
    int weeklyGoal = 0,
    /// T1-2：每日目标量（null / <=0 = 布尔打卡）。
    /// P3-4（v2.9.3 审计）：写入侧统一夹取 1..9999，与反序列化侧
    /// （[Habit._clampTarget]）同区间——旁路写入（导入/脚本/未来入口）此前
    /// 会把越界值原样落库，重载时再被静默降级，留下「写完即变」的隐患。
    int? dailyTarget,
    /// T1-4：宽限日（每周允许缺卡 N 天不断签，0..3）。
    int graceDays = 0,
  }) async {
    final h = Habit(
      id: _nextHabitId(),
      title: title,
      emoji: emoji,
      colorValue: colorValue,
      weekdays: weekdays,
      reminderMinute: reminderMinute,
      // P3-4：上界夹取（UI 已限 9999/14，这里兜住一切非 UI 入口）。
      // P3-10（v2.9.4 审计）：weeklyGoal 的上界由写死 14 改为**联动计划天数**
      // （`weekdays` 为空 = 7 天）——「每周一三五」的习惯此前能设「每周 14 次」，
      // 目标不可达。weeklyGoal.clamp / dailyTarget.clamp 返回 num，需 toInt 收敛。
      weeklyGoal: Habit.clampWeeklyGoalTo(weeklyGoal, weekdays),
      dailyTarget: (dailyTarget != null && dailyTarget > 0)
          ? dailyTarget.clamp(1, Habit.maxDailyTarget).toInt()
          : null,
      graceDays: graceDays.clamp(0, 3),
      createdAt: DateTime.now(),
    );
    _habits.add(h);
    await _persistHabits();
    // 若设置了提醒，立即调度每日打卡提醒（失败静默，不影响建习惯）。
    if (reminderMinute != null) {
      await NotificationService.instance.scheduleHabitReminder(h);
    }
    notifyListeners();
    // P3-8（v2.9.4 审计）：此前**漏掉**本回调。新建习惯会改变 23:00 晚间
    // 简报 / 挽留通知的内容（缺卡提醒、明日预告），不重排就仍按旧习惯集
    // 推送——「新建了晚间提醒的习惯，当晚却没收到」正是这条缺失的表现。
    // 兄弟方法 [addHabitFromDraft] / [updateHabit] / [deleteHabit] 均已触发。
    _notifyHabitsChanged();
  }

  /// 生成全局唯一习惯 id（时间戳 + 进程内自增序号，避免同毫秒撞 id）。
  String _nextHabitId() =>
      '${DateTime.now().microsecondsSinceEpoch}.${_habitSeq++}';

  /// T1-3：按「任务 → 习惯」映射草稿新建习惯，返回创建出的 [Habit]。
  ///
  /// 与 [addHabit] 的差别只有「字段来自哪里」：这里由 [HabitDraft.fromTask]
  /// 统一给出（标题 / 打卡星期 / 提醒时刻 / 周目标），UI 只负责 emoji 与颜色，
  /// 从而保证「转习惯」在不同入口（任务详情、未来的右键菜单）行为一致。
  Future<Habit> addHabitFromDraft(
    HabitDraft draft, {
    required String emoji,
    required int colorValue,
    int? dailyTarget,
    int graceDays = 0,
  }) async {
    final h = Habit(
      id: _nextHabitId(),
      title: draft.title,
      emoji: emoji,
      colorValue: colorValue,
      weekdays: draft.weekdays,
      reminderMinute: draft.reminderMinute,
      // P3-4：与 [addHabit] 同款写入侧夹取。
      // P3-10：weeklyGoal 上界改为联动计划天数。
      weeklyGoal: Habit.clampWeeklyGoalTo(draft.weeklyGoal, draft.weekdays),
      dailyTarget: (dailyTarget != null && dailyTarget > 0)
          ? dailyTarget.clamp(1, Habit.maxDailyTarget).toInt()
          : null,
      graceDays: graceDays.clamp(0, 3),
      createdAt: DateTime.now(),
    );
    _habits.add(h);
    await _persistHabits();
    if (h.reminderMinute != null) {
      await NotificationService.instance.scheduleHabitReminder(h);
    }
    notifyListeners();
    _notifyHabitsChanged();
    return h;
  }

  /// 更新某习惯的每日提醒时间（null = 取消提醒）。先取消旧提醒，再按新值调度/保持静默。
  Future<void> setReminder(Habit habit, int? minute) async {
    final updated =
        habit.copyWith(reminderMinute: minute, clearReminder: minute == null);
    final idx = _habits.indexWhere((h) => h.id == habit.id);
    if (idx == -1) return;
    _habits[idx] = updated;
    await _persistHabits();
    // 取消旧的（无论改/删都先清干净），再按新值重新挂。
    // P2-1（v2.9.3 审计）：调度判据与其他四处统一为「达标」口径——
    // 今天已达标则跳过今日落点，避免「喝满 8 杯后补设提醒，当晚仍弹『该打卡啦』」。
    await NotificationService.instance.cancelHabitReminder(habit.id);
    if (minute != null) {
      await NotificationService.instance
          .scheduleHabitReminder(updated, checkedToday: isTargetMetToday(updated));
    }
    notifyListeners();
    // P3-8（v2.9.4 审计）：此前**漏掉**本回调。与 [addHabit] 同因——
    // 提醒时刻/取消提醒会改变「今天是否已达标」之外的可提醒习惯集，
    // 晚间简报的明日预告必须按新时刻重排，否则推送的是旧时刻的预告。
    _notifyHabitsChanged();
  }

  /// 删除习惯及其全部打卡记录（同时取消其提醒通知）。
  ///
  /// T1-4：返回被删除内容的**快照**，供 UI 做「撤销删除」（见 [restoreHabit]）。
  /// 此前删除是单向的：一次误触即永久丢失该习惯的历史打卡（连续天数、热力图全归零），
  /// 而任务侧早就有 SnackBar 撤销——习惯侧是明显的交互不对等。
  Future<DeletedHabit?> deleteHabit(String id) async {
    final idx = _habits.indexWhere((h) => h.id == id);
    if (idx == -1) return null;
    final snapshot = DeletedHabit(
      habit: _habits[idx],
      checkIns: _checkIns.where((c) => c.habitId == id).toList(),
      index: idx,
    );
    _habits.removeAt(idx);
    _checkIns.removeWhere((c) => c.habitId == id);
    await NotificationService.instance.cancelHabitReminder(id);
    await _persistHabits();
    await _persistCheckIns();
    notifyListeners();
    _notifyHabitsChanged();
    return snapshot;
  }

  /// T1-4：撤销删除——把 [snapshot] 里的习惯与打卡记录原样放回（含原列表位置）。
  ///
  /// 幂等：若同 id 习惯已存在（例如用户删后又自己重建了同一条）则不做任何改动、
  /// 返回 null，避免把撤销变成「制造重复习惯」。提醒按恢复后的状态重挂。
  Future<Habit?> restoreHabit(DeletedHabit snapshot) async {
    if (byId(snapshot.habit.id) != null) return null;
    final at = snapshot.index.clamp(0, _habits.length);
    _habits.insert(at, snapshot.habit);
    // 打卡记录逐条去重后放回（同 id 记录已随删除一并移除，这里的去重是防御性的）。
    final existing = _checkIns.map((c) => c.id).toSet();
    for (final c in snapshot.checkIns) {
      if (existing.add(c.id)) _checkIns.add(c);
    }
    await _persistHabits();
    await _persistCheckIns();
    if (!snapshot.habit.archived && snapshot.habit.reminderMinute != null) {
      _rescheduleReminder(snapshot.habit);
    }
    notifyListeners();
    _notifyHabitsChanged();
    return snapshot.habit;
  }

  /// App 启动时调度全部习惯的提醒（仅对已设提醒时间的活动习惯）。
  /// 由 main 在 habit.load() 后调用一次。失败单个静默不影响其它。
  Future<void> scheduleAllReminders() async {
    for (final h in _habits) {
      if (h.archived || h.reminderMinute == null) continue;
      // P2-1（v2.9.3 审计）：判据从「有记录」升级为「已达标」——
      // 量化习惯只喝 1/8 杯不再抑制当天提醒（旧口径下部分打卡即静默吞掉当日提醒，
      // 是「新口径未横向推广」通病的第 N 次复发）。
      await NotificationService.instance
          .scheduleHabitReminder(h, checkedToday: isTargetMetToday(h));
    }
  }

  /// 今天是否已打卡（按 date-only 判定）。
  bool isCheckedToday(Habit habit) => isCheckedOn(habit, DateTime.now());

  /// 指定日是否已打卡（date-only 判定）。
  /// P2-1：晚简报按**投递日**聚合，不能取「本机当前日」，否则跨天投递时口径会串。
  bool isCheckedOn(Habit habit, DateTime day) {
    final k = CheckIn.dateKey(day);
    return _checkIns.any(
        (c) => c.habitId == habit.id && CheckIn.dateKey(c.date) == k);
  }

  /// T1-2：指定日的累计量（无记录返回 0）。
  int checkInValueOn(Habit habit, DateTime day) {
    final k = CheckIn.dateKey(day);
    for (final c in _checkIns) {
      if (c.habitId == habit.id && CheckIn.dateKey(c.date) == k) return c.value;
    }
    return 0;
  }

  /// T1-2：指定日是否**达成目标**——量化习惯要求累计量 ≥ 每日目标，
  /// 布尔习惯即「有打卡记录」。
  ///
  /// 与 [isCheckedOn] 的分工：后者回答「今天有没有记录」（提醒抑制、补卡幂等用），
  /// 本方法回答「今天算不算完成」（连续天数、周目标、周报月报、成就用）。
  bool isTargetMetOn(Habit habit, DateTime day) =>
      habit.targetMetBy(checkInValueOn(habit, day));

  /// T1-2：今日累计量。
  int todayValue(Habit habit) => checkInValueOn(habit, DateTime.now());

  /// T1-2：今日是否达成目标。
  bool isTargetMetToday(Habit habit) => isTargetMetOn(habit, DateTime.now());

  /// T1-2：某日进度 0..1（量化按 value/target；布尔按有无记录）。
  double progressRatioOn(Habit habit, DateTime day) =>
      habit.progressRatioOf(checkInValueOn(habit, day));

  /// 某日热力图强度档位 0..4（0 = 无记录 / 未达标）。
  ///
  /// P2-7（v2.9.4 审计）：抽出为 provider 上的**单一真源**。
  /// 此前这段「四档分级」内联在习惯详情页的 `levelOf` 闭包里，分享卡
  /// （[HabitShareData.from] → `HabitHeatmap`）拿不到，只能退回二值着色——
  /// 于是同一份数据在 App 内按达成度四档、导出成长图却只有「有/无」，
  /// 量化习惯的 1/8 与 8/8 在分享图上完全同色。这是对外产物的口径失真。
  ///
  /// 档位与 [HabitHeatmap] 的 4 档 `steps` 一一对应（1..4）。
  /// 布尔习惯（无 dailyTarget）两档：达标 1、未记录 0（逐位等价于旧二值）。
  int progressLevelOn(Habit habit, DateTime day) {
    final v = checkInValueOn(habit, day);
    if (v <= 0) return 0;
    if (!habit.isQuantified) return 1;
    final r = habit.progressRatioOf(v);
    if (r < 0.5) return 1;
    if (r < 0.75) return 2;
    if (r < 1.0) return 3;
    return 4; // 达标档
  }

  /// P2-2：「习惯/打卡发生变动」时的重排回调，由 `main.dart` 注入。
  ///
  /// 之所以用回调而非直接 import `daily_briefing.dart`：后者反向依赖本文件
  /// （`buildEveningBriefFromState` 需要 `HabitProvider`），直接 import 会形成
  /// 循环依赖。注入式回调是最小改动且**未注入时静默跳过**的兜底方案——
  /// 挽留通知属锦上添花，绝不因回调缺失影响打卡主流程。
  static void Function(HabitProvider provider)? onHabitsChanged;

  /// 统一触发 [onHabitsChanged]；回调本身抛错一律吞掉（不阻断业务、不弹错）。
  void _notifyHabitsChanged() {
    final cb = onHabitsChanged;
    if (cb == null) return;
    try {
      cb(this);
    } catch (e) {
      AppLog.d('[HabitNudge] 变动重排回调失败（已忽略）：$e');
    }
  }

  /// 本周（周一~周日）某习惯的**达标天数**，用于「每周目标」进度。
  ///
  /// T1-2：口径由「有打卡记录的天数」升级为「达成每日目标的天数」。布尔习惯
  /// （无 dailyTarget）两者完全等价，因此旧数据行为不变；量化习惯则不再因为
  /// 「今天只喝了 1 杯水」就计入周目标的 1 次——否则周目标会被灌水失真。
  int weeklyCheckIns(Habit habit) {
    final monday = _mondayOf(DateTime.now());
    final sunday = monday.add(const Duration(days: 6));
    return _metDaysOf(habit).where((d) => !d.isBefore(monday) && !d.isAfter(sunday)).length;
  }

  /// 本周累计量（量化习惯用；布尔习惯等于达标天数）。
  ///
  /// P3-6（v2.9.3 审计）：量化叙事的接线入口——习惯详情弹层用它展示
  /// 「本周 x / y（目标）」。此前定义后零消费，维护者易误判为已实现。
  int weeklyValue(Habit habit) {
    final monday = _mondayOf(DateTime.now());
    final sunday = monday.add(const Duration(days: 6));
    if (!habit.isQuantified) return weeklyCheckIns(habit);
    var sum = 0;
    for (final c in _checkIns) {
      if (c.habitId != habit.id) continue;
      final d = DateTime(c.date.year, c.date.month, c.date.day);
      if (d.isBefore(monday) || d.isAfter(sunday)) continue;
      sum += c.value;
    }
    return sum;
  }

  /// 本周量化目标总量（计划天数 × 每日目标）；非量化习惯返回 0。
  int weeklyValueTarget(Habit habit) {
    if (!habit.isQuantified) return 0;
    final monday = _mondayOf(DateTime.now());
    final sunday = monday.add(const Duration(days: 6));
    var planned = 0;
    for (var d = monday; !d.isAfter(sunday); d = d.add(const Duration(days: 1))) {
      if (habit.shouldCheckInOn(d)) planned++;
    }
    return planned * habit.effectiveTarget;
  }

  /// 本周是否达成了周目标（weeklyGoal>0 且达标天数 ≥ 目标）。
  bool goalMetThisWeek(Habit habit) =>
      habit.weeklyGoal > 0 && weeklyCheckIns(habit) >= habit.weeklyGoal;

  /// 从本周往前连续达成周目标的周数（断一周即止）；weeklyGoal<=0 返回 0。
  /// 用于「连续 4 周达成周目标」成就判定。
  int consecutiveGoalWeeks(Habit habit, {int weeks = 4}) {
    if (habit.weeklyGoal <= 0) return 0;
    int run = 0;
    final today = DateTime.now();
    final metDays = _metDaysOf(habit);
    for (int w = 0; w < weeks; w++) {
      final monday = _mondayOf(DateTime(today.year, today.month, today.day)
          .subtract(Duration(days: 7 * w)));
      final sunday = monday.add(const Duration(days: 6));
      final count =
          metDays.where((d) => !d.isBefore(monday) && !d.isAfter(sunday)).length;
      if (count >= habit.weeklyGoal) {
        run++;
      } else {
        break;
      }
    }
    return run;
  }

  /// 返回某日期所在周的周一（每周首日）。
  static DateTime _mondayOf(DateTime d) {
    final base = DateTime(d.year, d.month, d.day);
    return base.subtract(Duration(days: base.weekday - 1));
  }

  /// 切换今天的打卡状态：已打卡则取消，否则打卡。
  ///
  /// T1-2：量化习惯下「打卡」= 记 1 个单位（喝第 1 杯水），**不**直接跳到目标量——
  /// 一键顶满会让「+1 累计」失去意义，也让热力图上的量级彻底失真。
  /// 想一键达标请用 [completeTodayTarget]（详情页「今日达标」按钮提供，U2-5）。
  ///
  /// P3-1（v2.9.3 审计）：收口到 [setCheckInValue]（单一真源）。旧实现直接
  /// `_checkIns.add/removeWhere`——「有记录 → 整日删除」的语义对量化习惯会一次
  /// 抹掉当天全部累计（3/8 → 0/8），且绕开了写盘收口（落盘/重排/挽留重排全靠
  /// 手工补齐，正是「某个入口忘记重排」的经典温床）。委托后行为与旧实现逐位等价
  /// （布尔习惯 0/1 互换），量化习惯的整日撤销语义保持不变但走统一路径。
  Future<void> toggleCheckInToday(Habit habit) async {
    await setCheckInValue(habit, DateTime.now(), isCheckedToday(habit) ? 0 : 1);
  }

  /// T1-2：在指定日把累计量调整为 [value]（0 → 删除记录，即撤卡）。
  ///
  /// 所有「+1 / 设置数量 / 撤卡」入口都收敛到这里，保证：
  /// 1. 只有一处写盘与重排逻辑，不会再出现「某个入口忘记重排提醒」的经典缺陷；
  /// 2. 值被夹在 [0, [Habit.maxDailyTarget]]，负数与天文数字都不会污染数据。
  Future<void> setCheckInValue(Habit habit, DateTime day, int value) async {
    final v = value.clamp(0, Habit.maxDailyTarget);
    final k = CheckIn.dateKey(day);
    final idx = _checkIns
        .indexWhere((c) => c.habitId == habit.id && CheckIn.dateKey(c.date) == k);
    if (v <= 0) {
      if (idx == -1) return; // 本就无记录 → 无操作，不触发无谓的落盘与重排
      _checkIns.removeAt(idx);
    } else if (idx == -1) {
      _checkIns.add(CheckIn.forDay(habit.id, day, value: v));
    } else {
      if (_checkIns[idx].value == v) return; // 值未变 → 无操作
      _checkIns[idx] = _checkIns[idx].withValue(v);
    }
    await _persistCheckIns();
    notifyListeners();
    _rescheduleReminder(habit);
    _notifyHabitsChanged();
  }

  /// T1-2：在某日累计量上增减 [delta]（+1 / −1 按钮走这里）。
  /// 结果 ≤0 时删除记录（等价于撤卡）。
  Future<void> adjustCheckInValue(Habit habit, DateTime day, int delta) =>
      setCheckInValue(habit, day, checkInValueOn(habit, day) + delta);

  /// T1-2：一键把当日累计量顶到每日目标（「今日达标」按钮）。已达标则无操作。
  Future<void> completeTodayTarget(Habit habit) async {
    final v = checkInValueOn(habit, DateTime.now());
    if (v >= habit.effectiveTarget) return;
    await setCheckInValue(habit, DateTime.now(), habit.effectiveTarget);
  }

  /// T1-2：撤销当日全部累计量（量化习惯的「撤卡」）。
  Future<void> clearToday(Habit habit) =>
      setCheckInValue(habit, DateTime.now(), 0);

  /// F10：按当前打卡状态重排某习惯的每日提醒（未设提醒 / 已归档则跳过）。
  /// 失败静默——提醒属锦上添花，绝不因调度失败阻断打卡主流程。
  ///
  /// P2-1（v2.9.3 审计）：抑制判据统一为 [isTargetMetToday]（达标口径）。
  /// 通知侧语义是 `checkedToday=true` 时跳过今天这一次落点——对量化习惯而言
  /// 「做了 1/8」不该算做完，旧判据 [isCheckedToday] 会在部分打卡后吞掉当天提醒。
  void _rescheduleReminder(Habit habit) {
    if (habit.archived || habit.reminderMinute == null) return;
    NotificationService.instance
        .scheduleHabitReminder(habit, checkedToday: isTargetMetToday(habit))
        .catchError((_) => false);
  }

  /// U2：编辑习惯（标题 / 表情 / 颜色 / 星期 / 周目标 / 归档）。
  ///
  /// 此前习惯一旦创建就既不能改名也不能删除（`deleteHabit` 定义后全库零调用），
  /// 名字打错字只能让错误的习惯永远躺在列表、热力图和连续天数榜里。
  /// 提醒时刻变更沿用 [setReminder] 的「先取消旧提醒再重挂」口径。
  ///
  /// T1-4（v2.9.2 功能增强）补齐三处此前**无法在编辑层修改**的字段：
  /// - **提醒时刻**（[reminderMinute] / [clearReminder]）：旧编辑层没有这一项，
  ///   用户只能去列表页点那个提醒 chip；而 chip 仅在「已有提醒」时渲染，
  ///   于是「建习惯时忘了设提醒」= 永远没有入口补设（提醒 chip 不存在）。
  /// - **每日目标量**（[dailyTarget] / [clearDailyTarget]，T1-2）。
  /// - **宽限日**（[graceDays]）。
  Future<void> updateHabit(
    Habit habit, {
    String? title,
    String? emoji,
    int? colorValue,
    List<int>? weekdays,
    int? weeklyGoal,
    bool? archived,
    int? reminderMinute,
    bool clearReminder = false,
    int? dailyTarget,
    bool clearDailyTarget = false,
    int? graceDays,
  }) async {
    final idx = _habits.indexWhere((h) => h.id == habit.id);
    if (idx == -1) return;
    final old = _habits[idx];
    // P3-10（v2.9.4 审计）：weeklyGoal 上界与「**更新后**的计划天数」联动。
    // 必须在 copyWith 之前算出生效 weekdays——用户在同一次编辑里把「每天」改成
    // 「每周一三五」时，若按旧值（7 天）算上界，就能把目标设成 7 次而计划只有
    // 3 天，又造出一个不可达目标。
    final effWeekdays = weekdays ?? old.weekdays;
    final updated = habit.copyWith(
      title: (title != null && title.trim().isNotEmpty) ? title.trim() : null,
      emoji: emoji,
      colorValue: colorValue,
      weekdays: weekdays,
      // P3-4（v2.9.3 审计）：写入侧统一夹取 weeklyGoal（与反序列化侧一致），
      // 兜住「导入 / 脚本 / 未来入口」的越界写入，避免「写完即被重载降级」。
      // P3-10：上界不再是 14，而是生效后的计划天数。
      weeklyGoal:
          Habit.clampWeeklyGoalTo(weeklyGoal ?? old.weeklyGoal, effWeekdays),
      archived: archived,
      reminderMinute: reminderMinute,
      clearReminder: clearReminder,
      // 0 / 负数视为「取消量化」，与 AddHabitSheet 的「关闭」语义一致；
      // 正数同样夹到 1..[Habit.maxDailyTarget]（P3-4）。
      dailyTarget: (dailyTarget != null && dailyTarget > 0)
          ? dailyTarget.clamp(1, Habit.maxDailyTarget).toInt()
          : null,
      clearDailyTarget: clearDailyTarget || (dailyTarget != null && dailyTarget <= 0),
      graceDays: graceDays?.clamp(0, 3),
    );
    _habits[idx] = updated;
    await _persistHabits();
    // 提醒相关字段（时刻 / 星期 / 归档）任一变化都影响调度，统一重排。
    // P2-1（v2.9.3 审计）：增补 [dailyTarget] 变化——达标门槛改变会改变「今天
    // 是否已达标」，从而决定当天落点是否该被跳过（例如目标 8→3 时，已记 5 个
    // 单位的习惯由未达标变达标，当天提醒应消失；反之 3→8 应恢复）。
    final reminderChanged = old.reminderMinute != updated.reminderMinute ||
        old.archived != updated.archived ||
        old.dailyTarget != updated.dailyTarget ||
        !_weekdaysEqual(old.weekdays, updated.weekdays);
    if (updated.archived) {
      await NotificationService.instance.cancelHabitReminder(updated.id);
    } else if (reminderChanged) {
      // 先取消旧提醒再重挂：仅当提醒时刻 / 星期 / 归档 / 目标量真的变了才动系统闹钟，
      // 避免「只改了个名字」也把提醒取消重挂一遍（无谓的调度抖动）。
      await NotificationService.instance.cancelHabitReminder(updated.id);
      if (updated.reminderMinute != null) {
        await NotificationService.instance.scheduleHabitReminder(
          updated,
          // P2-1：判据与全链路统一为「达标」口径。
          checkedToday: isTargetMetToday(updated),
        );
      }
    }
    notifyListeners();
    _notifyHabitsChanged();
  }

  /// 两个 int 列表是否逐元素相等（星期 / 归档比较用）。
  static bool _weekdaysEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// U3：取消指定日期的打卡记录（补卡的反操作，避免「补错卡无法撤回」）。
  ///
  /// T1-2 起委托给 [setCheckInValue]（值 0 = 删除记录）：单一真源，量化习惯
  /// 「撤卡」与布尔习惯「取消打卡」走同一条路径。
  Future<void> uncheckInOnDay(Habit habit, DateTime day) =>
      setCheckInValue(habit, day, 0);

  /// 在指定日期打卡（用于补打卡 / 历史回溯），已存在则忽略。
  ///
  /// T1-2：可用 [value] 指定当日累计量（量化习惯的补卡，如「昨天喝了 6 杯」）；
  /// 不传则记 1 个单位。记录已存在且未显式给 [value] 时保持幂等跳过。
  Future<void> checkInOnDay(Habit habit, DateTime day, {int? value}) async {
    final v = value ?? 1;
    final existing = checkInValueOn(habit, day);
    if (existing > 0 && value == null) return;
    if (existing == v && existing > 0) return;
    await setCheckInValue(habit, day, v);
  }

  /// 某习惯累计**达标天数**（T1-2 口径：量化习惯需当日累计量 ≥ 目标；
  /// 布尔习惯等价于原「打卡天数」）。
  int checkInCount(Habit habit) => _metDaysOf(habit).length;

  /// 某习惯累计投入总量（量化习惯为各单位之和；布尔习惯 = 达标天数）。
  /// 供导出与分享卡片展示「共 240 杯」这类累计量。
  int totalValue(Habit habit) {
    if (!habit.isQuantified) return checkInCount(habit);
    var sum = 0;
    for (final c in _checkIns) {
      if (c.habitId == habit.id) sum += c.value;
    }
    return sum;
  }

  /// 返回某习惯在近 [days] 天内（含今天）**有打卡记录**的 date-only 集合，供热力图着色。
  ///
  /// 刻意保留「有记录即着色」的宽松口径：热力图表达的是「这天有没有动过」，
  /// 量化习惯的**强度**由调用方通过 `levelOf` 传进度分级（见 habit_screen 详情层）。
  Set<DateTime> checkedDays(Habit habit, int days) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final start = today.subtract(Duration(days: days - 1));
    final set = <DateTime>{};
    for (final c in _checkIns) {
      if (c.habitId != habit.id) continue;
      final d = DateTime(c.date.year, c.date.month, c.date.day);
      if (!d.isBefore(start)) set.add(d);
    }
    return set;
  }

  /// T1-2：近 [days] 天内**达标**的日期集合（统计口径，与 [checkedDays] 的展示口径区分）。
  Set<DateTime> metDays(Habit habit, int days) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final start = today.subtract(Duration(days: days - 1));
    return _metDaysOf(habit).where((d) => !d.isBefore(start)).toSet();
  }

  /// 返回某习惯在 [start, end]（date-only，含端点）内已打卡的日期集合。
  ///
  /// 与 [checkedDays] 的「近 N 天」口径互补：月报 / 年报需要任意历史区间，
  /// 这里只是换一种读法，不新增任何存储。
  Set<DateTime> checkedDaysBetween(Habit habit, DateTime start, DateTime end) {
    final s = DateTime(start.year, start.month, start.day);
    final e = DateTime(end.year, end.month, end.day);
    final set = <DateTime>{};
    for (final c in _checkIns) {
      if (c.habitId != habit.id) continue;
      final d = DateTime(c.date.year, c.date.month, c.date.day);
      if (d.isBefore(s) || d.isAfter(e)) continue;
      set.add(d);
    }
    return set;
  }

  /// T1-2：区间内**达标**的日期集合（周报 / 月报习惯口径的单一真源）。
  Set<DateTime> metDaysBetween(Habit habit, DateTime start, DateTime end) {
    final s = DateTime(start.year, start.month, start.day);
    final e = DateTime(end.year, end.month, end.day);
    return _metDaysOf(habit)
        .where((d) => !d.isBefore(s) && !d.isAfter(e))
        .toSet();
  }

  /// T1-2：某习惯在区间内的累计投入量（量化习惯为各单位之和；布尔 = 达标天数）。
  int valueBetween(Habit habit, DateTime start, DateTime end) {
    final s = DateTime(start.year, start.month, start.day);
    final e = DateTime(end.year, end.month, end.day);
    if (!habit.isQuantified) return metDaysBetween(habit, start, end).length;
    var sum = 0;
    for (final c in _checkIns) {
      if (c.habitId != habit.id) continue;
      final d = DateTime(c.date.year, c.date.month, c.date.day);
      if (d.isBefore(s) || d.isAfter(e)) continue;
      sum += c.value;
    }
    return sum;
  }

  /// 某习惯当前连续天数（今天未打卡则从昨天起算，避免「还没打卡就显断」）。
  ///
  /// F-4（v2.8.5 审计）：[Habit.weekdays] 非空（每周部分天打卡）的习惯按
  /// 「计划打卡日序列」计算——计划外的休息日不再被当成「断签」。旧实现按
  /// 自然日逐天回退，「每周一/三/五」在周五打完回退到周四即断，连续天数恒 ≤ 1，
  /// 「连续 N 天」类成就对非每日习惯几乎不可达。weekdays 为空（每天）维持原口径。
  ///
  /// T1-2：判定基准由「有打卡记录」升级为「达标」（量化习惯需喝满每日目标）。
  /// T1-4：[Habit.graceDays] > 0 时，每周允许 [Habit.graceDays] 个计划日缺卡而不断签。
  int currentStreak(Habit habit) => _streakFor(
        _metDaysOf(habit),
        weekdays: habit.weekdays.toSet(),
        graceDays: habit.graceDays,
        allowTodayGap: true,
      );

  /// 某习惯历史最长连续打卡天数。口径同 [currentStreak]（F-4：感知 weekdays）。
  int longestStreak(Habit habit) => _streakFor(
        _metDaysOf(habit),
        weekdays: habit.weekdays.toSet(),
        graceDays: habit.graceDays,
        longest: true,
      );

  // ===== 跨习惯整体统计（成就解锁用）=====

  /// 全局「累计**达标**（天·次）」：各习惯达标天数之和（量化习惯需当日量 ≥ 目标）。
  ///
  /// P2-3（v2.9.4 审计）：此前是 `_checkIns.length`（**有记录**口径），与本轮
  /// 统一的「达标」口径全线漂移：详情页「累计」用 [checkInCount]（达标天数），
  /// 概览卡与成就体系却数「半途而废的天数」——同页两个「累计」给出两个数字，
  /// 且「每天 8 杯水」整周只喝 1 杯也能把 `checkin_100` 灌到 100。
  /// 现改为按 [_metDaysOf] 逐习惯聚合（布尔习惯与旧口径逐位等价，零数据迁移）。
  int get totalCheckIns {
    var sum = 0;
    for (final h in _habits) {
      sum += _metDaysOf(h).length;
    }
    return sum;
  }

  /// 「累计打卡**记录**数」（有记录即计，含未达标日）。仅用于导出 / 诊断等
  /// 确实需要「写盘条数」语义的场景，UI 一律用 [totalCheckIns]。
  int get totalCheckInRecords => _checkIns.length;
  int get habitCount => _habits.length;
  int get overallCurrentStreak =>
      _streakFor(_metDatesAll, allowTodayGap: true);
  int get overallLongestStreak => _streakFor(_metDatesAll, longest: true);

  /// T1-2：某习惯的「达标日」集合（date-only）。
  ///
  /// 量化习惯只认可达标的日子——否则「每天 8 杯水」喝 1 杯就计入连续天数与周目标，
  /// 统计会系统性虚高。布尔习惯（effectiveTarget == 1）与「有记录」完全等价。
  Set<DateTime> _metDaysOf(Habit habit) {
    final set = <DateTime>{};
    for (final c in _checkIns) {
      if (c.habitId != habit.id) continue;
      if (!habit.targetMetBy(c.value)) continue;
      set.add(DateTime(c.date.year, c.date.month, c.date.day));
    }
    return set;
  }

  /// 全部习惯的达标日并集（整体连续天数用）。
  Set<DateTime> get _metDatesAll {
    final set = <DateTime>{};
    for (final c in _checkIns) {
      final h = byId(c.habitId);
      // 习惯已被删除（不该发生，防御性）时退回「有记录即达标」，避免静默丢历史。
      if (h != null && !h.targetMetBy(c.value)) continue;
      set.add(DateTime(c.date.year, c.date.month, c.date.day));
    }
    return set;
  }

  /// 基于一组「达标日」计算连续天数（T1-4 起统一支持 [weekdays] 与 [graceDays]）。
  ///
  /// 口径：
  /// - **计划日** = [weekdays] 命中的星期；[weekdays] 为空 = 每天都计划。
  ///   计划外的休息日对连续性**中性**（不计入，也不打断）——F-4 的口径。
  /// - **宽限日**：每个自然周（周一~周日）最多允许 [graceDays] 个计划日缺卡；
  ///   缺卡消耗当周额度，额度耗尽才断签。0 = 严格模式（缺卡即断，旧行为）。
  /// - [longest]=true：从最早达标日扫到今天，取最长连续段；
  ///   否则从今天往回走，[allowTodayGap]=true 时「今天是计划日但尚未达标」
  ///   既不消耗宽限额度、也不算断签（对齐「还没打卡就显断」的旧体验）。
  ///
  /// 本函数同时取代旧的 `_streakFor`（自然日）与 `_plannedStreakFor`（计划日）两套实现：
  /// 二者在 `weekdays` 为空时等价，在非空时前者错误地把休息日当断签，故此前需要分叉。
  /// 统一后只有一处口径，`graceDays = 0` 时与旧行为逐位一致（回归测试钉死）。
  static int _streakFor(
    Set<DateTime> dates, {
    Set<int> weekdays = const <int>{},
    int graceDays = 0,
    bool longest = false,
    bool allowTodayGap = false,
  }) {
    if (dates.isEmpty) return 0;
    final planned = weekdays.where((d) => d >= 1 && d <= 7).toSet();
    final grace = graceDays < 0 ? 0 : graceDays;
    bool isPlanned(DateTime d) => planned.isEmpty || planned.contains(d.weekday);
    final earliest = dates.reduce((a, b) => a.isBefore(b) ? a : b);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    if (longest) {
      var best = 0;
      var run = 0;
      // 本周剩余宽限额度，按「该周周一（date-only）」记账；未出现过的周默认满额。
      final budget = <DateTime, int>{};
      for (var d = earliest;
          !d.isAfter(today);
          d = d.add(const Duration(days: 1))) {
        if (!isPlanned(d)) continue;
        if (dates.contains(d)) {
          run++;
          if (run > best) best = run;
        } else {
          final wk = _mondayOf(d);
          final left = budget[wk] ?? grace;
          if (left > 0) {
            budget[wk] = left - 1; // 消耗一次宽限，连续段不中断
          } else {
            run = 0; // 额度用尽 → 断签
          }
        }
      }
      return best;
    }

    var cursor = today;
    if (isPlanned(cursor) && !dates.contains(cursor) && allowTodayGap) {
      cursor = cursor.subtract(const Duration(days: 1));
    }
    final budget = <DateTime, int>{};
    var streak = 0;
    // 回退下界为最早达标日：再往前不可能有记录（同时保证循环必然终止）。
    while (!cursor.isBefore(earliest)) {
      if (isPlanned(cursor)) {
        if (dates.contains(cursor)) {
          streak++;
        } else {
          final wk = _mondayOf(cursor);
          final left = budget[wk] ?? grace;
          if (left > 0) {
            budget[wk] = left - 1;
          } else {
            break;
          }
        }
      }
      cursor = cursor.subtract(const Duration(days: 1));
    }
    return streak;
  }

  /// 全部打卡日期集合（date-only，去重），供热力图整体视图着色。
  /// 用「有记录」的宽松口径（与 [checkedDays] 一致），量化习惯也不漏着色。
  Set<DateTime> get allCheckedDays => _checkIns
      .map((c) => DateTime(c.date.year, c.date.month, c.date.day))
      .toSet();

  /// P3-2（v2.9.3 审计）：近 [days] 天内按「日」聚合的**达标习惯数**
  /// （量化习惯当日累计量 ≥ 目标才计入；布尔习惯即有记录）。
  ///
  /// 此前同位置还有一个旧口径版本（数「有记录的习惯数」）：量化习惯某日只完成
  /// 1/8 会与「8/8 达标」得到相同计数与颜色档位，与详情页「按达成度四档着色」
  /// 口径相悖。布尔习惯两者逐位等价。
  ///
  /// P3-10（v2.9.4 审计）：该旧口径方法已**删除**（自本方法落地后无任何生产
  /// 调用点，纯死代码）。理由：两套口径并存本身就是下一轮审计的抓手——谁再
  /// 误用「有记录」版，量化习惯的热力图会与概览卡打架。此刻删比留更便宜。
  Map<DateTime, int> metCountsByDay(int days) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final start = today.subtract(Duration(days: days - 1));
    final map = <DateTime, int>{};
    for (final c in _checkIns) {
      final h = byId(c.habitId);
      if (h == null || !h.targetMetBy(c.value)) continue; // 只计达标
      final d = DateTime(c.date.year, c.date.month, c.date.day);
      if (d.isBefore(start)) continue;
      map[d] = (map[d] ?? 0) + 1;
    }
    return map;
  }

  // ===== 备份 / 导出 / 恢复（并入「备份与恢复」「导出数据」）=====

  /// 完整备份数据（习惯 + 打卡记录），用于「备份与恢复」导出。
  /// 以独立键 ['habits'] / ['check_ins'] 写入，老备份缺这些键时恢复逻辑会跳过，
  /// 不会误清现有习惯数据。
  Map<String, dynamic> backupData() => {
        'habits': _habits.map((h) => h.toJson()).toList(),
        'check_ins': _checkIns.map((c) => c.toJson()).toList(),
      };

  /// 从备份 JSON 恢复：仅恢复备份中实际存在的部分（[habits] / [check_ins]）。
  /// 老备份无这两个键时不触碰现有习惯，避免「恢复任务备份反而清空习惯」。
  Future<void> restoreFromJson(Map<String, dynamic> data) async {
    if (data['habits'] is List) {
      final habitsList = data['habits'] as List;

      // 🔴 修复 Bug1（僵尸习惯提醒）：覆盖 _habits 之前，先取消**本机现有全部习惯**
      // 的每日打卡提醒。否则若本机有 H1、备份里只有 H2，恢复后 H1 从列表消失，
      // 但它在系统 AlarmManager 里已排的提醒不会被取消，之后到点仍会弹一个
      // 「点进去找不到的习惯」提醒。
      // （F-2 起习惯提醒也是「一次性闹钟 × 预挂 8 次」，不再由系统周期分量永久循环，
      //  但要挂的槽位依然存在，故这一步取消仍然必要且必须放在覆盖之前。）
      // 对比 TaskProvider.restoreFromJson 的做法（先整体 cancelAll 再重排），
      // 习惯侧此前漏掉了这一步，现补上。
      final oldIds = _habits.map((h) => h.id).toList();
      for (final id in oldIds) {
        await NotificationService.instance.cancelHabitReminder(id);
      }

      _habits
        ..clear()
        ..addAll(
            habitsList.map((e) => Habit.fromJson(e as Map<String, dynamic>)));
      // 取消旧提醒并按恢复的 habits 重新调度（仅习惯提醒，不动任务通知）。
      // 注：上面的 oldIds 取消已覆盖「本机多余习惯」，这里再对恢复的列表逐个
      // 重挂（含 archived/无提醒的跳过），保证最终状态与备份一致。
      for (final h in _habits) {
        await NotificationService.instance.cancelHabitReminder(h.id);
        if (!h.archived && h.reminderMinute != null) {
          await NotificationService.instance.scheduleHabitReminder(
            h,
            // P2-1（v2.9.3 审计）：判据统一为「达标」口径。
            checkedToday: isTargetMetToday(h),
          );
        }
      }
    }
    if (data['check_ins'] is List) {
      final checkList = data['check_ins'] as List;
      _checkIns
        ..clear()
        ..addAll(
            checkList.map((e) => CheckIn.fromJson(e as Map<String, dynamic>)));
    }
    await _persistHabits();
    await _persistCheckIns();
    notifyListeners();
    // P3-3（v2.9.3 审计）：补触发「习惯/打卡变动」回调——恢复可能整体替换习惯
    // 与打卡集，23:00 挽留等内容必须按恢复后的口径重排。
    // P3-8（v2.9.4 审计）：上一版注释在这里写「其他写入口（addHabit /
    // updateHabit / setCheckInValue / deleteHabit …）均已触发」——**与代码不符**：
    // [addHabit] 与 [setReminder] 当时都没触发，正文注释比代码乐观。
    // 现已补齐（见两处），本回调的全部写入口覆盖为：
    // addHabit / addHabitFromDraft / setReminder / updateHabit /
    // setCheckInValue（含 toggle / adjust / complete / clear / checkInOnDay /
    // uncheckInOnDay 的委托）/ deleteHabit / restoreHabit / restoreFromJson。
    _notifyHabitsChanged();
  }

  // ===== 导出列单一真源（P2-5，v2.9.3 审计）=====
  //
  // 此前 CSV 与 Excel 各写一份表头/取值：v2.9.3 给 CSV 补了「每日目标 / 宽限日 /
  // 累计量」三列，Excel 路径被漏掉——量化量级在 Excel 副本里全部丢失，且 Excel 的
  // 「累计打卡」列对量化习惯是达标天数而非投入总量，与 CSV「累计达标(天)」语义
  // 并列时易被误读。现在两份导出共用下面的列定义，下一轮加列只改这一处。

  /// 习惯表列定义（CSV / Excel 共用，逐列对齐 [habitExportCells]）。
  static const List<String> habitExportHeaders = [
    '习惯',
    '表情',
    '创建时间',
    '当前连续(天)',
    '最长连续(天)',
    '累计达标(天)',
    '提醒',
    '每日目标',
    '宽限日(天)',
    '是否归档',
  ];

  /// 习惯表一行取值（与 [habitExportHeaders] 逐列对齐）。
  ///
  /// 文本列回传 String（CSV 侧统一加引号转义、Excel 侧直写单元格），
  /// 数值列回传 int；「每日目标」对布尔习惯回传空串（与旧 CSV 逐字节一致）。
  /// 所有取值均非空（返回 List<Object>，Excel 侧 _set 的参数是非空 Object）。
  List<Object> habitExportCells(Habit h) => [
        h.title,
        h.emoji,
        _fmt(h.createdAt),
        currentStreak(h),
        longestStreak(h),
        checkInCount(h),
        h.reminderMinute == null ? '' : _fmtMinute(h.reminderMinute!),
        h.isQuantified ? '${h.dailyTarget}' : '',
        h.graceDays,
        h.archived ? '是' : '否',
      ];

  /// 打卡记录表列定义（CSV / Excel 共用）。
  static const List<String> checkInExportHeaders = ['习惯', '打卡日期', '累计量'];

  /// 打卡记录表一行取值（[name] = 习惯名，习惯已删时由调用方回退为 id）。
  List<Object> checkInExportCells(CheckIn c, {required String name}) =>
      [name, CheckIn.dateKey(c.date), c.value];

  /// 导出 CSV：先列习惯表（含当前/最长连续、累计达标、每日目标、宽限日），
  /// 再列打卡记录表（含累计量）。列定义见 [habitExportHeaders] / [checkInExportHeaders]。
  String exportCsv() {
    final buf = StringBuffer();
    buf.writeln(habitExportHeaders.join(','));
    for (final h in _habits) {
      buf.writeln(_csvLine(habitExportCells(h)));
    }
    buf.writeln();
    buf.writeln(checkInExportHeaders.join(','));
    final titleById = {for (final h in _habits) h.id: h.title};
    for (final c in _checkIns) {
      buf.writeln(_csvLine(
          checkInExportCells(c, name: titleById[c.habitId] ?? c.habitId)));
    }
    return buf.toString();
  }

  /// 一行 CSV：文本列加引号并转义（防公式注入 / 逗号破列），数值列直写。
  static String _csvLine(List<Object> cells) => cells
      .map((v) => v is String ? '"${_esc(v)}"' : '$v')
      .join(',');

  /// 导出 Markdown：习惯清单（含连续/累计）+ 打卡记录列表。
  String exportMarkdown() {
    final buf = StringBuffer();
    buf.writeln('# 有条 习惯导出');
    buf.writeln('');
    buf.writeln('> 导出时间：${_fmt(DateTime.now())}');
    buf.writeln('');
    if (_habits.isEmpty) {
      buf.writeln('_暂无习惯_');
      return buf.toString();
    }
    buf.writeln('## 习惯（${_habits.length}）');
    for (final h in _habits) {
      final reminder =
          h.reminderMinute == null ? '无' : _fmtMinute(h.reminderMinute!);
      // T1-2：量化习惯补显示「每日目标 / 累计量」，否则 MD 副本看不出量级。
      final target = h.isQuantified ? ' ｜ 每日目标 ${h.dailyTarget}' : '';
      final value = h.isQuantified ? ' ｜ 累计量 ${totalValue(h)}' : '';
      final grace = h.graceDays > 0 ? ' ｜ 宽限 ${h.graceDays} 天/周' : '';
      buf.writeln('- ${_mdText(h.emoji)} ${_mdText(h.title)} ｜ 当前连续 '
          '${currentStreak(h)} 天 · 最长 ${longestStreak(h)} 天 · 累计达标 '
          '${checkInCount(h)} 天$value ｜ 提醒 $reminder$target$grace'
          '${h.archived ? ' ｜ 已归档' : ''}');
    }
    if (_checkIns.isNotEmpty) {
      buf.writeln('');
      buf.writeln('## 打卡记录（${_checkIns.length}）');
      final titleById = {for (final h in _habits) h.id: h.title};
      for (final c in _checkIns) {
        final name = titleById[c.habitId] ?? c.habitId;
        buf.writeln('- ${CheckIn.dateKey(c.date)} ｜ ${_mdText(name)}'
            '${c.value > 1 ? ' ｜ ${c.value}' : ''}');
      }
    }
    return buf.toString();
  }

  static String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  static String _fmtMinute(int m) =>
      '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';
  static String _esc(String s) => csvCell(s);

  /// P3-10（v2.9.1 审计）：Markdown 导出不得复用 [csvCell]（其职责是防 Excel 把
  /// `=` / `+` / `-` / `@` 开头的单元格当公式执行），MD 无公式执行面，套用会给
  /// 标题硬加 `'` 前缀、把引号变成 `""`，污染可读副本。这里只做换行归一。
  static String _mdText(String s) => s.replaceAll(RegExp(r'[\r\n]+'), ' ');

  Future<void> _persistHabits() async {
    try {
      await LocalDatabase.instance.replaceHabits(_habits);
    } catch (e) {
      AppLog.d('HabitProvider 持久化 habits 失败：$e');
    }
  }
  Future<void> _persistCheckIns() async {
    try {
      await LocalDatabase.instance.replaceCheckIns(_checkIns);
    } catch (e) {
      AppLog.d('HabitProvider 持久化 checkIns 失败：$e');
    }
  }
}

/// T1-4：一次「删除习惯」的完整快照（习惯本体 + 其全部打卡记录 + 原列表位置）。
///
/// 删除是可撤销的：UI 拿到快照后展示 SnackBar「撤销」，用户点击即调
/// [HabitProvider.restoreHabit] 原样放回。之所以把打卡记录一起快照，是因为
/// 连续天数、热力图、周报月报全部由这些记录派生——只恢复习惯本体等于
/// 「留下一个历史为空的空壳」，撤销就名存实亡了。
class DeletedHabit {
  final Habit habit;
  final List<CheckIn> checkIns;
  /// 删除前在习惯列表中的下标，恢复时插回原位，避免列表顺序莫名跳动。
  final int index;
  const DeletedHabit({
    required this.habit,
    required this.checkIns,
    required this.index,
  });

  /// 撤销提示文案（如「已删除「喝水」（含 12 条打卡记录）」）。
  String get undoLabel =>
      '已删除「${habit.title}」${checkIns.isEmpty ? '' : '（含 ${checkIns.length} 条打卡记录）'}';
}
