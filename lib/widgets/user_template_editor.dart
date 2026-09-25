/// 用户模板「新建 / 编辑」底部弹层（P0-4）。
///
/// 编辑模板名称、图标、以及若干模板项（标题 / 分类 / 优先级 / 相对截止天数 / 重复规则），
/// 保存经 [UserTemplateStore.save] 落盘到 App 私有目录。纯本地、不联网。
import 'package:flutter/material.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/services/task_templates.dart';

/// P2-4（v2.9.4 审计）：月度重复规则的三档模式。
///
/// 与 `new_task_sheet.dart` 里的 `_MonthlyMode` 同名同义（该处是私有的，
/// 无法跨文件复用，故此处独立定义；两处判档优先级必须一致，见
/// [_monthlyModeOf]）。
enum _MonthlyMode { day, nthWeekday, fromEnd }

/// P2-4（v2.9.4 审计）：由 [TemplateItem] 现有字段反推应展示哪一档。
///
/// 优先级与 `new_task_sheet.dart:193-201` 完全一致：
/// [TemplateItem.monthlyFromEnd] > 0 → 倒数；否则 [TemplateItem.monthlyWeekday]
/// 与 [TemplateItem.monthlyWeekIndex] 同时非空 → 第 N 个周几；否则按号。
_MonthlyMode _monthlyModeOf(TemplateItem it) {
  if (it.monthlyFromEnd > 0) return _MonthlyMode.fromEnd;
  if (it.monthlyWeekday != null && it.monthlyWeekIndex != null) {
    return _MonthlyMode.nthWeekday;
  }
  return _MonthlyMode.day;
}

/// 每个模板项对应的文本编辑控制器集合（与 [TemplateItem] 并行维护）。
class _ItemCtl {
  final title = TextEditingController();
  final dueInDays = TextEditingController();
  final interval = TextEditingController();
  final monthlyDay = TextEditingController();
  // P2-4（v2.9.4 审计）：补「倒数第 N 天」控制器——此前月度规则只有
  // monthlyDay 一个输入框，「每月倒数第 3 天」既不可见也不可改，只能靠
  // 「另存为模板」间接携带，用户完全无法在编辑器里编辑这类规则。
  final monthlyFromEnd = TextEditingController();
  // P2-4（v2.9.4 审计）：补「每月第 N 个周几」的周几/序号输入。
  final monthlyWeekday = TextEditingController();
  final monthlyWeekIndex = TextEditingController();

  _ItemCtl(TemplateItem it) {
    title.text = it.title;
    dueInDays.text = it.dueInDays?.toString() ?? '';
    interval.text = it.repeatInterval.toString();
    monthlyDay.text = it.monthlyDay.toString();
    // 空串 = 不启用（0 在 UI 上没有意义，用户要表达的是「不倒数」）。
    monthlyFromEnd.text = it.monthlyFromEnd > 0 ? it.monthlyFromEnd.toString() : '';
    // monthlyWeekIndex 是可空字段（null = 不启用「第 N 个周几」规则），
    // 须先判空再比较；与下方 monthlyWeekday 同一口径。
    monthlyWeekIndex.text =
        it.monthlyWeekIndex != null && it.monthlyWeekIndex! > 0
            ? it.monthlyWeekIndex.toString()
            : '';
    monthlyWeekday.text = it.monthlyWeekday != null ? it.monthlyWeekday.toString() : '';
  }

  void dispose() {
    title.dispose();
    dueInDays.dispose();
    interval.dispose();
    monthlyDay.dispose();
    monthlyFromEnd.dispose();
    monthlyWeekday.dispose();
    monthlyWeekIndex.dispose();
  }
}

class UserTemplateEditorSheet {
  static Future<void> show(BuildContext context,
      {UserTemplate? initial}) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => _EditorBody(initial: initial),
    );
  }
}

class _EditorBody extends StatefulWidget {
  final UserTemplate? initial;
  const _EditorBody({this.initial});

  @override
  State<_EditorBody> createState() => _EditorBodyState();
}

class _EditorBodyState extends State<_EditorBody> {
  late final TextEditingController _nameCtl;
  late String _iconName;
  late List<TemplateItem> _items;
  late List<_ItemCtl> _ctls;

  @override
  void initState() {
    super.initState();
    final init = widget.initial;
    _nameCtl = TextEditingController(text: init?.name ?? '');
    _iconName = init?.iconName ?? 'checklist';
    _items = init?.items.map((e) => _clone(e)).toList() ?? [];
    _ctls = _items.map((e) => _ItemCtl(e)).toList();
  }

