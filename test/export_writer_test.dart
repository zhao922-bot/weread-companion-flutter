import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:weread_companion/services/export_writer.dart';

class _Sink implements IOSink {
  final flushes = <Completer<void>>[];
  final writes = <Object?>[];
  final closed = Completer<void>();
  int closes = 0;
  @override
  void write(Object? value) => writes.add(value);
  @override
  Future<void> flush() {
    final pending = Completer<void>();
    flushes.add(pending);
    return pending.future;
  }

  @override
  Future<void> get done => closed.future;
  @override
  Future<void> close() async {
    closes++;
    closed.complete();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('关闭等待最后一次 flush，立即拒绝写入和刷新，重复关闭共享结果', () async {
    final sink = _Sink();
    final writer = ExportWriter(sink);
    writer.write('完整内容');
    final first = writer.flush();
    final second = writer.flush();
    final closing = writer.close();
    expect(identical(closing, writer.close()), isTrue);
    expect(() => writer.write('迟到写入'), throwsStateError);
    await expectLater(writer.flush(), throwsStateError);
    sink.flushes.first.complete();
    await first;
    expect(sink.closes, 0);
    sink.flushes.last.complete();
    await second;
    await closing;
    expect(sink.closes, 1);
    expect(sink.writes, ['完整内容']);
    expect(() => writer.write('关闭后写入'), throwsStateError);
    await expectLater(writer.flush(), throwsStateError);
  });

  test('flush 失败仍关闭底层流，保留原始异常且不产生未处理错误', () async {
    final sink = _Sink();
    final writer = ExportWriter(sink);
    final failure = FileSystemException('磁盘写满');
    final flushing = expectLater(writer.flush(), throwsA(same(failure)));
    final closing = expectLater(writer.close(), throwsA(same(failure)));
    sink.flushes.single.completeError(failure);
    await Future.wait([flushing, closing]);
    expect(sink.closes, 1);
  });
}
