import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/widgets/whisper_brand.dart';
import '../../services/auth_service.dart';

class SignUpPage extends StatefulWidget {
  const SignUpPage({super.key});

  @override
  State<SignUpPage> createState() => _SignUpPageState();
}

class _SignUpPageState extends State<SignUpPage> {
  final _authService = AuthService();

  bool _loading = false;
  String _message = '';

  Future<void> _signInWithGoogle() async {
    setState(() {
      _loading = true;
      _message = '';
    });

    try {
      await _authService.signInWithGoogle();
    } on AuthException catch (e) {
      if (!mounted) return;

      setState(() {
        _message = e.message;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;

      debugPrint('GOOGLE AUTH ERROR: $e');

      setState(() {
        _message = 'Google sign-in failed. Please try again.';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: WhisperBrandColors.background,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isDesktop = constraints.maxWidth >= 820;
          return Stack(
            children: [
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _CampusArchitecturePainter(
                      opacity: isDesktop ? 0.17 : 0.22,
                    ),
                  ),
                ),
              ),
              SafeArea(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    isDesktop
                        ? _buildDesktop(constraints)
                        : _buildMobile(constraints),
                    Positioned(
                      top: 12,
                      left: 18,
                      right: 18,
                      child: Row(
                        mainAxisSize: MainAxisSize.max,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          WhisperBrand(
                            centered: true,
                            iconSize: isDesktop ? 34 : 31,
                            wordmarkSize: isDesktop ? 17 : 16,
                          ),
                          const Spacer(),
                          _MitsDuSeal(size: isDesktop ? 50 : 46),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildMobile(BoxConstraints constraints) {
    final compact = constraints.maxHeight < 700;
    final horizontalPadding = math
        .min(constraints.maxWidth * 0.075, 34.0)
        .toDouble();
    final headlineSize = (constraints.maxWidth * (compact ? 0.105 : 0.115))
        .clamp(42.0, 66.0)
        .toDouble();
    final bottomReserve = compact ? 124.0 : 174.0;

    return SingleChildScrollView(
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: constraints.maxHeight),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              SizedBox(height: compact ? 66 : 78),
              Padding(
                padding: EdgeInsets.only(top: compact ? 34 : 58),
                child: _buildMessageBlock(
                  headlineSize: headlineSize,
                  taglineSize: compact ? 18 : 21,
                  centered: true,
                  buttonHeight: 60,
                ),
              ),
              SizedBox(height: bottomReserve),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDesktop(BoxConstraints constraints) {
    final compact = constraints.maxHeight < 620;
    final headlineSize = (constraints.maxHeight * (compact ? 0.105 : 0.09))
        .clamp(54.0, 82.0)
        .toDouble();
    final bottomReserve = (constraints.maxHeight * 0.24)
        .clamp(110.0, 190.0)
        .toDouble();
    final content = Center(
      child: _buildMessageBlock(
        headlineSize: headlineSize,
        taglineSize: compact ? 18 : 21,
        centered: true,
        buttonHeight: compact ? 60 : 64,
      ),
    );

    if (constraints.maxHeight >= 500) {
      return Column(
        children: [
          SizedBox(height: compact ? 72 : 82),
          Expanded(child: content),
          SizedBox(height: bottomReserve),
        ],
      );
    }

    return SingleChildScrollView(
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: constraints.maxHeight),
        child: Column(
          children: [
            const SizedBox(height: 64),
            const SizedBox(height: 32),
            _buildMessageBlock(
              headlineSize: 54,
              taglineSize: 18,
              centered: true,
              buttonHeight: 58,
            ),
            const SizedBox(height: 90),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageBlock({
    required double headlineSize,
    required double taglineSize,
    required bool centered,
    required double buttonHeight,
  }) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 570),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: centered
            ? CrossAxisAlignment.center
            : CrossAxisAlignment.start,
        children: [
          _buildHeadline(fontSize: headlineSize, centered: centered),
          SizedBox(height: headlineSize < 50 ? 13 : 20),
          Text(
            'Speak freely. Stay anonymous.',
            textAlign: centered ? TextAlign.center : TextAlign.left,
            style: TextStyle(
              color: WhisperBrandColors.softLavender,
              fontSize: taglineSize,
              height: 1.35,
              letterSpacing: 0.15,
            ),
          ),
          SizedBox(height: headlineSize < 50 ? 28 : 42),
          _buildSignInActions(
            taglineSize: taglineSize,
            centered: centered,
            buttonHeight: buttonHeight,
          ),
        ],
      ),
    );
  }

  Widget _buildHeadline({required double fontSize, required bool centered}) {
    final style = TextStyle(
      fontFamily: 'Georgia',
      fontSize: fontSize,
      fontWeight: FontWeight.w600,
      height: 1.02,
      letterSpacing: -1.4,
      color: WhisperBrandColors.ivory,
    );
    return Column(
      crossAxisAlignment: centered
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
      children: [
        Text(
          'Your campus.',
          textAlign: centered ? TextAlign.center : null,
          style: style,
        ),
        Text(
          'Your voice.',
          textAlign: centered ? TextAlign.center : null,
          style: style.copyWith(color: WhisperBrandColors.lavender),
        ),
      ],
    );
  }

  Widget _buildSignInActions({
    required double taglineSize,
    required bool centered,
    required double buttonHeight,
  }) {
    return Column(
      crossAxisAlignment: centered
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: SizedBox(
            width: double.infinity,
            height: buttonHeight,
            child: FilledButton(
              onPressed: _loading ? null : _signInWithGoogle,
              style: FilledButton.styleFrom(
                backgroundColor: WhisperBrandColors.button,
                foregroundColor: WhisperBrandColors.buttonText,
                disabledBackgroundColor: WhisperBrandColors.button.withValues(
                  alpha: 0.82,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(17),
                ),
                textStyle: TextStyle(
                  fontSize: taglineSize < 19 ? 17 : 19,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.15,
                ),
              ),
              child: _loading
                  ? const SizedBox(
                      width: 23,
                      height: 23,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: WhisperBrandColors.buttonText,
                      ),
                    )
                  : const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _GoogleMark(),
                        SizedBox(width: 15),
                        Flexible(child: Text('Continue with Google')),
                      ],
                    ),
            ),
          ),
        ),
        const SizedBox(height: 22),
        Row(
          mainAxisSize: centered ? MainAxisSize.min : MainAxisSize.max,
          mainAxisAlignment: centered
              ? MainAxisAlignment.center
              : MainAxisAlignment.start,
          children: [
            const Icon(
              Icons.verified_user_outlined,
              size: 22,
              color: WhisperBrandColors.lavender,
            ),
            const SizedBox(width: 9),
            Text(
              'Only verified MITS DU students',
              style: TextStyle(
                color: WhisperBrandColors.softLavender,
                fontSize: taglineSize < 19 ? 14 : 16,
                letterSpacing: 0.05,
              ),
            ),
          ],
        ),
        if (_message.isNotEmpty) ...[
          const SizedBox(height: 18),
          Text(
            _message,
            textAlign: centered ? TextAlign.center : TextAlign.left,
            style: const TextStyle(color: Color(0xFFFFC4CD), height: 1.4),
          ),
        ],
      ],
    );
  }
}

class _MitsDuSeal extends StatelessWidget {
  const _MitsDuSeal({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Madhav Institute of Technology & Science, Deemed University',
      child: Semantics(
        image: true,
        label: 'MITS DU seal',
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.92),
            shape: BoxShape.circle,
            border: Border.all(
              color: WhisperBrandColors.lavender.withValues(alpha: 0.58),
            ),
          ),
          child: ClipOval(
            child: Image.asset(
              'assets/branding/mits_du_seal.jpg',
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
              filterQuality: FilterQuality.medium,
            ),
          ),
        ),
      ),
    );
  }
}

