import 'dart:async';
import 'dart:convert';
import 'dart:io';

class TelemetryStream {
  TelemetryStream({
    Uri? uri,
    String? cookie,
    required this.onOpen,
    required this.onUpdate,
    required this.onError,
  })  : _uri = uri,
        _cookie = cookie {
    if (_uri != null && _cookie != null) _connect();
  }

  final Uri? _uri;
  final String? _cookie;
  final void Function() onOpen;
  final void Function() onUpdate;
  final void Function() onError;
  HttpClient? _client;
  Timer? _retry;
  bool _closed = false;

  Future<void> _connect() async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    _client = client;
    try {
      final request = await client.getUrl(_uri!);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.cookieHeader, _cookie!);
      request.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('遥测连接失败（${response.statusCode}）');
      }
      if (_closed) return;
      onOpen();
      var hasData = false;
      await for (final line in response
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .timeout(const Duration(seconds: 45))) {
        if (_closed) return;
        if (line.isEmpty) {
          if (hasData) onUpdate();
          hasData = false;
        } else if (line.startsWith('data:')) {
          hasData = true;
        }
      }
      if (!_closed) throw const HttpException('遥测连接已关闭');
    } on Object catch (error) {
      if (!_closed) {
        stderr.writeln('遥测连接失败：$error');
        onError();
        _retry = Timer(const Duration(seconds: 3), _connect);
      }
    } finally {
      client.close(force: true);
      if (identical(_client, client)) _client = null;
    }
  }

  void close() {
    _closed = true;
    _retry?.cancel();
    _client?.close(force: true);
  }
}