  TemplateItem _clone(TemplateItem e) => TemplateItem(
        e.title,
        e.category,
        e.priority,
        e.dueInDays,
        tags: List.from(e.tags),
        repeat: e.repeat,
        repeatWeekdays: List.from(e.repeatWeekdays),
        repeatInterval: e.repeatInterval,
        repeatMinute: e.repeatMinute,
        repeatUntil: e.repeatUntil,
        monthlyDay: e.monthlyDay,
        monthlyWeekday: e.monthlyWeekday,
        monthlyWeekIndex: e.monthlyWeekIndex,
        // P2-4（v2.9.3 审计）：编辑器克隆项时带上预估时长，避免「另存为模板 →
        // 编辑 → 保存」把 estimateMinutes 洗掉（根因在数据模型层，四处贯通之一）。
        //
        // P2-4（v2.9.4 审计）：此处**曾漏传** monthlyFromEnd → 只要打开编辑器，
        // 内存副本已是 0，「直接保存」就把「每月倒数第 3 天」洗成「每月 0 号」。
        // 这是本轮三处同族缺陷里最隐蔽的一个：不改任何字段也会丢。
        monthlyFromEnd: e.monthlyFromEnd,
        estimateMinutes: e.estimateMinutes,
      );

  @override
  void dispose() {
    _nameCtl.dispose();
    for (final c in _ctls) c.dispose();
    super.dispose();
  }

  void _addItem() {
    final it = TemplateItem('新任务', Category.life, Priority.medium, null);
    setState(() {
      _items.add(it);
      _ctls.add(_ItemCtl(it));
    });
  }

  void _removeItem(int i) {
    setState(() {
      _ctls[i].dispose();
      _ctls.removeAt(i);
      _items.removeAt(i);
    });
  }

  void _replaceItem(int i, TemplateItem updated) {
    setState(() => _items[i] = updated);
  }

  int _int(String s, [int d = 0]) => int.tryParse(s.trim()) ?? d;

