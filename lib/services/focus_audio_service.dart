import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 专注环境音类型。
enum FocusSoundType {
  off,
  white,
  pink,
  brown,
  rain,
  ocean,
  campfire,
  wind,
}

extension FocusSoundTypeX on FocusSoundType {
  String get label {
    switch (this) {
      case FocusSoundType.off:
        return '关闭';
      case FocusSoundType.white:
        return '白噪音';
      case FocusSoundType.pink:
        return '粉噪音';
      case FocusSoundType.brown:
        return '棕噪音';
      case FocusSoundType.rain:
        return '雨声';
      case FocusSoundType.ocean:
        return '海浪';
      case FocusSoundType.campfire:
        return '篝火';
      case FocusSoundType.wind:
        return '风声';
    }
  }

  /// 对应 assets/audio 下的音频文件；[off] 无文件。
  /// just_audio 的 [AudioSource.asset] 直接走 Flutter rootBundle 加载，
  /// 路径需带 `assets/` 前缀，与 pubspec 中 assets 声明一致。
  String? get asset {
    switch (this) {
      case FocusSoundType.off:
        return null;
      case FocusSoundType.white:
        return 'assets/audio/white.wav';
      case FocusSoundType.pink:
        return 'assets/audio/pink.wav';
      case FocusSoundType.brown:
        return 'assets/audio/brown.wav';
      case FocusSoundType.rain:
        return 'assets/audio/rain.wav';
      case FocusSoundType.ocean:
        return 'assets/audio/ocean.wav';
      case FocusSoundType.campfire:
        return 'assets/audio/campfire.wav';
      case FocusSoundType.wind:
        return 'assets/audio/wind.wav';
    }
  }
}

/// 专注环境音播放服务（单例）。
///
/// 两个互相独立的维度：
/// - [_selected]：用户**选了哪些音效**（可多选，空集表示关闭），持久化。
/// - [_active]：专注**是否进行中**、即「应当播放」的状态，由专注页驱动。
///
/// 二者解耦：只有「该音效被选中」且「专注进行中」时才播放。
/// 任一音效可单独淡入/淡出；多音可同时叠加播放。
///
/// 播放生命周期由专注页根据番茄钟运行状态调用 [setActive] 驱动，
/// [setTypes] 仅改选中集合（并在进行中时即时淡入/淡出对应音源）。
class FocusAudioService {
  FocusAudioService._();

  static final FocusAudioService instance = FocusAudioService._();

  /// 每个被选中的音效各自一个播放器，支持多音叠加。
  final Map<FocusSoundType, AudioPlayer> _players = {};

  /// 防竞态：每次 start/pause 均自增序号，延迟回调只在序号未变时生效，
  /// 避免「先淡出又立刻淡入」时延迟的 pause 误停正在播放的实例。
  final Map<FocusSoundType, int> _epoch = {};

  Set<FocusSoundType> _selected = {};
  double _volume = 0.5;
  /// 是否处于「应当播放」的状态（专注进行中）。
  bool _active = false;
  /// 是否已从 [SharedPreferences] 读取过偏好。未初始化前内存态为默认值，
  /// [persist] 不可覆盖真实持久化值，否则会把用户已存的环境音设置清空。
  bool _initialized = false;

  Set<FocusSoundType> get types => Set<FocusSoundType>.from(_selected);
  double get volume => _volume;

  static const String _kTypes = 'focus_sound_types';
  static const String _kTypeLegacy = 'focus_sound_type';
  static const String _kVol = 'focus_sound_volume';

  /// 淡入淡出时长。
  static const Duration _fade = Duration(milliseconds: 500);

