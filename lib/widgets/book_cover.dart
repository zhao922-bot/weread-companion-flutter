import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../theme/readamber_theme.dart';

/// 统一书籍封面组件：使用 CachedNetworkImage 支持离线磁盘缓存，
/// 按需设置解码分辨率并支持 Hero 过渡动画。
class BookCover extends StatelessWidget {
  final String bookId;
  final String title;
  final String coverUrl;
  final double? width;
  final double? height;
  final BorderRadius borderRadius;

  const BookCover({
    super.key,
    required this.bookId,
    required this.title,
    required this.coverUrl,
    this.width,
    this.height,
    this.borderRadius = const BorderRadius.all(Radius.circular(8)),
  });

  @override
  Widget build(BuildContext context) {
    final palette = ReadAmberPalette.of(context);
    return Hero(
      tag: 'book-cover-$bookId',
      child: ClipRRect(
        borderRadius: borderRadius,
        child: Container(
          width: width,
          height: height,
          color: palette.surfaceMuted,
          child: coverUrl.isNotEmpty
              ? LayoutBuilder(
                  builder: (context, constraints) {
                    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
                    return CachedNetworkImage(
                      imageUrl: coverUrl,
                      fit: BoxFit.cover,
                      memCacheWidth: (constraints.maxWidth * pixelRatio).ceil(),
                      memCacheHeight:
                          (constraints.maxHeight * pixelRatio).ceil(),
                      placeholder: (context, _) => Container(
                        color: palette.surfaceMuted,
                        child: Center(
                          child: Icon(
                            Icons.menu_book_outlined,
                            size: 28,
                            color: palette.outline,
                          ),
                        ),
                      ),
                      errorWidget: (context, _, __) => _buildFallback(context),
                    );
                  },
                )
              : _buildFallback(context),
        ),
      ),
    );
  }

  Widget _buildFallback(BuildContext context) {
    final palette = ReadAmberPalette.of(context);
    return Container(
      color: palette.surfaceMuted,
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: SizedBox(
            width: 88,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.book, size: 36, color: palette.muted),
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    title,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: palette.muted),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
