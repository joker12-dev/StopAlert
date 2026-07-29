import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../util/anim_config.dart';

/// Varışta bir kez patlayan konfeti — dış paket olmadan (CustomPainter).
///
/// Tek seferlik oynatılır (forward), yaklaşık 2.6 sn sonra durur; sürekli
/// tekrarlamadığı için `pumpAndSettle`'ı kilitlemez. Bir Stack içinde
/// `Positioned.fill` olarak kullanılır ve dokunuşları geçirir.
class ConfettiOverlay extends StatefulWidget {
  const ConfettiOverlay({super.key, this.particleCount = 90});

  final int particleCount;

  @override
  State<ConfettiOverlay> createState() => _ConfettiOverlayState();
}

class _ConfettiOverlayState extends State<ConfettiOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  late final List<_Particle> _particles;

  static const _colors = [
    VigilantColors.primary,
    VigilantColors.secondary,
    VigilantColors.tertiaryContainer,
    VigilantColors.accentBlue,
    Colors.white,
  ];

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    );
    final rnd = math.Random(7);
    _particles = [
      for (var i = 0; i < widget.particleCount; i++)
        _Particle(
          // İki üst köşeden yelpaze gibi fırlar.
          origin: i.isEven ? const Offset(0.12, 0.18) : const Offset(0.88, 0.18),
          angle: (i.isEven ? -0.5 : math.pi + 0.5) +
              (rnd.nextDouble() - 0.5) * 1.6,
          speed: 0.55 + rnd.nextDouble() * 0.9,
          color: _colors[rnd.nextInt(_colors.length)],
          size: 6 + rnd.nextDouble() * 8,
          spin: (rnd.nextDouble() - 0.5) * 12,
          delay: rnd.nextDouble() * 0.15,
        ),
    ];
    if (AppAnim.enabled) _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => CustomPaint(
          painter: _ConfettiPainter(_particles, _c.value),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class _Particle {
  _Particle({
    required this.origin,
    required this.angle,
    required this.speed,
    required this.color,
    required this.size,
    required this.spin,
    required this.delay,
  });

  final Offset origin; // 0..1 ekran oranı
  final double angle;
  final double speed;
  final Color color;
  final double size;
  final double spin;
  final double delay;
}

class _ConfettiPainter extends CustomPainter {
  _ConfettiPainter(this.particles, this.t);

  final List<_Particle> particles;
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    for (final p in particles) {
      final lt = ((t - p.delay) / (1 - p.delay)).clamp(0.0, 1.0);
      if (lt <= 0) continue;

      // Yatay serbest atış + yerçekimiyle düşme.
      final launch = p.speed * size.height;
      final dx = math.cos(p.angle) * launch * lt;
      final dy = math.sin(p.angle) * launch * lt + 1.9 * launch * lt * lt;
      final pos = Offset(
        p.origin.dx * size.width + dx,
        p.origin.dy * size.height + dy,
      );
      if (pos.dy > size.height + 20) continue;

      final opacity = (1 - lt).clamp(0.0, 1.0);
      canvas.save();
      canvas.translate(pos.dx, pos.dy);
      canvas.rotate(p.spin * lt);
      canvas.drawRect(
        Rect.fromCenter(
            center: Offset.zero, width: p.size, height: p.size * 0.6),
        Paint()..color = p.color.withValues(alpha: opacity),
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _ConfettiPainter old) => old.t != t;
}
