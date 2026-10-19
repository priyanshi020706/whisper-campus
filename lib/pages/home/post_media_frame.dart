import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

class PostMediaFrame extends StatelessWidget {
  const PostMediaFrame({
    super.key,
    required this.imageUrl,
    required this.onTap,
    this.aspectRatio = 1.45,
  });

  final String imageUrl;
  final VoidCallback onTap;
  final double aspectRatio;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: 'Open image',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(13),
        child: AspectRatio(
          aspectRatio: aspectRatio,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                child: Image.network(
                  imageUrl,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) =>
                      ColoredBox(color: colors.surfaceContainerHighest),
                ),
              ),
              ColoredBox(color: colors.surface.withValues(alpha: 0.28)),
              Image.network(
                imageUrl,
                fit: BoxFit.contain,
                errorBuilder: (context, error, stackTrace) => ColoredBox(
                  color: colors.surfaceContainerLow,
                  child: const Center(child: Icon(Icons.broken_image_outlined)),
                ),
              ),
              Material(
                color: Colors.transparent,
                child: InkWell(onTap: onTap),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
