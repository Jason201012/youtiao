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
import 'package:todolist/services/app_log.dart'; // L11（v3.0.8 审计）：保存失败日志
import 'package:todolist/services/gbk_codec.dart'; // P3-6（v3.0.0 审计）：共享文本解码链
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

  /// P2-5：「每月倒数第 N 天」（1=最后一天，2=倒数第二天…），与
  /// [monthlyDay] / [monthlyWeekday] 互斥使用。
  final int monthlyFromEnd;

  /// 预计时长（分钟，1..43200）；null = 未预估。
  ///
  /// P2-4（v2.9.3 审计）：T1-1 的 [Task.estimateMinutes] 此前未进模板链路，
  /// 「另存为模板 → 套用」会静默丢失预估、排程建议退回 30 分钟兜底。
  /// 旧模板 JSON 缺该键时缺省 null（向后兼容，零迁移）。
  final int? estimateMinutes;

  /// 任务备注；套用时整体复制。
  ///
  /// P3-10（v2.9.5 审计）：此前 [TemplateItem] 字段集缺 `note`，
  /// 「另存为模板 → 套用」会静默丢掉备注（备注常含链接 / 口径 / 注意事项，
  /// 是**不可再生**的内容）。旧模板 JSON 缺该键时缺省空串（零迁移）。
  final String note;

  /// 一次性任务的提醒提前量（分钟；0 = 准时）。仅非重复任务有意义。
  ///
  /// P3-10（v2.9.5 审计）：此前非重复任务的 `reminderOffsetMin` 不进模板，
  /// 套用后退回默认「准时」，把「提前 15 分钟提醒」的用户设置改掉了。
  /// 旧模板 JSON 缺该键时缺省 0（与旧行为一致，零迁移）。
  final int reminderOffsetMin;

  /// P3-10（v2.9.5 审计）：**刻意不迁移**的 [Task] 字段及理由。
  ///
  /// 审计要求「补齐字段或明确标注不迁移」。逐项判定如下——这三项不是遗漏，
  /// 而是**迁移它们反而有害**，故在此固化为设计决策，避免下一轮审计再报：
  /// - `startDate`：模板以「相对今天 N 天」表达时间语义，套用时重算 `dueDate`；
  ///   携带绝对开始日会与重算出的 `dueDate` 互相矛盾。
  /// - `skipDates`（已跳过的发生日）：这是**执行历史**而非计划的一部分。
  ///   把原任务的「已跳过 3 月 10 日」套到新任务上，等于凭空让它跳过一次。
  /// - 子任务 / 附件：模板是「计划蓝图」，套用时是**新建**任务。
  ///   复制子任务进度与附件文件会带来「半完成的新任务」和附件重复占空间；
  ///   用户要的通常是干净的一份待办。子任务的**存在性**已有 [TemplateItem]
  ///   无法表达的问题留在功能增强报告里，不在本轮静默复制。
  static const List<String> intentionallyNotMigrated = [
    'startDate',
    'skipDates',
    'subtasks',
    'attachments',
  ];

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
    this.monthlyFromEnd = 0,
    this.estimateMinutes,
    // P3-10（v2.9.5 审计）：补齐此前静默丢失的两个字段（理由见各自注释）。
    this.note = '',
    this.reminderOffsetMin = 0,
  });

  /// 从一条真实任务生成模板项（「另存为模板」用）。
  /// 相对截止天数 = 原截止日期 − 今天（date-only），套用时会以相同偏移重生。
  factory TemplateItem.fromTask(Task t) {
    final int? rel;
    if (t.dueDate != null) {
      final now = DateTime.now();
      final base = DateTime(now.year, now.month, now.day);
      // 新P3-9（v2.9.7 审计）：比较键过 [dueCompareKey] 再落 date-only（与
      // provider 的日差管道同源）。语义不变：相对天数始终按 date-only 差计。
      final k = dueCompareKey(t.dueDate!);
      final due = DateTime(k.year, k.month, k.day);
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
      // P2-5：模板套用时一并带上「每月倒数第 N 天」。原实现漏掉，导致「另存为
      // 模板 → 套用」会让倒数天数任务被错误展开成「第 N 个周几」或退化为月度 1 号。
      monthlyFromEnd: t.monthlyFromEnd,
      // P2-4（v2.9.3 审计）：预估时长随任务进模板，套用后不再静默丢失。
      estimateMinutes: t.estimateMinutes,
      // P3-10（v2.9.5 审计）：备注 + 一次性任务提醒提前量此前不迁移。
      note: t.note,
      reminderOffsetMin: t.reminderOffsetMin,
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
        'monthlyFromEnd': monthlyFromEnd,
        'estimateMinutes': estimateMinutes,
        // P3-10（v2.9.5 审计）：新增两个键。旧模板 JSON 缺该键 → 缺省
        // '' / 0（零迁移，与旧行为逐位一致）。
        'note': note,
        'reminderOffsetMin': reminderOffsetMin,
      };

  factory TemplateItem.fromJson(Map<String, dynamic> j) {
    final wd = j['repeatWeekdays'];
    final tags = j['tags'];
    // P3-1（v3.0.2 审计）：字符串字段同族收口——title / repeat / note 此前
    // 裸 `as String?` 硬转型，非字符串值（手改 / 外部模板的 `"title":123`）
    // 抛错中断**整份模板**加载且无任何失效提示（该模板从列表静默消失）。
    // 改为 `is String` 判型回退默认值，与同文件 category / priority 的容错
    // 口径一致。
    final title = j['title'] is String ? j['title'] as String : '';
    final repeatStr = j['repeat'] is String ? j['repeat'] as String : null;
    final noteRaw = j['note'] is String ? j['note'] as String : '';
    return TemplateItem(
      title,
      _catFromName(j['category']),
      _prioFromName(j['priority']),
      // P3-3（v3.0.1 审计）：同族硬转型顺手收口——字符串 / 小数此前同样
      // 抛错中断整份模板加载。相对天数夹到 ±100 年（fromTask 产出可为负
      // ——逾期任务另存为模板——故下界不可为 0）。
      Task.clampIntOrNullJson(j['dueInDays'], -36500, 36500),
      tags: tags is List ? List<String>.from(tags.whereType<String>()) : const <String>[],
      repeat: RepeatType.values.asNameMap()[repeatStr] ?? RepeatType.none,
      // P3-1（v3.0.2 审计）：repeatWeekdays 与 [Task.fromJson] 完整同口径
      // （whereType<int>() + 1..7 过滤 + 去重 + 升序）。旧实现只 whereType
      // 不过滤不去重：`"repeatWeekdays":[9,3,3]` 套用后产出的每周任务
      // repeatsOn 永不命中（与 F-8 注释里 monthlyWeekday=9 的哑任务同型）。
      repeatWeekdays: wd is List
          ? (wd.whereType<int>().where((d) => d >= 1 && d <= 7).toSet().toList()
            ..sort())
          : const <int>[],
      // P3-3（v3.0.1 审计）：与 [Task.fromJson] 同口径夹取（repeatInterval
      // 1..365 / repeatMinute 0..1439 / monthlyWeekday 1..7 / monthlyWeekIndex
      // 1..5 / monthlyFromEnd 0..31）——v2.9.7 只补了 monthlyDay 一项，兄弟
      // 字段此前仍是裸 `as int?` / 无夹取：字符串 / 小数抛错中断**整份模板**
      // 加载；monthlyWeekday=9 / monthlyFromEnd=99 套用后产出永不命中 /
      // 非法的月规则任务。模板 JSON 是不可信输入（同文件对 estimateMinutes /
      // reminderOffsetMin 已做白名单夹取，口径见各自注释）。
      // repeatInterval 缺省沿用 TemplateItem 构造默认 2（与 Task.fromJson
      // 缺省 1 不同——历史内置模板的「每隔 N 天」项均显式携带，缺省只影响
      // 手写极简模板，保持旧行为零迁移）。
      repeatInterval: Task.clampIntJson(j['repeatInterval'], 1, 365, 2),
      repeatMinute: Task.clampIntOrNullJson(j['repeatMinute'], 0, 1439),
      // P3-1（v3.0.2 审计）：repeatUntil 接净化（[Task.sanitizeRepeatUntilJson]，
      // 与备份路径 [Task.fromJson] 的 F-8 同口径）——非法串此前原样透传，
      // 被 _parseYmd 回退 1970 → isRepeatEnded 恒真，套用产出的任务被 App
      // 静默视为「已结束」（不再循环不再提醒）。清空（=无限循环）比「视为
      // 已结束」更安全。
      repeatUntil: Task.sanitizeRepeatUntilJson(j['repeatUntil']),
      // 新P3-4（v2.9.7 审计）：与 [Task.fromJson] 同口径夹取（1..31，缺省 1）——
      // 此前 `as int?` 硬转型无 clamp：字段为字符串/小数时抛错中断**整份模板**
      // 加载；旧模板 / 手改 / 外部模板的 `monthlyDay = 0` 套用后会产出
      // 「每月 0 号」任务并落库。模板 JSON 是不可信输入（同文件对
      // estimateMinutes / reminderOffsetMin 已做白名单夹取，此处补齐）。
      monthlyDay: Task.clampIntJson(j['monthlyDay'], 1, 31, 1),
      monthlyWeekday: Task.clampIntOrNullJson(j['monthlyWeekday'], 1, 7),
      monthlyWeekIndex: Task.clampIntOrNullJson(j['monthlyWeekIndex'], 1, 5),
      monthlyFromEnd: Task.clampIntJson(j['monthlyFromEnd'], 0, 31, 0),
      // P2-4：与 [Task.fromJson] 同区间夹取（1..43200 分钟），越界视为未设——
      // 模板 JSON 同样是「不可信输入」（可被手改 / 来自他人 / 传输损坏）。
      estimateMinutes: _clampEstimateMinutes(j['estimateMinutes']),
      // P3-10：与 [Task.fromJson] 同一原则——模板 JSON 是不可信输入。
      // 备注归一化换行（模板项标题也做同样处理），提前量夹到 0..1440。
      // P3-1（v3.0.2 审计）：非字符串值不再抛错（见 title 处注释），回退空串。
      note: noteRaw.replaceAll(RegExp(r'[\r\n]+'), ' ').trim(),
      // P3-1（v3.0.2 审计）顺手收口：reminderOffsetMin 此前残留裸 `as num?`
      // 硬转型（字符串值抛错中断整份模板），改走与兄弟整型字段同一助手。
      reminderOffsetMin:
          Task.clampIntOrNullJson(j['reminderOffsetMin'], 0, 1440) ?? 0,
    );
  }

  /// 预估时长夹取（口径与 [Task.fromJson] 一致：1..43200，越界 / 非数值返回 null）。
  static int? _clampEstimateMinutes(dynamic v) {
    if (v is! num) return null;
    final n = v.toInt();
    if (n < 1 || n > 30 * 24 * 60) return null;
    return n;
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
    // 安全（P1-A）：id 直接用作文件名（`<documents>/templates/user/<id>.json`），
    // 外部 JSON 携带的 id 必须过白名单，非法则重新分配——杜绝 `../../backup/auto/...`
    // 这类路径穿越覆盖 App 私有文档目录内的任意 .json（含自动备份快照）。
    // P3-1（v3.0.3 审计）：四处元数据安全转型（is String 判型回退），与同文件
    // TemplateItem.fromJson 的同轮收口对齐——旧实现四处裸 `as String?`，外部 /
    // 手改 JSON 的元数据为非字符串值（{"name":123} / {"icon":42}）时抛 TypeError，
    // 整份模板被 loadAllWithBroken 计为损坏（U3-2 提示后仍「可见但不可用」，
    // 用户只能手动删除重导）。现按字段回退默认值，模板其余部分照常可用。
    return UserTemplate(
      id: sanitizeTemplateId(j['id'] is String ? j['id'] as String : null),
      name: j['name'] is String ? j['name'] as String : '未命名模板',
      description:
          j['description'] is String ? j['description'] as String : '',
      iconName: j['icon'] is String ? j['icon'] as String : 'checklist',
      items: items.length > UserTemplateStore.maxItems
          ? items.sublist(0, UserTemplateStore.maxItems)
          : items,
    );
  }

  /// 导入专用：无条件丢弃外部 id 并重新分配（id 只作本地文件名标识，用户既不
  /// 可见也不应控制）。这是 P1-A 的「更强」一档，与 [fromJson] 的净化互为双保险。
  factory UserTemplate.fromImportedJson(Map<String, dynamic> j) =>
      UserTemplate.fromJson({...j, 'id': _uid()});
}

