/// 内置任务模板 / 清单库 + 用户自定义模板（P0-4，纯离线）。
///
/// 本质是一组「打包进 App 的 Task 数据」，不依赖任何网络。用户一键套用后，
/// 模板里的每项会生成为一条真实任务加入当前列表，适合「开学 / 旅行 / 考试 /
/// 购物补货」这类高度重复的场景。落地的成本很低、感知很强。
///
/// P0-4 扩展：
/// - [TemplateItem] 支持重复规则（daily/weekly/monthly/interval + 星期/日/间隔）
///   与相对截止天数（[dueInDays]），套用重复项时直接生成重复任务；
/// - 新增 [UserTemplate]（用户自定义模板，存 App 私有目录 `templates/user/*.json`）
///   及 [UserTemplateStore]（读写 / 删除 / 导出分享 / 导入）；
/// - 内置模板保持 [const]，可选支持重复项。
///
/// 设计原则：
/// - 模板数据用 const 声明，零运行时开销；
/// - 套用逻辑只调用已有的 [TaskProvider.addTask]，不引入新的持久化路径；
/// - 用户模板落盘为私有目录 JSON 文件（文件方案比新增表更利于「导出分享」）。

import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/state/task_provider.dart';

/// 模板中的单个任务项。
class TemplateItem {
  final String title;

  /// 分类（默认生活）。
  final Category category;

  /// 优先级（默认中）。
  final Priority priority;

  /// 相对「今天」的截止天数；null 表示不设置截止时间。
  final int? dueInDays;

  /// 标签（默认空）。套用时整体复制。
  final List<String> tags;

  /// 重复规则（默认 none，即一次性任务）。P0-4：套用重复项时生成重复任务。
  final RepeatType repeat;

  /// 仅 [repeat]==[RepeatType.weekly] 时有意义（周几列表，1=周一…7=周日）。
  final List<int> repeatWeekdays;

  /// 每隔 N 天（[repeat]==[RepeatType.interval]）。
  final int repeatInterval;

  /// 重复提醒时刻（分钟，0~1439）；null 时套用默认 09:00。仅重复任务生效。
  final int? repeatMinute;

  /// 重复结束日期（yyyy-MM-dd）；null 表示无限重复。
  final String? repeatUntil;

  /// 每月重复的「日」(1-31)。仅 [repeat]==[RepeatType.monthly] 且 [monthlyWeekday]==null 时有意义。
  final int monthlyDay;

  /// 每月第几个周几的「周几」(1..7)，与 [monthlyWeekIndex] 配套。
  final int? monthlyWeekday;

  /// 每月第几个周几的「第几」(1..5，5=最后一个)。
  final int? monthlyWeekIndex;

  const TemplateItem(
    this.title,
    this.category,
    this.priority,
    this.dueInDays, {
    this.tags = const [],
    this.repeat = RepeatType.none,
    this.repeatWeekdays = const [],
    this.repeatInterval = 2,
    this.repeatMinute,
    this.repeatUntil,
    this.monthlyDay = 1,
    this.monthlyWeekday,
    this.monthlyWeekIndex,
  });

  /// 从一条真实任务生成模板项（「另存为模板」用）。
  /// 相对截止天数 = 原截止日期 − 今天（date-only），套用时会以相同偏移重生。
  factory TemplateItem.fromTask(Task t) {
    final int? rel;
    if (t.dueDate != null) {
      final now = DateTime.now();
      final base = DateTime(now.year, now.month, now.day);
      final due = DateTime(t.dueDate!.year, t.dueDate!.month, t.dueDate!.day);
      rel = due.difference(base).inDays;
    } else {
      rel = null;
    }
    return TemplateItem(
      t.title,
      t.category,
      t.priority,
      rel,
      tags: List.from(t.tags),
      repeat: t.repeat,
      repeatWeekdays: List.from(t.repeatWeekdays),
      repeatInterval: t.repeatInterval,
      repeatMinute: t.repeatMinute,
      repeatUntil: t.repeatUntil,
      monthlyDay: t.monthlyDay,
      monthlyWeekday: t.monthlyWeekday,
      monthlyWeekIndex: t.monthlyWeekIndex,
    );
  }

  Map<String, dynamic> toJson() => {
        'title': title,
        'category': category.name,
        'priority': priority.name,
        'dueInDays': dueInDays,
        'tags': tags,
        'repeat': repeat.name,
        'repeatWeekdays': repeatWeekdays,
        'repeatInterval': repeatInterval,
        'repeatMinute': repeatMinute,
        'repeatUntil': repeatUntil,
        'monthlyDay': monthlyDay,
        'monthlyWeekday': monthlyWeekday,
        'monthlyWeekIndex': monthlyWeekIndex,
      };

