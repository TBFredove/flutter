import 'dart:js_interop';

import 'package:web/web.dart' as web;

class TelemetryStream {
  TelemetryStream({
    Uri? uri,
    String? cookie,
    required void Function() onOpen,
    required void Function() onUpdate,
    required void Function() onError,
  }) : _source = web.EventSource(
            (uri ?? Uri.parse('/api/v1/telemetry/events')).toString()) {
    _source.onopen = ((web.Event _) => onOpen()).toJS;
    _source.onmessage = ((web.Event _) => onUpdate()).toJS;
    _source.onerror = ((web.Event _) => onError()).toJS;
  }

  final web.EventSource _source;

  void close() => _source.close();
}
