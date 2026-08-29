import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:provider/provider.dart';
import 'package:todolist/models/focus_session.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/widgets/top_app_bar.dart';
import 'package:todolist/widgets/focus_share_sheet.dart';
import 'package:todolist/widgets/focus_trend_stats.dart';
import 'package:todolist/widgets/focus_task_stats.dart';
import 'package:todolist/services/focus_audio_service.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/widgets/focus_chart.dart';

/// 专注页（番茄钟）：大圆环倒计时 + 预设切换 + 可选关联任务 + 今日统计与记录。
///
/// 计时逻辑已下沉到 [FocusProvider]（墙钟推算 + 持久化 + 被杀后台可恢复），
/// 本页只负责展示与派发动作，不再持有 [Timer]。
class FocusScreen extends StatefulWidget {
  const FocusScreen({super.key});

  @override
  State<FocusScreen> createState() => _FocusScreenState();
}

class _FocusScreenState extends State<FocusScreen> {
  /// 预设：[秒, 标签]
  static const List<(int, String)> _presets = [
    (25 * 60, '专注 25'),
    (5 * 60, '休息 5'),
    (15 * 60, '长休 15'),
  ];

  /// _modeIndex 取值 0..2 为预设，3 为自定义。
  static const int _kCustomIndex = 3;

  int _modeIndex = 0;
  bool get _isCustom => _modeIndex == _kCustomIndex;
  int get _customSec => context.read<FocusProvider>().customSec;
  int get _totalSec => _isCustom ? _customSec : _presets[_modeIndex].$1;

  // —— 环境音 ——
  final FocusAudioService _audio = FocusAudioService.instance;
  bool _audioReady = false;
  bool _lastRunning = false;
  Set<FocusSoundType> _soundTypes = {};
  double _soundVol = 0.5;

  /// 关联任务选择（开始专注前可选；null = 独立专注）。
  String? _selectedTaskId;
  String? _selectedTaskTitle;

  @override
  void initState() {
    super.initState();
    _initAudio();
    // 从任务行「专注」按钮跳转过来时，预选该任务（消费 pending 后清空）。
    final focus = context.read<FocusProvider>();
    if (focus.pendingTaskId != null) {
      _selectedTaskId = focus.pendingTaskId;
      _selectedTaskTitle = focus.pendingTaskTitle;
      focus.pendingTaskId = null;
      focus.pendingTaskTitle = null;
    } else if (focus.hasActive && focus.activeTaskId != null) {
      // 切走再切回时页面 state 已重建：从进行中的会话恢复已关联任务，避免显示成「独立专注」。
      _selectedTaskId = focus.activeTaskId;
      _selectedTaskTitle = focus.activeTaskTitle;
    }
  }

  Future<void> _initAudio() async {
    await _audio.init();
    if (!mounted) return;
    setState(() {
      _audioReady = true;
      _soundTypes = _audio.types;
      _soundVol = _audio.volume;
    });
    _syncAudio();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 番茄钟运行状态变化时同步环境音播放/暂停。
    if (_audioReady) _syncAudio();
  }

  /// 根据专注运行状态驱动环境音：进行中则播放，否则暂停。
  void _syncAudio() {
    final focus = context.read<FocusProvider>();
    final running = focus.activeRunning;
    if (running == _lastRunning) return;
    _lastRunning = running;
    _audio.setActive(running);
  }

  void _toggleSound(FocusSoundType t) async {
    if (_soundTypes.contains(t)) {
      _soundTypes = Set<FocusSoundType>.from(_soundTypes)..remove(t);
    } else {
      _soundTypes = Set<FocusSoundType>.from(_soundTypes)..add(t);
    }
    setState(() {});
    await _audio.setTypes(_soundTypes);
  }

  void _clearSound() async {
    _soundTypes = {};
    setState(() {});
    await _audio.setTypes({});
  }

  void _setVol(double v) async {
    setState(() => _soundVol = v);
    await _audio.setVolume(v);
  }