  factory TemplateItem.fromJson(Map<String, dynamic> j) {
    final wd = j['repeatWeekdays'];
    final tags = j['tags'];
    return TemplateItem(
      (j['title'] as String?) ?? '',
      _catFromName(j['category']),
      _prioFromName(j['priority']),
      j['dueInDays'] as int?,
      tags: tags is List ? List<String>.from(tags.whereType<String>()) : const <String>[],
      repeat: RepeatType.values.asNameMap()[j['repeat'] as String?] ?? RepeatType.none,
      repeatWeekdays: wd is List ? List<int>.from(wd.whereType<int>()) : const <int>[],
      repeatInterval: j['repeatInterval'] as int? ?? 2,
      repeatMinute: j['repeatMinute'] as int?,
      repeatUntil: j['repeatUntil'] as String?,
      monthlyDay: j['monthlyDay'] as int? ?? 1,
      monthlyWeekday: j['monthlyWeekday'] as int?,
      monthlyWeekIndex: j['monthlyWeekIndex'] as int?,
    );
  }
}

/// 一个内置模板：名称 + 说明 + 图标 + 任务项列表。
class BuiltInTemplate {
  final String name;
  final String description;
  final IconData icon;
  final List<TemplateItem> items;

  const BuiltInTemplate({
    required this.name,
    required this.description,
    required this.icon,
    required this.items,
  });
}

/// 全部内置模板（离线打包进 App，无需联网）。
const List<BuiltInTemplate> builtInTemplates = [
  BuiltInTemplate(
    name: '开学装备清单',
    description: '返校 / 开学前逐项打勾，避免遗漏',
    icon: Icons.school,
    items: [
      TemplateItem('收拾书包', Category.life, Priority.high, 1),
      TemplateItem('文具：笔 / 本子 / 尺规', Category.study, Priority.medium, 1),
      TemplateItem('水杯 / 雨伞', Category.life, Priority.low, 2),
      TemplateItem('课本与作业本', Category.study, Priority.high, 1),
      TemplateItem('校服 / 运动鞋', Category.life, Priority.medium, 2),
      TemplateItem('宿舍用品（床品 / 洗漱）', Category.life, Priority.low, 3),
    ],
  ),
  BuiltInTemplate(
    name: '旅行打包清单',
    description: '出差 / 出游前整理行李',
    icon: Icons.luggage,
    items: [
      TemplateItem('身份证 / 护照', Category.life, Priority.high, 1),
      TemplateItem('手机充电器 / 充电宝', Category.life, Priority.high, 1),
      TemplateItem('换洗衣物', Category.life, Priority.medium, 2),
      TemplateItem('洗漱用品', Category.life, Priority.medium, 2),
      TemplateItem('常用药 / 创可贴', Category.life, Priority.low, 3),
      TemplateItem('雨伞 / 防晒', Category.life, Priority.low, 3),
    ],
  ),
  BuiltInTemplate(
    name: '考试复习计划',
    description: '考前一周的复习节奏',
    icon: Icons.menu_book,
    items: [
      TemplateItem('整理课堂笔记', Category.study, Priority.high, 2),
      TemplateItem('刷真题 / 套卷', Category.study, Priority.high, 4),
      TemplateItem('查漏补缺（错题本）', Category.study, Priority.medium, 5),
      TemplateItem('做一套模拟考', Category.study, Priority.high, 6),
      TemplateItem('调整作息、早睡', Category.life, Priority.medium, 7),
    ],
  ),
  BuiltInTemplate(
    name: '购物补货清单',
    description: '日常采购 / 囤货',
    icon: Icons.shopping_cart,
    items: [
      TemplateItem('米 / 面 / 油', Category.life, Priority.medium, 1),
      TemplateItem('蔬菜 / 水果', Category.life, Priority.medium, 1),
      TemplateItem('肉蛋奶', Category.life, Priority.medium, 1),
      TemplateItem('日用品（纸 / 洗护）', Category.life, Priority.low, 2),
      TemplateItem('零食 / 饮料', Category.life, Priority.low, 3),
    ],
  ),
  BuiltInTemplate(
    name: '周末大扫除',
    description: '居家清洁一次搞定',
    icon: Icons.cleaning_services,
    items: [
      TemplateItem('整理桌面 / 杂物', Category.life, Priority.medium, 2),
      TemplateItem('拖地 / 吸尘', Category.life, Priority.medium, 2),
      TemplateItem('洗衣服 / 换床单', Category.life, Priority.low, 2),
      TemplateItem('清理冰箱 / 扔过期', Category.life, Priority.low, 3),
      TemplateItem('倒垃圾', Category.life, Priority.low, 1),
    ],
  ),
  BuiltInTemplate(
    name: '搬家准备',
    description: '搬前搬后事项',
    icon: Icons.move_to_inbox,
    items: [
      TemplateItem('纸箱 / 打包袋', Category.life, Priority.high, 2),
      TemplateItem('贵重物品单独装箱', Category.life, Priority.high, 3),
      TemplateItem('预约搬家公司', Category.life, Priority.medium, 4),
      TemplateItem('水电燃气过户 / 退订', Category.life, Priority.high, 5),
      TemplateItem('通知地址变更（银行 / 快递）', Category.life, Priority.medium, 5),
    ],
  ),
  // P0-4：内置模板升级——示范「重复项」可直接套用为重复任务。
  BuiltInTemplate(
    name: '周期性 SOP（示例）',
    description: '演示重复规则：每周例会 + 每月缴费',
    icon: Icons.repeat,
    items: [
      TemplateItem('周会纪要同步', Category.work, Priority.medium, null,
          repeat: RepeatType.weekly, repeatWeekdays: [DateTime.monday]),
      TemplateItem('月度房租 / 缴费', Category.life, Priority.high, 1,
          repeat: RepeatType.monthly, monthlyDay: 1),
      TemplateItem('每三天喝水打卡', Category.life, Priority.low, null,
          repeat: RepeatType.interval, repeatInterval: 3),
    ],
  ),
];