/// 模板 id 安全白名单（与 `AttachmentService._isSafeSegment` 同口径）：
/// 仅允许字母数字、点、下划线、连字符；禁空串、`.`、`..` 及任何含 `/` `\` `..` 的串。
/// 任何 id 落盘前必须先过此关，否则一律重新分配。
bool isSafeTemplateId(String s) {
  if (s.isEmpty || s.length > 128) return false;
  if (s == '.' || s == '..') return false;
  if (s.contains('..') || s.contains('/') || s.contains('\\')) return false;
  return RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(s);
}

/// 把任意来源的 id 收敛为安全值：不合法则重新分配一个本地 id（永不抛错，便于兜底）。
String sanitizeTemplateId(String? raw) =>
    (raw != null && isSafeTemplateId(raw)) ? raw : _uid();

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

  /// 把经白名单校验的文件名拼到目录内，并在拼装后断言结果确实落在 [dir] 之内
  /// （双重防护，与 `AttachmentService._safeFileFor` 同思路）。不安全则抛 [ArgumentError]。
  ///
  /// P2-4（修复）：先对白名单之外的字符做 sanitize（替换为 `_`），而非直接拒绝——
  /// 这样即便未来模板文件名混入了中文 / 空格等合法但不属于白名单的字符，也不会被整条丢弃，
  /// 而是收敛为安全文件名后再做硬性路径安全校验。路径穿越类字符（`/ \ ..`）仍会被拦截。
  static File _safeFileFor(Directory dir, String fileName) {
    if (fileName.isEmpty || fileName.length > 140) {
      throw ArgumentError('非法模板文件名');
    }
    // 先 sanitize：白名单外的字符统一替换为 `_`（中文、空格、标点等不再被拒）。
    fileName = fileName.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    if (fileName.isEmpty || fileName.length > 140) {
      throw ArgumentError('非法模板文件名');
    }
    if (fileName == '.' ||
        fileName == '..' ||
        fileName.contains('..') ||
        fileName.contains('/') ||
        fileName.contains('\\')) {
      throw ArgumentError('非法模板文件名：$fileName');
    }
    final absDir = dir.absolute.path;
    final sep = Platform.pathSeparator;
    final file = File('$absDir$sep$fileName');
    if (!file.absolute.path.startsWith('$absDir$sep')) {
      throw ArgumentError('模板路径越过目录边界：$fileName');
    }
    return file;
  }

  /// 读取全部用户模板（按名称排序；损坏文件跳过）。
  ///
  /// 安全（P1-A）：以**文件名为 id 的权威来源**——即便 JSON 内容里躺着
  /// `../../backup/auto/2026-08-28` 这样的恶意 id，也永远不会进入内存模型，
  /// 后续的编辑 / 删除 / 覆盖都只会作用于该文件自身。
  ///
  /// P3-1（v3.0.2 审计）：损坏文件不再纯静默——新入口 [loadAllWithBroken]
  /// 附带**损坏文件数**供 UI 给可见提示（U3-2「模板损坏静默消失」）；本方法
  /// 保持原签名（返回纯列表），既有调用点行为逐位不变。
  static Future<List<UserTemplate>> loadAll() async =>
      (await loadAllWithBroken()).templates;

  /// [loadAll] 的完整版：附带损坏（JSON 解析失败 / 字段异常）被跳过的文件数。
  /// 全目录枚举失败（目录不存在等）返回空列表 + 0 + **failed=true**（N5，
  /// v3.0.9 审计：旧实现把枚举失败与「真的没有模板」压成同一个返回值，
  /// 备份收集无法区分——换机后才发觉模板没进备份。现透出失败信号，
  /// 由 exportAllForBackup 转成备份侧的「收集失败」提示）。
  static Future<({List<UserTemplate> templates, int broken, bool failed})>
      loadAllWithBroken() async {
    try {
      final d = await _dir();
      final files = d
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList();
      final out = <UserTemplate>[];
      var broken = 0;
      for (final f in files) {
        try {
          final name = f.path.split(Platform.pathSeparator).last;
          final id = name.substring(0, name.length - '.json'.length);
          if (!isSafeTemplateId(id)) continue; // 非法文件名跳过
          final m = jsonDecode(
                  decodeTextFileBytes(await f.readAsBytes())) // P3-6（v3.0.0 审计）：共享解码链
              as Map<String, dynamic>;
          out.add(UserTemplate.fromJson({...m, 'id': id}));
        } catch (_) {
          // 损坏的模板文件跳过，不阻断其余模板加载；计数供 UI 提示（P3-1，v3.0.2 审计）。
          broken++;
        }
      }
      out.sort((a, b) => a.name.compareTo(b.name));
      return (templates: out, broken: broken, failed: false);
    } catch (_) {
      // 显式类型实参：裸 `const []` 在 record 字面量字段位会推断为 List<dynamic>，
      // 与声明返回类型 List<UserTemplate> 不符（编译错误）。
      return (templates: const <UserTemplate>[], broken: 0, failed: true);
    }
  }

  /// 保存（新增或覆盖，按 [UserTemplate.id] 同名文件）。
  /// 安全（P1-A）：id 先经 [sanitizeTemplateId] 净化，路径再经 [_safeFileFor] 断言。
  ///
  /// L11（v3.0.8 审计）：改**原子写**（先 `.tmp` 再 rename，与
  /// [AttachmentService.importFile] / DataIo 同口径）并返回落盘结果——旧实现直接
  /// `writeAsString`：写入中途打断（低电量 / 存储满 / 进程被杀）会留下半截 JSON，
  /// 模板库下次读取即坏一个文件；且异常直接冒泡到调用方，编辑器零反馈
  /// （用户以为保存成功了）。返回 false 时调用方停留编辑层如实提示。
  static Future<bool> save(UserTemplate t) async {
    try {
      final d = await _dir();
      final id = sanitizeTemplateId(t.id);
      final file = _safeFileFor(d, '$id.json');
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(t.toJson()..['id'] = id));
      await tmp.rename(file.path); // 同文件系统内原子替换
      return true;
    } catch (e) {
      AppLog.d('[UserTemplateStore] 保存模板失败 id=${t.id}：$e');
      return false;
    }
  }

  /// 删除指定 id 的模板文件。安全（P1-A）：与 [save] 同款净化 + 路径断言，
  /// 防止历史遗留的恶意 id 模板在删除时越界删文件。
  static Future<void> delete(String id) async {
    final d = await _dir();
    if (!isSafeTemplateId(id)) return; // 非法 id 直接忽略，绝不拼进路径
    final file = _safeFileFor(d, '$id.json');
    if (await file.exists()) await file.delete();
  }

  /// 导出为可分享的 JSON 文件（App 私有文档目录），返回文件句柄供 [DataIo.shareFile]。
  ///
  /// L11（v3.0.8 审计）：同样改原子写（半截文件分享出去 = 对方导入即坏）。
  static Future<File> exportTemplate(UserTemplate t) async {
    final base = await getApplicationDocumentsDirectory();
    final safe = t.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final name = '有条-模板-$safe-${_ts()}.json';
    final file = File('${base.path}/$name');
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(t.toJson()));
    await tmp.rename(file.path);
    return file;
  }

  /// M2（v3.0.8 审计）：序列化全部用户模板为 JSON 列表（备份 / 自动快照装配用）。
  ///
  /// 背景：模板是**文件存储**（App 文档目录 `<id>.json`），此前完全不在
  /// `backupData()` / `_writeAutoBackup()` 覆盖范围内——备份恢复 / 换机后
  /// 用户自建模板全部凭空消失（内置模板不受影响，用户难以察觉数据边界）。
  /// 现以 `user_templates` 段纳入备份；读取失败（目录不存在等）按空列表，
  /// 不阻断备份主流程。
  ///
  /// N5（v3.0.9 审计）：返回 `(templates, failed)`——旧实现目录枚举失败时
  /// 静默吞错返回空列表：备份里 user_templates 恒空且用户不知情（换机后才
  /// 发觉模板没进备份）。对照 collectBlobs 的 `__skipped` 统计段，补一个
  /// 「收集失败」信号，由调用方（手动备份 snackbar / 自动快照错误栏）如实
  /// 提示，不阻断备份主流程。`failed == false` 且列表为空 = 真的没有模板
  /// （与失败可区分）。失败信号来自 [loadAllWithBroken] 的 `failed`
  /// （目录枚举异常），本方法自身不再需要 try/catch——loadAllWithBroken
  /// 已保证不抛。
  static Future<({List<dynamic> templates, bool failed})>
      exportAllForBackup() async {
    final loaded = await loadAllWithBroken();
    return (
      templates: [for (final t in loaded.templates) t.toJson()],
      failed: loaded.failed,
    );
  }

  /// M2（v3.0.8 审计）：从备份的 `user_templates` 段恢复模板。
  ///
  /// N6（v3.0.9 审计）：注释与行为对齐——本方法是**合并语义**（只覆盖同 id
  /// 文件、本地多出的模板保留），与 tasks/trash 的整表覆盖不同，旧注释称
  /// 「与备份以备份为准的恢复语义一致」与事实不符。这是有意的安全取舍：
  /// 恢复旧备份不应把用户此后新建的模板删掉（那才是真正的数据丢失），
  /// 「同 id 覆盖」已保证备份内的修改生效。已知边界：多次恢复不同备份会
  /// 累积模板，用户可在模板库手动删除。
  ///
  /// N7（v3.0.9 审计）：返回值从「成功条数」改为 `(restored, total)`——
  /// 恢复入口已下沉进 [TaskProvider.restoreFromJson]（此前后仅 backup_sheet
  /// 两个 UI 入口消费，新增恢复入口会静默丢模板），由本体消费并经
  /// [RestoreBlobsStats] 透出统计，`total` 供「恢复 x/y 条」文案。
  /// 逐条 try/catch：单条损坏跳过不阻断其余。
  static Future<({int restored, int total})> restoreAllFromBackup(
      List<dynamic> rawList) async {
    var restored = 0;
    for (final e in rawList) {
      if (e is! Map) continue;
      try {
        final t = UserTemplate.fromJson(Map<String, dynamic>.from(e));
        if (await save(t)) restored++;
      } catch (_) {
        // 单条损坏（缺字段 / 非法 id）跳过，不阻断其余模板恢复。
      }
    }
    return (restored: restored, total: rawList.length);
  }
}