  void _selectMode(int index) {
    // 进行中不切换预设，避免打断计时。
    if (context.read<FocusProvider>().hasActive) return;
    setState(() => _modeIndex = index);
  }

  /// 打开自定义时长对话框：分钟 + 秒，附快捷选项，选择后切换为自定义模式。
  Future<void> _openCustomDialog() async {
    if (context.read<FocusProvider>().hasActive) return;
    final cur = _customSec;
    final minCtl =
        TextEditingController(text: (cur ~/ 60).toString());
    final secCtl =
        TextEditingController(text: (cur % 60).toString().padLeft(2, '0'));

    final result = await showDialog<int>(
      context: context,
      builder: (ctx) {
        int? picked;
        return StatefulBuilder(
          builder: (ctx2, setSt) => AlertDialog(
            title: const Text('自定义专注时长'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: minCtl,
                        keyboardType: TextInputType.number,
                        textAlign: TextAlign.center,
                        decoration: const InputDecoration(
                          labelText: '分钟',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: secCtl,
                        keyboardType: TextInputType.number,
                        textAlign: TextAlign.center,
                        decoration: const InputDecoration(
                          labelText: '秒',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final m in [10, 20, 30, 45, 60, 90])
                      ChoiceChip(
                        label: Text('$m 分'),
                        selected: picked == m * 60,
                        onSelected: (_) {
                          picked = m * 60;
                          minCtl.text = '$m';
                          secCtl.text = '00';
                          setSt(() {});
                        },
                      ),
                  ],
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(null),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () {
                  final m = int.tryParse(minCtl.text) ?? 0;
                  final s = int.tryParse(secCtl.text) ?? 0;
                  final total = m * 60 + s;
                  if (total <= 0 || total > 24 * 3600) {
                    Navigator.of(ctx).pop(null);
                    return;
                  }
                  Navigator.of(ctx).pop(total);
                },
                child: const Text('确定'),
              ),
            ],
          ),
        );
      },
    );

