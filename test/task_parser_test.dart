import 'package:flutter_test/flutter_test.dart';
import 'package:todolist/models/task.dart';
import 'package:todolist/services/task_parser.dart';

/// 固定时间基准：2026-08-09 10:00，**周日**（weekday = 7）。
/// 特意选周日，因为「下周三」在周日这天最容易算错整整一周。
final _base = DateTime(2026, 8, 9, 10, 0);

ParsedTask _p(String input) => TaskParser.parse(input, now: _base);

void main() {
  group('综合场景', () {
    test('设计稿示例：明天下午3点 交周报 !高 #工作', () {
      final r = _p('明天下午3点 交周报 !高 #工作');
      expect(r.title, '交周报');
      expect(r.dueDate, DateTime(2026, 8, 10, 15, 0));
      expect(r.priority, Priority.high);
      expect(r.category, Category.work);
      expect(r.tags, isEmpty); // 「工作」命中分类，不重复塞进标签
      expect(r.repeat, RepeatType.none);
      expect(r.isValid, isTrue);
      expect(r.hasStructuredInfo, isTrue);
    });

    test('纯标题：没有任何标记时原样返回', () {
      final r = _p('给妈妈打电话');
      expect(r.title, '给妈妈打电话');
      expect(r.dueDate, isNull);
      expect(r.priority, isNull);
      expect(r.category, isNull);
      expect(r.tags, isEmpty);
      expect(r.hasStructuredInfo, isFalse);
    });

    test('空输入：标题为空且不可用', () {
      expect(_p('').isValid, isFalse);
      expect(_p('   ').isValid, isFalse);
    });

    test('标题内多余空白被压缩', () {
      final r = _p('明天   整理    书桌');
      expect(r.title, '整理 书桌');
    });
  });

  group('日期', () {
    test('相对日：今天/明天/后天/大后天', () {
      expect(_p('今天 A').dueDate, DateTime(2026, 8, 9, 9, 0));
      expect(_p('明天 A').dueDate, DateTime(2026, 8, 10, 9, 0));
      expect(_p('后天 A').dueDate, DateTime(2026, 8, 11, 9, 0));
      expect(_p('大后天 A').dueDate, DateTime(2026, 8, 12, 9, 0));
    });

    test('N天后 / N周后', () {
      expect(_p('3天后 A').dueDate, DateTime(2026, 8, 12, 9, 0));
      expect(_p('2周后 A').dueDate, DateTime(2026, 8, 23, 9, 0));
    });

    test('裸写周X：取最近的那一个，今天即今天', () {
      // base 是周日(7)
      expect(_p('周三 A').dueDate, DateTime(2026, 8, 12, 9, 0));
      expect(_p('周日 A').dueDate, DateTime(2026, 8, 9, 9, 0));
      expect(_p('星期五 A').dueDate, DateTime(2026, 8, 14, 9, 0));
      expect(_p('礼拜一 A').dueDate, DateTime(2026, 8, 10, 9, 0));
    });

    test('下周X 按自然周算（周一为周首），不是简单加7天', () {
      // 本周一 = 8/3，下周一 = 8/10
      expect(_p('下周一 A').dueDate, DateTime(2026, 8, 10, 9, 0));
      expect(_p('下周三 A').dueDate, DateTime(2026, 8, 12, 9, 0));
      expect(_p('下下周三 A').dueDate, DateTime(2026, 8, 19, 9, 0));
      expect(_p('本周三 A').dueDate, DateTime(2026, 8, 5, 9, 0));
    });

    test('绝对日期：N月N日 / N月N号 / N/N', () {
      expect(_p('8月15日 A').dueDate, DateTime(2026, 8, 15, 9, 0));
      expect(_p('8月15号 A').dueDate, DateTime(2026, 8, 15, 9, 0));
      expect(_p('9/1 A').dueDate, DateTime(2026, 9, 1, 9, 0));
    });

    test('绝对日期今年已过则顺延到明年', () {
      expect(_p('1月1日 A').dueDate, DateTime(2027, 1, 1, 9, 0));
    });

    test('非法日期不解析，原文留在标题里', () {
      final r = _p('2月30日 A');
      expect(r.dueDate, isNull);
      expect(r.title, contains('2月30日'));
    });
  });

  group('时间', () {
    test('24 小时制 HH:mm', () {
      expect(_p('明天 15:30 A').dueDate, DateTime(2026, 8, 10, 15, 30));
    });

    test('N点 / N点半 / N点N分', () {
      expect(_p('明天 9点 A').dueDate, DateTime(2026, 8, 10, 9, 0));
      expect(_p('明天 9点半 A').dueDate, DateTime(2026, 8, 10, 9, 30));
      expect(_p('明天 9点45分 A').dueDate, DateTime(2026, 8, 10, 9, 45));
    });

    test('上下午修正 12 小时制', () {
      expect(_p('明天下午3点 A').dueDate, DateTime(2026, 8, 10, 15, 0));
      expect(_p('明天晚上8点 A').dueDate, DateTime(2026, 8, 10, 20, 0));
      expect(_p('明天上午9点 A').dueDate, DateTime(2026, 8, 10, 9, 0));
      expect(_p('明天中午12点 A').dueDate, DateTime(2026, 8, 10, 12, 0));
      expect(_p('明天凌晨2点 A').dueDate, DateTime(2026, 8, 10, 2, 0));
    });

    test('只有时段词时落到该时段代表时刻', () {
      expect(_p('明天下午 A').dueDate, DateTime(2026, 8, 10, 15, 0));
      expect(_p('明天晚上 A').dueDate, DateTime(2026, 8, 10, 20, 0));
    });

    test('只给时间不给日期：今天已过则顺延到明天', () {
      // base 是 10:00
      expect(_p('14点 A').dueDate, DateTime(2026, 8, 9, 14, 0)); // 今天还没到
      expect(_p('8点 A').dueDate, DateTime(2026, 8, 10, 8, 0)); // 今天已过 → 明天
    });

    test('无时间时默认落在早上 9 点', () {
      expect(_p('明天 A').dueDate, DateTime(2026, 8, 10, 9, 0));
    });
  });

  group('优先级', () {
    test('文字式', () {
      expect(_p('A !高').priority, Priority.high);
      expect(_p('A !急').priority, Priority.high);
      expect(_p('A !重要').priority, Priority.high);
      expect(_p('A !中').priority, Priority.medium);
      expect(_p('A !低').priority, Priority.low);
    });

    test('感叹号数量式：!!! 高 / !! 中', () {
      expect(_p('A !!!').priority, Priority.high);
      expect(_p('A !!').priority, Priority.medium);
    });

    test('单个裸感叹号不解析，避免误伤正常文案', () {
      final r = _p('终于写完了!');
      expect(r.priority, isNull);
      expect(r.title, '终于写完了!');
    });

    test('中文全角感叹号同样生效', () {
      expect(_p('A ！高').priority, Priority.high);
    });
  });

  group('标签与分类', () {
    test('多个标签', () {
      final r = _p('开会 #项目A #紧急');
      expect(r.title, '开会');
      expect(r.tags, ['项目A', '紧急']);
    });

    test('命中内置分类时设为 category 而非 tag', () {
      expect(_p('A #学习').category, Category.study);
      expect(_p('A #生活').category, Category.life);
      expect(_p('A #学习').tags, isEmpty);
    });

    test('第二个分类词退化为普通标签', () {
      final r = _p('A #工作 #生活');
      expect(r.category, Category.work);
      expect(r.tags, ['生活']);
    });

    test('标签不会吞掉后面的优先级标记', () {
      final r = _p('A #工作!高');
      expect(r.category, Category.work);
      expect(r.priority, Priority.high);
      expect(r.title, 'A');
    });
  });

  group('重复规则', () {
    test('每天', () {
      final r = _p('每天 喝水');
      expect(r.repeat, RepeatType.daily);
      expect(r.title, '喝水');
    });

    test('每工作日', () {
      expect(_p('每工作日 打卡').repeat, RepeatType.weekday);
    });

    test('每隔N天', () {
      final r = _p('每隔3天 浇花');
      expect(r.repeat, RepeatType.interval);
      expect(r.repeatInterval, 3);
      expect(r.title, '浇花');
    });

    test('每周一三五', () {
      final r = _p('每周一三五 健身');
      expect(r.repeat, RepeatType.weekly);
      expect(r.repeatWeekdays, [1, 3, 5]);
      expect(r.title, '健身');
    });

    test('「每周X」不会被「周X」日期规则截胡', () {
      final r = _p('每周三 例会');
      expect(r.repeat, RepeatType.weekly);
      expect(r.repeatWeekdays, [3]);
      expect(r.title, '例会');
    });

    test('重复任务没写日期时不再伪造「当天 23:59」的截止时间（F-4/F-5）', () {
      // 旧约定把 dueDate 复用为「重复窗口结束日」，制造了一串连带缺陷：
      // 创建次日即被判定「已过期」（提醒门槛失灵 / 每日重置失效）、
      // 改期副本被钉在 23:59、结束后掉进「逾期」分区。
      // 现在重复规则由 repeat / repeatMinute / repeatUntil 表达，
      // 截止时间留空（用户显式写了日期才会填）。
      expect(_p('每天 喝水').dueDate, isNull);
      expect(_p('每天 喝水').repeatMinute, isNotNull,
          reason: 'F-04：无时刻也应给默认提醒时刻，保证「每天」真的会响');
      // 显式写了时刻（但没写日期）时，截止时间仍按「最近一次该时刻」正常填充——
      // 去掉的只是「有重复规则就无条件补 23:59」这一条隐式约定。
      expect(_p('每天 早上7点 喝水').dueDate, isNotNull);
    });

    test('重复 + 时间 → 生成 repeatMinute', () {
      final r = _p('每天 晚上9点 复盘');
      expect(r.repeat, RepeatType.daily);
      expect(r.repeatMinute, 21 * 60);
      expect(r.title, '复盘');
    });
  });

  group('识别片段（供 UI 高亮）', () {
    test('片段按原串位置升序，且类型齐全', () {
      final r = _p('明天下午3点 交周报 !高 #工作');
      expect(r.segments.map((s) => s.kind).toList(), [
        TokenKind.date,
        TokenKind.time,
        TokenKind.priority,
        TokenKind.category,
      ]);
      for (var i = 1; i < r.segments.length; i++) {
        expect(r.segments[i].start, greaterThanOrEqualTo(r.segments[i - 1].end));
      }
    });

    test('片段带有可展示的规范化文案', () {
      final r = _p('明天下午3点 A');
      expect(r.segments.first.label, '明天');
      expect(r.segments[1].label, '15:00');
    });
  });

  group('toTask 映射', () {
    test('缺省优先级为中、分类为工作', () {
      final t = _p('随手记一笔').toTask();
      expect(t.title, '随手记一笔');
      expect(t.priority, Priority.medium);
      expect(t.category, Category.work);
      expect(t.dueDate, isNull);
      expect(t.repeat, RepeatType.none);
      expect(t.id, isEmpty); // 交给 TaskProvider 生成
    });

    test('完整字段透传', () {
      final t = _p('明天下午3点 交周报 !高 #工作 #紧急').toTask();
      expect(t.title, '交周报');
      expect(t.priority, Priority.high);
      expect(t.category, Category.work);
      expect(t.dueDate, DateTime(2026, 8, 10, 15, 0));
      expect(t.tags, ['紧急']);
    });

    test('每隔N天会带上锚点日（date-only）', () {
      final t = _p('每隔3天 浇花').toTask();
      expect(t.repeat, RepeatType.interval);
      expect(t.repeatInterval, 3);
      expect(t.repeatAnchor, DateTime(2026, 8, 9));
    });

    test('每周重复缺省至少落一个星期', () {
      final t = _p('每周 复盘').toTask();
      expect(t.repeat, RepeatType.weekly);
      expect(t.repeatWeekdays, isNotEmpty);
    });
  });

  group('P1-5 日期区间', () {
    test('周X~周X：起点落 startDate，终点落截止日', () {
      // 基准 2026-08-09 是周日：裸写「周日」= 今天，裸写「周五」= 最近的周五 = 08-14
      final r = _p('周五~周日 出差');
      expect(r.startDate, DateTime(2026, 8, 9));
      expect(r.dueDate, DateTime(2026, 8, 14, 9, 0));
      expect(r.title, '出差');
    });

    test('明天到后天：「到」作为区间连接词，且顺序颠倒时自动归位', () {
      final r = _p('后天到明天 出差');
      expect(r.startDate, DateTime(2026, 8, 10));
      expect(r.dueDate, DateTime(2026, 8, 11, 9, 0));
    });

    test('绝对日期区间：3月1日-3月5日（今年已过则顺延到明年）', () {
      final r = _p('3月1日-3月5日 出差');
      expect(r.startDate, DateTime(2027, 3, 1));
      expect(r.dueDate, DateTime(2027, 3, 5, 9, 0));
    });

    test('任一端无法解析时整体放弃，回退为普通单日期', () {
      final r = _p('周五~出差');
      expect(r.startDate, isNull);
      expect(r.dueDate, DateTime(2026, 8, 14, 9, 0)); // 退化为「周五」
    });
  });

  group('P1-5 预估时长', () {
    test('N分钟 / N小时 / N小时N分 / N min', () {
      expect(_p('看书 45分钟').estimateMinutes, 45);
      expect(_p('写方案 2小时').estimateMinutes, 120);
      expect(_p('开会 1小时30分').estimateMinutes, 90);
      expect(_p('跑步 30min').estimateMinutes, 30);
    });

    test('时长不误伤时间：下午3点30分 只认时间不认时长', () {
      final r = _p('下午3点30分 开会');
      expect(r.estimateMinutes, isNull);
      expect(r.dueDate, DateTime(2026, 8, 9, 15, 30));
    });

    test('裸写「N分」不解析（与时间点高度混淆，宁漏勿错）', () {
      expect(_p('看书 45分').estimateMinutes, isNull);
    });

    test('兜底：0 与超出 30 天的数值被丢弃', () {
      expect(_p('看书 0分钟').estimateMinutes, isNull);
      expect(_p('写书 9999小时').estimateMinutes, isNull);
    });

    test('时长被识别后从标题中剔除', () {
      expect(_p('看书 45分钟').title, '看书');
    });
  });

  group('P1-5 地点', () {
    test('@公司 解析为地点并从标题剔除', () {
      final r = _p('面试 @公司');
      expect(r.location, '公司');
      expect(r.title, '面试');
    });

    test('全角＠同样生效', () {
      expect(_p('面试 ＠公司').location, '公司');
    });

    test('地点与标签互不干扰', () {
      // 注意：「#工作」是预置分类词，会被识别为分类而非标签，故此处用非分类词
      final r = _p('面试 @公司 #紧急');
      expect(r.location, '公司');
      expect(r.tags, ['紧急']);
    });
  });

  group('P1-5 备注合成', () {
    test('仅地点', () {
      expect(_p('面试 @公司').toTask().note, '@公司');
    });

    test('仅时长（T1-1：改落结构化字段，不再写进备注）', () {
      final t = _p('看书 45分钟').toTask();
      // T1-1（v2.9.2 功能增强）改口径：预估时长此前没有模型字段可落，只能拼进备注
      // 充当「临时载体」；[Task.estimateMinutes] 落地后此处断言改为结构化字段，
      // 备注保持干净（否则详情页会出现「备注里的预计45分钟 + 结构化行」两份重复信息）。
      expect(t.estimateMinutes, 45);
      expect(t.note, '');
    });

    test('地点仍留备注，时长走字段（「 · 」不再拼接时长）', () {
      final t = _p('面试 @公司 45分钟').toTask();
      expect(t.note, '@公司');
      expect(t.estimateMinutes, 45);
    });

    test('无地点无时长时备注为空串（不污染既有数据）', () {
      expect(_p('买牛奶').toTask().note, '');
    });
  });

  group('P1-9 每月最后一天 / 倒数第 N 天', () {
    test('每月最后一天', () {
      final r = _p('每月最后一天 交房租');
      expect(r.repeat, RepeatType.monthly);
      expect(r.monthlyFromEnd, 1);
      expect(r.title, '交房租');
    });

    test('每月月底（同义写法）', () {
      expect(_p('每月月底 结算').monthlyFromEnd, 1);
    });

    test('倒数第 2 天：阿拉伯数字与中文数字均可', () {
      expect(_p('每月倒数第2天 盘点').monthlyFromEnd, 2);
      expect(_p('每月倒数第二天 盘点').monthlyFromEnd, 2);
    });

    test('倒数第 3 天', () {
      expect(_p('每月倒数第3天 对账').monthlyFromEnd, 3);
    });

    test('不误伤「每月最后一个周日」', () {
      final r = _p('每月最后一个周日 复盘');
      expect(r.monthlyFromEnd, 0);
      expect(r.monthlyWeekIndex, 5);
      expect(r.monthlyWeekday, 7);
    });

    test('不误伤「每月15号」', () {
      final r = _p('每月15号 交房租');
      expect(r.monthlyFromEnd, 0);
      expect(r.monthlyDay, 15);
    });

    test('落地到 Task 后 repeatsOn 生效', () {
      final t = _p('每月最后一天 交房租').toTask();
      expect(t.monthlyFromEnd, 1);
      expect(t.repeatsOn(DateTime(2026, 1, 31)), isTrue);
      expect(t.repeatsOn(DateTime(2026, 1, 30)), isFalse);
    });
  });

  group('提醒提前量边界（P2-3）', () {
    test('常规值原样解析', () {
      expect(_p('提前30分钟 A').reminderOffsetMin, 30);
      expect(_p('提前2小时 A').reminderOffsetMin, 120);
      expect(_p('到期前1天 A').reminderOffsetMin, 1440);
    });

    test('超大值收口到 1 年（525600 分钟），不崩、不下溢', () {
      expect(_p('提前100000天 A').reminderOffsetMin, 525600); // 天 ≤365
      expect(_p('提前999999999小时 A').reminderOffsetMin, 525600); // 小时 ≤8760
      expect(_p('提前999999999999999分钟 A').reminderOffsetMin, 525600); // 分 ≤525600
    });

    test('超出 int64 的数字串不抛 FormatException（tryParse 兜底）', () {
      // 20 位以上超出 int64：旧实现 int.parse 直接崩掉整条解析链。
      final r = _p('提前99999999999999999999999天 A');
      expect(r.isValid, isTrue); // 整体解析不崩
      expect(r.reminderOffsetMin, isNull); // 非法 token 被放弃
      expect(r.title, contains('A'));
    });
  });
}
