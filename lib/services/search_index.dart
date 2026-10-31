import 'package:todolist/models/task.dart';
import 'package:todolist/models/habit.dart';
import 'package:todolist/services/pinyin_index.dart';

/// 全局搜索结果：任务与习惯分别成组，便于 UI 按类型分区展示。
class GlobalSearchResult {
  final List<Task> tasks;
  final List<Habit> habits;

  const GlobalSearchResult({this.tasks = const [], this.habits = const []});

  /// 命中总数（任务 + 习惯）。
  int get total => tasks.length + habits.length;
}

/// 全局搜索：跨「任务」与「习惯」两类内容做关键字匹配。
///
/// 设计要点（与 B 线解析器一致）：
/// - 纯 Dart、不依赖 flutter，可直接单测；
/// - 零新存储，全部基于现有 Provider 的公开列表现算；
/// - 关键字统一归一化（去空白 + 转小写），匹配按「包含」语义、忽略大小写；
/// - 匹配逻辑下沉为私有纯函数，界面只负责把结果分组渲染。
class GlobalSearch {
  /// 对 [tasks] 与 [habits] 做关键字检索，返回分组结果。
  ///
  /// [query] 为空时直接返回空结果（界面据此提示「输入关键字」）。
  static GlobalSearchResult query(
    String query, {
    required List<Task> tasks,
    required List<Habit> habits,
  }) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const GlobalSearchResult();
    final matchedTasks = tasks.where((t) => _matchesTask(t, q)).toList();
    final matchedHabits = habits.where((h) => _matchesHabit(h, q)).toList();
    return GlobalSearchResult(tasks: matchedTasks, habits: matchedHabits);
  }

  /// 任务命中规则：标题 / 分类（中文 label + 英文 name）/ 优先级（中文 + 英文）/
  /// 备注 / 重复规则（label + 摘要）/ 标签 / 子任务标题（S2）/ 拼音首字母（A1）/
  /// 拼音全拼（A4）。
  static bool _matchesTask(Task t, String q) {
    if (t.title.toLowerCase().contains(q)) return true;
    if (t.category.label.toLowerCase().contains(q)) return true;
    if (t.category.name.toLowerCase().contains(q)) return true;
    if (_prioLabel(t.priority).contains(q)) return true;
    if (t.priority.name.toLowerCase().contains(q)) return true;
    if (t.note.toLowerCase().contains(q)) return true;
    if (t.repeat.label.toLowerCase().contains(q)) return true;
    if (t.repeatSummary.toLowerCase().contains(q)) return true;
    if (t.tags.any((tag) => tag.toLowerCase().contains(q))) return true;
    // S2：子任务标题纳入全局搜索（如任务里拆了「写大纲」，搜「大纲」即命中该任务）。
    if (t.subtasks.any((s) => s.title.toLowerCase().contains(q))) return true;
    // A1：拼音首字母匹配（搜 "zl" 命中「整理」），仅当首字母串非空时尝试，避免空串恒真。
    if (t.pinyinInitials.isNotEmpty && t.pinyinInitials.contains(q)) return true;
    // A4（v3.1.1 功能增强）：全拼匹配（搜 "zhoulibao" 命中「周立波」）。
    // 仅对「纯字母 ≥2 位」的查询启用——长度阈值挡住单字母的过匹配，
    // 空串（旧数据）跳过避免恒真；首字母路径保持原状不受影响。
    if (q.length >= 2 &&
        PinyinIndex.isAlphaQuery(q) &&
        t.pinyinFull.isNotEmpty &&
        t.pinyinFull.contains(q)) {
      return true;
    }
    return false;
  }

  /// 习惯命中规则：标题 / 频率文案（每天 / 每周 X）/ 提醒时间（HH:mm + 小时数字）/
  /// 拼音首字母 + 全拼（A4，与任务侧同口径）。
  static bool _matchesHabit(Habit h, String q) {
    if (h.title.toLowerCase().contains(q)) return true;
    // A4（v3.1.1 功能增强）：拼音匹配——此前习惯搜索只命中中文标题 / 频率 /
    // 提醒时间，敲拼音搜不到习惯；现与任务侧同一套阈值与空串守卫。
    if (h.pinyinInitials.isNotEmpty && h.pinyinInitials.contains(q)) return true;
    if (q.length >= 2 &&
        PinyinIndex.isAlphaQuery(q) &&
        h.pinyinFull.isNotEmpty &&
        h.pinyinFull.contains(q)) {
      return true;
    }
    // 频率文案同时提供「紧凑」(每周一三五) 与「带空格」(每周 一 三 五) 两种写法，
    // 这样搜「周一」既能命中紧凑串里的「周一」子串，也兼容带空格的展示文案。
    final labels = h.weekdays.map(_wdLabel).join();
    final compact = h.weekdays.isEmpty ? '每天' : '每周$labels';
    final spaced =
        h.weekdays.isEmpty ? '每天' : '每周 ${h.weekdays.map(_wdLabel).join(' ')}';
    if (compact.toLowerCase().contains(q) || spaced.toLowerCase().contains(q)) {
      return true;
    }
    if (h.reminderMinute != null) {
      final hh = (h.reminderMinute! ~/ 60).toString().padLeft(2, '0');
      final mm = (h.reminderMinute! % 60).toString().padLeft(2, '0');
      final time = '$hh:$mm';
      // 匹配规则（兼顾 V-21 修复与既有搜索习惯）：
      //  1) 整串相等：搜 "08:30" 命中；
      //  2) HH:mm 前缀：搜 "08" 命中 08:30；
      //  3) 纯整数按「小时」匹配：搜 "8" 命中 08:xx，且不会误命中 18/10-19 等其它小时
      //     （修复旧实现搜 "1" 误命中 01/10-19/21 点的过匹配问题）。
      final intQ = int.tryParse(q);
      final hour = h.reminderMinute! ~/ 60;
      if (time == q || time.startsWith(q) || (intQ != null && intQ == hour)) {
        return true;
      }
    }
    return false;
  }

  static String _prioLabel(Priority p) =>
      p == Priority.high ? '高' : p == Priority.medium ? '中' : '低';

  /// 1=周一 … 7=周日 → 中文单字。
  static String _wdLabel(int w) =>
      ['一', '二', '三', '四', '五', '六', '日'][(w - 1).clamp(0, 6)];
}