    if (result == null || !mounted) return;
    await context.read<FocusProvider>().setCustomSec(result);
    if (!mounted) return;
    setState(() => _modeIndex = _kCustomIndex);
  }

  /// 开始 / 暂停 / 恢复：根据进行中状态派发到 Provider。
  /// 番茄循环开启时，未开始则启动整个循环（从专注阶段起算）。
  void _onStartPause(FocusProvider focus) {
    if (focus.hasActive) {
      if (focus.activeRunning) {
        focus.pauseTimer();
      } else {
        focus.resumeTimer();
      }
    } else if (focus.pomodoroEnabled) {
      focus.startPomodoroCycle(
        taskId: _selectedTaskId,
        taskTitle: _selectedTaskTitle,
      );
    } else {
      focus.startTimer(
        totalSec: _totalSec,
        modeIndex: _modeIndex,
        customSec: _customSec,
        taskId: _selectedTaskId,
        taskTitle: _selectedTaskTitle,
      );
    }
  }

  /// 停止（手动结束当前番茄钟，按已逝时间补录）。
  Future<void> _onStop(FocusProvider focus) async {
    if (!focus.hasActive) return;
    await focus.stopTimer();
    await _audio.stop();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已记录本次专注'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final scheme = Theme.of(context).colorScheme;
    final primary = scheme.primary;
    final onBg = scheme.onBackground;
    final focus = context.watch<FocusProvider>();

    final hasActive = focus.hasActive;
    final running = focus.activeRunning;
    final ringTotal = hasActive ? focus.activeTotalSec : _totalSec;
    final remaining = hasActive ? focus.remainingSec : _totalSec;
    final progress = ringTotal == 0 ? 0.0 : (1 - remaining / ringTotal);

    // 当前阶段：番茄循环开启时取运行态阶段（未开始则默认专注）；关闭时按预设推断。
    final effectivePhase = focus.pomodoroEnabled
        ? (hasActive ? focus.activePhase : FocusPhase.focus)
        : (_modeIndex == 1 || _modeIndex == 2
            ? FocusPhase.shortBreak
            : FocusPhase.focus);
    final isBreak = effectivePhase.isBreak;
    final phaseLabel = effectivePhase.label;

    // 预设高亮：进行中按 activeModeIndex，否则按本地 _modeIndex。
    final selectedIndex = hasActive ? focus.activeModeIndex : _modeIndex;
    final canSwitchPreset = !hasActive;

    return Column(
      children: [
        const TopAppBar(title: '专注'),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
              AppColors.pagePadX,
              8,
              AppColors.pagePadX,
              20,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // 今日统计（仅计专注阶段时长；番茄数 = 专注阶段跑满次数）
                _StatRow(
                  totalSec: focus.todayFocusSec,
                  completed: focus.todayCompleted,
                  ext: ext,
                  onBg: onBg,
                  meta: ext.meta,
                ),
                const SizedBox(height: 12),

                // 番茄循环开关 + 设置
                _PomodoroToggle(
                  focus: focus,
                  onOpenSettings: () => _openPomodoroSettings(context, focus),
                ),
                const SizedBox(height: 16),

                // 预设切换：番茄循环开启时显示三阶段（只读、高亮当前阶段）；
                // 关闭时显示可交互预设 + 自定义。
                if (focus.pomodoroEnabled)
                  _PhaseChips(focus: focus, ext: ext, primary: primary, meta: ext.meta)
                else
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (var i = 0; i < _presets.length; i++)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: GestureDetector(
                              onTap:
                                  canSwitchPreset ? () => _selectMode(i) : null,
                              child: Container(
                                height: 32,
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 14),
                                decoration: BoxDecoration(
                                  color:
                                      i == selectedIndex ? primary : ext.chip,
                                  borderRadius:
                                      BorderRadius.circular(AppColors.chipRadius),
                                ),
                                child: Center(
                                  child: Text(
                                    _presets[i].$2,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w500,
                                      color: i == selectedIndex
                                          ? Colors.white
                                          : ext.meta,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        // 自定义
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: GestureDetector(
                            onTap: canSwitchPreset ? _openCustomDialog : null,
                            child: Container(
                              height: 32,
                              padding: const EdgeInsets.symmetric(horizontal: 14),
                              decoration: BoxDecoration(
                                color: selectedIndex == _kCustomIndex
                                    ? primary
                                    : ext.chip,
                                borderRadius:
                                    BorderRadius.circular(AppColors.chipRadius),
                              ),
                              child: Center(
                                child: Text(
                                  selectedIndex == _kCustomIndex
                                      ? '自定义 ${_customSec ~/ 60}分'
                                      : '自定义',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                    color: selectedIndex == _kCustomIndex
                                        ? Colors.white
                                        : ext.meta,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 20),

                // 关联任务选择（开始专注前可选）
                _TaskPicker(
                  selectedTaskId: _selectedTaskId,
                  onPick: canSwitchPreset
                      ? (id, title) => setState(() {
                            _selectedTaskId = id;
                            _selectedTaskTitle = title;
                          })
                      : (_, __) {},
                ),
                const SizedBox(height: 24),

                // 番茄循环进度：第 N 轮 + 回合圆点（仅循环开启时显示）
                if (focus.pomodoroEnabled)
                  _CycleIndicator(
                    focus: focus,
                    meta: ext.meta,
                    primary: primary,
                  ),
                if (focus.pomodoroEnabled) const SizedBox(height: 12),

                // 大圆环倒计时
                SizedBox(
                  width: 220,
                  height: 220,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      SizedBox(
                        width: 220,
                        height: 220,
                        child: CircularProgressIndicator(
                          value: progress,
                          strokeWidth: 12,
                          backgroundColor: ext.track,
                          color: isBreak ? ext.meta : primary,
                        ),
                      ),
                      Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            formatFocusDuration(remaining),
                            style: TextStyle(
                              fontSize: 48,
                              fontWeight: FontWeight.bold,
                              color: onBg,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            running
                                ? '${phaseLabel}中…'
                                : (hasActive ? '已暂停' : '准备开始'),
                            style: TextStyle(fontSize: 13, color: ext.meta),
                          ),
                          if (hasActive && focus.activeTaskTitle != null) ...[
                            const SizedBox(height: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 3),
                              decoration: BoxDecoration(
                                color: ext.chip,
                                borderRadius:
                                    BorderRadius.circular(AppColors.chipRadius),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Symbols.timer,
                                      size: 13, color: ext.meta),
                                  const SizedBox(width: 4),
                                  Text(
                                    focus.activeTaskTitle!,
                                    style: TextStyle(
                                        fontSize: 12, color: ext.meta),
                                  ),
                                ],
                              ),
                            ),
                          ],
                          // P0-4：本段落的打断次数——让「实际专注质量」在计时页就能看见。
                          if (hasActive && focus.activeInterruptCount > 0) ...[
                            const SizedBox(height: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 3),
                              decoration: BoxDecoration(
                                color: ext.accent.withOpacity(0.14),
                                borderRadius:
                                    BorderRadius.circular(AppColors.chipRadius),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Symbols.phone_iphone,
                                      size: 13, color: ext.accent),
                                  const SizedBox(width: 4),
                                  Text(
                                    '已切出 ${focus.activeInterruptCount} 次',
                                    style: TextStyle(
                                        fontSize: 12, color: ext.accent),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 28),

                // 控制按钮：两个等大圆形按钮（64×64），图标严格居中
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // 停止/重置
                    SizedBox(
                      width: 64,
                      height: 64,
                      child: OutlinedButton(
                        onPressed: hasActive ? () => _onStop(focus) : null,
                        style: OutlinedButton.styleFrom(
                          shape: const CircleBorder(),
                          side: BorderSide(color: ext.meta),
                          foregroundColor: ext.meta,
                          padding: EdgeInsets.zero, // 去默认内边距让图标居中
                        ),
                        child: const Icon(Symbols.stop, size: 28),
                      ),
                    ),
                    const SizedBox(width: 32),
                    // 开始/暂停/恢复
                    SizedBox(
                      width: 64,
                      height: 64,
                      child: FilledButton(
                        onPressed: () => _onStartPause(focus),
                        style: FilledButton.styleFrom(
                          shape: const CircleBorder(),
                          backgroundColor: primary,
                          padding: EdgeInsets.zero, // 去默认内边距让图标居中
                        ),
                        child: Icon(
                          running ? Symbols.pause : Symbols.play_arrow,
                          size: 32,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (_audioReady)
                  _SoundCard(
                    types: _soundTypes,
                    volume: _soundVol,
                    onToggle: _toggleSound,
                    onClear: _clearSound,
                    onVolume: _setVol,
                  ),

                const SizedBox(height: 16),

                // 专注历史趋势图（置于计时钟下方）
                FocusTrendStats(focus: focus),

                const SizedBox(height: 16),

                // 专注与任务关联统计
                FocusTaskStats(focus: focus),

                const SizedBox(height: 24),

                // 今日记录
                _RecordList(ext: ext, meta: ext.meta, onBg: onBg),

                const SizedBox(height: 16),

                // 专注时段分布图（A2）：24 小时桶直方图，看出一天中何时专注最多。
                const FocusHourChart(),

                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 今日统计：总时长 + 完成番茄数。
class _StatRow extends StatelessWidget {
  final int totalSec;
  final int completed;
  final AppColorsExt ext;
  final Color onBg;
  final Color meta;
  const _StatRow({
    required this.totalSec,
    required this.completed,
    required this.ext,
    required this.onBg,
    required this.meta,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
      decoration: BoxDecoration(
        color: ext.chip,
        borderRadius: BorderRadius.circular(AppColors.cardRadius),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _StatItem(
            value: formatFocusDuration(totalSec),
            label: '今日专注',
            onBg: onBg,
            meta: meta,
          ),
          Container(width: 1, height: 36, color: meta.withOpacity(0.3)),
          _StatItem(
            value: '$completed',
            label: '完成番茄',
            onBg: onBg,
            meta: meta,
          ),
        ],
      ),
    );
  }
}

class _StatItem extends StatelessWidget {
  final String value;
  final String label;
  final Color onBg;
  final Color meta;
  const _StatItem({
    required this.value,
    required this.label,
    required this.onBg,
    required this.meta,
  });
  @override
  Widget build(BuildContext context) => Column(
        children: [
          Text(value,
              style: TextStyle(
                  fontSize: 22, fontWeight: FontWeight.bold, color: onBg)),
          const SizedBox(height: 4),
          Text(label, style: TextStyle(fontSize: 12, color: meta)),
        ],
      );
}

/// 今日专注记录列表。
class _RecordList extends StatelessWidget {
  final AppColorsExt ext;
  final Color meta;
  final Color onBg;
  const _RecordList({
    required this.ext,
    required this.meta,
    required this.onBg,
  });

  @override
  Widget build(BuildContext context) {
    final focus = context.watch<FocusProvider>();
    final today = DateTime.now();
    final list = focus.sessions.where((s) {
      final d = DateTime(s.endedAt.year, s.endedAt.month, s.endedAt.day);
      final t = DateTime(today.year, today.month, today.day);
      return d == t;
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            children: [
              Text('今日记录',
                  style: TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold, color: onBg)),
              const Spacer(),
              if (list.isNotEmpty) ...[
                IconButton(
                  icon: const Icon(Symbols.share, size: 20),
                  tooltip: '分享今日记录',
                  onPressed: () => showFocusShareSheet(context),
                ),
                IconButton(
                  icon: const Icon(Symbols.delete_sweep, size: 20),
                  tooltip: '清空今日记录',
                  onPressed: () => _confirmClear(context, focus),
                ),
              ],
            ],
          ),
        ),
        if (list.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('还没有专注记录', style: TextStyle(color: meta)),
          )
        else
          for (final s in list)
            Dismissible(
              key: ValueKey(s.id),
              direction: DismissDirection.endToStart,
              background: Container(
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: Colors.red.shade400,
                  borderRadius: BorderRadius.circular(AppColors.cardRadius),
                ),
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 20),
                child: const Icon(Symbols.delete, color: Colors.white),
              ),
              onDismissed: (_) {
                final removed = s;
                focus.removeSession(s.id);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: const Text('已删除该专注记录'),
                    duration: const Duration(seconds: 4),
                    action: SnackBarAction(
                      label: '撤销',
                      onPressed: () => focus.addSession(removed),
                    ),
                  ),
                );
              },
              child: Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
                decoration: BoxDecoration(
                  color: ext.chip,
                  borderRadius: BorderRadius.circular(AppColors.cardRadius),
                ),
                child: Row(
                  children: [
                    _phaseIcon(s.phase, s.completed, ext, meta),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        s.taskTitle ?? '独立专注',
                        style: TextStyle(fontSize: 14, color: onBg),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      formatFocusDuration(s.durationSec),
                      style: TextStyle(fontSize: 13, color: meta),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      TimeOfDay.fromDateTime(s.endedAt).format(context),
                      style: TextStyle(fontSize: 12, color: meta),
                    ),
                  ],
                ),
              ),
            ),
      ],
    );
  }

  Future<void> _confirmClear(BuildContext context, FocusProvider focus) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空今日记录'),
        content: const Text('将删除今天的所有专注记录，此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok == true) {
      focus.clearToday();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已清空今日专注记录')),
        );
      }
    }
  }
}

