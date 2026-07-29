import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Dairesel ilerleme halkası — canlı takipte "kalan durak"ı görselleştirir.
///
/// Yol alındıkça halka dolar; renk yeşilden (yeni başladın) ambere, oradan
/// markanın kırmızısına (durağın dibindesin) geçer. Ortada serbest bir [child]
/// (kalan durak sayısı + etiket) durur. [progress] 0..1 arasıdır.
class ProgressRing extends StatelessWidget {
  const ProgressRing({
    super.key,
    required this.progress,
    required this.child,
    this.size = 148,
    this.strokeWidth = 12,
  });

  /// 0 = yolculuk başı, 1 = hedefe varış.
  final double progress;
  final Widget child;
  final double size;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      // Değer değiştikçe yumuşak dolum (tek seferlik — testi kilitlemez).
      tween: Tween(begin: 0, end: progress.clamp(0.0, 1.0)),
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeOutCubic,
      builder: (context, value, _) {
        return SizedBox(
          width: size,
          height: size,
          child: CustomPaint(
            painter: _RingPainter(progress: value, strokeWidth: strokeWidth),
            child: Center(child: child),
          ),
        );
      },
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.progress, required this.strokeWidth});

  final double progress;
  final double strokeWidth;

  static const _sweepColors = [
    VigilantColors.secondary, // yeşil — yeni başladı
    VigilantColors.tertiaryContainer, // amber — yaklaşıyor
    VigilantColors.primary, // kırmızı — dibinde
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = (size.width - strokeWidth) / 2;
    const start = -math.pi / 2; // tepe noktası (12 yönü)
    final sweep = 2 * math.pi * progress.clamp(0.0, 1.0);

    // Arka iz
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..color = VigilantColors.surfaceContainerHighest;
    canvas.drawCircle(center, radius, track);

    if (progress <= 0) return;

    // İlerleme yayı — renk geçişli.
    final rect = Rect.fromCircle(center: center, radius: radius);
    final gradient = SweepGradient(
      startAngle: 0,
      endAngle: 2 * math.pi,
      transform: const GradientRotation(-math.pi / 2),
      colors: _sweepColors,
      stops: const [0.0, 0.55, 1.0],
    );
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..shader = gradient.createShader(rect);
    canvas.drawArc(rect, start, sweep, false, arc);

    // Yay ucunda küçük parlayan nokta
    final endAngle = start + sweep;
    final dot = Offset(
      center.dx + radius * math.cos(endAngle),
      center.dy + radius * math.sin(endAngle),
    );
    canvas.drawCircle(
      dot,
      strokeWidth / 2 + 1,
      Paint()..color = Colors.white.withValues(alpha: 0.9),
    );
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) =>
      old.progress != progress || old.strokeWidth != strokeWidth;
}
