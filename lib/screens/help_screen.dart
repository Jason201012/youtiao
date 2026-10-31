import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/widgets/top_app_bar.dart';

/// 帮助与反馈页
/// - 常见问题（可展开的 FAQ，内容对齐 v2.8 真实交互）
/// - 联系我们（邮箱可点击复制 / 唤起邮件）
class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  static const _email = '2872536293@qq.com';

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final scheme = Theme.of(context).colorScheme;
    final onBg = scheme.onBackground;

    return Scaffold(
      backgroundColor: scheme.background,
      body: SafeArea(
        child: Column(
          children: [
            TopAppBar(
              title: '帮助与反馈',
              onBack: () => Navigator.of(context).maybePop(),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  AppColors.pagePadX,
                  8,
                  AppColors.pagePadX,
                  20,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _GroupTitle('开始使用'),
                    _FaqTile(
                      question: '如何新建任务？',
                      answer:
                          '在「首页」右下角点「＋」（快速录入）或用底部「＋」新建。'
                          '单行可直接写日期/时间，如「明天下午3点 交周报 !高 #工作」：'
                          '#标签、!优先级、时间、截止日期都能自动解析。'
                          '桌面端（Windows/Linux/macOS）还可按 Ctrl/Cmd + N 快速新建。',
                      initiallyExpanded: true,
                    ),
                    const SizedBox(height: AppColors.contentGap),
                    _FaqTile(
                      question: '如何完成任务 / 删除任务？',
                      answer:
                          '完成：点任务行左侧的圆圈即可打勾（重复任务按天记录完成）。\n'
                          '查看详情：点任务标题（整行文字区域）。\n'
                          '删除：在任务上长按进入多选 → 勾选后点顶部「删除」（可撤销）；'
                          '也可以对单条任务向左滑出「编辑」、向右滑出「删除」。\n'
                          '批量操作：多选后可统一改截止日期 / 优先级 / 分类 / 追加标签。',
                    ),
                    const SizedBox(height: AppColors.contentGap),
                    _FaqTile(
                      question: '提醒怎么设置，到点为什么没响？',
                      answer:
                          '建任务时设提醒时间即可；「设置 → 通知提醒」里可统一开关、改默认提醒。'
                          'ColorOS / Realme / 小米等系统还需在系统设置里允许「有条」通知，'
                          '并授予「闹钟与提醒 / 精确闹钟」权限、允许后台运行，否则到点可能不弹。'
                          '另外在「设置 → 勿扰时段」避开免打扰区间，提醒不会半夜打扰。',
                    ),
                    const SizedBox(height: 24),
                    _GroupTitle('进阶功能'),
                    _FaqTile(
                      question: '重复任务怎么用？',
                      answer:
                          '新建/编辑任务时选择「每天 / 每周 / 每月 / 仅工作日 / 每隔N天」。'
                          '每周可再勾选具体星期。任务行上带「重复」图标的，'
                          '点它可打开未来 30 天预览，逐次补打完成、跳过或顺延。\n'
                          // 顺手发现 #3（v3.1.1 功能增强报告）：原文案「也支持把任务
                          // 按农历（如每月初一）重复」与实现不符——农历目前只支持
                          // 「一次性日期换算」（B2 农历循环重复尚未实现），按原说明
                          // 操作会失败。改为如实描述。
                          '农历相关：快速录入支持「农历八月十五」这类一次性日期'
                          '（自动换算成今年的公历日）；农历的循环重复暂未支持。',
                    ),
                    const SizedBox(height: AppColors.contentGap),
                    _FaqTile(
                      question: '快速录入语法（单行解析）支持什么？',
                      answer:
                          '写在一行里即可自动拆解：\n'
                          '· 日期：今天/明天/后天/下周三/6月8日/2026-09-01/N天后\n'
                          '· 时刻：上午9点/下午3:30/15:00\n'
                          '· 优先级：!高 / !中 / !低（也可 !1 / !3）\n'
                          '· 标签：`#工作`（可多个）；地点：@公司（写进备注）\n'
                          '示例：「每周五 14:00 写周报 #工作 !高」——回车即建好并提醒。',
                    ),
                    const SizedBox(height: AppColors.contentGap),
                    _FaqTile(
                      question: '命令面板怎么打开？',
                      answer:
                          '各主界面顶栏都有命令图标（⌘）。点击后可输入页面名跳转，'
                          '或以「/」开头执行命令：/new 新建、/trash 回收站、/tags 标签管理、'
                          '/export 导出、/backup 备份、/done 完成勾选的任务。'
                          '桌面端也可按 Ctrl/Cmd + P。',
                    ),
                    const SizedBox(height: AppColors.contentGap),
                    // P3-1（v2.8.7 审计）：说明「提醒时区」的能力边界。
                    _FaqTile(
                      question: '「提醒时区」是什么？会影响任务日期吗？',
                      answer:
                          '设置 → 通知提醒 → 提醒时区：可把提醒固定为某个时区'
                          '（如常驻海外时仍按北京时间提醒），除常用清单外还支持'
                          '手动输入任意 IANA 时区名。\n'
                          '注意边界：它**只改变提醒的触发时刻**；任务的完成状态、'
                          '跨天重置与统计口径仍按设备本地日期计算。两者在时区差异'
                          '较大时可能出现「提醒已按北京时间响、但任务当日尚未重置」'
                          '的边界现象，属预期行为。',
                    ),
                    const SizedBox(height: AppColors.contentGap),
                    _FaqTile(
                      question: '专注 / 习惯 / 统计在哪？',
                      answer:
                          '底部导航分别是：首页 · 看板 · 日历 · 专注 · 习惯 · 设置。\n'
                          '· 专注：番茄钟/计时，可与任务绑定，结束后自动累计「已专注 X 分钟」。\n'
                          '· 习惯：每日打卡、热力图与连续天数；漏卡可在习惯详情里「补卡」。\n'
                          '· 看板/日历/统计：不同维度的进度与回顾，支持导出分享图片。',
                    ),
                    const SizedBox(height: 24),
                    _GroupTitle('数据安全'),
                    _FaqTile(
                      question: '数据存在哪里，怎么备份？',
                      answer:
                          '数据默认保存在本机（离线优先），不联网上传。'
                          '「设置 → 备份与恢复」可手动备份/恢复；「本地自动备份」每天自动留快照，'
                          '可选 AES-256-GCM 加密（口令存系统密钥库）。'
                          '备份文件可分享到微信/网盘留存；恢复时从备份文件导入即可。',
                    ),
                    const SizedBox(height: 24),
                    // 联系我们卡片（邮箱可点击：复制 / 唤起邮件客户端）
                    Container(
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surface,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Icon(Symbols.mail, size: 24, color: ext.meta),
                              const SizedBox(width: 12),
                              Text(
                                '联系我们',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w500,
                                  color: onBg,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          // U20：邮箱从「纯文本不可点」改为可点操作（复制 / 发邮件）。
                          InkWell(
                            borderRadius: BorderRadius.circular(8),
                            onTap: () async {
                              await Clipboard.setData(
                                  ClipboardData(text: _email));
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content: Text('邮箱已复制到剪贴板')),
                                );
                              }
                            },
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 6),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Flexible(
                                    child: Text(
                                      _email,
                                      style: TextStyle(
                                        fontSize: 14,
                                        color: ext.meta,
                                        decoration: TextDecoration.underline,
                                        decorationColor:
                                            ext.meta.withOpacity(0.5),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Icon(Symbols.content_copy,
                                      size: 14, color: ext.meta),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text('点邮箱可复制；建议附上问题描述与截图',
                              style:
                                  TextStyle(fontSize: 12, color: ext.meta)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GroupTitle extends StatelessWidget {
  final String text;
  const _GroupTitle(this.text);

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppColors.contentGap),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: ext.meta,
        ),
      ),
    );
  }
}

class _FaqTile extends StatelessWidget {
  final String question;
  final String answer;
  final bool initiallyExpanded;

  const _FaqTile({
    required this.question,
    required this.answer,
    this.initiallyExpanded = false,
  });

  @override
  Widget build(BuildContext context) {
    final ext = appColors(context);
    final onBg = Theme.of(context).colorScheme.onBackground;
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(
          dividerColor: Colors.transparent,
        ),
        child: ExpansionTile(
          initiallyExpanded: initiallyExpanded,
          tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          childrenPadding:
              const EdgeInsets.only(left: 16, right: 16, bottom: 16),
          expandedAlignment: Alignment.centerLeft,
          iconColor: ext.meta,
          collapsedIconColor: ext.meta,
          title: Text(
            question,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: onBg,
            ),
          ),
          children: [
            Text(
              answer,
              style: TextStyle(
                fontSize: 13,
                color: ext.meta,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
