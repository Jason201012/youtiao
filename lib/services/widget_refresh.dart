import 'package:flutter/services.dart';

/// 桌面小组件（今日任务列表）刷新桥接。
///
/// 在 [TaskProvider._persist] 末尾调用，经 MethodChannel 通知原生侧
/// [TodayWidgetProvider.refreshAll] 主动刷新所有已添加的桌面部件，使任务变更后即时反映，
/// 不必等系统 updatePeriodMillis 兜底。非 Android 平台或引擎未就绪时静默忽略。
const MethodChannel _channel = MethodChannel('com.example.todolist/widget_refresh');

/// 请求原生侧刷新桌面小组件。fire-and-forget，不阻塞持久化流程。
void requestWidgetRefresh() {
  // S1 修复：MethodChannel.invokeMethod 返回的是 Future，在 flutter test、
  // iOS、Windows 等「通道未注册」平台上会**异步**以 MissingPluginException 失败。
  // 同步 try-catch 只能抓同步抛出，抓不到这个 rejected Future，会变成未处理
  // 异步错误导致测试失败（曾致 69 个用例失败）。必须用 .catchError 兜住异步错误。
  _channel.invokeMethod<void>('refresh').catchError((_) {});
}
