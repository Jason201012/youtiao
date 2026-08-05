import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:provider/provider.dart';
import 'package:todolist/models/focus_session.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/widgets/top_app_bar.dart';
import 'package:todolist/widgets/focus_share_sheet.dart';
import 'package:todolist/services/focus_audio_service.dart';

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
  FocusSoundType _soundType = FocusSoundType.off;
  double _soundVol = 0.5;

  @override
  void initState() {
    super.initState();
    _initAudio();
  }

  Future<void> _initAudio() async {
    await _audio.init();
    if (!mounted) return;
    setState(() {
      _audioReady = true;
      _soundType = _audio.type;
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

  void _pickSound(FocusSoundType t) async {
    setState(() => _soundType = t);
    await _audio.setType(t);
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
  void _onStartPause(FocusProvider focus) {
    if (focus.hasActive) {
      if (focus.activeRunning) {
        focus.pauseTimer();
      } else {
        focus.resumeTimer();
      }
    } else {
      focus.startTimer(
        totalSec: _totalSec,
        modeIndex: _modeIndex,
        customSec: _customSec,
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
    final isBreak = !hasActive
        ? (_modeIndex == 1 || _modeIndex == 2)
        : (focus.activeModeIndex == 1 || focus.activeModeIndex == 2);

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
                // 今日统计
                _StatRow(
                  totalSec: focus.todayTotalSec,
                  completed: focus.todayCompleted,
                  ext: ext,
                  onBg: onBg,
                  meta: ext.meta,
                ),
                const SizedBox(height: 16),

                // 预设切换
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (var i = 0; i < _presets.length; i++)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: GestureDetector(
                            onTap: canSwitchPreset ? () => _selectMode(i) : null,
                            child: Container(
                              height: 32,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 14),
                              decoration: BoxDecoration(
                                color: i == selectedIndex ? primary : ext.chip,
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
                const SizedBox(height: 28),

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
                                ? '专注中…'
                                : (hasActive ? '已暂停' : '准备开始'),
                            style: TextStyle(fontSize: 13, color: ext.meta),
                          ),
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
                if (_audioReady)
                  _SoundCard(
                    type: _soundType,
                    volume: _soundVol,
                    onPick: _pickSound,
                    onVolume: _setVol,
                  ),

                const SizedBox(height: 24),

                // 今日记录
                _RecordList(ext: ext, meta: ext.meta, onBg: onBg),
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
                    Icon(
                      s.completed ? Symbols.local_fire_department : Symbols.timer,
                      size: 20,
                      color: meta,
                    ),
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

/// 环境音卡片：关闭 / 白 / 粉 / 棕 四选一 + 音量条。
class _SoundCard extends StatelessWidget {
  final FocusSoundType type;
  final double volume;
  final ValueChanged<FocusSoundType> onPick;
  final ValueChanged<double> onVolume;

  const _SoundCard({
    required this.type,
    required this.volume,
    required this.onPick,
    required this.onVolume,
  });

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final onBg = Theme.of(context).colorScheme.onBackground;
    final types = FocusSoundType.values; // [off, white, pink, brown]
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
              Text('专注时播放', style: TextStyle(fontSize: 11, color: ext.meta)),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final t in types)
                ChoiceChip(
                  label: Text(t.label),
                  selected: t == type,
                  onSelected: (_) => onPick(t),
                ),
            ],
          ),
          if (type != FocusSoundType.off) ...[
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