/// 把 [template] 套用为真实任务并加入 [provider]。每项按相对天数计算截止时间
/// （date-only，落在 09:00）；重复项按规则生成重复任务，interval 以今天为锚点避免首日逾期。
///
/// U3-6（v3.0.8 审计）：返回 `(created: 实际落库数, total: 模板条目数)`——
/// 批量套用已改为「一次性插入 + 单次落盘 + 失败整批回滚」，created < total
/// 仅可能出现在整批失败（created = 0）时，调用方按失败分支提示。
Future<({int created, int total})> applyTemplate(
        TaskProvider provider, BuiltInTemplate template) async =>
    applyTemplateItems(provider, template.items);

/// 把用户模板 [t] 套用为真实任务并加入 [provider]。
///
/// U3-6（v3.0.8 审计）：同 [applyTemplate] 返回 `(created, total)`。
Future<({int created, int total})> applyUserTemplate(
        TaskProvider provider, UserTemplate t) async =>
    applyTemplateItems(provider, t.items);

/// 套用一组 [TemplateItem] 为真实任务（内置 / 用户模板共用）。
///
/// U3-6（v3.0.8 审计）：改走 [TaskProvider.addTasksForTemplateApply] ——
/// 旧实现逐条 `await provider.addTask`，每条内部都是一次全量 `replaceTasks`
/// 落库（模板 7 项 = 7 次串行全表写，大库点套用明显卡顿，还放大 P2-1 的
/// 双击窗口），且部分条目失败只体现为计数偏少、UI 无从提示。现在先构造
/// 全部草稿，再一次性插入 + 单次落盘；落盘失败整批回滚（created = 0）。
Future<({int created, int total})> applyTemplateItems(
    TaskProvider provider, List<TemplateItem> items) async {
  final today = DateTime.now();
  final base = DateTime(today.year, today.month, today.day);
  final drafts = <Task>[];
  for (final item in items) {
    final due = _firstDueDate(base, item);
    // 重复任务需有提醒时刻；未指定时默认 09:00。
    final repeatMinute =
        item.repeat != RepeatType.none ? (item.repeatMinute ?? 9 * 60) : null;
    // interval 锚点设为今天（date-only），保证「从今天起每 N 天」循环、首日不逾期。
    final anchor =
        item.repeat == RepeatType.interval ? base : null;
    drafts.add(Task(
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
      // 新P3-4（v2.9.7 审计）：套用侧兜底夹取——fromTask / 编辑器路径的
      // monthlyDay 理论上已合法，这里防「未来新增写入点 / 编程构造」旁路，
      // 保证 Task 构造器（不夹取）永远拿不到 0 或 >31。
      monthlyDay: item.monthlyDay.clamp(1, 31).toInt(),
      monthlyWeekday: item.monthlyWeekday,
      monthlyWeekIndex: item.monthlyWeekIndex,
      // P2-5：从模板创建任务时一并带上「每月倒数第 N 天」字段。
      monthlyFromEnd: item.monthlyFromEnd,
      // P2-4（v2.9.3 审计）：套用模板时恢复预估时长，排程建议不再退回 30 分钟兜底。
      estimateMinutes: item.estimateMinutes,
      // P3-10（v2.9.5 审计）：备注 + 提醒提前量往返补齐。
      // `reminderOffsetMin` 仅在**有截止且非重复**时生效（`Task` 侧
      // `normalizedRepeatFields` / 构造校验同口径），无截止时传 0 不会挂出
      // 幽灵提醒——`_scheduleRemindersFor` 不为无截止任务排提醒。
      note: item.note,
      reminderOffsetMin: due == null ? 0 : item.reminderOffsetMin,
      tags: List.from(item.tags),
    ));
  }
  // U3-6（v3.0.8 审计）：整批一次落盘；失败 = 0 条落库（已回滚）。
  final ok = await provider.addTasksForTemplateApply(drafts);
  return (created: ok ? drafts.length : 0, total: drafts.length);
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
