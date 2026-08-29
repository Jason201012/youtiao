/// 日历月视图的农历 / 节气 / 传统节日标注（P0-3，纯离线）。
///
/// v2.7.0 已支持「农历重复」与「农历八月十五」这类快速录入，但日历页本身不显示
/// 农历，用户设了农历任务却找不到对应的阳历位置——认知断层。这里补上展示层：
/// 全部由 `package:lunar`（纯 Dart、零联网）离线换算，不引入任何网络能力。
///
/// 设计取向：日历格子很小，只放一行小字，因此按「信息价值」排优先级——
/// 节气 ≈ 节日 > 农历月份锚点（初一） > 普通农历日名。
library;

import 'package:lunar/lunar.dart';

/// 某一天在日历格中显示的农历信息。
class LunarLabel {
  /// 显示的短文案；为空串表示该日无可展示内容（调用方应跳过渲染）。
  final String text;

  /// 是否为节气 / 节日（日历里用强调色渲染，便于一眼扫到）。
  final bool isFestival;

  const LunarLabel({required this.text, required this.isFestival});

  static const LunarLabel empty = LunarLabel(text: '', isFestival: false);
}

/// 计算 [day] 的农历标注。任何异常（越界日期、库内部抛错）都静默降级为
/// [LunarLabel.empty]——日历是纯展示层，绝不能因算不出农历而崩掉整页。
LunarLabel lunarLabelOf(DateTime day) {
  try {
    final lunar = Lunar.fromDate(day);

    // 1) 节气：清明 / 立夏 / 冬至 …（一年仅 24 天命中，信息价值最高）
    final jieqi = lunar.getJieQi();
    if (jieqi.isNotEmpty) {
      return LunarLabel(text: jieqi, isFestival: true);
    }
    // 2) 农历传统节日：春节 / 端午 / 中秋 / 除夕 …
    final lunarFestivals = lunar.getFestivals();
    if (lunarFestivals.isNotEmpty) {
      return LunarLabel(text: lunarFestivals.first, isFestival: true);
    }
    // 3) 阳历节日：元旦 / 劳动节 / 国庆 …
    final solarFestivals = Solar.fromDate(day).getFestivals();
    if (solarFestivals.isNotEmpty) {
      return LunarLabel(text: solarFestivals.first, isFestival: true);
    }
    // 4) 农历初一：改用月份作锚点（「初一」信息量低，「八月」能标出月份边界）
    if (lunar.getDay() == 1) {
      return LunarLabel(text: '${lunar.getMonthInChinese()}月', isFestival: false);
    }
    // 5) 其余按农历日名：初二 / 十五 / 廿三 / 三十
    return LunarLabel(text: lunar.getDayInChinese(), isFestival: false);
  } catch (_) {
    return LunarLabel.empty;
  }
}
