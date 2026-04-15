import 'package:flutter/material.dart';

/// Network poster with a dark movie-icon fallback. Use everywhere we render
/// a TMDB poster so a broken CDN link cannot blank out a row/tile.
class PosterImage extends StatelessWidget {
  const PosterImage({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.borderRadius,
    this.iconSize = 24,
  });

  final String? url;
  final double? width;
  final double? height;
  final BoxFit fit;
  final BorderRadius? borderRadius;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      width: width,
      height: height,
      color: const Color(0xFF1A1A1A),
      alignment: Alignment.center,
      child: Icon(Icons.movie_outlined, size: iconSize, color: Colors.white24),
    );
    final child = (url == null || url!.isEmpty)
        ? placeholder
        : Image.network(
            url!,
            width: width,
            height: height,
            fit: fit,
            errorBuilder: (_, _, _) => placeholder,
          );
    if (borderRadius != null) {
      return ClipRRect(borderRadius: borderRadius!, child: child);
    }
    return child;
  }
}
