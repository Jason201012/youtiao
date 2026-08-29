import 'package:flutter_test/flutter_test.dart';
import 'package:todolist/services/palette_command.dart';

void main() {
  group('PaletteCommand.parse 基本判定', () {
    test('不以斜杠开头 → 不是命令（退回关键字搜索）', () {
      expect(PaletteCommand.parse('首页'), isNull);
      expect(PaletteCommand.parse(''), isNull);
      expect(PaletteCommand.parse('  '), isNull);
    });

    test('仅一个斜杠仍算搜索，避免列表瞬间清空', () {
      expect(PaletteCommand.parse('/'), isNull);
      expect(PaletteCommand.parse('/   '), isNull);
    });

    test('斜杠后必须紧跟命令名', () {
      expect(PaletteCommand.parse('/today'), isNotNull);
      expect(PaletteCommand.parse('  /today  '), isNotNull);
    });
  });

  group('PaletteCommand 导航类命令', () {
    test('英文别名映射到正确 Tab', () {
      expect(PaletteCommand.parse('/today')!.gotoIndex, 0);
      expect(PaletteCommand.parse('/home')!.gotoIndex, 0);
      expect(PaletteCommand.parse('/board')!.gotoIndex, 1);
      expect(PaletteCommand.parse('/kanban')!.gotoIndex, 1);
      expect(PaletteCommand.parse('/calendar')!.gotoIndex, 2);
      expect(PaletteCommand.parse('/focus')!.gotoIndex, 3);
      expect(PaletteCommand.parse('/habit')!.gotoIndex, 4);
      expect(PaletteCommand.parse('/settings')!.gotoIndex, 5);
      expect(PaletteCommand.parse('/setting')!.gotoIndex, 5);
    });

    test('中文别名同样可用', () {
      expect(PaletteCommand.parse('/首页')!.gotoIndex, 0);
      expect(PaletteCommand.parse('/看板')!.gotoIndex, 1);
      expect(PaletteCommand.parse('/日历')!.gotoIndex, 2);
      expect(PaletteCommand.parse('/专注')!.gotoIndex, 3);
      expect(PaletteCommand.parse('/习惯')!.gotoIndex, 4);
      expect(PaletteCommand.parse('/设置')!.gotoIndex, 5);
    });

    test('命令名大小写不敏感', () {
      expect(PaletteCommand.parse('/FOCUS')!.gotoIndex, 3);
      expect(PaletteCommand.parse('/Board')!.gotoIndex, 1);
    });

    test('导航命令带参数不影响 Tab 判定', () {
      final c = PaletteCommand.parse('/today 明天')!;
      expect(c.gotoIndex, 0);
      expect(c.arg, '明天');
    });
  });

  group('PaletteCommand /done 动作类命令', () {
    test('识别为 done 而非导航', () {
      final c = PaletteCommand.parse('/done')!;
      expect(c.isDone, isTrue);
      expect(c.gotoIndex, isNull);
      expect(c.label, '完成选中项');
    });

    test('大写同样识别', () {
      expect(PaletteCommand.parse('/DONE')!.isDone, isTrue);
    });

    test('参数被解析出来但不会扩大作用范围（安全断言）', () {
      final c = PaletteCommand.parse('/done 全部')!;
      // 报告原文举例是 `/done 全部`，但本实现刻意忽略参数：
      // 「完成全库任务」是一次高危、难撤销的批量写操作，
      // 命令面板也没有列表上下文去界定「全部」到底指什么。
      expect(c.isDone, isTrue);
      expect(c.arg, '全部');
      expect(c.gotoIndex, isNull, reason: '参数不得把 done 变成别的语义');
    });
  });

  group('PaletteCommand 未知命令', () {
    test('未知命令被标记出来，供 UI 提示', () {
      final c = PaletteCommand.parse('/xyz')!;
      expect(c.isKnown, isFalse);
      expect(c.gotoIndex, isNull);
      expect(c.isDone, isFalse);
    });

    test('未知中文命令同样不误判', () {
      expect(PaletteCommand.parse('/删库')!.isKnown, isFalse);
    });
  });
}
