import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 可按需下载的开源可商用字体元数据（全部为 SIL OFL 1.1 协议）。
class OpenSourceFont {
  final String id;
  final String name;
  final String family;
  final String description;
  final String license;
  final String sizeHint;
  final String downloadUrl;
  final String fileName;

  const OpenSourceFont({
    required this.id,
    required this.name,
    required this.family,
    required this.description,
    required this.license,
    required this.sizeHint,
    required this.downloadUrl,
    required this.fileName,
  });

  static const List<OpenSourceFont> catalog = [
    OpenSourceFont(
      id: 'lxgw_wenkai_lite',
      name: '霞鹜文楷 Lite',
      family: 'ReadAmber_LxgwWenKaiLite',
      description: '温润楷体，读书笔记与摘录首选',
      license: 'SIL OFL 1.1 · 免费可商用',
      sizeHint: '约 10 MB',
      downloadUrl:
          'https://cdn.jsdelivr.net/gh/lxgw/LxgwWenKai-Lite@main/fonts/TTF/LXGWWenKaiLite-Regular.ttf',
      fileName: 'LXGWWenKaiLite-Regular.ttf',
    ),
    OpenSourceFont(
      id: 'noto_sans_sc',
      name: '思源黑体',
      family: 'ReadAmber_NotoSansSC',
      description: '清晰现代无衬线体，适合界面与长列表',
      license: 'SIL OFL 1.1 · 免费可商用',
      sizeHint: '约 17 MB',
      downloadUrl:
          'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/notosanssc/NotoSansSC%5Bwght%5D.ttf',
      fileName: 'NotoSansSC-VariableFont_wght.ttf',
    ),
    OpenSourceFont(
      id: 'zcool_xiaowei',
      name: '站酷小薇体',
      family: 'ReadAmber_ZcoolXiaoWei',
      description: '雅致文艺宋体，兼具书卷与古风韵味',
      license: 'SIL OFL 1.1 · 免费可商用',
      sizeHint: '约 6 MB',
      downloadUrl:
          'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/zcoolxiaowei/ZCOOLXiaoWei-Regular.ttf',
      fileName: 'ZCOOLXiaoWei-Regular.ttf',
    ),
    OpenSourceFont(
      id: 'zcool_huangyou',
      name: '站酷庆科黄油体',
      family: 'ReadAmber_ZcoolHuangYou',
      description: '圆润柔和现代无衬线体，轻松舒适',
      license: 'SIL OFL 1.1 · 免费可商用',
      sizeHint: '约 5 MB',
      downloadUrl:
          'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/zcoolqingkehuangyou/ZCOOLQingKeHuangYou-Regular.ttf',
      fileName: 'ZCOOLQingKeHuangYou-Regular.ttf',
    ),
    OpenSourceFont(
      id: 'ma_shan_zheng',
      name: '马善政毛笔楷书',
      family: 'ReadAmber_MaShanZheng',
      description: '苍劲手写楷书，适合金句卡片与诗词',
      license: 'SIL OFL 1.1 · 免费可商用',
      sizeHint: '约 3 MB',
      downloadUrl:
          'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/mashanzheng/MaShanZheng-Regular.ttf',
      fileName: 'MaShanZheng-Regular.ttf',
    ),
    OpenSourceFont(
      id: 'long_cang',
      name: '龙藏体',
      family: 'ReadAmber_LongCang',
      description: '飘逸行楷手写风格，适合文学摘录',
      license: 'SIL OFL 1.1 · 免费可商用',
      sizeHint: '约 3 MB',
      downloadUrl:
          'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/longcang/LongCang-Regular.ttf',
      fileName: 'LongCang-Regular.ttf',
    ),
    OpenSourceFont(
      id: 'zhi_mang_xing',
      name: '志莽行书',
      family: 'ReadAmber_ZhiMangXing',
      description: '洒脱行书体，赋予书摘笔墨质感',
      license: 'SIL OFL 1.1 · 免费可商用',
      sizeHint: '约 2 MB',
      downloadUrl:
          'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/zhimangxing/ZhiMangXing-Regular.ttf',
      fileName: 'ZhiMangXing-Regular.ttf',
    ),
  ];

  static OpenSourceFont? byId(String? id) {
    if (id == null) return null;
    for (final font in catalog) {
      if (font.id == id) return font;
    }
    return null;
  }
}

/// 负责开源字体的本地缓存、按需下载与动态注册（无需重启应用）。
class FontService {
  final Dio _dio;
  final Future<Directory> Function() _directoryProvider;
  final Future<void> Function(String family, Uint8List bytes) _registerFont;
  final Set<String> _loadedFamilies = {};

  FontService({
    Dio? dio,
    Future<Directory> Function()? directoryProvider,
    Future<void> Function(String family, Uint8List bytes)? registerFont,
  })  : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(minutes: 5),
            )),
        _directoryProvider = directoryProvider ?? getApplicationSupportDirectory,
        _registerFont = registerFont ?? _defaultRegisterFont;

  static Future<void> _defaultRegisterFont(
      String family, Uint8List bytes) async {
    final loader = FontLoader(family)
      ..addFont(Future.value(ByteData.sublistView(bytes)));
    await loader.load();
  }

  Future<Directory> _fontsDir() async {
    final base = await _directoryProvider();
    return Directory(p.join(base.path, 'fonts'));
  }

  Future<File> fontFile(OpenSourceFont font) async {
    final dir = await _fontsDir();
    return File(p.join(dir.path, font.fileName));
  }

  Future<Set<String>> listDownloadedIds() async {
    final downloaded = <String>{};
    for (final font in OpenSourceFont.catalog) {
      final file = await fontFile(font);
      if (await file.exists() && await file.length() > 0) {
        downloaded.add(font.id);
      }
    }
    return downloaded;
  }

  Future<void> loadFont(OpenSourceFont font) async {
    if (_loadedFamilies.contains(font.family)) return;
    final file = await fontFile(font);
    if (!await file.exists()) {
      throw StateError('字体文件尚未下载');
    }
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) {
      throw StateError('字体文件已损坏，请重新下载');
    }
    await _registerFont(font.family, bytes);
    _loadedFamilies.add(font.family);
  }

  Future<void> downloadFont(
    OpenSourceFont font, {
    void Function(double progress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final dir = await _fontsDir();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final target = File(p.join(dir.path, font.fileName));
    final temp = File('${target.path}.tmp');
    try {
      await _dio.download(
        font.downloadUrl,
        temp.path,
        cancelToken: cancelToken,
        onReceiveProgress: (received, total) {
          if (total > 0) {
            onProgress?.call((received / total).clamp(0.0, 1.0));
          }
        },
      );
      if (await target.exists()) await target.delete();
      await temp.rename(target.path);
      _loadedFamilies.remove(font.family);
      await loadFont(font);
    } catch (_) {
      if (await temp.exists()) await temp.delete();
      rethrow;
    }
  }

  Future<void> deleteFont(OpenSourceFont font) async {
    final file = await fontFile(font);
    if (await file.exists()) await file.delete();
    _loadedFamilies.remove(font.family);
  }
}