/// 用户自定义模板（存 App 私有目录 `templates/user/<id>.json`）。
/// [iconName] 为可序列化的图标代号（见 [_iconNameMap]），显示时经 [_iconByName] 还原。
class UserTemplate {
  final String id;
  final String name;
  final String description;
  final String iconName;
  final List<TemplateItem> items;

  UserTemplate({
    required this.id,
    required this.name,
    this.description = '',
    this.iconName = 'checklist',
    this.items = const [],
  });

  /// 显示用图标（由 [iconName] 还原，未知代号回退 [Icons.list_alt]）。
  IconData get icon => iconFromName(iconName);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'icon': iconName,
        'items': items.map((e) => e.toJson()).toList(),
      };

  factory UserTemplate.fromJson(Map<String, dynamic> j) {
    final itemsRaw = j['items'];
    final items = itemsRaw is List
        ? itemsRaw
            .whereType<Map>()
            .map((e) => TemplateItem.fromJson(Map<String, dynamic>.from(e)))
            .toList()
        : const <TemplateItem>[];
    return UserTemplate(
      id: (j['id'] as String?) ?? _uid(),
      name: (j['name'] as String?) ?? '未命名模板',
      description: (j['description'] as String?) ?? '',
      iconName: (j['icon'] as String?) ?? 'checklist',
      items: items,
    );
  }
}

/// 用户模板的本地存储（私有目录 JSON，每模板一个文件）。
/// 严格离线：仅文件读写，不联网；「导出分享」是把 JSON 交给系统分享面板。
class UserTemplateStore {
  /// 自定义模板体积上限（条），防止误存巨量数据。
  static const int maxItems = 200;

