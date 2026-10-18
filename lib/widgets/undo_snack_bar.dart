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
/// 4. **P2-1 · 「已结束」提示滞后入队、指代不清**（v2.9.6 审计）：提示条是 FIFO
///    队列，A 超时后补的「窗口已结束」会排在 B 之后——用户看到提示时屏幕上
///    却是 B 的横幅。现在超时后先看队列里是否还有后继条在展示，有则**跳过**
///    本条（最后一条超时时队列已空，其提示即代表「全部窗口已结束」），且
///    默认文案从 [content] 剥出操作描述，提示明确绑定到具体动作。
/// 5. **P2-2 · 撤销缓冲失效静默 no-op**（v2.9.6 审计）：[onUndo] 此前是
///    `VoidCallback`，缓冲被清（彻底删除 / 清空回收站 / 恢复备份）后点「撤销」
///    毫无反应。现在 [UndoAction] 返回是否成功，失败时明确提示「撤销已失效」，
///    与习惯侧「撤销已失效」口径一致。
///
/// 三者共性是「同一个语义散落多处、逐个点名补」，故收成单一包装。
///
/// ## 口径（与习惯侧 `showCheckInUndoSnackBar` 完全一致）
///
/// - **不**调 `hideCurrentSnackBar()` / `clearSnackBars()`：`ScaffoldMessenger`
///   自带队列（后一条排在前一条播完之后），主动清场等于亲手丢掉上一条撤销机会。
/// - 窗口 = [kUndoWindow]，文案秒数用 [kUndoWindowSeconds] 插值，不写死数字。
/// - 超时且用户未点撤销、且队列无后继条时，补一句绑定操作描述的「已结束」。
library;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/material.dart';
import 'package:todolist/theme/ui_durations.dart';

/// 撤销动作契约：返回 true = 撤销已生效；false = 缓冲已失效 / 无可恢复之物。
///
/// P2-2（v2.9.6 审计）：此前 `VoidCallback` 无返回值，provider 层
/// 「快照找不到 → 静默 return」的失效路径传不到 UI，横幅承诺「可撤销」
/// 用户点了却毫无反应。抛出的异常按失败处理（一律不向上传播）。
typedef UndoAction = Future<bool> Function();

/// 失败提示上挂的动作（P2-1，v3.0.7 审计：给「请重试」一个可点的载体）。
typedef UndoFailureAction = ({String label, VoidCallback onPressed});

/// 展示一条带撤销的底部提示。
///
/// [onUndo] 为 null 时只展示提示（无 action 按钮、不做超时追加提示）。
/// [content] 里**不要**自己写「N 秒内可撤销」——统一用 [undoContent] 拼装，
/// 避免又一处硬编码秒数。
///
/// [expiredHint] 为超时后的追加提示文案；缺省时自动从 [content] 剥出操作
/// 描述（undoContent 的固定后缀）拼装为「已删除「X」：撤销窗口已结束」，
/// 使提示与具体操作绑定（P2-1）。
///
/// [failureHint] 为撤销失效（onUndo 返回 false / 抛错）时的提示文案；缺省 =
/// 统一口径「撤销已失效：该操作已不可恢复」。习惯打卡侧传入带细节的文案
/// （新P3-2，v2.9.7 审计：委托唯一实现的同时保留「已被再次修改」的语义）。
///
/// [failureAction] 为失败提示上挂的可选动作（P2-1，v3.0.7 审计）——撤销
/// action 一经点按、横幅即被框架关闭，快照只存在于闭包内，「请重试」四个字
/// 在没有载体时是虚假承诺（习惯删除撤销实测：横幅一关快照与重试入口一同
/// 销毁）。传了本参数时失败提示带按钮，点击回调由调用方提供（如重新调一次
/// `restoreHabit`），提示时长同步放宽到 [kUndoWindowSeconds] 秒，给用户
/// 足够的反应时间。返回 false 的两种成因（真失效 / 落盘失败但内存已生效）
/// 由调用方在 onUndo 内自行分支，本参数只负责「有按钮可点」。
///
/// 返回该提示的控制器，便于调用方在需要时（如页面销毁）主动收起。

/// P2-1（v2.9.6 审计）：每个 [ScaffoldMessengerState] 上**活跃**的撤销横幅计数。
///
/// `ScaffoldMessengerState` 不公开 SnackBar 队列（`currentSnackBar` 是内部
/// 成员），无法直接查询「是否还有后继条在展示」。这里用 Expando 按 messenger
/// 实例记账：入队 +1、`closed` 触发 −1。Expando 不持强引用，messenger 销毁
/// 后条目自动可回收；测试中每个 MaterialApp 都是新的 messenger 实例，天然
/// 隔离，不串用例。
final Expando<int> _activeUndoSnacks = Expando<int>();

