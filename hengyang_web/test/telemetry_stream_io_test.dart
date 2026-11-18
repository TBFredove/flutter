import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hengyang_web/telemetry_stream_io.dart';

void main() {
  test('native telemetry reconnects and closes its stream', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final opened = Completer<void>();
    final updated = Completer<void>();
    final disconnected = Completer<void>();
    final reconnected = Completer<void>();
    var connections = 0;
    server.listen((request) async {
      expect(request.headers.value(HttpHeaders.cookieHeader), 'session=test');
      connections++;
      request.response.headers.contentType =
          ContentType('text', 'event-stream');
      request.response.write(': connected\n\n');
      await request.response.flush();
      if (connections == 1) {
        request.response.write('data: changed\n\n');
        await request.response.flush();
        await request.response.close();
      }
    });
    final stream = TelemetryStream(
      uri: Uri.parse('http://127.0.0.1:${server.port}/events'),
      cookie: 'session=test',
      onOpen: () {
        if (!opened.isCompleted) {
          opened.complete();
        } else if (!reconnected.isCompleted) {
          reconnected.complete();
        }
      },
      onUpdate: () {
        if (!updated.isCompleted) updated.complete();
      },
      onError: () {
        if (!disconnected.isCompleted) disconnected.complete();
      },
    );
    try {
      await opened.future.timeout(const Duration(seconds: 5));
      await updated.future.timeout(const Duration(seconds: 5));
      await disconnected.future.timeout(const Duration(seconds: 5));
      await reconnected.future.timeout(const Duration(seconds: 8));
      expect(connections, 2);
    } finally {
      stream.close();
      await server.close(force: true);
    }
  });
}
