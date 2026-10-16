import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:weread_companion/pages/cards_page.dart';
import 'package:weread_companion/services/database.dart';
import 'package:weread_companion/services/card_image_renderer.dart';
import 'package:weread_companion/services/export_service.dart';
import 'package:weread_companion/services/sync_service.dart';
import 'support/wait_until.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  Future<void> Function()? beforeTemporary;
  @override
  Future<String?> getTemporaryPath() async {
    await beforeTemporary?.call();
    return path;
  }

  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

class _Gate {
  final entered = Completer<void>();
  final release = Completer<void>();
  Future<void> wait() async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
  }
}

class _Image implements ui.Image {
  Future<ByteData?> Function()? encode;
  int encodes = 0;
  int disposals = 0;
  @override
  Future<ByteData?> toByteData(
      {ui.ImageByteFormat format = ui.ImageByteFormat.rawRgba}) async {
    expect(format, ui.ImageByteFormat.png);
    encodes++;
    return await encode?.call();
  }

  @override
  void dispose() => disposals++;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Renderer extends CardImageRenderer {
  bool available = true;
  Future<ui.Image> Function()? onCapture;
  @override
  CardRenderBoundary? findBoundary(GlobalKey key) =>
      available ? super.findBoundary(key) : null;
  @override
  Future<ui.Image> capture(
          CardRenderBoundary boundary, Rect region, double ratio) =>
      onCapture?.call() ?? super.capture(boundary, region, ratio);
}

final class _PngFaults extends IOOverrides {
  final nativeZone = Zone.current;
  Future<void> Function(String)? beforeWrite;
  Future<void> Function(String)? afterWrite;
  Future<void> Function(String)? beforeDelete;
  final writes = <String>[];
  final deletions = <String>[];
  @override
  Future<FileSystemEntityType> fseGetType(String path, bool followLinks) =>
      nativeZone
          .run(() => FileSystemEntity.type(path, followLinks: followLinks));
  @override
  File createFile(String path) => path.endsWith('.png')
      ? _PngFile(super.createFile(path), this)
      : super.createFile(path);
}

class _PngFile implements File {
  _PngFile(this.file, this.faults);
  final File file;
  final _PngFaults faults;
  @override
  String get path => file.path;
  @override
  Future<bool> exists() => file.exists();
  @override
  Future<File> writeAsBytes(List<int> bytes,
      {FileMode mode = FileMode.write, bool flush = false}) async {
    await faults.beforeWrite?.call(path);
    final result = await file.writeAsBytes(bytes, mode: mode, flush: flush);
    faults.writes.add(p.normalize(path));
    await faults.afterWrite?.call(path);
    return result;
  }

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async {
    faults.deletions.add(p.normalize(path));
    await faults.beforeDelete?.call(path);
    return file.delete(recursive: recursive);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.fluttercommunity.plus/share');
  late Directory directory;
  late DatabaseService db;
  late PathProviderPlatform originalPaths;
  late _Paths paths;
  late _PngFaults faults;
  late ValueNotifier<bool> active;
  late ValueNotifier<bool> present;
  late GlobalKey<NavigatorState> navigator;
  late _Renderer renderer;
  final shares = <List<String>>[];
  Future<void> Function()? onShare;

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    directory = await Directory.systemTemp.createTemp('weread-card-lifecycle-');
    await databaseFactory.setDatabasesPath(directory.path);
    originalPaths = PathProviderPlatform.instance;
    paths = _Paths(directory.path);
    PathProviderPlatform.instance = paths;
    await DatabaseService.selectAccount('123');
    db = DatabaseService.instance;
    await db.insertBookmark({
      'bookmark_id': 'a',
      'book_id': 'book',
      'book_title': '导出测试',
      'mark_text': '待导出的引文',
      'created_at': 1,
    });
    faults = _PngFaults();
    active = ValueNotifier(true);
    present = ValueNotifier(true);
    navigator = GlobalKey<NavigatorState>();
    renderer = _Renderer();
    shares.clear();
    onShare = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      shares.add(List<String>.from((call.arguments as Map)['paths'] as List)
          .map(p.normalize)
          .toList());
      await onShare?.call();
      return 'success';
    });
  });

  tearDown(() async {
    paths.beforeTemporary = null;
    await ExportService.clearLocalExports();
    await DatabaseService.endSession();
    PathProviderPlatform.instance = originalPaths;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    active.dispose();
    present.dispose();
    await directory.delete(recursive: true);
  });

  Future<List<String>> pngs() async => (await directory.list().toList())
      .where((entry) => entry.path.endsWith('.png'))
      .map((entry) => entry.path)
      .toList();

  Future<void> mount(WidgetTester tester, {bool narrow = false}) async {
    if (narrow) {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigator,
      home: ValueListenableBuilder<bool>(
        valueListenable: present,
        builder: (context, exists, child) => exists
            ? ValueListenableBuilder<bool>(
                valueListenable: active,
                builder: (context, visible, child) =>
                    CardsPage(isActive: visible, renderer: renderer))
            : const Scaffold(body: Text('其他页面')),
      ),
    ));
    await pumpUntil(tester, () => find.text('共 1 条').evaluate().isNotEmpty);
    if (narrow) {
      await tester.tap(find.textContaining('待导出的引文').first);
      await tester.pumpAndSettle();
    }
  }

  Future<void> Function() exportAction(WidgetTester tester) => tester
      .widget<ElevatedButton>(find.widgetWithText(ElevatedButton, '导出图片'))
      .onPressed! as Future<void> Function();

  Future<void> export(WidgetTester tester) async {
    final action = exportAction(tester);
    await tester.runAsync(() => IOOverrides.runWithIOOverrides(action, faults));
    await tester.pumpAndSettle();
  }

  testWidgets('没有已挂载的截图边界时安全结束并释放交互锁', (tester) async {
    expect(const CardImageRenderer().findBoundary(GlobalKey()), isNull);
    await mount(tester);
    renderer.available = false;
    await export(tester);
    expect(shares, isEmpty);
    expect(exportAction(tester), isNotNull);
    renderer.available = true;
    await export(tester);
    expect(shares, hasLength(1));
  });

  for (final stage in ['截图', '编码']) {
    for (final transition in ['隐藏后返回', '销毁', '退出']) {
      testWidgets('$stage等待期间$transition，丢弃迟到结果并恰好释放一次图片', (tester) async {
        await mount(tester);
        final raster = _Image();
        late _Gate gate;
        late Future<void> pending;
        final action = exportAction(tester);
        await tester.runAsync(() async {
          gate = _Gate();
          raster.encode = () async {
            if (stage == '编码') await gate.wait();
            return ByteData(1);
          };
          renderer.onCapture = () async {
            if (stage == '截图') await gate.wait();
            return raster;
          };
          pending = IOOverrides.runWithIOOverrides(action, faults);
          await gate.entered.future;
        });
        if (transition == '销毁') {
          present.value = false;
        } else if (transition == '退出') {
          await tester.runAsync(DatabaseService.endSession);
        } else {
          active.value = false;
        }
        await tester.pump();
        if (transition == '隐藏后返回') {
          active.value = true;
          await tester.pump();
        }
        await tester.runAsync(() async {
          gate.release.complete();
          await pending;
          expect(await pngs(), isEmpty);
        });
        await tester.pumpAndSettle();
        expect(raster.disposals, 1);
        expect(raster.encodes, stage == '截图' ? 0 : 1);
        expect(shares, isEmpty);
        expect(faults.writes, isEmpty);
        expect(find.textContaining('导出失败'), findsNothing);
        expect(tester.takeException(), isNull);
        if (transition == '隐藏后返回') {
          renderer.onCapture = null;
          await export(tester);
          expect(shares, hasLength(1));
        }
      });
    }
  }

  for (final failure in ['截图异常', '编码异常', '编码为空']) {
    testWidgets('$failure释放资源，显示错误并允许重新导出', (tester) async {
      await mount(tester, narrow: failure == '编码为空');
      final raster = _Image();
      renderer.onCapture = () async {
        if (failure == '截图异常') throw StateError(failure);
        return raster;
      };
      raster.encode = () async {
        if (failure == '编码异常') throw StateError(failure);
        return null;
      };
      await export(tester);
      expect(raster.disposals, failure == '截图异常' ? 0 : 1);
      expect(find.textContaining('导出失败'), findsOneWidget);
      expect(shares, isEmpty);
      await tester.runAsync(() async => expect(await pngs(), isEmpty));
      renderer.onCapture = null;
      await export(tester);
      expect(shares, hasLength(1));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('编码返回缓冲区切片时只写入有效图片字节', (tester) async {
    await mount(tester);
    final raster = _Image();
    raster.encode = () async => ByteData.sublistView(
        Uint8List.fromList([99, 137, 80, 78, 71, 88]), 1, 5);
    renderer.onCapture = () async => raster;
    await export(tester);
    expect(raster.disposals, 1);
    expect(shares, hasLength(1));
    await tester.runAsync(() async {
      expect(await File(shares.single.single).readAsBytes(), [137, 80, 78, 71]);
    });
  });

  for (final transition in ['隐藏', '隐藏后立即返回', '销毁底层页面']) {
    testWidgets('等待临时目录时$transition取消旧导出，恢复后可重试', (tester) async {
      final orphanSheet = transition == '销毁底层页面';
      await mount(tester, narrow: orphanSheet);
      late _Gate gate;
      late Future<void> pending;
      final action = exportAction(tester);
      await tester.runAsync(() async {
        gate = _Gate();
        paths.beforeTemporary = gate.wait;
        pending = IOOverrides.runWithIOOverrides(action, faults);
        await gate.entered.future;
      });
      if (orphanSheet) {
        present.value = false;
      } else {
        active.value = false;
      }
      await tester.pump();
      if (transition == '隐藏后立即返回') {
        active.value = true;
        await tester.pump();
      }
      await tester.runAsync(() async {
        gate.release.complete();
        await pending;
        expect(await pngs(), isEmpty);
      });
      await tester.pumpAndSettle();
      expect(shares, isEmpty);
      expect(faults.writes, isEmpty);
      expect(find.textContaining('导出失败'), findsNothing);
      paths.beforeTemporary = null;
      if (orphanSheet) {
        // The bottom sheet still exists independently of its disposed owner.
        expect(find.text('导出图片'), findsOneWidget);
        await export(tester);
        expect(shares, isEmpty);
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        present.value = true;
        await tester.pump();
        await pumpUntil(tester, () => find.text('共 1 条').evaluate().isNotEmpty);
        await tester.tap(find.text('待导出的引文'));
        await tester.pumpAndSettle();
      } else {
        active.value = true;
        await tester.pump();
      }
      await export(tester);
      expect(shares, hasLength(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('销毁后保存的导出回调安全退出', (tester) async {
    await mount(tester);
    final action = exportAction(tester);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(action);
    expect(tester.takeException(), isNull);
    expect(shares, isEmpty);
  });

  testWidgets('导出等待时进入新路由再返回，旧任务仍取消且可重新导出', (tester) async {
    await mount(tester);
    late _Gate gate;
    late Future<void> pending;
    final action = exportAction(tester);
    await tester.runAsync(() async {
      gate = _Gate();
      paths.beforeTemporary = gate.wait;
      pending = IOOverrides.runWithIOOverrides(action, faults);
      await gate.entered.future;
    });
    await tester.pump();
    unawaited(navigator.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('新页面')))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(() async {
      gate.release.complete();
      await pending;
      expect(await pngs(), isEmpty);
    });
    await tester.pumpAndSettle();
    expect(shares, isEmpty);
    paths.beforeTemporary = null;
    await export(tester);
    expect(shares, hasLength(1));
    await tester.pumpWidget(const SizedBox());
  });

  for (final transition in ['隐藏后返回', '销毁页面', '关闭预览', '销毁预览底层页面', '结束账号']) {
    testWidgets('首张分片写入中$transition，清理已写文件并停止后续渲染', (tester) async {
      await tester.runAsync(() => db.insertBookmark({
            'bookmark_id': 'a',
            'book_id': 'book',
            'book_title': '导出测试',
            'mark_text': List.filled(100, '待导出的引文').join('\n'),
            'created_at': 1,
          }));
      await mount(tester, narrow: transition.contains('预览'));
      late _Gate gate;
      late Future<void> pending;
      final action = exportAction(tester);
      await tester.runAsync(() async {
        gate = _Gate();
        faults.afterWrite = (_) => gate.wait();
        pending = IOOverrides.runWithIOOverrides(action, faults);
        await gate.entered.future;
        expect(await pngs(), hasLength(1));
      });
      switch (transition) {
        case '隐藏后返回':
          active.value = false;
          await tester.pump();
          active.value = true;
          await tester.pump();
        case '销毁页面':
        case '销毁预览底层页面':
          present.value = false;
          await tester.pump();
        case '关闭预览':
          navigator.currentState!.pop();
          await tester.pumpAndSettle();
        case '结束账号':
          await tester.runAsync(DatabaseService.endSession);
      }
      await tester.runAsync(() async {
        gate.release.complete();
        await pending;
        expect(await pngs(), isEmpty);
      });
      await tester.pumpAndSettle();
      expect(faults.writes, hasLength(1));
      expect(shares, isEmpty);
      expect(find.textContaining('导出失败'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final stage in ['临时目录', '写入前', '写入后', '分享']) {
    testWidgets('$stage失败恢复交互并清理文件，立即重试成功', (tester) async {
      await mount(tester);
      Future<void> fail() async => throw StateError('$stage故障');
      switch (stage) {
        case '临时目录':
          paths.beforeTemporary = fail;
        case '写入前':
          faults.beforeWrite = (_) => fail();
        case '写入后':
          faults.afterWrite = (_) => fail();
        case '分享':
          onShare = fail;
      }
      await export(tester);
      await tester.runAsync(() async => expect(await pngs(), isEmpty));
      expect(find.textContaining('$stage故障'), findsOneWidget);
      expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNotNull);
      expect(
          tester
              .widget<AbsorbPointer>(find
                  .descendant(
                      of: find.byType(CardsPage),
                      matching: find.byType(AbsorbPointer))
                  .first)
              .absorbing,
          isFalse);
      paths.beforeTemporary = null;
      faults.beforeWrite = null;
      faults.afterWrite = null;
      onShare = null;
      final previousShares = shares.length;
      await export(tester);
      expect(shares, hasLength(previousShares + 1));
      await tester.runAsync(() async => expect(await pngs(), shares.last));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final fileSystemError in [true, false]) {
    testWidgets('删除抛出${fileSystemError ? '文件异常' : '其他异常'}仍清理其他分片，先重试清理再生成图片',
        (tester) async {
      await tester.runAsync(() => db.insertBookmark({
            'bookmark_id': 'a',
            'book_id': 'book',
            'book_title': '导出测试',
            'mark_text': List.filled(100, '待导出的引文').join('\n'),
            'created_at': 1,
          }));
      await mount(tester);
      onShare = () async => throw StateError('原始分享故障');
      faults.beforeDelete = (path) async {
        if (path.endsWith('_1.png')) {
          if (fileSystemError) throw FileSystemException('拒绝删除', path);
          throw StateError('删除故障');
        }
      };
      await export(tester);
      expect(shares.single.length, greaterThan(1));
      expect(faults.deletions, unorderedEquals(shares.single));
      expect(find.textContaining('原始分享故障'), findsOneWidget);
      final orphan = shares.single.first;
      await tester.runAsync(() async => expect(await pngs(), [orphan]));
      final writes = faults.writes.length;
      onShare = null;
      await export(tester);
      expect(faults.writes, hasLength(writes));
      expect(shares, hasLength(1));
      faults.beforeDelete = null;
      await export(tester);
      expect(shares, hasLength(2));
      await tester.runAsync(() async {
        expect(await File(orphan).exists(), isFalse);
        expect(await pngs(), unorderedEquals(shares.last));
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final transition in ['隐藏后返回', '销毁页面', '结束账号']) {
    testWidgets('系统分享等待中$transition，完成前保留文件，完成后清理且不重复分享', (tester) async {
      await mount(tester);
      late _Gate gate;
      late Future<void> pending;
      final action = exportAction(tester);
      await tester.runAsync(() async {
        gate = _Gate();
        onShare = gate.wait;
        pending = IOOverrides.runWithIOOverrides(action, faults);
        await gate.entered.future;
      });
      if (transition == '隐藏后返回') {
        active.value = false;
        await tester.pump();
        active.value = true;
        await tester.pump();
      } else if (transition == '销毁页面') {
        present.value = false;
        await tester.pump();
      } else {
        await tester.runAsync(DatabaseService.endSession);
      }
      await tester.runAsync(() async {
        expect(await pngs(), shares.single);
        expect(faults.deletions, isEmpty);
        gate.release.complete();
        await pending;
        expect(await pngs(), isEmpty);
      });
      await tester.pumpAndSettle();
      expect(shares, hasLength(1));
      expect(find.textContaining('导出失败'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('取消后平台错误不污染当前页面，失败清理可在下次导出恢复', (tester) async {
    await mount(tester);
    late _Gate gate;
    late Future<void> pending;
    final action = exportAction(tester);
    await tester.runAsync(() async {
      gate = _Gate();
      onShare = () async {
        await gate.wait();
        throw StateError('过期分享故障');
      };
      faults.beforeDelete =
          (path) async => throw FileSystemException('清理故障', path);
      pending = IOOverrides.runWithIOOverrides(action, faults);
      await gate.entered.future;
    });
    active.value = false;
    await tester.pump();
    active.value = true;
    await tester.pump();
    await tester.runAsync(() async {
      gate.release.complete();
      await pending;
      expect(await pngs(), shares.single);
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('导出失败'), findsNothing);
    final orphan = shares.single.single;
    onShare = null;
    faults.beforeDelete = null;
    await export(tester);
    expect(shares, hasLength(2));
    await tester.runAsync(() async {
      expect(await File(orphan).exists(), isFalse);
      expect(await pngs(), shares.last);
    });
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('清理与其他任务删除同一文件竞争时允许文件已不存在', (tester) async {
    await mount(tester);
    onShare = () async => throw StateError('分享故障');
    faults.beforeDelete = (path) async {
      await faults.nativeZone.run(() => File(path).delete());
    };
    await export(tester);
    await tester.runAsync(() async => expect(await pngs(), isEmpty));
    onShare = null;
    faults.beforeDelete = null;
    await export(tester);
    expect(shares, hasLength(2));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('失败重试只删除失败任务文件，保留此前已分享的图片', (tester) async {
    await mount(tester);
    await export(tester);
    final successful = shares.single.single;
    onShare = () async => throw StateError('第二次分享故障');
    await export(tester);
    await tester.runAsync(() async => expect(await pngs(), [successful]));
    onShare = null;
    await export(tester);
    expect(shares.expand((paths) => paths).toSet(), hasLength(3));
    await tester.runAsync(() async => expect(
        await pngs(),
        unorderedEquals([
          successful,
          ...shares.last,
        ])));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('重复回调和导出中的多次同步通知只导出一次，完成后刷新最新数据', (tester) async {
    await mount(tester);
    late _Gate gate;
    late Future<void> pending;
    final action = exportAction(tester);
    await tester.runAsync(() async {
      gate = _Gate();
      paths.beforeTemporary = gate.wait;
      pending = IOOverrides.runWithIOOverrides(action, faults);
      await gate.entered.future;
      await action();
      await db.insertBookmark({
        'bookmark_id': 'b',
        'book_id': 'book',
        'book_title': '新书',
        'mark_text': '同步新增引文',
        'created_at': 2
      });
    });
    for (var i = 0; i < 5; i++) {
      SyncService.changes.publish(db);
    }
    await tester.pump();
    expect(find.text('共 1 条'), findsOneWidget);
    expect(find.text('同步新增引文'), findsNothing);
    await tester.runAsync(() async {
      gate.release.complete();
      await pending;
    });
    await pumpUntil(tester, () => find.text('共 2 条').evaluate().isNotEmpty);
    expect(shares, hasLength(1));
    expect(faults.writes, hasLength(1));
    expect(find.text('同步新增引文'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  test('退出清理识别旧图片和新唯一文件名，保留其他文件', () async {
    final names = [
      'weread_card_123.png',
      'weread_card_123_1.png',
      'weread_card_123_${'a' * 32}_1.png'
    ];
    for (final name in [...names, 'weread_card_user_photo.png', 'keep.png']) {
      await File('${directory.path}/$name').writeAsString('image');
    }
    await ExportService.clearLocalExports();
    expect(
        (await pngs()).map((path) => path.split(Platform.pathSeparator).last),
        unorderedEquals(['weread_card_user_photo.png', 'keep.png']));
  });

  testWidgets('重试旧文件清理期间切页又返回，不继续生成新图片', (tester) async {
    await mount(tester);
    onShare = () async => throw StateError('分享故障');
    faults.beforeDelete =
        (path) async => throw FileSystemException('暂时占用', path);
    await export(tester);
    final orphan = shares.single.single;
    onShare = null;
    late _Gate gate;
    late Future<void> pending;
    final action = exportAction(tester);
    await tester.runAsync(() async {
      gate = _Gate();
      faults.beforeDelete = (_) => gate.wait();
      pending = IOOverrides.runWithIOOverrides(action, faults);
      await gate.entered.future;
    });
    active.value = false;
    await tester.pump();
    active.value = true;
    await tester.pump();
    await tester.runAsync(() async {
      gate.release.complete();
      await pending;
      expect(await File(orphan).exists(), isFalse);
      expect(await pngs(), isEmpty);
    });
    await tester.pumpAndSettle();
    expect(faults.writes, hasLength(1));
    expect(shares, hasLength(1));
    faults.beforeDelete = null;
    await export(tester);
    expect(shares, hasLength(2));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('失败清理尚未完成时重复调用不会创建第二个任务，清理后可重试', (tester) async {
    await mount(tester);
    late _Gate gate;
    late Future<void> pending;
    final action = exportAction(tester);
    await tester.runAsync(() async {
      gate = _Gate();
      onShare = () async => throw StateError('分享故障');
      faults.beforeDelete = (_) => gate.wait();
      pending = IOOverrides.runWithIOOverrides(action, faults);
      await gate.entered.future;
      await action();
    });
    await tester.pump();
    expect(find.text('导出中...'), findsOneWidget);
    expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNull);
    expect(shares, hasLength(1));
    expect(faults.writes, hasLength(1));
    await tester.runAsync(() async {
      gate.release.complete();
      await pending;
      expect(await pngs(), isEmpty);
    });
    await tester.pumpAndSettle();
    onShare = null;
    faults.beforeDelete = null;
    await export(tester);
    expect(shares, hasLength(2));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('退出全局清理可回收导出遗留文件，后续导出不重复失败', (tester) async {
    await mount(tester);
    onShare = () async => throw StateError('分享故障');
    faults.beforeDelete =
        (path) async => throw FileSystemException('暂时占用', path);
    await export(tester);
    final orphan = shares.single.single;
    faults.beforeDelete = null;
    await tester.runAsync(() async {
      await IOOverrides.runWithIOOverrides(
          ExportService.clearLocalExports, faults);
      expect(await File(orphan).exists(), isFalse);
    });
    onShare = null;
    await export(tester);
    expect(shares, hasLength(2));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final state in ['隐藏', '路由覆盖', '已退出登录']) {
    testWidgets('$state后残留的导出回调不启动任务', (tester) async {
      await mount(tester);
      final action = exportAction(tester);
      var temporaryLookups = 0;
      paths.beforeTemporary = () async {
        temporaryLookups++;
      };
      if (state == '隐藏') {
        active.value = false;
        await tester.pump();
      } else if (state == '路由覆盖') {
        unawaited(navigator.currentState!.push(MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('其他路由')))));
        await tester.pumpAndSettle();
      } else {
        await tester.runAsync(DatabaseService.endSession);
      }
      await tester.runAsync(action);
      expect(temporaryLookups, 0);
      expect(shares, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('临时目录迟到失败发生在页面隐藏后，不显示过期错误', (tester) async {
    await mount(tester);
    late _Gate gate;
    late Future<void> pending;
    final action = exportAction(tester);
    await tester.runAsync(() async {
      gate = _Gate();
      paths.beforeTemporary = () async {
        await gate.wait();
        throw FileSystemException('迟到目录故障');
      };
      pending = IOOverrides.runWithIOOverrides(action, faults);
      await gate.entered.future;
    });
    active.value = false;
    await tester.pump();
    await tester.runAsync(() async {
      gate.release.complete();
      await pending;
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('导出失败'), findsNothing);
    expect(shares, isEmpty);
    expect(faults.writes, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('单张图片写入完成时隐藏，不打开分享且删除文件，恢复后可重新导出', (tester) async {
    await mount(tester);
    late _Gate gate;
    late Future<void> pending;
    final action = exportAction(tester);
    final select = tester
        .widget<GestureDetector>(find
            .ancestor(
                of: find.text('待导出的引文').first,
                matching: find.byType(GestureDetector))
            .first)
        .onTap!;
    await tester.runAsync(() async {
      gate = _Gate();
      faults.afterWrite = (_) => gate.wait();
      pending = IOOverrides.runWithIOOverrides(action, faults);
      await gate.entered.future;
    });
    // A gesture already dispatched before AbsorbPointer rebuilt must also stop.
    select();
    active.value = false;
    await tester.pump();
    await tester.runAsync(() async {
      gate.release.complete();
      await pending;
      expect(await pngs(), isEmpty);
    });
    await tester.pumpAndSettle();
    expect(shares, isEmpty);
    expect(faults.writes, hasLength(1));
    expect(faults.deletions, hasLength(1));
    expect(tester.takeException(), isNull);
    faults.afterWrite = null;
    active.value = true;
    await tester.pumpAndSettle();
    await export(tester);
    expect(shares, hasLength(1));
    await tester.pumpWidget(const SizedBox());
  });
}
