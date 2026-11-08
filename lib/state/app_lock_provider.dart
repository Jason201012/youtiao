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
/// - 本机无可用凭据（未录入生物识别且未设锁屏密码）时 [canAuthenticate] 为
///   false，设置页开关禁用并如实说明原因。
/// - 指纹/面容之外允许降级用手机锁屏密码（PIN/图案/密码）解锁；
///   系统验证弹窗文案统一汉化（v2.6.4 用户反馈部分文案为英文）。
class AppLockProvider extends ChangeNotifier {
  static const String _kEnabled = 'app_lock_enabled';

  final LocalAuthentication _auth = LocalAuthentication();

  bool _enabled = false;
  bool get appLockEnabled => _enabled;

  /// P1-1 / U-1（v3.1.5 审计）：**本机现在能否完成一次身份验证**。
  ///
  /// 旧实现用 `canCheckBiometrics`（生物识别**硬件**能力）当可用性，语义是
  /// 「有指纹 / 面容硬件」，不要求已录入；在「有硬件 + 未录入 + 未设锁屏密码」
  /// 的设备上，旧逻辑允许开启应用锁，随后 `authenticate` 必然返回
  /// `notAvailable`，而解锁页又因 `bioOk == true` 不渲染关闭出口 —— 用户被
  /// 永久锁在应用外，唯一出路是清数据。现在只认 `isDeviceSupported()`
  /// （Android 原生 = `isDeviceSecure() || canAuthenticateWithBiometrics()`），
  /// 即「有锁屏密码或已录入生物识别」二者之一，才允许开启 / 才隐藏关闭出口。
  bool _canAuthenticate = false;
  bool get canAuthenticate => _canAuthenticate;

  /// P1-1（v3.1.5 审计）：`canCheckBiometrics` 的原始语义——**只有硬件**，
  /// 不参与任何门槛判定，仅用于设置页文案区分「有硬件但未录入」。
  bool _biometricHardware = false;
  bool get hasBiometricHardware => _biometricHardware;

  /// U-1（v3.1.5 审计）：本机是否已录入生物识别（`getAvailableBiometrics`
  /// 非空）。用于区分「生物识别 / 锁屏密码 / 两者皆可」三套文案，不再把
  /// 「有锁屏密码」的设备说成「使用生物识别解锁」。
  bool _hasEnrolledBiometrics = false;
  bool get hasEnrolledBiometrics => _hasEnrolledBiometrics;

  /// 兼容旧字段名：语义已修正为 [canAuthenticate]（「现在能验证身份」）。
  bool get biometricAvailable => _canAuthenticate;

  /// P1-1（v3.1.5 审计）：最近一次 [authenticate] 是否因「无处可验证」失败
  /// （`notAvailable` / `notEnrolled` / `passcodeNotSet` 等）。为 true 时解锁页
  /// 动态渲染关闭出口——即便启动探测曾误判，用户也不会被永久锁死。
  bool _authUnavailable = false;
  bool get authUnavailable => _authUnavailable;

  /// 解锁页是否应显示「无法验证？关闭应用锁」出口。
  bool get unlockEscapeVisible => !_canAuthenticate || _authUnavailable;

  /// 当前可用凭据的展示文案（设置页 / 解锁页共用，避免两处各写一份）。
  String get credentialLabel {
    if (!_canAuthenticate) return '无可用验证方式';
    return _hasEnrolledBiometrics ? '生物识别或锁屏密码' : '锁屏密码';
  }

  /// 无可用凭据时的原因文案。
  String get unavailableHint => _biometricHardware
      ? '本机有生物识别硬件，但尚未录入指纹 / 面容，也没有设置锁屏密码'
      : '本机未设置锁屏密码';

  /// U-3（v3.1.4 审计）：最近一次 [refreshEnabled] 是否把备份恢复来的
  /// 「应用锁已开启」强制关掉。恢复结果据此如实告知用户，不再静默降级。
  bool _lastRefreshForceDisabled = false;
  bool get lastRefreshForceDisabled => _lastRefreshForceDisabled;

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

