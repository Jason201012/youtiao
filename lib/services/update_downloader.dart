import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:todolist/services/update_policy.dart';

/// 下载失败（含被白名单拒绝、HTTP 非 200、体积超限、校验失败等）。
class ApkDownloadException implements Exception {
  final String message;
  const ApkDownloadException(this.message);
  @override
  String toString() => 'ApkDownloadException: $message';
}

/// 用户主动取消下载。公开暴露以便调用方区分「取消」与「失败」：
/// 取消不算错误，不应向用户弹失败提示。
class ApkDownloadCancelledException implements Exception {
  const ApkDownloadCancelledException();
  @override
  String toString() => 'ApkDownloadCancelledException';
}

/// APK 流式下载器（安全审计 L-02 / L-03 / L-10）。
///
/// 相比原先直接在弹窗里用 `http.Client().send()`，这里做了三件事：
///
/// 1. **关闭自动重定向**，手动逐跳处理 3xx，每一跳的 Location 都过
///    [UpdatePolicy.isAllowedRedirectTarget]（原实现只校验首跳 host，
///    `HttpClient` 默认 `followRedirects=true` 会静默跟随到任意主机）；
/// 2. **体积熔断**：优先看 `contentLength`，流式过程中再累计一次，超过
///    [UpdatePolicy.maxApkBytes] 立即中断，防投毒清单把存储写满；
/// 3. **失败即清理**：任何异常（含超时、校验失败、取消）都删除半成品文件，
///    且开始下载前先清空 `updates/` 目录，杜绝残片长期累积。
///
/// 下载全程流式写入磁盘 + 流式计算 SHA-256，不会把 APK 整体读进内存。
class UpdateDownloader {
  HttpClient? _client;

  /// 是否已取消（取消后不再继续写盘）。
  bool _cancelled = false;

  /// 取消下载：强制断开底层连接，下载循环会抛出 [ApkDownloadCancelledException]。
  void cancel() {
    _cancelled = true;
    _client?.close(force: true);
    _client = null;
  }

  /// 流式下载 APK 到 [target]，返回该文件的 SHA-256（小写十六进制）。
  ///
  /// - [url]：APK 直链，首跳必须过 [UpdatePolicy.isAllowedApkUrl]；
  /// - [target]：目标文件（目录会被自动创建，且下载前会清空该文件所在目录）；
  /// - [onProgress]：`(已收字节, 总字节或 -1)`，用于进度展示；
  /// - 抛出 [ApkDownloadException] 表示可展示给用户的失败；
  /// - 抛出 [ApkDownloadCancelledException] 表示用户取消（不向用户展示为错误）。
  Future<String> download({
    required String url,
    required File target,
    void Function(int received, int total)? onProgress,
  }) async {
    if (!UpdatePolicy.isAllowedApkUrl(url)) {
      throw const ApkDownloadException(
          '下载地址不在允许范围（仅限作者发布仓的 releases/download/ 路径）');
    }
    await target.parent.create(recursive: true);
    await _clearUpdatesDir(target.parent);

    // 注意：`followRedirects` 是 **HttpClientRequest** 的属性（Dart 3.13 起
    // HttpClient 上已不再有该 setter），必须逐请求设置，见下方循环内。
    final client = HttpClient()
      ..connectionTimeout = UpdatePolicy.requestTimeout;
    _client = client;

    IOSink? sink;
    var currentUri = Uri.parse(url);
    // 只有「流完整读完 + 校验值已算出」才置 true；非成功路径一律删除半成品（L-10）。
    var completed = false;
    try {
      // —— 手动跟随重定向，逐跳校验主机 ——
      HttpClientResponse response;
      var hops = 0;
      while (true) {
        final request = await client.getUrl(currentUri);
        request.headers.set(HttpHeaders.userAgentHeader, 'youtiao-update-checker');
        // L-02：关闭自动跟随，改由本循环逐跳把 Location 过一遍主机白名单。
        request.followRedirects = false;
        response = await request.close().timeout(UpdatePolicy.requestTimeout);

        final location = response.headers.value(HttpHeaders.locationHeader);
        final isRedirect = response.isRedirect ||
            (response.statusCode >= 300 && response.statusCode < 400);
        if (!isRedirect || location == null || location.isEmpty) break;

        // 丢弃重定向响应体，否则连接无法复用 / 下一跳会被挂住。
        await response.drain<void>();
        if (hops >= UpdatePolicy.maxRedirects) {
          throw const ApkDownloadException('下载重定向次数过多，已中止');
        }
        final next = currentUri.resolve(location);
        if (!UpdatePolicy.isAllowedRedirectTarget(next.toString())) {
          throw ApkDownloadException(
              '下载重定向到不受信任的主机（${next.host}），已拒绝');
        }
        currentUri = next;
        hops++;
      }

      if (response.statusCode != 200) {
        await response.drain<void>();
        throw ApkDownloadException('下载失败（HTTP ${response.statusCode}）');
      }
      // L-03：已知总长度超限则根本不开始写盘。
      // contentLength 为非空 int，未知时取 -1（服务端未给 Content-Length）。
      final declared = response.contentLength;
      if (declared > UpdatePolicy.maxApkBytes) {
        await response.drain<void>();
        throw ApkDownloadException(
            '安装包体积 ${(declared / 1048576).toStringAsFixed(1)} MB，超出 '
            '${(UpdatePolicy.maxApkBytes / 1048576).round()} MB 上限，已拒绝下载');
      }

      Digest? digest;
      final hashSink = sha256.startChunkedConversion(
        ChunkedConversionSink<Digest>.withCallback((d) => digest = d.single),
      );
      sink = target.openWrite();
      var received = 0;
      try {
        await for (final chunk
            in response.timeout(UpdatePolicy.requestTimeout)) {
          if (_cancelled) throw const ApkDownloadCancelledException();
          sink.add(chunk);
          hashSink.add(chunk);
          received += chunk.length;
          // L-03：流式熔断（contentLength 可能缺失 / 撒谎，必须自己数）。
          if (received > UpdatePolicy.maxApkBytes) {
            throw ApkDownloadException(
                '安装包超出 ${(UpdatePolicy.maxApkBytes / 1048576).round()} MB 上限，已中止');
          }
          onProgress?.call(received, declared);
        }
      } finally {
        hashSink.close();
      }
      await sink.flush();
      await sink.close();
      sink = null;
      completed = true;
      return (digest ?? sha256.convert(const <int>[])).toString();
    } on ApkDownloadCancelledException {
      rethrow;
    } on ApkDownloadException {
      rethrow;
    } on TimeoutException {
      throw const ApkDownloadException('下载超时，请检查网络后重试');
    } catch (e) {
      throw ApkDownloadException('下载失败：$e');
    } finally {
      // L-10：无论成功与否都收尾；失败时清理半成品。
      try {
        await sink?.flush();
        await sink?.close();
      } catch (_) {}
      _client = null;
      client.close(force: true);
      if (!completed) {
        await _deleteQuietly(target);
      }
    }
  }

  /// L-10：清空 updates/ 目录，清掉历史失败留下的残片。
  static Future<void> _clearUpdatesDir(Directory dir) async {
    try {
      if (!await dir.exists()) return;
      await for (final entity in dir.list()) {
        await _deleteQuietly(entity);
      }
    } catch (_) {
      // 清理失败不阻断下载。
    }
  }

  static Future<void> _deleteQuietly(FileSystemEntity e) async {
    try {
      if (await e.exists()) await e.delete(recursive: true);
    } catch (_) {}
  }
}
