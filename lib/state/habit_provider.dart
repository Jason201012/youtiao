import 'package:flutter/material.dart';
import 'package:todolist/services/app_log.dart';
import 'package:todolist/models/habit.dart';
import 'package:todolist/models/checkin.dart';
import 'package:todolist/services/habit_migration.dart';
import 'package:todolist/services/local_database.dart';
import 'package:todolist/services/notification_service.dart';
import 'package:todolist/services/pinyin_index.dart';
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

  /// U2-1（v3.0.5 审计）：本会话 9 号槽确认条存在性的**内存近似**——
  /// habitId → 确认条展示日（dateKey）。通知 action 路径每次 show 确认条后
  /// 由 main 调 [markConfirmShown] 登记；[setCheckInValue] 的今日非零写入据此
  /// 判断「是否已有确认条可覆盖刷新」（恢复 v3.0.3 U3-1 的内容新鲜度，同时
  /// 保持 v3.0.4 U2-1「无中生有」的消除）。进程重启即清空——重启后的通知栏
  /// 残留由 P3-1（v3.0.5 审计）的冷启动清理兜住；跨天标记经 [_confirmShownToday]
  /// 自然失效。
  final Map<String, String> _confirmShownMarks = <String, String>{};

  /// P3-1（v3.0.8 审计）：习惯侧安全模式标志——与 [TaskProvider.dbLoadFailed]
  /// 同口径。此前 `load()` 失败只清空内存并写日志，UI 无从感知「现在处于
  /// 写盘恒失败的安全模式」，打卡失败提示一律复读「请重试」（重试必然再失败），
  /// 与顶部「本次修改不会保存」横幅自相矛盾。置位后由 habit_screen 的
  /// `showCheckInPersistFailedHint` 分化为根因文案。
  bool _dbLoadFailed = false;
  bool get dbLoadFailed => _dbLoadFailed;

  /// P1-1（v3.1.0 审计）：测试钩子——同 FocusProvider.markDbLoadFailedForTest。
  /// 「加载失败 → 写入被拒」的守卫语义由回归测试显式置位后钉死。
  @visibleForTesting
  void markDbLoadFailedForTest() => _dbLoadFailed = true;

  /// U2-1（v3.0.5 审计）：通知 action 路径 show 确认条后登记（见
  /// [_confirmShownMarks]）。仅供 main 的通知 action 回调调用。
  void markConfirmShown(String habitId) =>
      _confirmShownMarks[habitId] = CheckIn.dateKey(DateTime.now());

  /// U2-1（v3.0.5 审计）：该习惯本会话是否有**今天的**确认条标记；
  /// 跨天标记顺带清除（昨天的确认条在跨天路径已被 cancel，标记不该再命中）。
  bool _confirmShownToday(String habitId) {
    final today = CheckIn.dateKey(DateTime.now());
    final marked = _confirmShownMarks[habitId];
    if (marked == null) return false;
    if (marked != today) {
      _confirmShownMarks.remove(habitId);
      return false;
    }
    return true;
  }

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
  ///
  /// A3（v3.1.1 功能增强）：按 [Habit.order] 升序展示（拖拽排序的读点）；
  /// 同 order 值按创建时间兜底——旧数据全 0 时展示顺序与升级前逐位一致
  /// （零迁移）。归档习惯不参与排序（[archivedHabits] 单独成区）。
  List<Habit> get activeHabits {
    final list = _habits.where((h) => !h.archived).toList()
      ..sort((a, b) {
        final c = a.order.compareTo(b.order);
        if (c != 0) return c;
        final c2 = a.createdAt.compareTo(b.createdAt);
        if (c2 != 0) return c2;
        // 终极并列（同毫秒创建）：按 id 兜底——id 形如「微秒时间戳.序号」，
        // 字典序 ≈ 创建序，保证排序**全序确定**（List.sort 非稳定排序，
        // 无兜底时同键元素顺序随输入抖动，会打乱依赖顺序的用例与 UI）。
        return a.id.compareTo(b.id);
      });
    return list;
  }

  /// 新P2-2（v2.9.7 审计）：已归档的习惯。
  ///
  /// 归档此前是**单向不可逆**操作——习惯页只渲染 `activeHabits`、搜索命中
  /// 归档习惯只切 Tab，详情/编辑层（含取消归档开关）永久不可达。补本 getter
  /// 供习惯页「已归档」折叠区展示，让取消归档入口重新可达。
  List<Habit> get archivedHabits =>
      _habits.where((h) => h.archived).toList();

  /// P2-5（v2.9.6 审计）：[day] 在计划内的活动习惯（`shouldCheckInOn` 过滤）。
  ///
  /// 习惯页概览卡「今日 x/y」的分子分母统一从这里取——此前分母用
  /// `activeHabits.length`，休息日也被计入（「每周一三五 + 每天」在周二显示
  /// 「今日 1/2」，持续暗示漏卡），与今日卡（`TodayAggregate`）、晚简报
  /// （daily_briefing 的 P2-6 修复）同族口径打架。
  List<Habit> habitsDueOn(DateTime day) =>
      activeHabits.where((h) => h.shouldCheckInOn(day)).toList();

  /// 按 id 查找习惯，找不到返回 null（通知稍后提醒等场景用）。
  Habit? byId(String id) {
    for (final h in _habits) {
      if (h.id == id) return h;
    }
    return null;
  }

  Future<void> load() async {
    _instance = this; // 注册单例，供自动备份等场景安全取用
    // U3-1（v3.0.8 审计）：load 会整体替换数据集，删除撤销的失败暂存
    // （[_pendingRestore]）随之作废——否则备份恢复后点旧横幅会把备份外 /
    // 已不存在的习惯塞回当前数据集。
    _pendingRestore = null;
    try {
      final db = LocalDatabase.instance;
      // 内存后端（测试）无需打开真实 SQLite；仅在生产（非内存）模式确保建表。
      if (!LocalDatabase.testUseMemory) {
        await db.db;
      }
      _habits
        ..clear()
        ..addAll(await db.loadHabits());
      // A4（v3.1.1 功能增强）：旧数据拼音索引回填——两串皆空且标题非空时按
      // 标题补算（仅内存，随后任意持久化顺带落库；标题无汉字者计算结果本就
      // 为空串，每轮重复计算的开销可忽略）。旧习惯无需恢复备份即可全拼搜索。
      for (var i = 0; i < _habits.length; i++) {
        final h = _habits[i];
        if (h.title.isEmpty) continue;
        if (h.pinyinInitials.isEmpty && h.pinyinFull.isEmpty) {
          _habits[i] = h.copyWith(
            pinyinInitials: PinyinIndex.initials(h.title),
            pinyinFull: PinyinIndex.full(h.title),
          );
        }
      }
      _checkIns
        ..clear()
        ..addAll(await db.loadCheckIns());
      _dbLoadFailed = false; // 加载成功即脱离安全模式
    } catch (e, stack) {
      AppLog.d('HabitProvider 加载失败（习惯/打卡暂不可用）：$e\n$stack');
      _habits.clear();
      _checkIns.clear();
      // P3-1（v3.0.8 审计）：置位安全模式标志（见字段注释）。
      _dbLoadFailed = true;
    }
    // L3（v3.0.8 审计）：数据集已整体替换，9 号槽确认条的会话内存标记全部
    // 作废——否则备份恢复后「已有确认条」的近似命中，会让 App 内打卡
    // 「无中生有」覆盖刷新一条本会话并未展示过的确认条（v3.0.4 U2-1 不变量的
    // 恢复路径缺口）。
    _confirmShownMarks.clear();
    notifyListeners();
  }

  /// 新建习惯（自动生成 id 与时间戳）。
  ///
  /// U2-1（v3.0.6 审计）：返回落盘是否成功，失败**回滚内存**——旧实现
  /// `Future<void>` 忽略 `_persistHabits()` 结果：新建的习惯仅存内存，
  /// 重启即丢，UI 却显示成功（与任务侧 P2-1，v3.0.5 审计同构）。回滚口径
  /// 与 [deleteHabit] / [updateHabit] / [setCheckInValue]（P3-2，v3.0.5
  /// 审计）一致，调用方（_AddHabitSheet）据此停留编辑层并如实提示，
  /// 重试不会造出重复习惯。
  Future<bool> addHabit({
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
    /// A3（v3.1.1 功能增强）：量化单位（空/缺省 = 无单位；超界截断）。
    String? unit,
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
      // A3：单位写入侧夹取与反序列化侧同真源（Habit.clampUnit）。
      unit: unit == null ? '' : Habit.clampUnit(unit),
      // A3：新建习惯追加到排序末尾（order = 当前最大 + 1，_gap 兜底）。
      order: _nextHabitOrder(),
      // A4（v3.1.1 功能增强）：拼音索引随新建落库（全拼搜索的数据源）。
      pinyinInitials: PinyinIndex.initials(title),
      pinyinFull: PinyinIndex.full(title),
      createdAt: DateTime.now(),
    );
    _habits.add(h);
    // U2-1（v3.0.6 审计）：落盘失败回滚内存并返回 false（见方法注释）。
    final ok = await _persistHabits();
    if (!ok) {
      _habits.removeWhere((x) => x.id == h.id);
      notifyListeners();
      return false;
    }
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
    return true;
  }

  /// 生成全局唯一习惯 id（时间戳 + 进程内自增序号，避免同毫秒撞 id）。
  String _nextHabitId() =>
      '${DateTime.now().microsecondsSinceEpoch}.${_habitSeq++}';

  /// A3（v3.1.1 功能增强）：新建习惯的排序权重——追加到当前末尾之后
  /// （活动习惯的最大 order + 1；无活动习惯时从 0 起）。归档习惯不参与。
  double _nextHabitOrder() {
    var max = -1.0;
    for (final h in _habits) {
      if (h.archived) continue;
      if (h.order > max) max = h.order;
    }
    return max + 1;
  }

  /// A3（v3.1.1 功能增强）：习惯列表拖拽排序——把活动习惯从 [oldIndex] 移到
  /// [newIndex]（ReorderableListView 回调语义：newIndex 为目标插入位，含移除
  /// 前的偏移，这里按惯例先做 -1 归一），随后**全量重排** 0..n-1 并落盘。
  ///
  /// - 只重排活动习惯；归档习惯的 order 原样保留（不参与排序）。
  /// - 返回落盘是否成功；失败回滚全部 order（与 [updateHabit] 同口径：
  ///   不留「内存已重排、库未落盘」的分歧）。
  /// - 顺序只影响展示，不影响打卡 / 统计 / 连续天数。
  Future<bool> reorderHabits(int oldIndex, int newIndex) async {
    final actives = activeHabits;
    if (oldIndex < 0 || oldIndex >= actives.length) return false;
    var target = newIndex > oldIndex ? newIndex - 1 : newIndex;
    if (target < 0) target = 0;
    if (target > actives.length - 1) target = actives.length - 1;
    final moved = actives[oldIndex];
    if (moved.id == actives[target].id) return true; // 原位：无操作
    final reordered = [...actives]..removeAt(oldIndex);
    reordered.insert(target, moved);
    final orderById = <String, double>{
      for (var i = 0; i < reordered.length; i++) reordered[i].id: i.toDouble(),
    };
    final snapshot = List<Habit>.of(_habits);
    var dirty = false;
    for (var i = 0; i < _habits.length; i++) {
      final n = orderById[_habits[i].id];
      if (n == null || _habits[i].order == n) continue;
      _habits[i] = _habits[i].copyWith(order: n);
      dirty = true;
    }
    if (!dirty) return true;
    notifyListeners();
    final ok = await _persistHabits();
    if (!ok) {
      _habits
        ..clear()
        ..addAll(snapshot);
      notifyListeners();
      return false;
    }
    return true;
  }

  /// T1-3：按「任务 → 习惯」映射草稿新建习惯，返回创建出的 [Habit]。
  ///
  /// 与 [addHabit] 的差别只有「字段来自哪里」：这里由 [HabitDraft.fromTask]
  /// 统一给出（标题 / 打卡星期 / 提醒时刻 / 周目标），UI 只负责 emoji 与颜色，
  /// 从而保证「转习惯」在不同入口（任务详情、未来的右键菜单）行为一致。
  ///
  /// U2-1（v3.0.6 审计）：落盘失败回滚内存并返回 **null**——旧实现
  /// `Future<Habit>` 忽略 `_persistHabits()` 结果，任务详情页照弹
  /// 「已转为习惯」并询问是否删除原任务（把用户往数据丢失上引）。返回
  /// null 与 [restoreHabit] 的「未生效」同型，调用方按失败分支走。
  Future<Habit?> addHabitFromDraft(
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
      // A3：与 [addHabit] 同口径——转习惯的新条目同样追加到排序末尾。
      order: _nextHabitOrder(),
      // A4（v3.1.1 功能增强）：拼音索引随新建落库。
      pinyinInitials: PinyinIndex.initials(draft.title),
      pinyinFull: PinyinIndex.full(draft.title),
      createdAt: DateTime.now(),
    );
    _habits.add(h);
    final ok = await _persistHabits();
    if (!ok) {
      _habits.removeWhere((x) => x.id == h.id);
      notifyListeners();
      return null;
    }
    if (h.reminderMinute != null) {
      await NotificationService.instance.scheduleHabitReminder(h);
    }
    notifyListeners();
    _notifyHabitsChanged();
    return h;
  }

  /// 更新某习惯的每日提醒时间（null = 取消提醒）。先取消旧提醒，再按新值调度/保持静默。
  ///
  /// U2-1（v3.0.6 审计）：返回落盘是否成功，失败**回滚内存且不动通知**——
  /// 旧实现 `Future<void>` 忽略 `_persistHabits()` 结果：改提醒时间仅存
  /// 内存，重启回退，而系统闹钟已按新时刻重挂（内存/通知/DB 三处口径
  /// 分裂）。回滚后旧提醒仍在，与恢复后的习惯状态天然一致。
  Future<bool> setReminder(Habit habit, int? minute) async {
    final updated =
        habit.copyWith(reminderMinute: minute, clearReminder: minute == null);
    final idx = _habits.indexWhere((h) => h.id == habit.id);
    if (idx == -1) return false;
    // U2-1（v3.0.6 审计）：回滚到**列表当前对象**而非调用方实参。调用方的
    // [habit] 可能是过期快照——「先成功改过一次提醒、再改第二次且落盘失败」
    // 时实参仍是改之前的对象，按实参回滚会把第一次已落盘的改动一并抹掉
    // （v306 回归测试实证：reminderMinute 540 → null）。与 [updateHabit] 的
    // `old = _habits[idx]` 同口径。
    final old = _habits[idx];
    _habits[idx] = updated;
    final ok = await _persistHabits();
    if (!ok) {
      // U2-1（v3.0.6 审计）：回滚内存（编辑不生效），通知保持原样。
      _habits[idx] = old;
      notifyListeners();
      return false;
    }
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
    return true;
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
    // P3-2（v3.0.6 审计）：撤提醒挪到**落盘成功之后**——旧实现先
    // cancelHabitReminder（0..7 每日落点 + 8 号 snooze + 9 号确认条）再落盘，
    // 失败回滚只按 reminderMinute 重挂每日提醒，漏掉 9 号确认条：删除失败
    // 但用户刚收到的「已记 x/y · 撤销」确认条永久消失（内存态回滚了、
    // 通知态没回滚，与本轮 P3-2「回滚后状态与落盘前一致」的目标自相矛盾）。
    // 与任务侧 P2-2（v3.0.5 审计）「先撤后挂按门控」是同族顺序问题——现在
    // 失败路径根本不动通知，成功路径才撤，彻底消除「先撤后落盘」。
    final okHabits = await _persistHabits();
    // P3-5（v3.0.7 审计）：两段式落盘**首段失败即短路**，不再写次段——旧实现
    // 两段都写，四种组合里有两种留下「告知与库内状态相反」的部分成功态：
    // ① habits❌/checkins✅ → 库里习惯还在、打卡全没（用户看到「删除未生效」，
    // 重启后习惯带着空白历史回来）；② habits✅/checkins❌ → 孤儿打卡记录。
    // 短路后只剩组合②（危害远小于①：重试一次删除即可清掉孤儿记录），且内存
    // 全量回滚与告知口径一致（「删除未生效，请重试」）。与 restoreFromJson
    // 「整体替换、不做内存回滚」的论证并不矛盾——那是单段全量替换，本方法是
    // 两段独立写，注释里早已承认两段式不可回滚补偿（见 restoreFromJson 注释）。
    if (!okHabits) {
      _habits.insert(idx, snapshot.habit);
      _checkIns.addAll(snapshot.checkIns);
      // P3-2（v3.0.6 审计）：通知未被触碰，无需重挂（旧实现在此按
      // reminderMinute 补挂每日提醒、漏 9 号槽——现已无撤可补）。
      notifyListeners();
      return null;
    }
    final okCheckIns = await _persistCheckIns();
    if (!okCheckIns) {
      // 首段已落库（库里习惯已删）、次段失败：内存同样全量回滚，用户得到
      // 「删除未生效」的如实告知；孤儿打卡记录由重试删除时清掉。
      _habits.insert(idx, snapshot.habit);
      _checkIns.addAll(snapshot.checkIns);
      notifyListeners();
      return null;
    }
    await NotificationService.instance.cancelHabitReminder(id);
    // L3（v3.0.8 审计）：删除成功即作废该习惯的 9 号槽确认条会话标记——
    // 否则（备份恢复 / 同 id 重建等路径）会让后续 App 内打卡「无中生有」地
    // 覆盖刷新一条本会话并未展示过的确认条，违背 v3.0.4 U2-1 不变量。
    _confirmShownMarks.remove(id);
    notifyListeners();
    _notifyHabitsChanged();
    return snapshot;
  }

  /// T1-4：撤销删除——把 [snapshot] 里的习惯与打卡记录原样放回（含原列表位置）。
  ///
  /// 幂等：若同 id 习惯已存在（例如用户删后又自己重建了同一条）则不做任何改动、
  /// 返回 null，避免把撤销变成「制造重复习惯」。提醒按恢复后的状态重挂。
  ///
  /// U2-1（v3.0.6 审计）：落盘失败也回滚（习惯与本次放回的打卡一并撤下）
  /// 并返回 null——旧实现忽略两个 persist 结果，撤销仅存内存，重启后习惯
  /// 「没恢复」而用户已看到撤销成功。返回 null 现覆盖两种「未生效」：
  /// 同 id 已重建 / 落盘失败，调用方统一按失败提示（habit_screen 的
  /// failureHint 已相应改为「撤销未生效：请重试」）。
  ///
  /// P2-1（v3.0.7 审计）：落盘失败时把快照**暂存**进 [_pendingRestore]——撤销
  /// action 点按后横幅即被框架关闭，快照原本只活在该闭包里：习惯已从内存与
  /// 数据库同时移除（deleteHabit 早已成功落盘），数据实际不可恢复，而文案
  /// 承诺的「请重试」在物理上不存在入口。现由 [retryRestoreHabit] 从暂存区
  /// 重新恢复， habit_screen 的失败提示挂「再试一次」action 调用它——与通知侧
  /// `showTaskUndoNotSaved` 的「重试」载体对齐。成功恢复或同 id 已重建（早退
  /// 分支不暂存）时清空暂存。
  ///
  /// P3-5（v3.0.7 审计）：同 [deleteHabit] 首段失败即短路次段，把「部分成功」
  /// 面从 2 种收窄到 1 种（仅剩首段成功/次段失败：库里习惯已复活、打卡未写，
  /// 重试撤销即可补上）。
  Future<Habit?> restoreHabit(DeletedHabit snapshot) async {
    if (byId(snapshot.habit.id) != null) {
      _pendingRestore = null; // 同 id 已重建：真失效，无可重试之物
      return null;
    }
    final at = snapshot.index.clamp(0, _habits.length);
    _habits.insert(at, snapshot.habit);
    // 打卡记录逐条去重后放回（同 id 记录已随删除一并移除，这里的去重是防御性的）。
    final existing = _checkIns.map((c) => c.id).toSet();
    final added = <String>[];
    for (final c in snapshot.checkIns) {
      if (existing.add(c.id)) {
        _checkIns.add(c);
        added.add(c.id);
      }
    }
    // U2-1（v3.0.6 审计）：落盘失败回滚（见方法注释）。
    final okHabits = await _persistHabits();
    if (!okHabits) {
      _habits.removeWhere((h) => h.id == snapshot.habit.id);
      _checkIns.removeWhere((c) => added.contains(c.id));
      notifyListeners();
      _pendingRestore = snapshot; // P2-1（v3.0.7 审计）：暂存快照供重试
      return null;
    }
    final okCheckIns = await _persistCheckIns();
    if (!okCheckIns) {
      _habits.removeWhere((h) => h.id == snapshot.habit.id);
      _checkIns.removeWhere((c) => added.contains(c.id));
      notifyListeners();
      _pendingRestore = snapshot; // P2-1（v3.0.7 审计）：暂存快照供重试
      return null;
    }
    _pendingRestore = null;
    if (!snapshot.habit.archived && snapshot.habit.reminderMinute != null) {
      _rescheduleReminder(snapshot.habit);
    }
    notifyListeners();
    _notifyHabitsChanged();
    return snapshot.habit;
  }

  /// P2-1（v3.0.7 审计）：[restoreHabit] 落盘失败后暂存的删除快照（单槽位）。
  /// 只由失败路径写入、成功路径与同 id 重建早退时清空；重试入口见
  /// [retryRestoreHabit]。
  DeletedHabit? _pendingRestore;

  /// 当前暂存的待恢复快照（null = 无）。供 UI 在失败提示挂「再试一次」前
  /// 判断载体是否仍在（快照不会因提示条超时消失而丢失）。
  DeletedHabit? get pendingRestore => _pendingRestore;

  /// P2-1（v3.0.7 审计）：重试恢复——从 [_pendingRestore] 重新走一遍
  /// [restoreHabit]。返回恢复后的习惯；仍失败（含暂存已空 / 与入参不是同一
  /// 快照）时返回 null，快照继续暂存（restoreHabit 失败路径会重新写入），
  /// 用户可再次重试。与通知侧 `showTaskUndoNotSaved` 的「重试」action 同口径：
  /// 给「请重试」一个真实可点的载体，而不是让用户去找一个不存在的按钮。
  ///
  /// U3-1（v3.0.8 审计）：入参从无参改为**显式快照**并按 id 校验——暂存区是
  /// 单槽位，两次删除撤销连续失败时会被后一次覆盖：旧无参版让第一张横幅的
  /// 「再试一次」恢复**第二个**习惯，却用第一个习惯的标题提示「已恢复『A』」
  /// （恢复错对象 + 报错标题）。闭包捕获的快照与暂存区不一致时按失效处理。
  Future<Habit?> retryRestoreHabit(DeletedHabit snapshot) async {
    final snap = _pendingRestore;
    if (snap == null) return null;
    if (snap.habit.id != snapshot.habit.id) return null;
    return restoreHabit(snap);
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
  ///
  /// P3-7（v2.9.6 审计）：统一读 [Habit.effectiveWeeklyGoal]（按当前计划天数
  /// 夹取的生效值），不再消费裸字段——裸字段自本轮起保留 fromJson 原值（保真），
  /// 消费点若不经过夹取判据，「计划日 3 天 · 周目标 7」的存量数据会让目标
  /// 永不可达（`consecutiveGoalWeeks` 恒 0）。
  bool goalMetThisWeek(Habit habit) =>
      habit.effectiveWeeklyGoal > 0 &&
      weeklyCheckIns(habit) >= habit.effectiveWeeklyGoal;

  /// 从本周往前连续达成周目标的周数（断一周即止）；weeklyGoal<=0 返回 0。
  /// 用于「连续 4 周达成周目标」成就判定。
  int consecutiveGoalWeeks(Habit habit, {int weeks = 4}) {
    final goal = habit.effectiveWeeklyGoal; // P3-7（v2.9.6 审计）：生效值
    if (goal <= 0) return 0;
    int run = 0;
    final today = DateTime.now();
    final metDays = _metDaysOf(habit);
    // L6（v3.0.8 审计）：从**上一个完整周**起算——旧实现把进行中的本周也当
    // 链条一环，「连续 4 周」成就实际只能在每周后半段解锁（本周只打了 1 天卡
    // 也计入链条）。w=1 即上一个已结束的自然周；本周达成由 goalMetThisWeek
    // 单独表达，不混入「连续」语义。
    for (int w = 1; w <= weeks; w++) {
      final monday = _mondayOf(DateTime(today.year, today.month, today.day)
          .subtract(Duration(days: 7 * w)));
      final sunday = monday.add(const Duration(days: 6));
      final count =
          metDays.where((d) => !d.isBefore(monday) && !d.isAfter(sunday)).length;
      if (count >= goal) {
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
  /// P3-2（v3.0.5 审计）：透传 [setCheckInValue] 的落盘结果（App 内写入口
  /// 据此如实反馈，不再忽略 bool）。
  Future<bool> toggleCheckInToday(Habit habit) async {
    return setCheckInValue(habit, DateTime.now(), isCheckedToday(habit) ? 0 : 1);
  }

  /// T1-2：在指定日把累计量调整为 [value]（0 → 删除记录，即撤卡）。
  ///
  /// 所有「+1 / 设置数量 / 撤卡」入口都收敛到这里，保证：
  /// 1. 只有一处写盘与重排逻辑，不会再出现「某个入口忘记重排提醒」的经典缺陷；
  /// 2. 值被夹在 [0, [Habit.maxDailyTarget]]，负数与天文数字都不会污染数据。
  ///
  /// P2-3（v3.0.1 审计）：归档习惯守卫——归档语义 = 退场（「不再出现在今日
  /// 打卡与提醒中」），此前归档习惯的详情页写按钮全部可用、通知 action 也
  /// 能写入，统计与成就仍被改动，与归档提示语自相矛盾。UI 侧已对归档行 /
  /// 详情页禁用写按钮，此处兜底拦截**全部程序化入口**（在途旧闹钟、未来
  /// 新增入口）：直接返回，不写、不落盘、不重排。
  /// P2-1（v3.0.4 审计）：返回写入是否**落盘成功**（含幂等早退 = true）。
  /// 通知 action 回调（main._doHabitCheckIn / _doHabitUndo）按本结果回报，
  /// DB 异常不再被吞成「成功」。
  Future<bool> setCheckInValue(Habit habit, DateTime day, int value) async {
    // H4（v3.0.8 审计）：归档 / 休息日守卫改判 **provider 当前对象**，不信任
    // 调用方实参——详情/编辑弹层此前一次性持有 Habit 对象、永不按 id 回读，
    // 保存成功后继续持旧对象：归档习惯的写按钮照常可点并真实落盘，还会用旧
    // 对象把已归档习惯的提醒重挂回系统闹钟（habit_provider.dart 旧 :644）。
    // 当前对象存在则以其为准；不存在（独立 Habit 对象的直接写入，如统计/
    // 分享等历史用法）回落实参，保持既有调用契约不破。
    final live = byId(habit.id) ?? habit;
    // P3-8（v3.1.0 审计）：归档早退从「返回 true」改为 **false**。旧语义把
    // 「拒绝写入」谎报成「落盘成功」——UI 已禁用归档习惯的写按钮、通知侧也有
    // 前置守卫，目前不爆发；但任何未来新增的批量/程序入口都会把「未写入」当
    // 成功，与全仓「bool = 落盘成功」的契约冲突。归档语义 = 退场，写入被拒，
    // 如实返回 false（休息日的幂等早退仍返回 true：那是「无需打卡」而非错误，
    // 两者语义不同，不合并处理）。
    if (live.archived) return false;
    // 休息日守卫同样按当前 weekdays 判定（改星期后旧弹层仍按旧 weekdays 放行
    // 的旁路）。仅限「写今天」——补卡（过去日期）按产品语义不限计划日，
    // UI（详情弹层「补卡」）对该路径有独立说明，不受此限。
    if (_sameDayKey(day, DateTime.now()) && !live.shouldCheckInOn(day)) {
      return true;
    }
    final v = value.clamp(0, Habit.maxDailyTarget);
    final k = CheckIn.dateKey(day);
    final idx = _checkIns
        .indexWhere((c) => c.habitId == live.id && CheckIn.dateKey(c.date) == k);
    // P3-2（v3.0.5 审计）：写前留存旧记录与写入形态，落盘失败时回滚内存——
    // 旧实现先改内存再落盘、失败不回滚，App 内 UI 乐观显示成功、重启静默回退。
    final CheckIn? previous = idx == -1 ? null : _checkIns[idx];
    final bool added = idx == -1 && v > 0;
    if (v <= 0) {
      if (idx == -1) return true; // 本就无记录 → 无操作，不触发无谓的落盘与重排
      _checkIns.removeAt(idx);
    } else if (added) {
      _checkIns.add(CheckIn.forDay(live.id, day, value: v));
    } else {
      if (_checkIns[idx].value == v) return true; // 值未变 → 无操作
      _checkIns[idx] = _checkIns[idx].withValue(v);
    }
    final ok = await _persistCheckIns(); // P2-1（v3.0.4 审计）：透传落盘结果
    if (!ok) {
      // P3-2（v3.0.5 审计）：落盘失败回滚内存改动，保证「UI 显示的即已落盘的」。
      // 按 habitId + dateKey 定位（await 期间下标可能漂移），回滚后不发
      // _notifyHabitsChanged（状态已还原，挽留等派生调度无需重排）。
      final cur = _checkIns.indexWhere(
          (c) => c.habitId == live.id && CheckIn.dateKey(c.date) == k);
      if (added) {
        if (cur != -1) _checkIns.removeAt(cur);
      } else if (previous != null && cur != -1) {
        _checkIns[cur] = previous;
      }
      _confirmShownMarks.remove(live.id);
      notifyListeners();
      return false;
    }
    notifyListeners();
    _rescheduleReminder(live);
    // P2-7（v2.9.5 审计）：**达标后撤掉挂起的「稍后提醒」**。
    //
    // 旧行为：21:00 弹提醒 → 点「稍后提醒」(+10min) → 21:05 在 App 里记满 8/8
    // → 21:10 仍弹「该打卡啦」。落点重排（[_rescheduleReminder]）只能把**今天**
    // 这一次顺延走，管不到独立 8 号槽的 snooze，于是已做完仍被打扰。
    // 任务侧「完成」会撤掉 snooze，习惯侧此前完全没有对应动作 → 两侧不对称。
    //
    // P2-6（v2.9.6 审计）：判据修正为「**写入的是今天** 且 今天达标」。本段
    // 注释在 v2.9.5 的判据句与理由句自相矛盾（判据句写 `isTargetMetOn(habit,
    // day)`、理由句却说「只有今天达标才与在途 snooze 有关」），实际代码取了
    // 前者——于是 21:00 挂着 snooze 时补卡**昨天**达标，也会把今天 21:10 的
    // 在途提醒静默撤掉（当天实际 0/8，提醒再也不响），与 P2-7 的修复目的正好
    // 相反。`_sameDayKey` 保证跨午夜补卡（凌晨补昨天的卡）也不会误判。
    // 未达标时不清——用户可能只是先记了 1/8，稍后提醒仍该响。
    if (_sameDayKey(day, DateTime.now()) && isTargetMetOn(live, day)) {
      NotificationService.instance.cancelHabitSnooze(live.id);
    }
    // P3-3（v3.0.2 审计）：**今天的打卡被撤到 0 时，一并撤掉 9 号槽确认通知**。
    // 通知打卡产生的「已打卡 ✓ / 撤销」确认条（[showHabitCheckedConfirm] /
    // [showHabitUndoConfirm]，独立 9 号槽）在 App 内撤卡后内容已失真（仍称
    // 「已打卡 ✓」且带可点「撤销」），用户再次打卡后点它会误退新卡。P3-4
    // （v3.0.1 审计）只在删除 / 归档路径清理，此为同一修复原则的另一半。
    // 仅「今天 + 实际删除了记录」（走到此处必已删除，见上方早退）才清：
    // 补昨天 / 前天的撤卡与展示中的今日确认条无关，不动。
    //
    // U2-1（v3.0.4 审计）：**App 内打卡不再「无中生有」生成确认条**。v3.0.3
    // U3-1 的「今日任何非零写入都覆盖式 show」让 App 内打卡也弹常驻通知，
    // v3.0.4 把 show 收口回通知 action 回调（main 按 P2-1 写入结果回报）。
    //
    // U2-1（v3.0.5 审计）：**恢复折中方案——仅当 9 号槽已有确认条时覆盖刷新**。
    // v3.0.4 的收口把「内容新鲜度」一并砍掉：「通知打卡已记 1/8 → App 内改到
    // 5/8」后确认条停在 1/8（失真窗口持续到归零 / 跨天），撤销预期错位回归。
    // 「是否已有确认条」用本会话通知 action 生成过的**内存标记**近似
    // （[markConfirmShown]，见字段注释）——标记不存在时不 show，保持「无中生有」
    // 的消除；归零仍走 cancel（失真清理，P3-3 v3.0.2 口径保留）。
    if (_sameDayKey(day, DateTime.now())) {
      if (v <= 0) {
        _confirmShownMarks.remove(live.id);
        NotificationService.instance.cancelHabitConfirm(live.id);
      } else if (_confirmShownToday(live.id)) {
        NotificationService.instance.showHabitCheckedConfirm(
          live,
          value: v,
          target: live.effectiveTarget,
        );
      }
    }
    _notifyHabitsChanged();
    return ok;
  }

  /// date-only 同日判定（P2-6，v2.9.6 审计）：补卡判据用。
  static bool _sameDayKey(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  /// T1-2：在某日累计量上增减 [delta]（+1 / −1 按钮走这里）。
  /// 结果 ≤0 时删除记录（等价于撤卡）。
  /// P2-1（v3.0.4 审计）：透传 [setCheckInValue] 的落盘结果。
  Future<bool> adjustCheckInValue(Habit habit, DateTime day, int delta) =>
      setCheckInValue(habit, day, checkInValueOn(habit, day) + delta);

  /// T1-2：一键把当日累计量顶到每日目标（「今日达标」按钮）。已达标则无操作。
  /// P3-2（v3.0.5 审计）：透传落盘结果（幂等早退 = true，与习惯侧同口径）。
  Future<bool> completeTodayTarget(Habit habit) async {
    final v = checkInValueOn(habit, DateTime.now());
    if (v >= habit.effectiveTarget) return true;
    return setCheckInValue(habit, DateTime.now(), habit.effectiveTarget);
  }

  /// T1-2：撤销当日全部累计量（量化习惯的「撤卡」）。
  /// P3-2（v3.0.5 审计）：透传落盘结果。
  Future<bool> clearToday(Habit habit) =>
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
  /// - **单位**（[unit]，A3；null = 不修改，空串 = 清除单位）。
  ///
  /// P3-2（v3.0.5 审计）：返回落盘是否成功——落盘失败回滚内存（`_habits[idx]`
  /// 还原为 [old]），提醒调度在失败分支不触碰（UI 显示的即已落盘的）。习惯
  /// 元数据（改名 / 改提醒 / 归档）此前落盘失败无任何反馈，编辑层据本结果
  /// 如实提示。
  Future<bool> updateHabit(
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
    String? unit,
  }) async {
    final idx = _habits.indexWhere((h) => h.id == habit.id);
    if (idx == -1) return false; // P3-2（v3.0.5 审计）：目标不存在 = 未生效
    final old = _habits[idx];
    // H4（v3.0.8 审计）：copyWith 的基准改为**当前对象**（old）而非调用方实参
    // ——实参可能是弹层持有的过期快照（弹层不按 id 回读），旧实现 `habit.copyWith`
    // 会把首次编辑已落盘的标题/目标量/宽限日按旧值整体覆盖回去（「二次编辑
    // 回滚首次编辑」）。各入参均为「null = 保持」，换基准后语义不变且消除回滚。
    // L7（v3.0.8 审计）：归档 / 取消归档时维护 [archivedAt] 时间戳（周期报告
    // 据此把归档习惯的应打卡日截断到归档日，见 period_review）。
    final stampArchive = archived == true && !old.archived;
    // P3-10（v2.9.4 审计）：weeklyGoal 上界与「**更新后**的计划天数」联动。
    // 必须在 copyWith 之前算出生效 weekdays——用户在同一次编辑里把「每天」改成
    // 「每周一三五」时，若按旧值（7 天）算上界，就能把目标设成 7 次而计划只有
    // 3 天，又造出一个不可达目标。
    final effWeekdays = weekdays ?? old.weekdays;
    // A4（v3.1.1 功能增强）：标题变化时同步重算拼音索引（与任务侧
    // _applyTaskUpdate 同口径：两串是同一标题的两个派生视图，必须同算同存）。
    final effTitle =
        (title != null && title.trim().isNotEmpty) ? title.trim() : old.title;
    final titleChanged = effTitle != old.title;
    final updated = old.copyWith(
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
      // L7（v3.0.8 审计）：见上方 stampArchive 注释。
      archivedAt: stampArchive ? DateTime.now() : null,
      clearArchivedAt: archived == false,
      reminderMinute: reminderMinute,
      clearReminder: clearReminder,
      // 0 / 负数视为「取消量化」，与 AddHabitSheet 的「关闭」语义一致；
      // 正数同样夹到 1..[Habit.maxDailyTarget]（P3-4）。
      dailyTarget: (dailyTarget != null && dailyTarget > 0)
          ? dailyTarget.clamp(1, Habit.maxDailyTarget).toInt()
          : null,
      clearDailyTarget: clearDailyTarget || (dailyTarget != null && dailyTarget <= 0),
      graceDays: graceDays?.clamp(0, 3),
      // A3（v3.1.1 功能增强）：单位写入侧夹取（null = 不修改；'' = 清除）。
      unit: unit == null ? null : Habit.clampUnit(unit),
      // A4（v3.1.1 功能增强）：标题变化才重算拼音索引（null = 保留旧值）。
      pinyinInitials:
          titleChanged ? PinyinIndex.initials(effTitle) : null,
      pinyinFull: titleChanged ? PinyinIndex.full(effTitle) : null,
    );
    _habits[idx] = updated;
    final ok = await _persistHabits();
    if (!ok) {
      // P3-2（v3.0.5 审计）：落盘失败回滚内存（编辑不生效），不触碰提醒调度。
      _habits[idx] = old;
      notifyListeners();
      return false;
    }
    // 提醒相关字段（时刻 / 星期 / 归档）任一变化都影响调度，统一重排。
    // P2-1（v2.9.3 审计）：增补 [dailyTarget] 变化——达标门槛改变会改变「今天
    // 是否已达标」，从而决定当天落点是否该被跳过（例如目标 8→3 时，已记 5 个
    // 单位的习惯由未达标变达标，当天提醒应消失；反之 3→8 应恢复）。
    final reminderChanged = old.reminderMinute != updated.reminderMinute ||
        old.archived != updated.archived ||
        old.dailyTarget != updated.dailyTarget ||
        !_weekdaysEqual(old.weekdays, updated.weekdays) ||
        // L1（v3.0.8 审计）：标题 / 表情也纳入重挂判据——提醒正文由两者拼成，
        // 旧判据不含它们，改名后已挂的未来 8 次提醒仍烘焙旧标题（重启才自愈）。
        // 调度侧签名（scheduleHabitReminder 的 _armedSignatures）已同步纳入内容。
        old.title != updated.title ||
        old.emoji != updated.emoji;
    if (updated.archived) {
      await NotificationService.instance.cancelHabitReminder(updated.id);
    } else if (reminderChanged) {
      // 先取消旧提醒再重挂：提醒时刻 / 星期 / 归档 / 目标量 / 标题 / 表情任一
      // 变化才动系统闹钟（无谓的调度抖动已由「真的变了」判据挡掉）。
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
    return true;
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
  /// P3-2（v3.0.5 审计）：透传落盘结果。
  Future<bool> uncheckInOnDay(Habit habit, DateTime day) =>
      setCheckInValue(habit, day, 0);

  /// 在指定日期打卡（用于补打卡 / 历史回溯），已存在则忽略。
  ///
  /// T1-2：可用 [value] 指定当日累计量（量化习惯的补卡，如「昨天喝了 6 杯」）；
  /// 不传则记 1 个单位。记录已存在且未显式给 [value] 时保持幂等跳过。
  /// P2-1（v3.0.4 审计）：透传 [setCheckInValue] 的落盘结果。
  Future<bool> checkInOnDay(Habit habit, DateTime day, {int? value}) async {
    final v = value ?? 1;
    final existing = checkInValueOn(habit, day);
    if (existing > 0 && value == null) return true; // 幂等：已打卡则无操作
    if (existing == v && existing > 0) return true;
    return setCheckInValue(habit, day, v);
  }

  /// U2-2（v3.0.4 审计）：跨天时批量清掉全部习惯的 9 号槽确认条。
  ///
  /// 确认条回报的是「那一天」的打卡结果，跨天后内容过期，且其「撤销」action
  /// 固定作用到当前日——昨天的「已打卡 ✓」今天点撤销，要么静默无反应（今天
  /// 无记录）、要么误减今天的量（错日写入）。由 main 注入的
  /// TaskProvider.onDayChanged 跨天回调触发；逐一 [NotificationService.cancelHabitConfirm]
  /// 而非全局 cancelAll——不波及任务段 / 简报等其他通知。同步清 8 号槽 snooze
  /// 不在此列：snooze 是「10 分钟后响一次」的未来闹钟，无内容过期问题。
  void cancelAllConfirmNotifications() {
    for (final h in _habits) {
      NotificationService.instance.cancelHabitConfirm(h.id);
    }
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

  /// 新P3-11（v2.9.7 审计）：成就 streak_3/7/30 的取值已改为**逐习惯
  /// longestStreak 的最大值**（见 achievement.dart fromProviders 注）——本
  /// getter（全部习惯达标日并集、按自然日连续）不再被成就消费，保留供
  /// 诊断 / 回归测试（habit_provider_test 钉死其「并集自然日」语义）。
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
  ///
  /// U2-1（v3.0.6 审计）：返回落盘是否成功——旧实现 `Future<void>` 忽略
  /// 两个 persist 结果，backup_sheet 的 failures 机制拿不到本步结果：
  /// 「任务恢复了、习惯/打卡写库失败」时 UI 仍报「已恢复」，重启后恢复的
  /// 习惯静默丢失。**不做内存回滚**：恢复是整体替换，回滚需保留旧全集且
  /// 通知已按恢复集重排（DB 异常属极端场景，优先保证「用户所见 = 内存态」
  /// 与失败如实告知，由调用方把失败并入恢复结果对话框）。
  Future<bool> restoreFromJson(Map<String, dynamic> data) async {
    // U3-1（v3.0.8 审计）：整体替换数据集，删除撤销的失败暂存随之作废
    // （与 [load] 同口径，见该处注释）。
    _pendingRestore = null;
    // M8（v3.0.8 审计）：先在**局部变量**里完整反序列化（任一条失败即整体放弃
    // 本次恢复），全部通过后才触碰内存与通知。旧实现把 fromJson 内联进
    // `_habits.clear()..addAll(...)`：中途抛错（某条 habit 缺 id、weekdays 含
    // 字符串等）会留下半新半旧的混合态且**未落盘**——此后任意一次成功落盘就把
    // 混合态永久写库；且重排循环在抛错点之后永不执行，而全部旧提醒已被撤掉
    // （「全部习惯提醒被撤、不重挂」）。校验层（BackupValidator）已同步补
    // habits/check_ins 逐条体检（M8①），这里是二道防线；抛出的
    // FormatException 由 backup_sheet 两个恢复入口的 try/catch 如实呈现。
    List<Habit>? newHabits;
    List<CheckIn>? newCheckIns;
    if (data['habits'] is List) {
      final habitsList = data['habits'] as List;
      final parsedHabits = <Habit>[];
      for (var i = 0; i < habitsList.length; i++) {
        final e = habitsList[i];
        if (e is! Map) {
          throw FormatException('第 ${i + 1} 条习惯不是对象，备份可能已损坏');
        }
        var h = Habit.fromJson(Map<String, dynamic>.from(e));
        // A4（v3.1.1 功能增强）：与任务侧 P1-2 同口径——恢复后按标题重算拼音
        // 索引（旧版备份两串多为空串，直接采用会导致恢复后习惯拼音搜索失效）。
        if (h.title.isNotEmpty) {
          h = h.copyWith(
            pinyinInitials: PinyinIndex.initials(h.title),
            pinyinFull: PinyinIndex.full(h.title),
          );
        }
        parsedHabits.add(h);
      }
      newHabits = parsedHabits;
    }
    if (data['check_ins'] is List) {
      final checkList = data['check_ins'] as List;
      final parsedCheckIns = <CheckIn>[];
      for (var i = 0; i < checkList.length; i++) {
        final e = checkList[i];
        if (e is! Map) {
          throw FormatException('第 ${i + 1} 条打卡记录不是对象，备份可能已损坏');
        }
        parsedCheckIns.add(CheckIn.fromJson(Map<String, dynamic>.from(e)));
      }
      newCheckIns = parsedCheckIns;
    }

    if (newHabits != null) {
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
        ..addAll(newHabits);
    }
    // M7（v3.0.8 审计）：check_ins 的替换必须**早于**下面的重排循环——旧实现
    // 先按恢复前的打卡数据算 checkedToday 再挂提醒：换机恢复 / 回滚到较早备份后
    // 方向一「今晚该响的提醒不响」、方向二「已达标却仍弹该打卡啦」（正是 v2.9.3
    // 修掉的「达标仍提醒」在恢复路径复发），持续到下次打卡写入或重启。
    if (newCheckIns != null) {
      _checkIns
        ..clear()
        ..addAll(newCheckIns);
    }
    if (newHabits != null) {
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
    final okHabits = await _persistHabits();
    final okCheckIns = await _persistCheckIns();
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
    // U2-1（v3.0.6 审计）：透传落盘结果（见方法注释；无 habits / check_ins
    // 两个键时两个 persist 仍会执行——旧备份恢复只有任务时也走全量写，
    // 结果同样如实回报）。
    return okHabits && okCheckIns;
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
    // A3（v3.1.1 功能增强）：量化单位列（无单位回空串，与布尔习惯目标列同口径）。
    '单位',
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
        // A3：单位列——统一走 [Habit.clampUnit] 净化（防旁路脏数据入导出）。
        Habit.clampUnit(h.unit),
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
    // P3-10（v2.9.6 审计）：与任务 / 专注 MD 同口径——标注「可读摘要」定位，
    // 完整字段（备注等列）请用 CSV / Excel（列真源见 habitExportHeaders）。
    buf.writeln('> 说明：Markdown 为**可读摘要**；归档 / 迁移请用 CSV 或 Excel 导出。');
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
      // P3-7（v3.1.2 审计）：单位贯穿——目标与累计量统一带单位（无单位时
      // 不追加任何后缀，与升级前逐字节一致）。
      final unitSuffix = h.unit.trim().isEmpty ? '' : ' ${h.unit.trim()}';
      final target = h.isQuantified ? ' ｜ 每日目标 ${h.dailyTarget}$unitSuffix' : '';
      final value = h.isQuantified ? ' ｜ 累计量 ${totalValue(h)}$unitSuffix' : '';
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

  /// P2-1（v3.0.4 审计）：返回落盘是否成功。旧实现 try/catch 吞掉 DB 异常后
  /// Future 正常完成，外层「按写入结果回报」的分支（main._doHabitCheckIn /
  /// _doHabitUndo 的 .catchError）属**不可达死代码**——DB 写入失败时通知栏
  /// 照样谎报「已打卡 ✓ / 已记 x/y」。现在把结果透传给调用方，由其按结果分支。
  ///
  /// P1-1（v3.1.0 审计）：安全模式写盘守卫——与 [TaskProvider._persist]（S13）
  /// 同口径。此前只有任务侧拦截：本 Provider 加载失败只置 [dbLoadFailed] 给 UI
  /// 换文案，写入路径完全不读它——「加载失败 → 内存空 → 用户随便写一次」会让
  /// [LocalDatabase.replaceHabits]（差量合并 + 删掉库中多出来的 id）把库中
  /// **全部历史习惯**覆盖成内存态（一次新建/打卡 = 抹掉全部习惯，不可逆），
  /// 且 UI 报「保存成功」。置守卫后返回 false，各写入口既有的「失败回滚内存 +
  /// 如实提示」分支自然生效；habit_screen 的失败文案注释「此后 _persist 恒
  /// false」自此才与实现相符。
  Future<bool> _persistHabits() async {
    if (_dbLoadFailed) return false;
    try {
      await LocalDatabase.instance.replaceHabits(_habits);
      return true;
    } catch (e) {
      AppLog.d('HabitProvider 持久化 habits 失败：$e');
      return false;
    }
  }

  /// P2-1（v3.0.4 审计）：同 [_persistHabits]，返回落盘是否成功。
  /// P1-1（v3.1.0 审计）：安全模式守卫同上——否则一次打卡会把整张 check_ins
  /// 表覆盖成只剩这一条。
  Future<bool> _persistCheckIns() async {
    if (_dbLoadFailed) return false;
    try {
      await LocalDatabase.instance.replaceCheckIns(_checkIns);
      return true;
    } catch (e) {
      AppLog.d('HabitProvider 持久化 checkIns 失败：$e');
      return false;
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