int _bumpActiveUndoSnacks(ScaffoldMessengerState m, int delta) {
  final next = (_activeUndoSnacks[m] ?? 0) + delta;
  _activeUndoSnacks[m] = next < 0 ? 0 : next;
  return _activeUndoSnacks[m]!;
}

ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showUndoSnackBar(
  BuildContext context, {
  required String content,
  UndoAction? onUndo,
  String? expiredHint,
  String? failureHint,
  UndoFailureAction? failureAction,
}) {
  final messenger = ScaffoldMessenger.of(context);
  var undoPressed = false;
  // 新P3-1（v2.9.7 审计）：计数不变式 = 「在途的撤销横幅数」。无 action 的
  // 提示没有撤销窗口、也不会注册 `closed` 减计数，此前无条件 `+1` 会永久
  // 泄漏，导致该 messenger 上后续所有「窗口已结束」提示被 `> 0` 判据跳过。
  // 计数 `+1` 必须与 `closed.then` 里的 `−1` 同在 `onUndo != null` 分支。
  if (onUndo != null) _bumpActiveUndoSnacks(messenger, 1);
  final controller = messenger.showSnackBar(
    SnackBar(
      content: Text(content),
      // P3-4：时长读全局单一真源。
      duration: kUndoWindow,
      action: onUndo == null
          ? null
          : SnackBarAction(
              label: '撤销',
              onPressed: () async {
                undoPressed = true;
                bool ok;
                try {
                  ok = await onUndo();
                } catch (_) {
                  ok = false; // provider 抛错同样按「未生效」反馈，不静默。
                }
                // P2-2：缓冲失效（快照已被彻底删除 / 清空回收站 / 恢复备份
                // 作废）时明确反馈；[failureHint] 允许调用方替换为带细节的
                // 文案（见新P3-2 注）。
                if (!ok) {
                  messenger.showSnackBar(
                    SnackBar(
                      content: Text(
                        failureHint ?? '撤销已失效：该操作已不可恢复',
                      ),
                      // P2-1（v3.0.7 审计）：挂了重试动作时把时长放宽到撤销
                      // 窗口同量级——2 秒不够用户读完并点按，载体形同虚设。
                      duration: failureAction == null
                          ? const Duration(seconds: 2)
                          : Duration(seconds: kUndoWindowSeconds),
                      action: failureAction == null
                          ? null
                          : SnackBarAction(
                              label: failureAction.label,
                              onPressed: failureAction.onPressed,
                            ),
                    ),
                  );
                }
              },
            ),
    ),
  );
  // P3-5：超时收起不等于「用户看到了」，补一句明确反馈。
  //
  // `closed` 不是 [SnackBar] 的构造参数——它是 [ScaffoldMessenger.showSnackBar]
  // 返回的 [ScaffoldFeatureController.closed]。只在「超时」且「用户没点撤销」时追加。
  if (onUndo != null) {
    controller.closed.then((reason) async {
      _bumpActiveUndoSnacks(messenger, -1); // 自己已收起，先记账
      if (undoPressed || reason != SnackBarClosedReason.timeout) return;
      // P2-1：超时收起与下一条展示发生在收起动画完成的那一小段里，
      // 立即判断可能还看不到后继条的状态变化，等一拍再判断。
      await Future<void>.delayed(const Duration(milliseconds: 120));
      if (undoPressed) return; // 收起瞬间用户恰好点了撤销
      // P2-1：仍有活跃撤销条（后继条在队列/展示中）时**跳过**本条提示——
      // 排到后面只会指代错位（「A 已结束」显示时屏幕上是 B 的横幅）。连续
      // 多条撤销的场景下，最后一条超时后计数归零，它的提示即代表
      // 「全部窗口已结束」。
      if ((_activeUndoSnacks[messenger] ?? 0) > 0) return;
      // 注意：此处**不能**再对第 2 条调 hide/close——直接入队即可。
      messenger.showSnackBar(
        SnackBar(
          content: Text(expiredHint ?? expiredHintFromContent(content)),
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

/// 从 [undoContent] 拼出的文案中剥出操作描述，生成绑定该操作的「已结束」提示。
///
/// 例：`已删除「买牛奶」（10 秒内可撤销）` → `已删除「买牛奶」：撤销窗口已结束`。
/// [content] 不带固定后缀（调用方自己拼的文案）时退回通用文案。
///
/// P3-16（v2.9.6 审计）：公开为 `@visibleForTesting`——「文案与操作描述绑定」
/// 是 P2-1 的核心行为之一，纯 Dart 即可钉死；完整的超时链路（Timer → 收起动画
/// → closed → 120ms 判定 → hint 入队）横跨多次帧调度停止点，在 FakeAsync 下
/// 无法稳定驱动，不作为 widget 回归对象（与 v2.9.6 轮「撤销机制重构零覆盖」
/// 的补课策略一致：可稳定钉住的契约落测试，链路行为靠本文件的实现注释）。
@visibleForTesting
String expiredHintFromContent(String content) {
  final m = RegExp('（$kUndoWindowSeconds 秒内可撤销）\$').firstMatch(content);
  if (m == null) return '撤销窗口已结束';
  return '${content.substring(0, m.start)}：撤销窗口已结束';
}

/// P2-1（v2.9.6 审计）：[messenger] 上当前活跃的撤销横幅数（skip 判据的输入）。
///
/// 仅测试可见：`> 0` 表示有后继撤销条仍在队列/展示中，本条超时提示应跳过；
/// `== 0` 表示本条是最后一条，其超时提示代表「全部窗口已结束」。
@visibleForTesting
int debugActiveUndoSnackCount(ScaffoldMessengerState messenger) =>
    _activeUndoSnacks[messenger] ?? 0;

/// 拼装带秒数的撤销文案（单一真源，避免各处硬编码「10 秒」）。
///
/// [prefix] 为操作描述，如 `已删除「买牛奶」`。输出
/// `已删除「买牛奶」（10 秒内可撤销）`。
String undoContent(String prefix) => '$prefix（$kUndoWindowSeconds 秒内可撤销）';