  static Future<Directory> _dir() async {
    final base = await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}/templates/user');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// 读取全部用户模板（按名称排序；损坏文件跳过）。
  static Future<List<UserTemplate>> loadAll() async {
    try {
      final d = await _dir();
      final files = d
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList();
      final out = <UserTemplate>[];
      for (final f in files) {
        try {
          final m =
              jsonDecode(await f.readAsString()) as Map<String, dynamic>;
          out.add(UserTemplate.fromJson(m));
        } catch (_) {
          // 损坏的模板文件跳过，不阻断其余模板加载。
        }
      }
      out.sort((a, b) => a.name.compareTo(b.name));
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// 保存（新增或覆盖，按 [UserTemplate.id] 同名文件）。
  static Future<void> save(UserTemplate t) async {
    final d = await _dir();
    final file = File('${d.path}/${t.id}.json');
    await file.writeAsString(jsonEncode(t.toJson()));
  }

  /// 删除指定 id 的模板文件。
  static Future<void> delete(String id) async {
    final d = await _dir();
    final file = File('${d.path}/$id.json');
    if (await file.exists()) await file.delete();
  }

  /// 导出为可分享的 JSON 文件（App 私有文档目录），返回文件句柄供 [DataIo.shareFile]。
  static Future<File> exportTemplate(UserTemplate t) async {
    final base = await getApplicationDocumentsDirectory();
    final safe = t.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final name = '有条-模板-$safe-${_ts()}.json';
    final file = File('${base.path}/$name');
    await file.writeAsString(jsonEncode(t.toJson()));
    return file;
  }
}

/// 把 [template] 套用为真实任务并加入 [provider]。每项按相对天数计算截止时间
/// （date-only，落在 09:00）；重复项按规则生成重复任务，interval 以今天为锚点避免首日逾期。
/// 返回实际创建的任务数量。
int applyTemplate(TaskProvider provider, BuiltInTemplate template) =>
    applyTemplateItems(provider, template.items);

/// 把用户模板 [t] 套用为真实任务并加入 [provider]。
int applyUserTemplate(TaskProvider provider, UserTemplate t) =>
    applyTemplateItems(provider, t.items);

/// 套用一组 [TemplateItem] 为真实任务（内置 / 用户模板共用）。
int applyTemplateItems(TaskProvider provider, List<TemplateItem> items) {
  final today = DateTime.now();
  final base = DateTime(today.year, today.month, today.day);
  var created = 0;
  for (final item in items) {
    final due = _firstDueDate(base, item);
    // 重复任务需有提醒时刻；未指定时默认 09:00。
    final repeatMinute =
        item.repeat != RepeatType.none ? (item.repeatMinute ?? 9 * 60) : null;
    // interval 锚点设为今天（date-only），保证「从今天起每 N 天」循环、首日不逾期。
    final anchor =
        item.repeat == RepeatType.interval ? base : null;
    provider.addTask(Task(
      id: '',
      title: item.title,
      category: item.category,
      priority: item.priority,
      dueDate: due,
      repeat: item.repeat,
      repeatWeekdays: List.from(item.repeatWeekdays),
      repeatInterval: item.repeatInterval,
      repeatMinute: repeatMinute,
      repeatAnchor: anchor,
      repeatUntil: item.repeatUntil,
      monthlyDay: item.monthlyDay,
      monthlyWeekday: item.monthlyWeekday,
      monthlyWeekIndex: item.monthlyWeekIndex,
      tags: List.from(item.tags),
    ));
    created++;
  }
  return created;
}

/// 计算套用后的首个截止时间：有相对天数 → 今天 + N 天（00:00）；无相对天数但为重复任务
/// → 今天 09:00（保证首个循环日存在、不逾期、有提醒时刻）；否则 null。
DateTime? _firstDueDate(DateTime base, TemplateItem item) {
  if (item.dueInDays != null) {
    return DateTime(base.year, base.month, base.day + item.dueInDays!);
  }
  if (item.repeat != RepeatType.none) {
    return DateTime(base.year, base.month, base.day, 9, 0);
  }
  return null;
}

// ===== 图标代号 ↔ IconData 映射 =====
const Map<String, IconData> _iconNameMap = {
  'checklist': Icons.checklist,
  'event': Icons.event,
  'repeat': Icons.repeat,
  'shopping': Icons.shopping_cart,
  'school': Icons.school,
  'flight': Icons.flight,
  'home': Icons.home,
  'work': Icons.work,
  'fitness': Icons.fitness_center,
  'book': Icons.menu_book,
  'description': Icons.description,
  'star': Icons.star,
  'list': Icons.list_alt,
  'cleaning': Icons.cleaning_services,
  'move': Icons.move_to_inbox,
};

IconData iconFromName(String name) => _iconNameMap[name] ?? Icons.list_alt;

/// 新增模板默认可选图标代号列表（供编辑器下拉）。
const List<String> templateIconNames = [
  'checklist',
  'event',
  'repeat',
  'shopping',
  'school',
  'flight',
  'home',
  'work',
  'fitness',
  'book',
  'description',
  'star',
  'list',
  'cleaning',
  'move',
];

Category _catFromName(dynamic v) {
  if (v is String) {
    final c = Category.values.asNameMap()[v];
    if (c != null) return c;
  }
  return Category.life;
}

Priority _prioFromName(dynamic v) {
  if (v is String) {
    final p = Priority.values.asNameMap()[v];
    if (p != null) return p;
  }
  return Priority.medium;
}

/// 简单唯一 id（微秒时间戳取模，足够模板文件命名用，不依赖 uuid 包）。
String _uid() =>
    (DateTime.now().microsecondsSinceEpoch % 1000000000).toString();

String _ts() {
  final d = DateTime.now();
  final p = (int n) => n.toString().padLeft(2, '0');
  return '${d.year}${p(d.month)}${p(d.day)}-${p(d.hour)}${p(d.minute)}';
}
