import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:provider/provider.dart';
import 'package:todolist/models/focus_session.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/widgets/top_app_bar.dart';
import 'package:todolist/widgets/command_palette_button.dart';
import 'package:todolist/widgets/focus_share_sheet.dart';
import 'package:todolist/widgets/focus_trend_stats.dart';
import 'package:todolist/widgets/focus_task_stats.dart';
import 'package:todolist/services/focus_audio_service.dart';
import 'package:todolist/state/task_provider.dart';
import 'package:todolist/widgets/focus_chart.dart';
import 'package:todolist/widgets/undo_snack_bar.dart';
import 'package:todolist/theme/ui_durations.dart';

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

  /// P2-8（v2.9.6 审计）：FocusProvider 引用缓存（dispose 移除 listener 用）。
  FocusProvider? _focusRef;

  /// 关联任务选择（开始专注前可选；null = 独立专注）。
  String? _selectedTaskId;
  String? _selectedTaskTitle;

  @override
  void initState() {
    super.initState();
    _initAudio();
    // P2-8：缓存 provider 引用（dispose 里不能再用 context 取）。
    _focusRef = context.read<FocusProvider>();
    // 从任务行「专注」按钮跳转过来时，预选该任务（消费 pending 后清空）。
    _consumePending();
    // P2-8（v2.9.6 审计）：Tab 保活后本页 State 常驻（首访后不再销毁），
    // initState 的 pending 消费只在**首次**生效——第二次起「任务行 → 专注钮」
    // 静默失效。改为订阅 FocusProvider：`requestTask` 现已 notifyListeners
    // （见 focus_provider），通知到达即消费 pending。本页已在树中（哪怕不在
    // 当前 Tab），通知都能送达；从未访问过的场景仍由 initState 兜底。
    _focusRef!.addListener(_consumePending);
    if (_selectedTaskId == null &&
        _focusRef!.hasActive &&
        _focusRef!.activeTaskId != null) {
      // 从进行中的会话恢复已关联任务，避免显示成「独立专注」。
      _selectedTaskId = _focusRef!.activeTaskId;
      _selectedTaskTitle = _focusRef!.activeTaskTitle;
    }
  }

  /// P2-8（v2.9.6 审计）：消费 `FocusProvider.pendingTaskId`（幂等）。
  /// initState 与 provider 通知共用同一入口，先到先得、消费即清，
  /// pending 不再长期滞留（避免在下一次任意重建时被误消费）。
  ///
  /// 新P3-10（v2.9.7 审计）：补两道守卫——本 listener 在
  /// `FocusProvider.notifyListeners()` 内**同步**执行 `setState`：
  /// ① State 已 dispose（如应用锁重建窗口期）时 `mounted == false`，
  ///    markNeedsBuild 会抛「setState after dispose」；
  /// ② Element 已失活但未 dispose（deactivate → dispose 之间的窗口，
  ///    应用锁覆盖层翻转 U2-0 时会经过）时同样不应写入。
  /// 两道都要求 `pending != null` 才可能命中，概率极低，但属 P2-8 修复
  /// （listener 常驻）的耦合代价，守卫补齐后无副作用。
  void _consumePending() {
    if (!mounted) return;
    final focus = _focusRef;
    if (focus == null || focus.pendingTaskId == null) return;
    setState(() {
      _selectedTaskId = focus.pendingTaskId;
      _selectedTaskTitle = focus.pendingTaskTitle;
      focus.pendingTaskId = null;
      focus.pendingTaskTitle = null;
    });
  }

  @override
  void dispose() {
    // P2-8：dispose 里不能再用 context，initState 时缓存引用。
    _focusRef?.removeListener(_consumePending);
    super.dispose();
  }

  @override
  void deactivate() {
    // 新P3-10（v2.9.7 审计）：失活期间移除监听——Element 处于 deactivate →
    // dispose（或重挂窗口）期间，同步 notifyListeners 到达时对失活元素
    // setState 无意义且有「build 期 markNeedsBuild」风险。被保留重挂的场景
    // 由 [activate] 恢复监听。
    _focusRef?.removeListener(_consumePending);
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    // 新P3-10：与 [deactivate] 配对——重挂回树后恢复监听并补一次消费
    // （失活期间到达的 pending 在此刻兜底，等价于 initState 的兜底语义）。
    _focusRef?.addListener(_consumePending);
    _consumePending();
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
          builder: (ctx2, setSt) {
            String? errorText;
            return AlertDialog(
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
                  // U14：非法输入此前直接关对话框、零提示（用户以为成功了）。
                  // 改为在对话框内给出可读错误，由用户改正后再提交。
                  Builder(builder: (_) {
                    if (errorText == null) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        errorText!,
                        style: TextStyle(
                          color: Theme.of(ctx2).colorScheme.error,
                          fontSize: 12,
                        ),
                      ),
                    );
                  }),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(null),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () {
                    final m = int.tryParse(minCtl.text);
                    final s = int.tryParse(secCtl.text);
                    // U14：明确校验三段错误，替代旧「?? 0 后再判 total<=0 关框」。
                    if (m == null || s == null || (m == 0 && s == 0)) {
                      errorText = '请输入有效时长（分钟和秒都填数字）';
                    } else if (m! < 0 || s! < 0 || s! > 59) {
                      errorText = '秒需在 0-59 之间，分钟不能为负';
                    } else if (m! * 60 + s! > 24 * 3600) {
                      errorText = '专注时长不能超过 24 小时';
                    } else {
                      Navigator.of(ctx).pop(m! * 60 + s!);
                      return;
                    }
                    setSt(() {});
                  },
                  child: const Text('确定'),
                ),
              ],
            );
          },
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
    // P3-2（v3.1.0 审计）：stopTimer 透传补录落盘结果——失败时不再谎报
    // 「已记录本次专注」（记录仅存内存、重启即丢）。
    final ok = await focus.stopTimer();
    await _audio.stop();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok
            ? '已记录本次专注'
            : (focus.dbLoadFailed
                ? '安全模式下更改不会保存：已阻止写入以保护数据，请先修复或恢复后再试'
                : '写入失败：本次专注未保存，请重试')),
        duration: const Duration(seconds: 2),
      ),
    );
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
        const TopAppBar(
          title: '专注',
          // U4：命令面板移动端入口。
          actions: [CommandPaletteButton(currentIndex: 3)],
        ),
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
                  // U3-3（v2.9.5 审计）：此前硬编码 `Colors.red.shade400`，
                  // 脱离主题体系（亮色模式下对比度不足，且不随主题走）。
                  // 改用 `colorScheme.error`，与任务行滑删同一口径。
                  color: Theme.of(context).colorScheme.error,
                  borderRadius: BorderRadius.circular(AppColors.cardRadius),
                ),
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 20),
                child: const Icon(Symbols.delete, color: Colors.white),
              ),
              // U3-3：此前**无确认**且**撤销仅 4 秒**，而同一屏的任务行滑删是
              // 「确认 + 10 秒 + colorScheme.error」——同屏两种保护力度。
              // 专注记录虽可撤销，但误触（拇指横扫）频率高且用户不易察觉
              // 「今天的专注时长少了一段」，补齐确认与窗口。
              confirmDismiss: (direction) async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('删除该专注记录？'),
                    content: const Text('可在 $kUndoWindowSeconds 秒内撤销。'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(false),
                        child: const Text('取消'),
                      ),
                      FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: Theme.of(context).colorScheme.error,
                        ),
                        onPressed: () => Navigator.of(ctx).pop(true),
                        child: const Text('删除'),
                      ),
                    ],
                  ),
                );
                return ok ?? false;
              },
              onDismissed: (_) async {
                final removed = s;
                // P2-9（v2.9.6 审计）：removeSession 现已与 addSession 对称——
                // 删除即扣减任务累计专注（onFocusRemoved → removeFocusSec），
                // 撤销再经 addSession 回填，两侧相抵；此前删除不扣、撤销又加，
                // 任务「已专注」凭空多出一段。
                // P3-2（v3.1.0 审计）：落盘失败（返回 null，内存已回滚）时如实
                // 提示，不再弹「已删除 + 撤销」的假横幅。
                final deleted = await focus.removeSession(s.id);
                if (!context.mounted) return;
                if (deleted == null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(focus.dbLoadFailed
                          ? '安全模式下更改不会保存：已阻止写入以保护数据，请先修复或恢复后再试'
                          : '写入失败：数据未保存，请重试'),
                    ),
                  );
                  return;
                }
                // P3-4 / U3-1：此前硬编码 4 秒；改走唯一实现（10 秒 + 超时提示）。
                showUndoSnackBar(
                  context,
                  content: undoContent('已删除该专注记录'),
                  onUndo: () async {
                    // 新U3-2（v2.9.7 审计）：返回**真实结果**——同 id 记录已存在
                    // （如重复点撤销）时不回填第二条重复记录，按「撤销已失效」
                    // 反馈（此前恒返回 true，削弱唯一实现的失效提示）。
                    if (focus.sessions.any((e) => e.id == removed.id)) {
                      return false;
                    }
                    return focus.addSession(removed);
                  },
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
    // P3-2（v3.1.0 审计）：今天没有记录时无需确认与提示（clearToday 空列表的
    // 「未生效」语义专指落盘失败，与「无物可清」区分开）。
    if (focus.sessionsOn(DateTime.now()).isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空今日记录'),
        content: const Text('将删除今天的所有专注记录，可在 $kUndoWindowSeconds 秒内撤销。'),
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
      // P3-15（v2.9.6 审计）：清空也补 10 秒撤销——同屏单条删除已有撤销，
      // 批量清空反而「不可撤销」，保护力度与风险倒挂。clearToday 返回被删
      // 记录（含 P2-9 的对称扣减），撤销经 addSession 逐条原样回填（含 taskId
      // 的记录会同步回填任务累计专注，与删除时的扣减相抵）。
      // P3-2（v3.1.0 审计）：await 落盘结果——空列表 = 未生效（今天无记录或
      // 落盘失败已回滚），如实提示而不是弹「已清空 0 条」的假横幅。
      final removed = await focus.clearToday();
      if (!context.mounted) return;
      if (removed.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(focus.dbLoadFailed
                ? '安全模式下更改不会保存：已阻止写入以保护数据，请先修复或恢复后再试'
                : '写入失败：数据未保存，请重试'),
          ),
        );
        return;
      }
      showUndoSnackBar(
        context,
        content: undoContent('已清空今日专注记录（${removed.length} 条）'),
        onUndo: () async {
          // 新U3-2（v2.9.7 审计）：同 id 记录已在列表（重复撤销）→ 整批按
          // 失效处理，避免部分回填造成「一半恢复一半丢失」的中间态。
          final existing = focus.sessions.map((e) => e.id).toSet();
          if (removed.any((s) => existing.contains(s.id))) return false;
          var ok = true;
          for (final s in removed) {
            if (!await focus.addSession(s)) ok = false;
          }
          return ok;
        },
      );
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
/// U14：非法输入（非数字 / ≤0 / 越界）此前在对话框直接 `?? 0` 提交，
/// Provider 又对 ≤0 静默忽略——用户以为改成功、实际没变。现前置校验并给出错误。
Future<void> _openPomodoroSettings(BuildContext context, FocusProvider focus) async {
  final focusMin = TextEditingController(text: '${focus.pomoFocusSec ~/ 60}');
  final shortMin = TextEditingController(text: '${focus.pomoShortSec ~/ 60}');
  final longMin = TextEditingController(text: '${focus.pomoLongSec ~/ 60}');
  final roundsCtl = TextEditingController(text: '${focus.pomoRounds}');

  final result = await showDialog<Map<String, int>>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx2, setSt) {
        String? err;
        void applyError(String msg) {
          err = msg;
          setSt(() {});
        }

        return AlertDialog(
          title: const Text('番茄循环设置'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _NumField(label: '专注时长（分钟）', ctl: focusMin),
                _NumField(label: '短休时长（分钟）', ctl: shortMin),
                _NumField(label: '长休时长（分钟）', ctl: longMin),
                _NumField(label: '每几轮长休一次', ctl: roundsCtl),
                if (err != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        err!,
                        style: TextStyle(
                          color: Theme.of(ctx2).colorScheme.error,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
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
                int? v(String t, int maxMin, String name) {
                  final n = int.tryParse(t.trim());
                  if (n == null || n < 1) {
                    applyError('$name需为正整数（当前填的是「${t.trim()}」）');
                    return null;
                  }
                  if (n > maxMin) {
                    applyError('$name不能超过 $maxMin 分钟');
                    return null;
                  }
                  return n;
                }

                final f = v(focusMin.text, 24 * 60, '专注时长');
                if (f == null) return;
                final s = v(shortMin.text, 120, '短休时长');
                if (s == null) return;
                final l = v(longMin.text, 240, '长休时长');
                if (l == null) return;
                final r = v(roundsCtl.text, 20, '每几轮长休');
                if (r == null) return;
                Navigator.of(ctx).pop({
                  'focus': f,
                  'short': s,
                  'long': l,
                  'rounds': r,
                });
              },
              child: const Text('保存'),
            ),
          ],
        );
      },
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
