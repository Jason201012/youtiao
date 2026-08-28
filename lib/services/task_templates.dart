/// 内置任务模板 / 清单库（P1-7，纯离线）。
///
/// 本质是一组「打包进 App 的 Task 数据」，不依赖任何网络。用户一键套用后，
/// 模板里的每项会生成为一条真实任务加入当前列表，适合「开学 / 旅行 / 考试 /
/// 购物补货」这类高度重复的场景。落地的成本很低、感知很强。
///
/// 设计原则：
/// - 模板数据用 const 声明，零运行时开销；
/// - 套用逻辑只调用已有的 [TaskProvider.addTask]，不引入新的持久化路径；
/// - 每条任务项可带分类 / 优先级 / 相对截止天数，套用时一次性落库。

import 'package:flutter/material.dart';
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

  const TemplateItem(
    this.title, [
    this.category = Category.life,
    this.priority = Priority.medium,
    this.dueInDays,
  ]);
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
];

/// 把 [template] 套用为真实任务并加入 [provider]。
/// 返回实际创建的任务数量。每项按相对天数计算截止时间（date-only，落在 09:00）。
int applyTemplate(TaskProvider provider, BuiltInTemplate template) {
  final today = DateTime.now();
  final base = DateTime(today.year, today.month, today.day);
  var created = 0;
  for (final item in template.items) {
    final due = item.dueInDays == null
        ? null
        : base.add(Duration(days: item.dueInDays!));
    provider.addTask(Task(
      id: '',
      title: item.title,
      category: item.category,
      priority: item.priority,
      dueDate: due,
    ));
    created++;
  }
  return created;
}
