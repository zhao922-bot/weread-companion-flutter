import 'package:flutter_test/flutter_test.dart';

Future<void> waitUntil(bool Function() condition,
    {Duration timeout = const Duration(seconds: 5)}) async {
  final elapsed = Stopwatch()..start();
  while (!condition()) {
    if (elapsed.elapsed >= timeout) {
      throw StateError('等待条件超时 ($timeout)');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> pumpUntil(WidgetTester tester, bool Function() condition,
    {Duration timeout = const Duration(seconds: 5)}) async {
  final elapsed = Stopwatch()..start();
  while (!condition()) {
    if (elapsed.elapsed >= timeout) {
      throw StateError('等待界面条件超时 ($timeout)');
    }
    await tester.runAsync(() =>
        Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 10));
  }
  await tester.pumpAndSettle();
}
