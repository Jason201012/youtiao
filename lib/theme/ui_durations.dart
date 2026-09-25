/// 全局「撤销窗口」时长的**单一真源**。
///
/// U3-5 / P3-10（v2.9.4 审计）：此前同一个「撤销」概念在 App 里有**两个时长**
/// ——任务删除 5 秒、习惯打卡 10 秒；而任务侧的时长又分别硬编码在两个
/// SnackBar 与两个确认框文案里（共四处字面量），改一处必漏三处。v2.9.1 就因为
/// 「确认框写『5 秒』、SnackBar 实际 4 秒」打过一次补丁，说明这类漂移会复发。
///
/// 现在把时长与其派生文案统一挂到本常量上：
/// - 取 **10 秒**（原习惯侧口径）：对「误触删除 / 误触清空」这类会造成
///   连续天数回退、记录丢失的后果，更长的后悔窗口成本更低；
/// - 所有撤销入口（任务删除、批量删除、跳过循环日、习惯取消打卡、清空今日、
///   跳过今日提醒）都读它，UI 不再自行决定窗口长度；
/// - 确认框文案用 [kUndoWindowSeconds] 插值，不再写死数字。
library;

/// 撤销窗口时长（10 秒）。
///
/// 刻意放在 `theme/` 下而非某个 screen：撤销横跨首页、任务详情、occurrence
/// 弹层、今日页、习惯页五处，若定义在 `home_screen.dart` 则其它页面要么
/// 反向 import 首页（循环依赖风险），要么各写一份——后者就是本轮要消灭的病根。
const Duration kUndoWindow = Duration(seconds: 10);

/// [kUndoWindow] 的秒数，供文案插值（「可在 10 秒内撤销」）。
///
/// 刻意写成字面量而非 `kUndoWindow.inSeconds`：`Duration.inSeconds` 不是
/// const 可求值的属性，const 上下文里访问会编译失败（const_eval_property_access）。
/// 两者同步由测试 `test/v295_audit_fix_test.dart` 的 U3-5 组断言守住
/// （`kUndoWindowSeconds == kUndoWindow.inSeconds`）。
const int kUndoWindowSeconds = 10;
