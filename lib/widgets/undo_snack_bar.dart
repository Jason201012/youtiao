/// 「撤销」提示条的**唯一**实现（P3-4 / P3-5 / P2-4，v2.9.5 审计）。
///
/// ## 为什么要有这个文件
///
/// 历轮审计反复命中同一族缺陷，本轮一次性收口：
///
/// 1. **P3-4 / U3-1 · 窗口时长散落**：撤销窗口的真源是
///    `theme/ui_durations.dart` 的 [kUndoWindow]，但仍有 3 处入口（批量编辑、
///    逾期顺延、删专注记录）各自写死 4 秒或干脆不设 `duration`（落到框架默认
///    4 秒）。用户按「删除」的 10 秒经验去点，常常已经过期。
/// 2. **P2-4 · 残留兜底定时器误关后一条**：v2.9.5 已把 `clearSnackBars()` 换成
///    队列化，但仍在每条撤销上挂了 `Future.delayed(kUndoWindow, controller.close)`。
///    `ScaffoldFeatureController.close` 的语义是「**当前必须是队首**」，于是
///    第 1 条的兜底定时器到点时会把当时正在展示的第 2 条一起收起——debug 下触发
///    `assert(_snackBars.first == controller)`，release 下**静默截断**别人的撤销窗口。
///    `duration: kUndoWindow` 本身已足够，此定时器纯属有害。
/// 3. **P3-5 · 撤销窗口结束无提示**：`ScaffoldMessenger` 超时收起时不会告知用户，
///    10 秒后点空气却毫无反馈。习惯侧（`habit_screen.dart` 的
///    `showCheckInUndoSnackBar`）此前已单独补了这句话，任务侧全部入口都没有。
///
/// 三者共性是「同一个语义散落多处、逐个点名补」，故收成单一包装。
///
/// ## 口径（与习惯侧 `showCheckInUndoSnackBar` 完全一致）
///
/// - **不**调 `hideCurrentSnackBar()` / `clearSnackBars()`：`ScaffoldMessenger`
///   自带队列（后一条排在前一条播完之后），主动清场等于亲手丢掉上一条撤销机会。
/// - 窗口 = [kUndoWindow]，文案秒数用 [kUndoWindowSeconds] 插值，不写死数字。
/// - 超时且用户未点撤销时，补一句「撤销窗口已结束」。
library;

import 'package:flutter/material.dart';
import 'package:todolist/theme/ui_durations.dart';

/// 展示一条带撤销的底部提示。
///
/// [onUndo] 为 null 时只展示提示（无 action 按钮、不做超时追加提示）。
/// [content] 里**不要**自己写「N 秒内可撤销」——统一用 [undoContent] 拼装，
/// 避免又一处硬编码秒数。
///
/// 返回该提示的控制器，便于调用方在需要时（如页面销毁）主动收起。
ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showUndoSnackBar(
  BuildContext context, {
  required String content,
  VoidCallback? onUndo,
  String? expiredHint,
}) {
  final messenger = ScaffoldMessenger.of(context);
  var undone = false;
  final controller = messenger.showSnackBar(
    SnackBar(
      content: Text(content),
      // P3-4：时长读全局单一真源。
      duration: kUndoWindow,
      action: onUndo == null
          ? null
          : SnackBarAction(
              label: '撤销',
              onPressed: () {
                undone = true;
                onUndo();
              },
            ),
    ),
  );
  // P3-5：超时收起不等于「用户看到了」，补一句明确反馈。
  //
  // `closed` 不是 [SnackBar] 的构造参数——它是 [ScaffoldMessenger.showSnackBar]
  // 返回的 [ScaffoldFeatureController.closed]。只在「超时」且「用户没点撤销」时追加。
  if (onUndo != null) {
    controller.closed.then((reason) {
      if (undone || reason != SnackBarClosedReason.timeout) return;
      // 注意：此处**不能**再对第 2 条调 hide/close——直接入队即可。
      messenger.showSnackBar(
        SnackBar(
          content: Text(expiredHint ?? '撤销窗口已结束'),
          duration: const Duration(seconds: 2),
        ),
      );
    });
  }
  // P2-4：刻意**不**挂 `Future.delayed(kUndoWindow, controller.close)`。
  // `duration` 已负责收起；而 `close()` 要求「自己当前在队首」，对队列中的
  // 旧条目调用会误关新条目（debug 断言失败 / release 静默截断撤销窗口）。
  return controller;
}

/// 拼装带秒数的撤销文案（单一真源，避免各处硬编码「10 秒」）。
///
/// [prefix] 为操作描述，如 `已删除「买牛奶」`。输出
/// `已删除「买牛奶」（10 秒内可撤销）`。
String undoContent(String prefix) => '$prefix（$kUndoWindowSeconds 秒内可撤销）';
