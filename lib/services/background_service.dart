import 'package:flutter/services.dart';

/// 与原生前台守护服务通信：start/stop 让 App 在后台常驻，
/// 从而划掉最近任务后定时提醒仍准时送达（ColorOS 等国产 ROM 必需）。
class BackgroundService {
  BackgroundService._();
  static final BackgroundService instance = BackgroundService._();

  static const MethodChannel _channel =
      MethodChannel('com.example.todolist/background_service');

  /// 拉起前台守护服务（进程常驻）。失败返回 false，不影响主流程。
  Future<bool> start() async {
    try {
      return await _channel.invokeMethod<bool>('start') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 停止前台守护服务。
  Future<bool> stop() async {
    try {
      return await _channel.invokeMethod<bool>('stop') ?? false;
    } catch (_) {
      return false;
    }
  }
}
