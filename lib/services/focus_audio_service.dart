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
/// 负责循环播放自产的噪音 WAV、调节音量，并将「音效类型 + 音量」持久化到
/// [SharedPreferences]，跨会话记忆用户选择。播放生命周期由专注页根据番茄钟
/// 运行状态（开始/暂停/恢复/停止）驱动，本类只管播放本身。
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
    _player.setReleaseMode(ReleaseMode.loop);
    final prefs = await SharedPreferences.getInstance();
    final idx = prefs.getInt(_kType) ?? FocusSoundType.off.index;
    if (idx >= 0 && idx < FocusSoundType.values.length) {
      _type = FocusSoundType.values[idx];
    }
    _volume = (prefs.getDouble(_kVol) ?? 0.5).clamp(0.0, 1.0);
    await _player.setVolume(_volume);
  }

  /// 切换音效类型并持久化；若当前应播放则立即切换音源。
  Future<void> setType(FocusSoundType t) async {
    _type = t;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kType, t.index);
    if (t == FocusSoundType.off) {
      _active = false;
      await _player.stop();
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

  /// 专注开始 / 恢复：若选择了音效则循环播放。
  Future<void> startIfEnabled() async {
    if (_type == FocusSoundType.off) return;
    _active = true;
    await _play();
  }

  /// 专注暂停：暂停播放（保留位置，便于恢复时续播）。
  Future<void> pause() async {
    _active = false;
    if (_player.state == PlayerState.playing) {
      await _player.pause();
    }
  }

  /// 专注停止（手动结束）：彻底停止。
  Future<void> stop() async {
    _active = false;
    await _player.stop();
  }

  Future<void> _play() async {
    final asset = _type.asset;
    if (asset == null) return;
    // 先停后启，避免重复叠加。
    await _player.stop();
    await _player.setSource(AssetSource(asset));
    await _player.resume();
  }

  void dispose() => _player.dispose();
}
