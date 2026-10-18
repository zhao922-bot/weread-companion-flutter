import 'dart:io';

/// Serializes stream shutdown with outstanding flushes and rejects late writes.
class ExportWriter {
  final IOSink _sink;
  Future<void>? _flushing;
  Future<void>? _closing;

  ExportWriter(this._sink) {
    // Observe early errors while an asynchronous formatting task is running;
    // flush/close still propagate them through the export future.
    _sink.done.ignore();
  }

  void write(Object? text) {
    if (_closing != null) throw StateError('导出文件已关闭');
    _sink.write(text);
  }

  Future<void> flush() async {
    if (_closing != null) throw StateError('导出文件已关闭');
    // IOSink rejects a second flush while the first one binds its stream.
    // No additional writes can enter that bound stream; share its completion.
    final flushing = _flushing ??= _sink.flush().then<void>((_) {});
    try {
      await flushing;
    } finally {
      if (identical(_flushing, flushing)) _flushing = null;
    }
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    try {
      await _flushing;
    } finally {
      await _sink.close();
    }
  }
}