class _GoogleMark extends StatelessWidget {
  const _GoogleMark();

  @override
  Widget build(BuildContext context) {
    return const Text(
      'G',
      style: TextStyle(
        fontFamily: 'Arial',
        fontSize: 27,
        fontWeight: FontWeight.w700,
        color: Color(0xFF4285F4),
        height: 1,
      ),
    );
  }
}

class _CampusArchitecturePainter extends CustomPainter {
  const _CampusArchitecturePainter({required this.opacity});

  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(0, size.height * 0.62);
    canvas.scale(1, 0.40);

    final stroke = Paint()
      ..color = WhisperBrandColors.lineArt.withValues(alpha: opacity)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.05
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    final fill = Paint()
      ..color = WhisperBrandColors.background.withValues(alpha: 0.10)
      ..style = PaintingStyle.fill;

    final w = size.width;
    final h = size.height;
    final ground = h * 0.88;

    final leftWing = Path()
      ..moveTo(0, h * 0.23)
      ..lineTo(w * 0.19, h * 0.31)
      ..lineTo(w * 0.19, ground)
      ..lineTo(0, ground);
    final centerWing = Path()
      ..moveTo(w * 0.19, h * 0.34)
      ..lineTo(w * 0.51, h * 0.38)
      ..lineTo(w * 0.51, ground)
      ..lineTo(w * 0.19, ground);
    final rightWing = Path()
      ..moveTo(w * 0.51, h * 0.29)
      ..lineTo(w, h * 0.19)
      ..lineTo(w, ground)
      ..lineTo(w * 0.51, ground);

