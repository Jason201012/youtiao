import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:todolist/state/app_lock_provider.dart';

/// 应用锁（A4）状态机单测。覆盖「启用门槛 / 冷启动锁定 / 关闭即解锁 / 未启用时放行」
/// 等纯逻辑；[authenticate] 的真实生物识别链路（P0-1 的 FlutterFragmentActivity 修复）
/// 无法在 headless 环境验证，需真机回归。
///
/// 设计约束：headless 下 local_auth 的 canCheckBiometrics 会抛 MissingPluginException，
/// [AppLockProvider.probeBiometric] 已 try/catch 静默降级为 biometricAvailable=false，
/// 因此本文件不依赖任何平台通道 mock 即可安全运行。
void _installMocks() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferencesStorePlatform.instance = InMemorySharedPreferencesStore.empty();
}

void main() {
  setUpAll(_installMocks);

  group('AppLockProvider 默认态与探测降级', () {
    test('未 load 的默认值：未启用 / 未锁 / 不支持生物识别', () {
      final p = AppLockProvider();
      expect(p.appLockEnabled, isFalse);
      expect(p.locked, isFalse);
      expect(p.biometricAvailable, isFalse);
    });

    test('load() 缺省不被锁，biometric 探测静默降级', () async {
      final p = AppLockProvider();
      await p.load();
      expect(p.appLockEnabled, isFalse);
      expect(p.locked, isFalse);
      expect(p.biometricAvailable, isFalse);
    });
  });

  group('启用门槛（防 P0-1 把用户锁死）', () {
    test('setEnabled(true) 设备不支持生物识别时拒绝，保持关闭', () async {
      final p = AppLockProvider();
      final ok = await p.setEnabled(true);
      expect(ok, isFalse);
      expect(p.appLockEnabled, isFalse);
    });
  });

  group('冷启动锁定 / 关闭解锁', () {
    test('load() 已启用则冷启动锁定，需验证才能进', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('app_lock_enabled', true);
      final p = AppLockProvider();
      await p.load();
      expect(p.appLockEnabled, isTrue);
      expect(p.locked, isTrue);
    });

    test('setEnabled(false) 即视为已解锁并落盘', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('app_lock_enabled', true);
      final p = AppLockProvider();
      await p.load();
      expect(p.locked, isTrue);
      final ok = await p.setEnabled(false);
      expect(ok, isTrue);
      expect(p.appLockEnabled, isFalse);
      expect(p.locked, isFalse);
    });
  });

  group('authenticate 门禁语义', () {
    test('未启用锁时直接放行，不调系统验证', () async {
      final p = AppLockProvider();
      final ok = await p.authenticate();
      expect(ok, isTrue);
      expect(p.locked, isFalse);
    });
  });
}
