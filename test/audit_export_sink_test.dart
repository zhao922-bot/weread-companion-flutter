import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:weread_companion/services/export_writer.dart';

void main() {
  test('真实文件流的并发 flush 可以等待同一批内容，close 等待写完后释放文件', () async {
    final directory =
        await Directory.systemTemp.createTemp('readamber-real-sink-');
    final file = File('${directory.path}/notes.md');
    final writer = ExportWriter(file.openWrite());
    try {
      writer.write('完整笔记\n');
      await Future.wait([writer.flush(), writer.flush(), writer.close()]);
      expect(await file.readAsString(), '完整笔记\n');
      // Verify the real handle was released, including on Windows.
      await file.rename('${directory.path}/published.md');
    } finally {
      await writer.close();
      await directory.delete(recursive: true);
    }
  });
}
