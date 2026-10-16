import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weread_companion/models/book.dart';
import 'package:weread_companion/services/sync_service.dart';
import 'package:weread_companion/services/config.dart';

void main() {
  test('已取消或未配置的连接在访问API之前明确失败', () async {
    await expectLater(
        SyncService.connect(config: AppConfig(), isCancelled: () => true),
        throwsA(isA<StateError>().having((e) => e.message, '取消原因', '同步已取消')));
    await expectLater(SyncService.connect(config: AppConfig()),
        throwsA(isA<StateError>().having((e) => e.message, '登录提示', '请先登录后同步')));
  });
  for (final failedSource in ['bookmark', 'note']) {
    for (final successfulCount in [0, 7]) {
      test('$failedSource失败重试保留另一来源的$successfulCount条结果，包括成功但无增量', () async {
        final book = Book(bookId: 'b', title: '书');
        final calls = {'bookmark': 0, 'note': 0};
        var recovered = false;
        Future<int> load(String source) async {
          calls[source] = calls[source]! + 1;
          if (source == failedSource) {
            if (!recovered) throw StateError('failed');
            return 5;
          }
          return successfulCount;
        }

        final service = SyncService(
            loadBooks: () async => [book],
            loadBookmarks: (_) => load('bookmark'),
            loadNotes: (_) => load('note'),
            isCancelled: () => false,
            onChanged: () {});
        var result = await service.syncAll();
        final first = result.failures.single;
        final again = await service.retryBook(book, previous: first);
        expect(again.succeeded, isFalse);
        result = result.replace(again);
        recovered = true;
        final repaired = await service.retryBook(book, previous: again);
        result = result.replace(repaired);
        expect(result.successCount, 1);
        expect(result.bookmarks + result.notes, successfulCount + 5);
        expect(repaired.bookmarksSucceeded, isTrue);
        expect(repaired.notesSucceeded, isTrue);
        expect(calls[failedSource], 3);
        expect(calls[failedSource == 'note' ? 'bookmark' : 'note'], 1);
        expect(
            () => service.retryBook(Book(bookId: 'other', title: '其他'),
                previous: repaired),
            throwsArgumentError);
      });
    }
  }

  for (final type in [
    DioExceptionType.connectionTimeout,
    DioExceptionType.receiveTimeout
  ]) {
    test('$type最多尝试三次，耗尽后释放请求槽并保留原错误', () async {
      var calls = 0;
      final service = SyncService(
          loadBooks: () async {
            calls++;
            throw DioException(
                requestOptions: RequestOptions(path: '/shelf'), type: type);
          },
          loadBookmarks: (_) async => 0,
          loadNotes: (_) async => 0,
          isCancelled: () => false,
          onChanged: () {});
      await expectLater(service.syncAll(),
          throwsA(isA<DioException>().having((e) => e.type, '类型', type)));
      expect(calls, 3);
      final next = SyncService(
          loadBooks: () async => [],
          loadBookmarks: (_) async => 0,
          loadNotes: (_) async => 0,
          isCancelled: () => false,
          onChanged: () {});
      expect((await next.syncAll()).cancelled, isFalse);
    });
  }

  test('503按重试头恢复，400不做无效重试', () async {
    for (final status in [503, 400]) {
      var calls = 0;
      final service = SyncService(
          loadBooks: () async {
            if (++calls == 1) {
              final request = RequestOptions(path: '/shelf');
              throw DioException(
                  requestOptions: request,
                  response: Response(
                      requestOptions: request,
                      statusCode: status,
                      headers: Headers.fromMap({
                        'retry-after': ['0']
                      })));
            }
            return [];
          },
          loadBookmarks: (_) async => 0,
          loadNotes: (_) async => 0,
          isCancelled: () => false,
          onChanged: () {});
      if (status == 503) {
        expect((await service.syncAll()).failureCount, 0);
        expect(calls, 2);
      } else {
        await expectLater(service.syncAll(), throwsA(isA<DioException>()));
        expect(calls, 1);
      }
    }
  });
}
