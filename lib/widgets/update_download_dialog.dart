import 'dart:io';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:todolist/services/apk_installer.dart';
import 'package:todolist/services/update_checker.dart';
import 'package:todolist/services/update_downloader.dart';
import 'package:todolist/services/update_policy.dart';

/// 应用内下载并安装更新包：流式下载 APK 到外部缓存目录（updates/），
/// 实时显示进度，下载完成后流式计算 sha256 校验完整性，再经系统安装器安装。
/// 失败时提供「浏览器下载」兜底。
///
/// 安全审计相关（L-01 / L-02 / L-03 / L-04 / L-10）：
/// - 落盘文件名固定为 `updates/update.apk`，**不使用清单里的 version 拼接**（防路径穿越）；
/// - 下载全程由 [UpdateDownloader] 负责：URL 首跳前缀白名单 + 逐跳重定向主机校验
///   + 200MB 体积熔断 + 失败即清理半成品；
/// - 底部「浏览器下载」外跳前，releaseUrl 必须过 [UpdatePolicy.isAllowedReleaseUrl]。
class UpdateDownloadDialog {
  static Future<void> show(BuildContext context, UpdateInfo info) async {
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _DownloadBody(info: info),
    );
  }
}

class _DownloadBody extends StatefulWidget {
  final UpdateInfo info;
  const _DownloadBody({required this.info});

  @override
  State<_DownloadBody> createState() => _DownloadBodyState();
}

class _DownloadBodyState extends State<_DownloadBody> {
  double _progress = 0;
  String _status = '准备下载…';
  bool _done = false;
  bool _cancelled = false;
  String? _error;
  UpdateDownloader? _downloader;
  File? _apkFile;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _downloader?.cancel();
    super.dispose();
  }

  /// 取消下载：中断连接并退出下载循环（半成品由 [UpdateDownloader] 的 finally 删除）。
  Future<void> _cancel() async {
    if (_done || _error != null || _cancelled) return;
    _cancelled = true;
    _downloader?.cancel();
    if (mounted) Navigator.pop(context);
  }

  /// 删除已下载的 APK（用户选择「稍后」时避免长期占用缓存）。
  Future<void> _deleteApkQuietly() async {
    final f = _apkFile;
    if (f == null) return;
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  Future<void> _start() async {
    final url = widget.info.apkUrl;
    if (url == null) {
      setState(() => _error = '更新清单未提供可用的下载地址');
      return;
    }
    try {
      final cacheDirs = await getExternalCacheDirectories();
      final cacheDir = cacheDirs?.first;
      if (cacheDir == null) throw Exception('无法获取外部缓存目录');
      // L-01：文件名固定，不掺入清单里的任何外部输入。
      // 旧实现拼 `app-release-v${version}.apk`，而 version 未做格式校验，
      // 取 `../../../files/x` 即可在应用沙箱目录树内任意落文件。
      final apkFile = File('${cacheDir.path}/updates/update.apk');
      _apkFile = apkFile;

      final downloader = UpdateDownloader();
      _downloader = downloader;
      // 下载器内部完成：URL 白名单 → 逐跳重定向校验 → 200MB 熔断 → 流式 sha256。
      final actual = await downloader.download(
        url: url,
        target: apkFile,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _progress = total > 0 ? received / total : 0;
            _status = total > 0
                ? '下载中 ${(received / 1048576).toStringAsFixed(1)} / '
                    '${(total / 1048576).toStringAsFixed(1)} MB'
                : '下载中 ${(received / 1048576).toStringAsFixed(1)} MB';
          });
        },
      );
      _downloader = null;

      // S3 修复①：完整性校验强制化。
      // P2-7（v2.9.1 审计）：清单**未提供** apkSha256 时不再提供「仍要安装（风险自担）」
      // 兜底——那是把完整性校验降级成一句免责声明。当前所有正式清单都由发版脚本
      // （_finalize_*.py）写入 apkSha256，缺失只可能意味着清单被删字段 / 降级到
      // 未签名旧清单；此时一律拒绝下载并清理半成品，改由「浏览器下载」兜底
      // （releaseUrl 已过白名单，且用户能自行核对发布页）。
      final expected = widget.info.apkSha256?.trim();
      if (expected == null || expected.isEmpty) {
        await _deleteApkQuietly();
        if (!mounted) return;
        setState(() =>
            _error = '更新清单缺少 SHA-256 校验值，无法验证安装包完整性（已拒绝）');
        return;
      }
      if (actual.toLowerCase() != expected.toLowerCase()) {
        // 校验不通过的半成品必须立即删除，避免被其它途径利用（L-10）。
        await _deleteApkQuietly();
        if (!mounted) return;
        setState(() => _error = 'APK 校验失败：文件可能被篡改或下载不完整');
        return;
      }

      if (!mounted) return;
      // S8 修复①：校验通过后再征求用户确认，避免静默唤起安装器。
      final proceed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('校验通过'),
          content: const Text('APK 已下载并通过 SHA-256 完整性校验，是否立即安装？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('稍后'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('立即安装'),
            ),
          ],
        ),
      );
      if (proceed != true) {
        // 用户选择稍后：不留残片，下次重新下载（L-10）。
        await _deleteApkQuietly();
        if (mounted) Navigator.pop(context);
        return;
      }

      await ApkInstaller.install(apkFile.path);
      if (mounted) setState(() => _done = true);
    } on ApkDownloadCancelledException {
      // 用户取消：半成品已由下载器清理，直接退出，不展示错误。
      return;
    } on ApkDownloadException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// L-04：外跳前校验下载地址。清单里的 releaseUrl 属于不可信输入，
  /// 不校验就可能把用户引到钓鱼页（更新弹窗是高信任场景，用户不会怀疑其中链接）。
  Future<void> _openReleasePage() async {
    final url = widget.info.releaseUrl;
    if (url == null || !UpdatePolicy.isAllowedReleaseUrl(url)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('下载页地址异常，已阻止跳转')),
      );
      return;
    }
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Symbols.system_update_alt, size: 22),
          const SizedBox(width: 8),
          const Expanded(child: Text('更新中')),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_error == null) ...[
              LinearProgressIndicator(value: _progress > 0 ? _progress : null),
              const SizedBox(height: 12),
              Text(_status, style: theme.textTheme.bodySmall),
            ] else ...[
              // U3-6（v2.9.6 审计）：`Colors.red` → `colorScheme.error`。
              Icon(Symbols.error_outline_rounded,
                  size: 36, color: Theme.of(context).colorScheme.error),
              const SizedBox(height: 8),
              Text('下载或安装失败：\n$_error', style: theme.textTheme.bodySmall),
              const SizedBox(height: 6),
              const Text('可改用浏览器下载安装。', style: TextStyle(fontSize: 12)),
            ],
          ],
        ),
      ),
      actions: [
        if (_error != null) ...[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
          FilledButton(
            onPressed: () async {
              await _openReleasePage();
              if (mounted) Navigator.pop(context);
            },
            child: const Text('浏览器下载'),
          ),
        ] else if (_done) ...[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('完成'),
          ),
        ] else ...[
          // S8 修复③：下载进行中提供「取消下载」按钮，弱网下不再被锁死在进度框里。
          TextButton(
            onPressed: _cancel,
            child: const Text('取消下载'),
          ),
        ],
      ],
    );
  }
}
