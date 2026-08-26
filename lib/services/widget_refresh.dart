import 'package:flutter/services.dart';

/// 桌面小组件（今日任务列表）刷新桥接。
///
/// 在 [TaskProvider._persist] 末尾调用，经 MethodChannel 通知原生侧
/// [TodayWidgetProvider.refreshAll] 主动刷新所有已添加的桌面部件，使任务变更后即时反映，
/// 不必等系统 updatePeriodMillis 兜底。非 Android 平台或引擎未就绪时静默忽略。
const MethodChannel _channel = MethodChannel('com.example.todolist/widget_refresh');

/// 请求原生侧刷新桌面小组件。fire-and-forget，不阻塞持久化流程。
void requestWidgetRefresh() {
  try {
    _channel.invokeMethod<void>('refresh');
  } catch (_) {
    // 平台不支持 / 通道未注册时忽略，不影响主流程。
  }
}