/// 环境音卡片：可多选（叠加播放）+ 音量条。
/// 选中 [FocusSoundType.off] 表示清空全部（即关闭）。
class _SoundCard extends StatelessWidget {
  final Set<FocusSoundType> types;
  final double volume;
  final ValueChanged<FocusSoundType> onToggle;
  final VoidCallback onClear;
  final ValueChanged<double> onVolume;

  const _SoundCard({
    required this.types,
    required this.volume,
    required this.onToggle,
    required this.onClear,
    required this.onVolume,
  });

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final onBg = Theme.of(context).colorScheme.onBackground;
    final all = FocusSoundType.values; // [off, white, pink, brown, ...]
    final isOff = types.isEmpty;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: ext.chip,
        borderRadius: BorderRadius.circular(AppColors.cardRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Symbols.music_note, size: 18, color: ext.meta),
              const SizedBox(width: 8),
              Text('环境音',
                  style: TextStyle(
                      fontSize: 15, fontWeight: FontWeight.bold, color: onBg)),
              const Spacer(),
              Text('可多选叠加', style: TextStyle(fontSize: 11, color: ext.meta)),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final t in all)
                ChoiceChip(
                  label: Text(t.label),
                  selected: t == FocusSoundType.off ? isOff : types.contains(t),
                  onSelected: (_) =>
                      t == FocusSoundType.off ? onClear() : onToggle(t),
                ),
            ],
          ),
          if (!isOff) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(Symbols.volume_down, size: 18, color: ext.meta),
                Expanded(
                  child: Slider(
                    value: volume,
                    min: 0,
                    max: 1,
                    onChanged: onVolume,
                  ),
                ),
                Icon(Symbols.volume_up, size: 18, color: ext.meta),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// 关联任务选择器：横向 chip 列表，含「独立专注」与各个任务；开始前可选。
