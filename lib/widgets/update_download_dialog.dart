import 'dart:convert';
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
/// 实时显示进度，下载完成后流式计算 sha256 校验完整性，再经系统安装器安装。
/// 失败时提供「浏览器下载」兜底。
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
  http.Client? _client;
  IOSink? _sink;
  File? _apkFile;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _client?.close();
    super.dispose();
  }

  /// 取消下载：关闭连接并退出下载循环（循环会在 catch 中统一清理不完整文件）。
  Future<void> _cancel() async {
    if (_done || _error != null || _cancelled) return;
    _cancelled = true;
    _client?.close(); // 终止下载流，循环会捕获异常后退出
    if (mounted) Navigator.pop(context);
  }

  /// S3 修复②：APK 下载地址域名白名单。仅允许官方托管域名，降低清单被投毒后
  /// 指向任意 https 地址下发恶意 APK 的风险。如需放开到自有域，在此列表追加 host。
  static bool _isAllowedApkHost(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    const allowed = {
      'gitee.com',
      'github.com',
      'raw.githubusercontent.com',
    };
    final host = uri.host.toLowerCase();
    return host.isNotEmpty && allowed.contains(host);
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
    // S3 修复②：下载地址域名白名单，仅允许官方托管域名，防止清单被投毒
    // （Gitee 账号被盗 / 协作仓库被改）后指向任意 https 地址下发恶意 APK。
    if (!_isAllowedApkHost(url)) {
      setState(() => _error = '下载地址域名不在允许列表（仅限 gitee.com / github.com），已拒绝安装');
      return;
    }
    try {
      final cacheDirs = await getExternalCacheDirectories();
      final cacheDir = cacheDirs?.first;
      if (cacheDir == null) throw Exception('无法获取外部缓存目录');
      final apkFile =
          File('${cacheDir.path}/updates/app-release-v${widget.info.version}.apk');
      await apkFile.parent.create(recursive: true);
      _apkFile = apkFile;

      final client = http.Client();
      _client = client;
      final response = await client.send(http.Request('GET', Uri.parse(url)));
      if (response.statusCode != 200) {
        throw Exception('下载失败（HTTP ${response.statusCode}）');
      }
      final total = response.contentLength ?? 0;
      var received = 0;
      final sink = apkFile.openWrite();
      _sink = sink;
      // S8 修复②：流式分块计算 sha256，避免把约 85MB 的 APK 整体读入内存（低内存机型 OOM 风险）。
      Digest? digest;
      final hashSink = sha256.startChunkedConversion(
        ChunkedConversionSink<Digest>.withCallback((d) => digest = d.single),
      );
      await for (final chunk in response.stream) {
        if (_cancelled) return; // 取消分支在 catch 中统一清理
        sink.add(chunk);
        hashSink.add(chunk);
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
      hashSink.close();
      await sink.close();
      _client = null;
      _sink = null;

      // S3 修复①：完整性校验强制化。
      // - 清单提供了 apkSha256：比对下载文件，不一致（篡改/下载不完整）直接拒绝安装；
      // - 清单**未**提供 apkSha256：绝不谎称"校验通过"，改为明确要求用户
      //   二次确认（风险自担）后才允许安装。
      final expected = widget.info.apkSha256?.trim();
      final bool verified;
      final String verifyTitle;
      final String verifyBody;
      if (expected != null && expected.isNotEmpty) {
        final actual = (digest ?? sha256.convert(const <int>[])).toString();
        if (actual.toLowerCase() != expected.toLowerCase()) {
          if (!mounted) return;
          setState(() => _error = 'APK 校验失败：文件可能被篡改或下载不完整');
          return;
        }
        verified = true;
        verifyTitle = '校验通过';
        verifyBody = 'APK 已下载并通过 SHA-256 完整性校验，是否立即安装？';
      } else {
        // 清单缺省校验值：任何"校验通过"的措辞都属误导，必须如实告知并二次确认。
        verified = false;
        verifyTitle = '未校验完整性';
        verifyBody =
            '本次更新清单未提供 SHA-256 校验值，无法验证来源完整性。是否仍要安装（风险自担）？';
      }

      if (!mounted) return;
      // S8 修复①：校验（或明确告知未校验）后再征求用户确认，避免静默唤起安装器。
      final proceed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: Text(verifyTitle),
          content: Text(verifyBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('稍后'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(verified ? '立即安装' : '仍要安装'),
            ),
          ],
        ),
      );
      if (proceed != true) {
        if (mounted) Navigator.pop(context);
        return;
      }

      await ApkInstaller.install(apkFile.path);
      if (mounted) setState(() => _done = true);
    } catch (e) {
      if (_cancelled) {
        // S8 修复③：取消时清理不完整文件后退出，不报错。
        try {
          await _sink?.close();
        } catch (_) {}
        try {
          if (_apkFile != null && await _apkFile!.exists()) {
            await _apkFile!.delete();
          }
        } catch (_) {}
        return;
      }
      if (mounted) setState(() => _error = e.toString());
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
