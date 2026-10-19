import 'package:flutter/material.dart';

class WhisperBrandColors {
  WhisperBrandColors._();

  static const background = Color(0xFF241A34);
  static const lavender = Color(0xFFC08AF5);
  static const softLavender = Color(0xFFC6B8D8);
  static const ivory = Color(0xFFFFFCFF);
  static const lineArt = Color(0xFFD8B8F6);
  static const button = Color(0xFFF3EAFB);
  static const buttonText = Color(0xFF261B35);
}

class WhisperBrand extends StatelessWidget {
  const WhisperBrand({
    super.key,
    this.iconSize = 42,
    this.wordmarkSize = 20,
    this.centered = false,
    this.foregroundColor = WhisperBrandColors.ivory,
    this.accentColor = WhisperBrandColors.lavender,
    this.bubbleInteriorColor = WhisperBrandColors.background,
  });

  final double iconSize;
  final double wordmarkSize;
  final bool centered;
  final Color foregroundColor;
  final Color accentColor;
  final Color bubbleInteriorColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: centered ? MainAxisSize.min : MainAxisSize.max,
      mainAxisAlignment: centered
          ? MainAxisAlignment.center
          : MainAxisAlignment.start,
      children: [
        CustomPaint(
          size: Size.square(iconSize),
          painter: _WhisperBubblePainter(
            color: accentColor,
            interiorColor: bubbleInteriorColor,
          ),
        ),
        SizedBox(width: iconSize * 0.22),
        RichText(
          text: TextSpan(
            style: TextStyle(
              fontFamily: 'sans-serif',
              fontSize: wordmarkSize,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.55,
            ),
            children: [
              TextSpan(
                text: 'whisper ',
                style: TextStyle(color: foregroundColor),
              ),
              TextSpan(
                text: 'campus',
                style: TextStyle(color: accentColor),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _WhisperBubblePainter extends CustomPainter {
  const _WhisperBubblePainter({
    required this.color,
    required this.interiorColor,
  });

  final Color color;
  final Color interiorColor;

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final body = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        size.width * 0.08,
        size.height * 0.13,
        size.width * 0.84,
        size.height * 0.68,
      ),
      Radius.circular(size.height * 0.29),
    );
    canvas.drawRRect(body, fill);
    final tail = Path()
      ..moveTo(size.width * 0.22, size.height * 0.69)
      ..lineTo(size.width * 0.16, size.height * 0.94)
      ..lineTo(size.width * 0.43, size.height * 0.76)
      ..close();
    canvas.drawPath(tail, fill);

    final dotPaint = Paint()
      ..color = interiorColor
      ..style = PaintingStyle.fill;
    final dotY = size.height * 0.47;
    for (final x in [0.36, 0.50, 0.64]) {
      canvas.drawCircle(
        Offset(size.width * x, dotY),
        size.width * 0.047,
        dotPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WhisperBubblePainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.interiorColor != interiorColor;
}