  /// 启动期探测可用凭据：不抛错、安静降级（无可验证方式则开关不可用）。
  ///
  /// P1-1（v3.1.5 审计）：三个标志分工明确——
  /// - [hasBiometricHardware]（`canCheckBiometrics`）：仅文案用，**不作门槛**；
  /// - [canAuthenticate]（`isDeviceSupported`）：唯一门槛，等价「现在能验证」；
  /// - [hasEnrolledBiometrics]（`getAvailableBiometrics` 非空）：区分布局文案。
  /// 旧实现把硬件能力当门槛，是「可开启但必然验证失败」的自锁死路根因。
  Future<void> probeBiometric() async {
    var hardware = false;
    try {
      hardware = await _auth.canCheckBiometrics;
    } catch (e) {
      AppLog.d('[AppLock] 探测生物识别硬件失败（按无硬件处理）：$e');
    }
    var canAuth = false;
    try {
      canAuth = await _auth.isDeviceSupported();
    } catch (e) {
      AppLog.d('[AppLock] 探测设备凭据失败（按不可验证处理）：$e');
    }
    var enrolled = false;
    if (canAuth) {
      try {
        enrolled = (await _auth.getAvailableBiometrics()).isNotEmpty;
      } catch (e) {
        AppLog.d('[AppLock] 探测已录入生物识别失败（按未录入处理）：$e');
      }
    }
    _biometricHardware = hardware;
    _canAuthenticate = canAuth;
    _hasEnrolledBiometrics = enrolled;
    notifyListeners();
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_kEnabled) ?? false;
    await probeBiometric();
    // P1-1（v3.1.5 审计）：这里**不**因「探测不到可用凭据」而自动关闭应用锁。
    // 自动降级等于静默削弱用户已开启的安全设置；真实死路由解锁页的动态出口
    // （[unlockEscapeVisible]）兜底 —— 用户能自己看到原因、亲手关闭。
    // 只有恢复备份这条路径（[refreshEnabled]）才强制关闭，因为那是把别人的
    // 开关状态写进本机，必须过门槛。
    _locked = _enabled;
    notifyListeners();
  }

  /// 设置开关：开→关闭时立即解锁；关→开时若本机无可用凭据则拒绝并回 false。
  Future<bool> setEnabled(bool v) async {
    if (v && !_canAuthenticate) return false; // 无可用凭据，拒绝开启
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
  ///
  /// P2-3（v3.1.0 审计）：恢复路径补上与 [setEnabled] 同等的**凭据门槛**——
  /// 备份可携带 app_lock_enabled=true，恢复把它写进 prefs；若本机无可用凭据
  /// （未录入生物识别且无锁屏密码），下一次回前台就会锁死在解锁页（设置页
  /// 不可达）。这里检测到「开关为开但不可验证」时强制写回 false，与「启用必有
  /// 门槛」的启用校验一致；配合解锁页新增的「无法验证？关闭应用锁」出口（
  /// main AppLockGate，P1-1 v3.1.2 审计收窄：仅在真实死路渲染，且关闭前强制
  /// 一次 authenticate），两道防线共同消除不可解锁路径。
  /// P1-1（v3.1.5 审计）：门槛判定由 `canCheckBiometrics`（硬件）改为
  /// [canAuthenticate]（现在能验证），否则「有硬件未录入」的设备会被判为可用。
  Future<void> refreshEnabled() async {
    _lastRefreshForceDisabled = false;
    final prefs = await SharedPreferences.getInstance();
    var enabled = prefs.getBool(_kEnabled) ?? false;
    await probeBiometric();
    // P1-1（v3.1.5 审计）：门槛从「有生物识别硬件」改为「现在能验证身份」。
    if (enabled && !_canAuthenticate) {
      enabled = false;
      _lastRefreshForceDisabled = true;
      try {
        await prefs.setBool(_kEnabled, false);
      } catch (e) {
        AppLog.d('[AppLock] 恢复后强制关闭应用锁失败（内存仍按关闭处理）：$e');
      }
    }
    _enabled = enabled;
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
        // P1-1（v3.1.5 审计）：验证成功说明本机有可用凭据，撤销「不可验证」标记。
        _authUnavailable = false;
        // 记录解锁时刻，供 [onResumed] 的宽限期判断（竞态豁免 2）。
        _lastUnlockAt = DateTime.now();
      }
      notifyListeners();
      return ok;
    } catch (e) {
      AppLog.d('[AppLock] 验证异常：$e');
      // P1-1（v3.1.5 审计）：识别「本机无可用凭据」类失败，动态放出解锁页的
      // 关闭出口。旧实现只靠启动探测，探测一旦误判（有硬件但未录入）用户就
      // 再也没有出口；现在真实调用失败也能兜底。
      if (_isUnavailableError(e)) _authUnavailable = true;
      // 异常时不自动解锁（安全优先），返回 false 让 UI 维持锁定页。
      return false;
    } finally {
      _authenticating = false;
      // 状态可能已变（成功解锁 / 新增不可验证标记），通知监听方刷新。
      notifyListeners();
    }
  }

  /// P1-1（v3.1.5 审计）：「无处可验证」类平台错误码 / 文案的宽松判定。
  /// local_auth 各平台 / 版本对同一语义的命名不一（`NotAvailable` /
  /// `notEnrolled` / `noBiometrics` / `PasscodeNotSet` / `deviceCredentialsNotSet`），
  /// 这里统一小写后做包含匹配；无法判定时保守返回 false（不放宽安全边界）。
  static bool _isUnavailableError(Object e) {
    final text = e.toString().toLowerCase();
    for (final key in const [
      'notavailable',
      'not enrolled',
      'notenrolled',
      'nobiometric',
      'no biometric',
      'devicecredentialsnotset',
      'passcodenotset',
      'passcode not set',
      'devicenotsupported',
      'no_fragment_activity',
    ]) {
      if (text.contains(key)) return true;
    }
    return false;
  }
}
