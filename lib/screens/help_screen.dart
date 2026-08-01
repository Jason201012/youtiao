import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:todolist/theme/tokens.dart';
import 'package:todolist/theme/app_theme.dart';
import 'package:todolist/widgets/top_app_bar.dart';

/// 帮助与反馈页
/// - 常见问题（可展开的 FAQ）
/// - 联系我们（直接展示邮箱）
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
                    _GroupTitle('常见问题'),
                    _FaqTile(
                      question: '如何新建和完成任务？',
                      answer:
                          '点击底部「+」新建任务，填写标题、分类与提醒时间；勾选左侧圆圈即可标记完成，长按可删除。',
                      initiallyExpanded: true,
                    ),
                    const SizedBox(height: AppColors.contentGap),
                    _FaqTile(
                      question: '如何备份和恢复我的数据？',
                      answer:
                          '在「设置」→「备份与恢复」中点击备份，数据会保存在本地；更换设备时选择「恢复」即可还原。',
                    ),
                    const SizedBox(height: AppColors.contentGap),
                    _FaqTile(
                      question: '如何开启每日提醒？',
                      answer:
                          '创建任务时设置提醒时间，并确保「设置」→「通知提醒」已开启；ColorOS/Realme 等系统还需授予「精确闹钟」权限。',
                    ),
                    const SizedBox(height: 24),
                    // 联系我们卡片（图标+标题一行，邮箱在框内下方）
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
                          Text(
                            _email,
                            style: TextStyle(
                              fontSize: 14,
                              color: ext.meta,
                            ),
                          ),
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