    for (final path in [leftWing, centerWing, rightWing]) {
      canvas.drawPath(path, fill);
      canvas.drawPath(path, stroke);
    }

    _drawFloorLines(canvas, stroke, w, h, ground, 0.48, 0.66, 0.82);
    _drawWindows(
      canvas,
      stroke,
      w * 0.025,
      w * 0.175,
      h * 0.42,
      h * 0.78,
      4,
      3,
    );
    _drawWindows(
      canvas,
      stroke,
      w * 0.215,
      w * 0.485,
      h * 0.48,
      h * 0.79,
      5,
      3,
    );
    _drawWindows(canvas, stroke, w * 0.545, w * 0.97, h * 0.39, h * 0.78, 6, 3);

    final roofDetail = Path()
      ..moveTo(w * 0.04, h * 0.38)
      ..lineTo(w * 0.19, h * 0.40)
      ..moveTo(w * 0.23, h * 0.44)
      ..lineTo(w * 0.48, h * 0.47)
      ..moveTo(w * 0.55, h * 0.36)
      ..lineTo(w * 0.96, h * 0.27);
    canvas.drawPath(roofDetail, stroke);

    final base = Path()
      ..moveTo(0, h * 0.88)
      ..quadraticBezierTo(w * 0.22, h * 0.84, w * 0.47, h * 0.89)
      ..quadraticBezierTo(w * 0.75, h * 0.94, w, h * 0.87);
    canvas.drawPath(base, stroke);
    canvas.restore();
  }

  void _drawFloorLines(
    Canvas canvas,
    Paint paint,
    double width,
    double height,
    double ground,
    double firstY,
    double secondY,
    double thirdY,
  ) {
    final path = Path()
      ..moveTo(0, height * firstY)
      ..lineTo(width * 0.19, height * (firstY + 0.015))
      ..moveTo(width * 0.19, height * secondY)
      ..lineTo(width * 0.51, height * (secondY + 0.015))
      ..moveTo(width * 0.51, height * thirdY)
      ..lineTo(width, height * (thirdY - 0.02))
      ..moveTo(0, ground - height * 0.08)
      ..lineTo(width * 0.19, ground - height * 0.075)
      ..moveTo(width * 0.19, ground - height * 0.08)
      ..lineTo(width * 0.51, ground - height * 0.075)
      ..moveTo(width * 0.51, ground - height * 0.08)
      ..lineTo(width, ground - height * 0.09);
    canvas.drawPath(path, paint);
  }

  void _drawWindows(
    Canvas canvas,
    Paint paint,
    double left,
    double right,
    double top,
    double bottom,
    int columns,
    int rows,
  ) {
    final path = Path();
    final gap = (right - left) / columns;
    final rowHeight = (bottom - top) / rows;
    for (var column = 0; column < columns; column++) {
      for (var row = 0; row < rows; row++) {
        final rect = Rect.fromLTRB(
          left + gap * column + gap * 0.2,
          top + rowHeight * row + rowHeight * 0.16,
          left + gap * column + gap * 0.78,
          top + rowHeight * row + rowHeight * 0.82,
        );
        path.addRect(rect);
        path
          ..moveTo(rect.left, rect.top + rect.height * 0.62)
          ..lineTo(rect.right, rect.top + rect.height * 0.62);
      }
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _CampusArchitecturePainter oldDelegate) =>
      oldDelegate.opacity != opacity;
}
