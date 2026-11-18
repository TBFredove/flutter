export 'telemetry_stream_stub.dart'
    if (dart.library.io) 'telemetry_stream_io.dart'
    if (dart.library.js_interop) 'telemetry_stream_web.dart';