class _TaskPicker extends StatelessWidget {
  final String? selectedTaskId;
  final void Function(String? id, String? title) onPick;
  const _TaskPicker({required this.selectedTaskId, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final meta = ext.meta;
    final primary = Theme.of(context).colorScheme.primary;
    final tasks = context.watch<TaskProvider>().tasks;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text('关联任务（可选）',
              style: TextStyle(fontSize: 13, color: meta)),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _TaskChip(
                label: '独立专注',
                selected: selectedTaskId == null,
                primary: primary,
                meta: meta,
                ext: ext,
                onTap: () => onPick(null, null),
              ),
              for (final t in tasks)
                _TaskChip(
                  label: t.title,
                  selected: selectedTaskId == t.id,
                  primary: primary,
                  meta: meta,
                  ext: ext,
                  onTap: () => onPick(t.id, t.title),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TaskChip extends StatelessWidget {
  final String label;
  final bool selected;
  final Color primary;
  final Color meta;
  final AppColorsExt ext;
  final VoidCallback onTap;
  const _TaskChip({
    required this.label,
    required this.selected,
    required this.primary,
    required this.meta,
    required this.ext,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: selected ? primary : ext.chip,
              borderRadius: BorderRadius.circular(AppColors.chipRadius),
            ),
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: selected ? Colors.white : meta,
                ),
              ),
            ),
          ),
        ),
      );
}

