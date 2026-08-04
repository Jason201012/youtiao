import 'dart:async';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:provider/provider.dart';
import 'package:todolist/models/focus_session.dart';
import 'package:todolist/state/focus_provider.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/widgets/top_app_bar.dart';

/// 专注页（番茄钟）：大圆环倒计时 + 预设切换 + 可选关联任务 + 今日统计与记录。
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

  int _modeIndex = 0;
  int get _totalSec => _presets[_modeIndex].$1;

  late int _remaining;
  bool _running = false;
  Timer? _timer;
  DateTime? _startedAt;

  @override
  void initState() {
    super.initState();
    _remaining = _totalSec;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _selectMode(int index) {
    if (_running) _stop(silent: true);
    setState(() {
      _modeIndex = index;
      _remaining = _totalSec;
    });
  }

  void _startPause() {
    if (_running) {
      _timer?.cancel();
      _timer = null;
      _running = false;
    } else {
      if (_remaining == 0) _remaining = _totalSec;
      _startedAt ??= DateTime.now();
      _running = true;
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    }
    setState(() {});
  }

  void _tick() {
    if (_remaining > 0) {
      _remaining--;
      if (_remaining == 0) {
        _timer?.cancel();
        _timer = null;
        _running = false;
        _save(_totalSec, true);
        _startedAt = null;
      }
      setState(() {});
    }
  }

  void _stop({bool silent = false}) {
    _timer?.cancel();
    _timer = null;
    _running = false;
    final elapsed = _totalSec - _remaining;
    if (elapsed > 0 && _startedAt != null) {
      _save(elapsed, _remaining == 0);
    }
    _remaining = _totalSec;
    _startedAt = null;
    if (!silent) setState(() {});
  }

  void _save(int elapsed, bool completed) {
    if (!mounted) return;
    context.read<FocusProvider>().addSession(
          FocusSession(
            id: DateTime.now().millisecondsSinceEpoch.toString(),
            plannedSec: _totalSec,
            durationSec: elapsed,
            completed: completed,
            startedAt: _startedAt ?? DateTime.now(),
            endedAt: DateTime.now(),
          ),
        );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(completed
            ? '专注完成 🍅 已记录'
            : '已记录 ${formatFocusDuration(elapsed)} 专注'),
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

    final progress =
        _totalSec == 0 ? 0.0 : 1 - _remaining / _totalSec;
    final isBreak = _modeIndex != 0;

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
                            onTap: () => _selectMode(i),
                            child: Container(
                              height: 32,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 14),
                              decoration: BoxDecoration(
                                color: i == _modeIndex ? primary : ext.chip,
                                borderRadius:
                                    BorderRadius.circular(AppColors.chipRadius),
                              ),
                              child: Center(
                                child: Text(
                                  _presets[i].$2,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                    color: i == _modeIndex
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
                            formatFocusDuration(_remaining),
                            style: TextStyle(
                              fontSize: 48,
                              fontWeight: FontWeight.bold,
                              color: onBg,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _running
                                ? '专注中…'
                                : (_remaining == 0 ? '已完成' : '已暂停'),
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
                        onPressed: _running || _remaining != _totalSec
                            ? () => _stop()
                            : null,
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
                    // 开始/暂停
                    SizedBox(
                      width: 64,
                      height: 64,
                      child: FilledButton(
                        onPressed: _startPause,
                        style: FilledButton.styleFrom(
                          shape: const CircleBorder(),
                          backgroundColor: primary,
                          padding: EdgeInsets.zero, // 去默认内边距让图标居中
                        ),
                        child: Icon(
                          _running ? Symbols.pause : Symbols.play_arrow,
                          size: 32,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
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
          child: Text('今日记录',
              style: TextStyle(
                  fontSize: 16, fontWeight: FontWeight.bold, color: onBg)),
        ),
        if (list.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('还没有专注记录', style: TextStyle(color: meta)),
          )
        else
          for (final s in list)
            Container(
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
      ],
    );
  }
}
