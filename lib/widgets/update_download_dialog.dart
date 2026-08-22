import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:todolist/services/apk_installer.dart';
import 'package:todolist/services/update_checker.dart';

/// 应用内下载并安装更新包：流式下载 APK 到外部缓存目录（updates/），
/// 实时显示进度，下载完成后经系统安装器安装。失败时提供「浏览器下载」兜底。
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
  String? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final url = widget.info.apkUrl ?? widget.info.releaseUrl;
    if (url == null) {
      setState(() => _error = '未找到可用的下载地址');
      return;
    }
    // 仅允许 https 直链，避免明文 http 被中间人劫持后下载恶意 APK。
    if (!url.startsWith('https://')) {
      setState(() => _error = '更新地址不安全（需 https）');
      return;
    }
    try {
      final cacheDirs = await getExternalCacheDirectories();
      final cacheDir = cacheDirs?.first;
      if (cacheDir == null) throw Exception('无法获取外部缓存目录');
      final apkFile =
          File('${cacheDir.path}/updates/app-release-v${widget.info.version}.apk');
      await apkFile.parent.create(recursive: true);

      final client = http.Client();
      final response = await client.send(http.Request('GET', Uri.parse(url)));
      if (response.statusCode != 200) {
        throw Exception('下载失败（HTTP ${response.statusCode}）');
      }
      final total = response.contentLength ?? 0;
      var received = 0;
      final sink = apkFile.openWrite();
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (mounted) {
          setState(() {
            _progress = total > 0 ? received / total : 0;
            _status = total > 0
                ? '下载中 ${(received / 1048576).toStringAsFixed(1)} / '
                    '${(total / 1048576).toStringAsFixed(1)} MB'
                : '下载中 ${(received / 1048576).toStringAsFixed(1)} MB';
          });
        }
      }
      await sink.close();
      client.close();

      // APK 完整性校验：若 update.json 提供了 apkSha256，则比对下载文件，
      // 不一致（篡改 / 下载不完整）直接拒绝安装，避免诱导安装恶意 APK。
      final expected = widget.info.apkSha256?.trim();
      if (expected != null && expected.isNotEmpty) {
        final bytes = await apkFile.readAsBytes();
        final actual = sha256.convert(bytes).toString();
        if (actual.toLowerCase() != expected.toLowerCase()) {
          if (!mounted) return;
          setState(() => _error = 'APK 校验失败：文件可能被篡改或下载不完整');
          return;
        }
      }

      if (!mounted) return;
      setState(() {
        _progress = 1;
        _status = '下载完成，正在唤起安装…';
      });
      await ApkInstaller.install(apkFile.path);
      if (mounted) setState(() => _done = true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Row(
        children: [
          Icon(Symbols.system_update_alt, size: 22),
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
              const Icon(Symbols.error_outline_rounded, size: 36, color: Colors.red),
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
              final url = widget.info.releaseUrl ?? widget.info.apkUrl;
              if (url != null) {
                final uri = Uri.parse(url);
                if (await canLaunchUrl(uri)) {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                }
              }
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
          const SizedBox.shrink(),
        ],
      ],
    );
  }
}