/// 番茄循环开关卡片：开启后专注页进入"专注↔休息"自动循环模式。
class _PomodoroToggle extends StatelessWidget {
  final FocusProvider focus;
  final VoidCallback onOpenSettings;
  const _PomodoroToggle(
      {required this.focus, required this.onOpenSettings});

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final onBg = Theme.of(context).colorScheme.onBackground;
    final primary = Theme.of(context).colorScheme.primary;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: ext.chip,
        borderRadius: BorderRadius.circular(AppColors.cardRadius),
      ),
      child: Row(
        children: [
          Icon(Symbols.repeat, size: 18, color: ext.meta),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('番茄循环',
                    style:
                        TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: onBg)),
                Text(
                  focus.pomodoroEnabled
                      ? '自动在 专注 / 休息 间循环'
                      : '单次计时，手动开始每段',
                  style: TextStyle(fontSize: 11, color: ext.meta),
                ),
              ],
            ),
          ),
          if (focus.pomodoroEnabled)
            IconButton(
              icon: Icon(Symbols.settings, size: 20, color: ext.meta),
              tooltip: '循环设置',
              onPressed: onOpenSettings,
            ),
          Switch(
            value: focus.pomodoroEnabled,
            onChanged: (v) => focus.setPomodoroEnabled(v),
            activeColor: primary,
          ),
        ],
      ),
    );
  }
}