  Future<void> _save(BuildContext ctx) async {
    final name = _nameCtl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(ctx).showSnackBar(
          const SnackBar(content: Text('请填写模板名称')));
      return;
    }
    if (_items.isEmpty) {
      ScaffoldMessenger.of(ctx).showSnackBar(
          const SnackBar(content: Text('请至少添加一项任务')));
      return;
    }
    if (_items.length > UserTemplateStore.maxItems) {
      ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
          content: Text('模板项过多（上限 ${UserTemplateStore.maxItems}）')));
      return;
    }
    final built = <TemplateItem>[];
    for (var i = 0; i < _items.length; i++) {
      final c = _ctls[i];
      final it = _items[i];
      // P2-4（v2.9.4 审计）：按三档模式重建月度规则，判据与
      // `new_task_sheet.dart` 的 `_MonthlyMode` 保持一致（fromEnd 优先 →
      // nthWeekday → day）。此前这里只读 [c.monthlyDay]、其余两档原样透传，
      // 于是「用户在编辑器里把倒数规则改掉」根本不可能——控制器都没有。
      final fromEnd = _int(c.monthlyFromEnd.text, 0).clamp(0, 30);
      final wd = _int(c.monthlyWeekday.text, 0);
      final wkIdx = _int(c.monthlyWeekIndex.text, 0).clamp(0, 5);
      final useNth = fromEnd <= 0 && wd >= 1 && wd <= 7 && wkIdx >= 1;
      built.add(TemplateItem(
        c.title.text.trim().isEmpty ? '未命名任务' : c.title.text.trim(),
        it.category,
        it.priority,
        c.dueInDays.text.trim().isEmpty ? null : _int(c.dueInDays.text),
        tags: List.from(it.tags),
        repeat: it.repeat,
        repeatWeekdays: List.from(it.repeatWeekdays),
        repeatInterval: _int(c.interval.text, 2),
        repeatMinute: it.repeatMinute,
        repeatUntil: it.repeatUntil,
        monthlyDay: _int(c.monthlyDay.text, 1),
        monthlyWeekday: useNth ? wd : null,
        monthlyWeekIndex: useNth ? wkIdx : null,
        // P2-4（v2.9.3 审计）同族收口：保存时此前把「每月倒数第 N 天」与
        // 「预计时长」静默洗成默认值——与模板链路丢字段同一类缺陷。
        // P2-4（v2.9.4 审计）：改为取控制器值（真正可编辑），空串 = 0 = 不倒数。
        monthlyFromEnd: fromEnd,
        estimateMinutes: it.estimateMinutes,
      ));
    }
    final t = UserTemplate(
      id: widget.initial?.id ??
          (DateTime.now().microsecondsSinceEpoch % 1000000000).toString(),
      name: name,
      description: '',
      iconName: _iconName,
      items: built,
    );
    await UserTemplateStore.save(t);
    if (ctx.mounted) Navigator.pop(ctx);
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      minChildSize: 0.5,
      expand: false,
      builder: (_, scroll) => Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Text('模板编辑',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              controller: scroll,
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
              children: [
                TextField(
                  controller: _nameCtl,
                  decoration: const InputDecoration(
                    labelText: '模板名称',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: _iconName,
                  decoration: const InputDecoration(
                    labelText: '图标',
                    border: OutlineInputBorder(),
                  ),
                  items: templateIconNames
                      .map((n) => DropdownMenuItem(
                            value: n,
                            child: Row(children: [
                              Icon(iconFromName(n), size: 20),
                              const SizedBox(width: 8),
                              Text(n),
                            ]),
                          ))
                      .toList(),
                  onChanged: (v) => setState(() => _iconName = v ?? 'checklist'),
                ),
                const SizedBox(height: 12),
                const Text('模板项',
                    style:
                        TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                ..._items.asMap().entries.map((e) => _itemCard(e.key, e.value)),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _addItem,
                  icon: const Icon(Icons.add),
                  label: const Text('添加任务项'),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => _save(context),
                child: const Text('保存模板'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _itemCard(int i, TemplateItem it) {
    final c = _ctls[i];
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: c.title,
                    decoration: const InputDecoration(
                      labelText: '标题',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: '删除该项',
                  onPressed: () => _removeItem(i),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<Category>(
                    value: it.category,
                    decoration: const InputDecoration(
                      labelText: '分类',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    items: Category.values
                        .map((x) => DropdownMenuItem(
                            value: x, child: Text(x.label)))
                        .toList(),
                    onChanged: (v) => _replaceItem(
                        i, it.copyEditable(category: v ?? it.category)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: DropdownButtonFormField<Priority>(
                    value: it.priority,
                    decoration: const InputDecoration(
                      labelText: '优先级',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    items: Priority.values
                        .map((x) => DropdownMenuItem(
                            value: x, child: Text(x.label)))
                        .toList(),
                    onChanged: (v) => _replaceItem(
                        i, it.copyEditable(priority: v ?? it.priority)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: c.dueInDays,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '相对截止(天)',
                      hintText: '留空=不设置',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: DropdownButtonFormField<RepeatType>(
                    value: it.repeat,
                    decoration: const InputDecoration(
                      labelText: '重复',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    items: RepeatType.values
                        .map((x) => DropdownMenuItem(
                            value: x, child: Text(x.label)))
                        .toList(),
                    onChanged: (v) => _replaceItem(
                        i, it.copyEditable(repeat: v ?? RepeatType.none)),
                  ),
                ),
              ],
            ),
            if (it.repeat == RepeatType.weekly) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                children: [
                  for (var d = 1; d <= 7; d++)
                    FilterChip(
                      label: Text(_wdLabel(d)),
                      selected: it.repeatWeekdays.contains(d),
                      onSelected: (sel) {
                        final set = {...it.repeatWeekdays};
                        if (sel) {
                          set.add(d);
                        } else {
                          set.remove(d);
                        }
                        _replaceItem(
                            i, it.copyEditable(weekdays: set.toList()));
                      },
                    ),
                ],
              ),
            ] else if (it.repeat == RepeatType.interval) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: 140,
                child: TextField(
                  controller: c.interval,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '每隔 N 天',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ] else if (it.repeat == RepeatType.monthly) ...[
              const SizedBox(height: 8),
              // P2-4（v2.9.4 审计）：月度规则此前**只有**「每月 N 号」一个输入框，
              // 「每月倒数第 N 天」「每月第 N 个周几」两类规则在编辑器里既不可见
              // 也不可改（只能靠「另存为模板」间接携带）。现在三档齐备。
              // 判档 [_monthlyModeOf] 与 `new_task_sheet.dart` 的 `_MonthlyMode`
              // 保持同一优先级：倒数 > 第 N 个周几 > 号。
              Builder(
                builder: (ctx) {
                  final mode = _monthlyModeOf(it);
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      DropdownButtonFormField<_MonthlyMode>(
                        value: mode,
                        decoration: const InputDecoration(
                          labelText: '月度规则',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                        items: const [
                          DropdownMenuItem(
                              value: _MonthlyMode.day, child: Text('每月 N 号')),
                          DropdownMenuItem(
                              value: _MonthlyMode.nthWeekday,
                              child: Text('每月第 N 个周几')),
                          DropdownMenuItem(
                              value: _MonthlyMode.fromEnd,
                              child: Text('每月倒数第 N 天')),
                        ],
                        onChanged: (v) {
                          if (v == null) return;
                          setState(() {
                            // 切档时清掉**另两档**的控制器，避免上一档残留值
                            // 被 _save 读走（判档是「谁有值谁生效」的多值模型）。
                            if (v == _MonthlyMode.day) {
                              c.monthlyFromEnd.clear();
                              c.monthlyWeekday.clear();
                              c.monthlyWeekIndex.clear();
                            } else if (v == _MonthlyMode.fromEnd) {
                              c.monthlyWeekday.clear();
                              c.monthlyWeekIndex.clear();
                              if (c.monthlyFromEnd.text.trim().isEmpty) {
                                c.monthlyFromEnd.text = '1';
                              }
                            } else {
                              c.monthlyFromEnd.clear();
                              if (c.monthlyWeekday.text.trim().isEmpty) {
                                c.monthlyWeekday.text = '1';
                              }
                              if (c.monthlyWeekIndex.text.trim().isEmpty) {
                                c.monthlyWeekIndex.text = '1';
                              }
                            }
                          });
                        },
                      ),
                      const SizedBox(height: 8),
                      if (mode == _MonthlyMode.day)
                        SizedBox(
                          width: 140,
                          child: TextField(
                            controller: c.monthlyDay,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: '每月 N 号',
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                      if (mode == _MonthlyMode.fromEnd)
                        SizedBox(
                          width: 180,
                          child: TextField(
                            controller: c.monthlyFromEnd,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: '倒数第 N 天（1 = 最后一天）',
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                      if (mode == _MonthlyMode.nthWeekday)
                        Row(
                          children: [
                            SizedBox(
                              width: 110,
                              child: TextField(
                                controller: c.monthlyWeekIndex,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                  labelText: '第 N 个',
                                  isDense: true,
                                  border: OutlineInputBorder(),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: DropdownButtonFormField<int>(
                                value: _int(c.monthlyWeekday.text, 1).clamp(1, 7),
                                decoration: const InputDecoration(
                                  labelText: '周几',
                                  isDense: true,
                                  border: OutlineInputBorder(),
                                ),
                                items: List.generate(
                                  7,
                                  (k) => DropdownMenuItem(
                                    value: k + 1,
                                    child: Text('周${_wdLabel(k + 1)}'),
                                  ),
                                ),
                                onChanged: (v) => c.monthlyWeekday.text =
                                    (v ?? 1).toString(),
                              ),
                            ),
                          ],
                        ),
                    ],
                  );
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _wdLabel(int d) =>
      {1: '一', 2: '二', 3: '三', 4: '四', 5: '五', 6: '六', 7: '日'}[d] ?? '';
}

/// [TemplateItem] 的不可变更新助手（编辑器内便捷重建）。
extension _TemplateItemEdit on TemplateItem {
  TemplateItem copyEditable({
    Category? category,
    Priority? priority,
    RepeatType? repeat,
    List<int>? weekdays,
    int? repeatInterval,
    int? monthlyDay,
    int? repeatMinute,
    String? repeatUntil,
    // P2-4（v2.9.4 审计）：补齐月度规则的**全部**可改字段。
    // 此前本助手只能改 monthlyDay，`monthlyWeekday` / `monthlyWeekIndex` /
    // `monthlyFromEnd` 既不可改也不可清——编辑器里「每月 N 号 / 倒数第 N 天 /
    // 每月第 N 个周几」三档只能靠 _save 透传，用户改不动。
    // `clearMonthlyWeekday` 用于「从『每月第 N 个周几』退回『每月 N 号』」。
    int? monthlyWeekday,
    int? monthlyWeekIndex,
    int? monthlyFromEnd,
    bool clearMonthlyWeekday = false,
  }) =>
      TemplateItem(
        title,
        category ?? this.category,
        priority ?? this.priority,
        dueInDays,
        tags: tags,
        repeat: repeat ?? this.repeat,
        repeatWeekdays: weekdays ?? repeatWeekdays,
        repeatInterval: repeatInterval ?? this.repeatInterval,
        repeatMinute: repeatMinute ?? this.repeatMinute,
        repeatUntil: repeatUntil ?? this.repeatUntil,
        monthlyDay: monthlyDay ?? this.monthlyDay,
        // P2-4（v2.9.3 审计）同族收口：此前 monthlyWeekday 被未赋值的形参
        // 直接顶掉（编辑器不传 → 恒 null → 丢字段），monthlyFromEnd /
        // estimateMinutes 更是整段缺失——改个分类就会把这三项洗成默认值。
        monthlyWeekday: clearMonthlyWeekday ? null : (monthlyWeekday ?? this.monthlyWeekday),
        monthlyWeekIndex: monthlyWeekIndex ?? this.monthlyWeekIndex,
        monthlyFromEnd: monthlyFromEnd ?? this.monthlyFromEnd,
        estimateMinutes: estimateMinutes,
      );
}
