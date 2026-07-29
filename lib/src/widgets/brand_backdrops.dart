import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Kodla çizilen marka arkaplanları — görsel dosyası gerektirmez.
///
/// Tasarım paketindeki "hero banner arkaplanı" ve "dekoratif ögeler"
/// dilinin vektörel karşılığı: şehir silüeti, kesikli rota, konum
/// iğneleri, yumuşak ışıma ve nokta ızgarası. Statik çizimdir (animasyon
/// yok) — widget testlerinde pumpAndSettle'ı etkilemez.
class HeroBackdrop extends StatelessWidget {
  const HeroBackdrop({super.key});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _HeroBackdropPainter(), size: Size.infinite);
  }
}

class _HeroBackdropPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    const red = VigilantColors.primary;

    // 1) Maskotun arkasına yumuşak ışıma.
    final glowCenter = Offset(w * 0.80, h * 0.58);
    final glow = Paint()
      ..shader = RadialGradient(
        colors: [red.withValues(alpha: 0.16), Colors.transparent],
      ).createShader(Rect.fromCircle(center: glowCenter, radius: w * 0.30));
    canvas.drawCircle(glowCenter, w * 0.30, glow);

    // 2) Alt kenarda İstanbul silüeti (kubbe + minareler + bloklar + köprü).
    final sil = Paint()..color = red.withValues(alpha: 0.09);
    void block(double x, double bw, double bh) =>
        canvas.drawRect(Rect.fromLTWH(x, h - bh, bw, bh), sil);
    block(0, w * 0.07, h * 0.14);
    block(w * 0.09, w * 0.05, h * 0.22);
    block(w * 0.16, w * 0.08, h * 0.10);
    // Kubbe
    canvas.drawArc(
      Rect.fromLTWH(w * 0.26, h - h * 0.30, w * 0.16, h * 0.34),
      math.pi,
      math.pi,
      true,
      sil,
    );
    // Minareler (ince kule + uç)
    void minaret(double x) {
      canvas.drawRect(Rect.fromLTWH(x, h - h * 0.34, w * 0.012, h * 0.34), sil);
      final tip = Path()
        ..moveTo(x - w * 0.004, h - h * 0.34)
        ..lineTo(x + w * 0.006, h - h * 0.42)
        ..lineTo(x + w * 0.016, h - h * 0.34)
        ..close();
      canvas.drawPath(tip, sil);
    }

    minaret(w * 0.24);
    minaret(w * 0.435);
    // Köprü: iki kule + kesikli halat hissi veren yay
    block(w * 0.52, w * 0.012, h * 0.30);
    block(w * 0.66, w * 0.012, h * 0.30);
    final rope = Path()
      ..moveTo(w * 0.50, h - h * 0.28)
      ..quadraticBezierTo(w * 0.59, h - h * 0.06, w * 0.685, h - h * 0.28);
    canvas.drawPath(
      rope,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = red.withValues(alpha: 0.12),
    );

    // 3) Kesikli rota + uçlarında konum iğneleri.
    final route = Path()
      ..moveTo(w * 0.05, h * 0.34)
      ..cubicTo(w * 0.22, h * 0.10, w * 0.34, h * 0.52, w * 0.52, h * 0.22);
    _drawDashed(
      canvas,
      route,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = red.withValues(alpha: 0.28),
    );
    _pin(canvas, Offset(w * 0.05, h * 0.34), 5, red.withValues(alpha: 0.45));
    _pin(canvas, Offset(w * 0.52, h * 0.22), 6, red.withValues(alpha: 0.55));

    // 4) Sol alt köşede seyrek nokta ızgarası.
    final dot = Paint()..color = red.withValues(alpha: 0.10);
    for (var i = 0; i < 4; i++) {
      for (var j = 0; j < 3; j++) {
        canvas.drawCircle(
          Offset(w * 0.05 + i * 10.0, h * 0.62 + j * 10.0),
          1.2,
          dot,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Hızlı Başlat kartları için renk parametreli, sade arka doku:
/// köşe ışıması + kesikli yay + mini iğne.
class ChipBackdrop extends StatelessWidget {
  const ChipBackdrop({super.key, required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _ChipBackdropPainter(color),
      size: Size.infinite,
    );
  }
}

class _ChipBackdropPainter extends CustomPainter {
  const _ChipBackdropPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // İkonun arkasına köşe ışıması.
    final glow = Paint()
      ..shader = RadialGradient(
        colors: [color.withValues(alpha: 0.22), Colors.transparent],
      ).createShader(
        Rect.fromCircle(center: Offset(w * 0.22, h * 0.18), radius: w * 0.55),
      );
    canvas.drawCircle(Offset(w * 0.22, h * 0.18), w * 0.55, glow);

    // Sağ üstten inen kesikli yay + iğne.
    final arc = Path()
      ..moveTo(w * 1.02, h * 0.30)
      ..quadraticBezierTo(w * 0.72, h * 0.38, w * 0.66, h * 0.06);
    _drawDashed(
      canvas,
      arc,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.3
        ..color = color.withValues(alpha: 0.30),
    );
    _pin(canvas, Offset(w * 0.66, h * 0.06), 4, color.withValues(alpha: 0.45));

    // Alt bölgede seyrek noktalar.
    final dot = Paint()..color = color.withValues(alpha: 0.14);
    canvas.drawCircle(Offset(w * 0.82, h * 0.58), 1.4, dot);
    canvas.drawCircle(Offset(w * 0.90, h * 0.66), 1.1, dot);
    canvas.drawCircle(Offset(w * 0.76, h * 0.70), 1.1, dot);
  }

  @override
  bool shouldRepaint(covariant _ChipBackdropPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// [path]'i kesikli çizer.
void _drawDashed(Canvas canvas, Path path, Paint paint,
    {double dash = 6, double gap = 5}) {
  for (final metric in path.computeMetrics()) {
    var d = 0.0;
    while (d < metric.length) {
      canvas.drawPath(
        metric.extractPath(d, math.min(d + dash, metric.length)),
        paint,
      );
      d += dash + gap;
    }
  }
}

/// Küçük konum iğnesi (damla gövde + beyaz merkez).
void _pin(Canvas canvas, Offset center, double r, Color color) {
  final body = Paint()..color = color;
  canvas.drawCircle(center, r, body);
  final tail = Path()
    ..moveTo(center.dx - r * 0.62, center.dy + r * 0.35)
    ..lineTo(center.dx + r * 0.62, center.dy + r * 0.35)
    ..lineTo(center.dx, center.dy + r * 1.9)
    ..close();
  canvas.drawPath(tail, body);
  canvas.drawCircle(
    center,
    r * 0.38,
    Paint()..color = Colors.white.withValues(alpha: 0.9),
  );
}
