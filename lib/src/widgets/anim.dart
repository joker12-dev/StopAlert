import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../util/anim_config.dart';

/// Mount'ta fade + hafif yukarı kayma (tek seferlik). Bölümler kademeli
/// [delayMs] ile açılınca premium "giriş" hissi verir. [AppAnim] kapalıysa
/// (test) anında görünür.
class EntranceFade extends StatefulWidget {
  const EntranceFade({super.key, required this.child, this.delayMs = 0});

  final Widget child;
  final int delayMs;

  @override
  State<EntranceFade> createState() => _EntranceFadeState();
}

class _EntranceFadeState extends State<EntranceFade>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 440));
    if (!AppAnim.enabled) {
      _c.value = 1;
    } else {
      Future.delayed(Duration(milliseconds: widget.delayMs), () {
        if (mounted) _c.forward();
      });
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!AppAnim.enabled) return widget.child;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        final t = Curves.easeOutCubic.transform(_c.value);
        return Opacity(
          opacity: t,
          child: Transform.translate(offset: Offset(0, (1 - t) * 16), child: child),
        );
      },
      child: widget.child,
    );
  }
}

/// Periyodik hafif sallanma (bildirim zili gibi). Sürekli tekrar; [AppAnim]
/// ile geçilir.
class ShakeIcon extends StatefulWidget {
  const ShakeIcon({super.key, required this.child, this.period = 4200});

  final Widget child;
  final int period;

  @override
  State<ShakeIcon> createState() => _ShakeIconState();
}

class _ShakeIconState extends State<ShakeIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: Duration(milliseconds: widget.period));
    if (AppAnim.enabled) _c.repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!AppAnim.enabled) return widget.child;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        // Döngünün yalnızca ilk ~%14'ünde sönümlenen bir titreşim.
        final v = _c.value;
        final burst = v < 0.14 ? (1 - v / 0.14) : 0.0;
        final angle = math.sin(v * math.pi * 18) * 0.28 * burst;
        return Transform.rotate(angle: angle, child: child);
      },
      child: widget.child,
    );
  }
}

/// Nabız atan küçük nokta (konum göstergesi). Sürekli tekrar; [AppAnim] ile
/// geçilir (kapalıyken sabit nokta).
class PulseDot extends StatefulWidget {
  const PulseDot({super.key, required this.color, this.size = 9});

  final Color color;
  final double size;

  @override
  State<PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1800));
    if (AppAnim.enabled) _c.repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Widget get _dot => Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(shape: BoxShape.circle, color: widget.color),
      );

  @override
  Widget build(BuildContext context) {
    if (!AppAnim.enabled) return _dot;
    return SizedBox(
      width: widget.size * 2.6,
      height: widget.size * 2.6,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, child) {
          final t = _c.value;
          return Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: widget.size + t * widget.size * 1.8,
                height: widget.size + t * widget.size * 1.8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.color.withValues(alpha: (1 - t) * 0.35),
                ),
              ),
              child!,
            ],
          );
        },
        child: _dot,
      ),
    );
  }
}

/// Alt menü sekmeleri arasında geçiş hissi.
///
/// [IndexedStack] durumu koruyor ama sekme bir anda takla atmış gibi
/// değişiyordu. Çocukları değiştirmek (AnimatedSwitcher) durumu yok ederdi —
/// harita kamerası, kaydırma konumu, açık paneller sıfırlanırdı. Bu yüzden
/// yığının KENDİSİ kısa bir sönümle içeri giriyor: durum korunuyor, geçiş
/// yumuşuyor.
class TabSwitchTransition extends StatefulWidget {
  const TabSwitchTransition({
    super.key,
    required this.index,
    required this.child,
  });

  /// Değiştiğinde geçiş oynatılır.
  final int index;
  final Widget child;

  @override
  State<TabSwitchTransition> createState() => _TabSwitchTransitionState();
}

class _TabSwitchTransitionState extends State<TabSwitchTransition>
    with SingleTickerProviderStateMixin {
  // initState'TE KURULUR, `late final` ile DEĞİL. Tembel alan, animasyon
  // kapalıyken (testler) build sırasında hiç okunmuyor; dispose onu o anda
  // kurmaya çalışınca ağaçtan çıkmış bir öğeden TickerMode aranıyor ve
  // çöküyordu.
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
      value: 1,
    );
  }

  @override
  void didUpdateWidget(covariant TabSwitchTransition old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index && AppAnim.enabled) _c.forward(from: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!AppAnim.enabled) return widget.child;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        final t = Curves.easeOutCubic.transform(_c.value);
        return Opacity(
          opacity: 0.35 + 0.65 * t,
          // Yalnızca birkaç piksel: sekme değişimi fark edilsin ama sayfa
          // "kayıyor" hissi vermesin.
          child: Transform.translate(offset: Offset(0, 10 * (1 - t)), child: child),
        );
      },
      child: widget.child,
    );
  }
}