/// 番茄循环下的阶段指示 chips：三阶段只读展示，高亮当前运行阶段。
class _PhaseChips extends StatelessWidget {
  final FocusProvider focus;
  final AppColorsExt ext;
  final Color primary;
  final Color meta;
  const _PhaseChips({
    required this.focus,
    required this.ext,
    required this.primary,
    required this.meta,
  });

  @override
  Widget build(BuildContext context) {
    final phases = [
      (FocusPhase.focus, '专注', focus.pomoFocusSec),
      (FocusPhase.shortBreak, '短休', focus.pomoShortSec),
      (FocusPhase.longBreak, '长休', focus.pomoLongSec),
    ];
    final active = focus.hasActive ? focus.activePhase : FocusPhase.focus;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (final p in phases)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Container(
                height: 32,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: p.$1 == active ? primary : ext.chip,
                  borderRadius: BorderRadius.circular(AppColors.chipRadius),
                ),
                child: Center(
                  child: Text(
                    '${p.$2} ${p.$3 ~/ 60}分',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: p.$1 == active ? Colors.white : meta,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 番茄循环回合进度：第 N 轮 + 圆点（已完成的专注段高亮）。
class _CycleIndicator extends StatelessWidget {
  final FocusProvider focus;
  final Color meta;
  final Color primary;
  const _CycleIndicator({
    required this.focus,
    required this.meta,
    required this.primary,
  });

  @override
  Widget build(BuildContext context) {
    final rounds = focus.pomoRounds;
    final done = focus.hasActive ? focus.focusDoneInCycle : 0;
    return Column(
      children: [
        Text('第 ${focus.cycleNo} 轮 · 每 $rounds 个专注后长休',
            style: TextStyle(fontSize: 12, color: meta)),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < rounds; i++)
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 4),
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i < done ? primary : meta.withOpacity(0.3),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// 今日记录中按阶段选择图标：专注完成用🔥，专注片段用⏱，休息用☕。
Widget _phaseIcon(FocusPhase phase, bool completed, AppColorsExt ext, Color meta) {
  switch (phase) {
    case FocusPhase.focus:
      return Icon(
        completed ? Symbols.local_fire_department : Symbols.timer,
        size: 20,
        color: completed ? ext.accent : meta,
      );
    case FocusPhase.shortBreak:
    case FocusPhase.longBreak:
      return Icon(Symbols.local_cafe, size: 20, color: meta);
  }
}

/// 数字输入小部件（番茄循环设置弹窗用）。
class _NumField extends StatelessWidget {
  final String label;
  final TextEditingController ctl;
  const _NumField({required this.label, required this.ctl});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: ctl,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
          ),
        ),
      );
}

/// 打开番茄循环设置对话框：专注 / 短休 / 长休时长（分钟）与每轮个数。
Future<void> _openPomodoroSettings(BuildContext context, FocusProvider focus) async {
  final focusMin = TextEditingController(text: '${focus.pomoFocusSec ~/ 60}');
  final shortMin = TextEditingController(text: '${focus.pomoShortSec ~/ 60}');
  final longMin = TextEditingController(text: '${focus.pomoLongSec ~/ 60}');
  final roundsCtl = TextEditingController(text: '${focus.pomoRounds}');

  final result = await showDialog<Map<String, int>>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('番茄循环设置'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _NumField(label: '专注时长（分钟）', ctl: focusMin),
            _NumField(label: '短休时长（分钟）', ctl: shortMin),
            _NumField(label: '长休时长（分钟）', ctl: longMin),
            _NumField(label: '每几轮长休一次', ctl: roundsCtl),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(null),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(ctx).pop({
              'focus': int.tryParse(focusMin.text) ?? 0,
              'short': int.tryParse(shortMin.text) ?? 0,
              'long': int.tryParse(longMin.text) ?? 0,
              'rounds': int.tryParse(roundsCtl.text) ?? 0,
            });
          },
          child: const Text('保存'),
        ),
      ],
    ),
  );

  if (result == null || !context.mounted) return;
  await focus.setPomodoroConfig(
    focusSec: result['focus']! * 60,
    shortSec: result['short']! * 60,
    longSec: result['long']! * 60,
    rounds: result['rounds'],
  );
}
