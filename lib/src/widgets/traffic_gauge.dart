import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Trafik yoğunluğu için yuvarlak gösterge: halka doluluk = yoğunluk,
/// ortada yüzde. Renk yoğunlukla değişir (yeşil → turuncu → kırmızı).
///
/// [percent] null ise "veri yok" hâli çizilir (soluk halka, "—").
class TrafficGauge extends StatelessWidget {
  const TrafficGauge({
    super.key,
    required this.percent,
    this.size = 74,
    this.stroke = 7,
  });

  final int? percent;
  final double size;
  final double stroke;

  /// Yoğunluğa göre renk — 40 altı akıcı, 70 üstü yoğun.
  static Color colorFor(int p) {
    if (p < 40) return VigilantColors.secondary;
    if (p < 70) return VigilantColors.tertiaryContainer;
    return VigilantColors.primary;
  }

  /// Yoğunluğun kullanıcı dilinde karşılığı.
  static String labelFor(int p) {
    if (p < 40) return 'Akıcı';
    if (p < 70) return 'Orta';
    return 'Yoğun';
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final p = percent;
    final color = p == null ? VigilantColors.outline : colorFor(p);
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _GaugePainter(
          value: (p ?? 0) / 100,
          color: color,
          stroke: stroke,
          track: VigilantColors.surfaceContainerHigh,
        ),
        child: Center(
          child: Text(
            p == null ? '—' : '%$p',
            style: text.headlineSmall?.copyWith(
              // Yazı halka boyutuyla orantılı büyüsün.
              fontSize: size * 0.28,
              fontWeight: FontWeight.w800,
              color: p == null ? VigilantColors.onSurfaceVariant : color,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  _GaugePainter({
    required this.value,
    required this.color,
    required this.stroke,
    required this.track,
  });

  final double value;
  final Color color;
  final double stroke;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset(stroke / 2, stroke / 2) &
        Size(size.width - stroke, size.height - stroke);
    // Üstten başlayan tam halka.
    const start = -math.pi / 2;
    final trackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = track;
    canvas.drawArc(rect, start, math.pi * 2, false, trackPaint);

    if (value <= 0) return;
    final valuePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        startAngle: 0,
        endAngle: math.pi * 2,
        colors: [color.withValues(alpha: 0.55), color],
        transform: const GradientRotation(-math.pi / 2),
      ).createShader(rect);
    canvas.drawArc(
        rect, start, math.pi * 2 * value.clamp(0.0, 1.0), false, valuePaint);
  }

  @override
  bool shouldRepaint(covariant _GaugePainter old) =>
      old.value != value || old.color != color;
}
