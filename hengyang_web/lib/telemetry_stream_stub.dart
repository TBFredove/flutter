class TelemetryStream {
  TelemetryStream({
    Uri? uri,
    String? cookie,
    required void Function() onOpen,
    required void Function() onUpdate,
    required void Function() onError,
  });

  void close() {}
}
