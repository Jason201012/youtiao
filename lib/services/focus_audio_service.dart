import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 专注环境音类型。
enum FocusSoundType {
  off,
  white,
  pink,
  brown,
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
    }
  }

  /// 对应 assets/audio 下的音频文件；[off] 无文件。
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
    }
  }
}

/// 专注环境音播放服务（单例）。
///
/// 两个互相独立的维度：
/// - [_type]：用户**选了哪种音效**（关闭 / 白 / 粉 / 棕），持久化。
/// - [_active]：专注**是否进行中**、即「应当播放」的状态，由专注页驱动。
///
/// 二者解耦：无论先选音效还是先开始专注，只要两者同时为真就播放。
/// 播放生命周期由专注页根据番茄钟运行状态调用 [setActive] 驱动，
/// [setType] 仅改音效类型（并在进行中时立即切换音源）。
class FocusAudioService {
  FocusAudioService._();

  static final FocusAudioService instance = FocusAudioService._();

  final AudioPlayer _player = AudioPlayer();

  FocusSoundType _type = FocusSoundType.off;
  double _volume = 0.5;
  /// 是否处于「应当播放」的状态（专注进行中）。
  bool _active = false;

  FocusSoundType get type => _type;
  double get volume => _volume;

  static const String _kType = 'focus_sound_type';
  static const String _kVol = 'focus_sound_volume';

  /// 读取持久化偏好并初始化播放器。应在专注页 initState 中调用一次。
  Future<void> init() async {
    await _player.setReleaseMode(ReleaseMode.loop);
    final prefs = await SharedPreferences.getInstance();
    final idx = prefs.getInt(_kType) ?? FocusSoundType.off.index;
    if (idx >= 0 && idx < FocusSoundType.values.length) {
      _type = FocusSoundType.values[idx];
    }
    _volume = (prefs.getDouble(_kVol) ?? 0.5).clamp(0.0, 1.0);
    await _player.setVolume(_volume);
  }

  /// 切换音效类型并持久化。
  /// 若当前正处于专注进行中（[_active]），立即切换到新音源；
  /// 若选了 [off]，则停止播放；否则仅记录类型，待专注开始再播。
  Future<void> setType(FocusSoundType t) async {
    _type = t;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kType, t.index);
    if (t == FocusSoundType.off) {
      if (_player.state == PlayerState.playing) {
        await _player.stop();
      }
    } else if (_active) {
      await _play();
    }
  }

  /// 设置音量（0..1）并持久化；播放中实时生效。
  Future<void> setVolume(double v) async {
    _volume = v.clamp(0.0, 1.0);
    await _player.setVolume(_volume);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kVol, _volume);
  }

  /// 由专注页驱动：专注进行中（[active]=true）则播放，否则暂停。
  /// 与 [_type] 无关——即使先开始专注、后选音效，也会在选音效时补播，
  /// 因为 [setType] 会检查 [_active]。
  Future<void> setActive(bool active) async {
    _active = active;
    if (active) {
      if (_type != FocusSoundType.off) {
        await _play();
      }
    } else {
      if (_player.state == PlayerState.playing) {
        await _player.pause();
      }
    }
  }

  /// 专注停止（手动结束）：彻底停止，并标记不再播放。
  Future<void> stop() async {
    _active = false;
    if (_player.state != PlayerState.stopped) {
      await _player.stop();
    }
  }

  Future<void> _play() async {
    final asset = _type.asset;
    if (asset == null) return;
    // 先停后启，避免重复叠加。
    if (_player.state != PlayerState.stopped) {
      await _player.stop();
    }
    // ReleaseMode.loop 控制循环（注意：play() 的 mode 参数是 PlayerMode 而非 ReleaseMode）。
    await _player.setReleaseMode(ReleaseMode.loop);
    await _player.play(AssetSource(asset), volume: _volume);
  }

  void dispose() => _player.dispose();
}
