import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import 'package:local_auth_android/local_auth_android.dart';
import 'package:local_auth_darwin/local_auth_darwin.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:todolist/services/app_log.dart';

/// 应用锁（A4）：基于系统生物识别（指纹 / 面容）的启动 / 回前台解锁门禁。
///
/// 设计要点：
/// - 纯本地、零网络，符合产品「离线红线」。
/// - 状态只存一个开关 [appLockEnabled]（SharedPreferences），不存任何生物特征
///   （local_auth 仅调用系统 API，特征由系统保管）。
/// - [locked] 表示当前是否需要验证；每次 App 回到前台（resumed）且启用锁时置为
///   true，验证成功后置 false。冷启动首帧也需验证（MainScaffold 在 locked 时渲染
///   独立解锁页，而非主界面）。
/// - 设备不支持生物识别时 [biometricAvailable] 为 false，设置页开关禁用并提示。
/// - 指纹/面容之外允许降级用手机锁屏密码（PIN/图案/密码）解锁；
///   系统验证弹窗文案统一汉化（v2.6.4 用户反馈部分文案为英文）。
class AppLockProvider extends ChangeNotifier {
  static const String _kEnabled = 'app_lock_enabled';

  final LocalAuthentication _auth = LocalAuthentication();

  bool _enabled = false;
  bool get appLockEnabled => _enabled;

  /// 设备是否支持且已录入生物识别（启动时探测一次）。
  bool _biometricAvailable = false;
  bool get biometricAvailable => _biometricAvailable;

  /// 当前是否需要验证。true=显示解锁页；false=已解锁可正常交互。
  bool _locked = false;
  bool get locked => _locked;

  /// 正在调起系统生物识别。期间系统验证页（独立 Activity）开关会导致
  /// Flutter 收到 paused/resumed 生命周期抖动，[onResumed] 必须忽略，
  /// 否则会在验证过程中/刚成功时被误重新上锁。
  bool _authenticating = false;

  /// 最近一次解锁时间戳。[onResumed] 在解锁后短宽限期内忽略 resumed——
  /// 指纹成功关闭系统页触发的那次 resumed 与 authenticate() Future 完成存在
  /// 竞态，若不宽限会出现「识别成功却立刻回到锁定页」。
  DateTime? _lastUnlockAt;

  /// 启动期探测生物识别可用性：不抛错、安静降级（不支持则开关不可用）。
  Future<void> probeBiometric() async {
    try {
      _biometricAvailable = await _auth.canCheckBiometrics;
      // 部分机型 canCheckBiometrics 为 false 但 deviceSupportsBiometrics 为 true，
      // 再补一次探测，避免「有硬件但被标记不可用」导致开关误禁用。
      if (!_biometricAvailable) {
        _biometricAvailable = await _auth.isDeviceSupported();
      }
    } catch (e) {
      AppLog.d('[AppLock] 探测生物识别失败，降级为不可用：$e');
      _biometricAvailable = false;
    }
    notifyListeners();
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_kEnabled) ?? false;
    await probeBiometric();
    // 冷启动若已开启锁，则首帧需验证；未开启则直接解锁态。
    _locked = _enabled;
    notifyListeners();
  }

  /// 设置开关：开→关闭时立即解锁；关→开时若设备不支持则拒绝并回 false。
  Future<bool> setEnabled(bool v) async {
    if (v && !_biometricAvailable) return false; // 设备不支持，拒绝开启
    _enabled = v;
    if (!v) _locked = false; // 关闭锁即视为已解锁
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabled, _enabled);
    notifyListeners();
    return true;
  }

  /// 还原备份后刷新应用锁开关，使其与持久化值一致；**不修改 [_locked]**，
  /// 避免「还原过程中把正在使用的 App 立即锁屏」。
  ///
  /// 与 [load] 的区别：[load] 会在冷启动时按 `_enabled` 设置首帧是否需验证
  /// （`_locked = _enabled`），但还原发生在 App 前台运行期，若强行锁屏会打断用户操作，
  /// 因此这里只同步开关与生物特征可用性，真正的重新上锁交由下次生命周期回调处理。
  Future<void> refreshEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_kEnabled) ?? false;
    await probeBiometric();
    notifyListeners();
  }

  /// App 回到前台时调用：若启用锁则重新上锁（下次交互前需验证）。
  ///
  /// 两个豁免（均为真机实测出的竞态，缺一即出现「识别成功仍停留在锁定页」）：
  /// 1. 生物识别验证进行中（[onResumed] 由系统验证页关闭触发）——忽略；
  /// 2. 解锁后 3 秒宽限期内的那次 resumed（与 authenticate Future 完成存在竞态）——忽略。
  void onResumed() {
    if (_authenticating) return;
    final last = _lastUnlockAt;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(seconds: 3)) {
      return;
    }
    if (_enabled && !_locked) {
      _locked = true;
      notifyListeners();
    }
  }

  /// P1-2：无操作超时强制上锁。仅当已启用应用锁且当前处于解锁态时生效。
  /// 由 MainScaffold 的空闲定时器触发；未启用锁时调用为无操作，绝不凭空上锁。
  /// 定时上锁会清除「解锁宽限期」标记，避免刚超时锁定的瞬间被 lifecycle 抖动误解锁。
  void lock() {
    if (!_enabled || _locked) return;
    _lastUnlockAt = null;
    _locked = true;
    notifyListeners();
  }

  /// 调起系统生物识别验证。成功返回 true 并解锁；失败/取消返回 false。
  /// [reason] 为系统弹窗的本地化提示文案。
  Future<bool> authenticate({String reason = '验证身份以进入有条'}) async {
    if (!_enabled) {
      _locked = false;
      notifyListeners();
      return true;
    }
    // 标记验证中：系统验证页开关引发的生命周期抖动不得触发重新上锁。
    _authenticating = true;
    try {
      final ok = await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          // false = 指纹/面容之外允许降级用手机锁屏密码（PIN/图案/密码）解锁。
          biometricOnly: false,
          stickyAuth: true,
        ),
        // 系统验证弹窗文案汉化：Android 走 BiometricPrompt 各字段，
        // iOS 走 FaceID/TouchID 弹窗按钮与回退标题。
        authMessages: const [
          AndroidAuthMessages(
            signInTitle: '解锁「有条」',
            biometricHint: '',
            cancelButton: '取消',
            biometricSuccess: '验证成功',
            biometricNotRecognized: '未识别成功，请重试',
            biometricRequiredTitle: '需要验证身份',
            deviceCredentialsRequiredTitle: '需要验证锁屏密码',
            deviceCredentialsSetupDescription: '需要设置手机锁屏密码',
            goToSettingsButton: '去设置',
            goToSettingsDescription:
                '尚未设置手机锁屏密码，请到系统设置中设置后重试。',
          ),
          IOSAuthMessages(
            cancelButton: '取消',
            localizedFallbackTitle: '使用锁屏密码',
            lockOut: '验证次数过多，已锁定。请稍后重试或改用锁屏密码。',
          ),
        ],
      );
      if (ok) {
        _locked = false;
        // 记录解锁时刻，供 [onResumed] 的宽限期判断（竞态豁免 2）。
        _lastUnlockAt = DateTime.now();
      }
      notifyListeners();
      return ok;
    } catch (e) {
      AppLog.d('[AppLock] 验证异常：$e');
      // 异常时不自动解锁（安全优先），返回 false 让 UI 维持锁定页。
      return false;
    } finally {
      _authenticating = false;
      // 状态可能已变（成功解锁），通知监听方刷新。
      notifyListeners();
    }
  }
}