  /// 读取持久化偏好并初始化。应在专注页 initState 中调用一次。
  ///
  /// 兼容旧版：旧版只存单个音效（[FocusSoundType] 的 int 索引，键
  /// `focus_sound_type`）。检测到旧键则迁移为集合格式并删除旧键。
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final legacy = prefs.getInt(_kTypeLegacy);
    if (legacy != null) {
      final set = <FocusSoundType>{};
      if (legacy > 0 && legacy < FocusSoundType.values.length) {
        set.add(FocusSoundType.values[legacy]);
      }
      _selected = set;
      await prefs.remove(_kTypeLegacy);
      await prefs.setStringList(_kTypes, _selected.map((e) => e.name).toList());
    } else {
      final list = prefs.getStringList(_kTypes);
      if (list != null) {
        for (final n in list) {
          try {
            _selected.add(FocusSoundType.values.byName(n));
          } catch (_) {
            // 忽略未知/过时名称
          }
        }
      }
      _selected.remove(FocusSoundType.off);
    }
    _volume = (prefs.getDouble(_kVol) ?? 0.5).clamp(0.0, 1.0);
    _initialized = true;
  }

  /// 进程即将被杀（AppLifecycleState.paused/detached）时调用：把选中的音效集合与音量
  /// 重新落盘，防御 shared_preferences.apply() 在激进 ROM 杀进程时丢写。
  /// 未初始化（用户从未进入专注页）时不写，避免用默认值覆盖真实持久化值。
  Future<void> persist() async {
    if (!_initialized) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kTypes, _selected.map((e) => e.name).toList());
    await prefs.setDouble(_kVol, _volume);
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kTypes, _selected.map((e) => e.name).toList());
  }

  /// 设置选中的音效集合（多选）。[off] 不会进入集合。
  /// 与 [_active] 解耦：仅更新选中集合并做增删补差——
  /// 移除的音效淡出，新增且在专注进行中的音效淡入。
  Future<void> setTypes(Set<FocusSoundType> types) async {
    types.remove(FocusSoundType.off);
    _selected = Set<FocusSoundType>.from(types);
    await _persist();
    final current = _players.keys.toSet();
    final toStop = current.difference(_selected);
    final toStart = _selected.difference(current);
    for (final t in toStop) {
      _pauseType(t, fade: true);
    }
    if (_active) {
      for (final t in toStart) {
        _startType(t, fade: true);
      }
    }
  }

  /// 设置音量（0..1）并持久化；对当前所有播放器实时生效。
  Future<void> setVolume(double v) async {
    _volume = v.clamp(0.0, 1.0);
    for (final p in _players.values) {
      await p.setVolume(_volume);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kVol, _volume);
  }

  /// 由专注页驱动：专注进行中（[active]=true）则淡入所有选中音效，
  /// 否则淡出所有正在播放的音效（保留实例以便恢复时即时重播）。
  Future<void> setActive(bool active) async {
    _active = active;
    if (active) {
      for (final t in _selected) {
        _startType(t, fade: true);
      }
    } else {
      for (final t in _players.keys.toList()) {
        _pauseType(t, fade: true);
      }
    }
  }

  /// 专注停止（手动结束）：彻底标记不再播放并淡出所有音效。
  Future<void> stop() async {
    _active = false;
    for (final t in _players.keys.toList()) {
      _pauseType(t, fade: true);
    }
  }

  // —— 单音效控制 ——

  void _startType(FocusSoundType t, {bool fade = true}) {
    final asset = t.asset;
    if (asset == null) return;
    _epoch[t] = (_epoch[t] ?? 0) + 1;
    var p = _players[t];
    if (p == null) {
      p = AudioPlayer();
      _players[t] = p;
      p.setLoopMode(LoopMode.one);
    }
    final player = p;
    player.setAudioSource(AudioSource.asset(asset)).then((_) async {
      await player.setVolume(fade ? 0.0 : _volume);
      await player.play();
      if (fade) _ramp(player, 0.0, _volume, _fade);
    }).catchError((e, st) {
      // 便于真机排查：若仍无声，可在 logcat 看到具体错误。
      debugPrint('[FocusAudio] 环境音播放失败: $e\n$st');
    });
  }

  void _pauseType(FocusSoundType t, {bool fade = true}) {
    final p = _players[t];
    if (p == null) return;
    final my = (_epoch[t] = (_epoch[t] ?? 0) + 1);
    if (!fade) {
      p.pause();
      return;
    }
    _ramp(p, _volume, 0.0, _fade);
    Future.delayed(_fade, () {
      if (_epoch[t] == my) p.pause();
    });
  }

  /// 在 [dur] 内把音量从 [from] 线性过渡到 [to]。
  void _ramp(AudioPlayer p, double from, double to, Duration dur) {
    final sw = Stopwatch()..start();
    final step = const Duration(milliseconds: 30);
    Timer.periodic(step, (timer) {
      final k = (sw.elapsedMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0);
      p.setVolume(from + (to - from) * k);
      if (k >= 1) timer.cancel();
    });
  }

  void dispose() {
    for (final p in _players.values) {
      p.stop();
      p.dispose();
    }
    _players.clear();
    _epoch.clear();
  }
}
