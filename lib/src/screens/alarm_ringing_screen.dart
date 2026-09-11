import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../util/haptics.dart';
import '../widgets/slide_to_action.dart';

/// Alarm Çalıyor — telefonun yerleşik çalar saati gibi tam ekran, çıkışsız
/// uyarı ekranı. Üstte canlı saat, ortada dalga animasyonlu maskot, altta
/// kaydırarak durdurma + erteleme.
class AlarmRingingScreen extends StatefulWidget {
  const AlarmRingingScreen({
    super.key,
    required this.stopName,
    this.distanceText,
    this.snoozeMinutes = 5,
  });

  final String stopName;
  final String? distanceText;
  final int snoozeMinutes;

  @override
  State<AlarmRingingScreen> createState() => _AlarmRingingScreenState();
}

class _AlarmRingingScreenState extends State<AlarmRingingScreen>
    with TickerProviderStateMixin {
  late final AnimationController _ripple =
      AnimationController(vsync: this, duration: const Duration(seconds: 3))
        ..repeat();
  late final AnimationController _shake = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 600))
    ..repeat();
  bool _allowPop = false;

  DateTime _now = DateTime.now();
  Timer? _clock;

  /// Alarm çalarken cihazı ritmik olarak titreştir (yerleşik alarm hissi;
  /// kullanıcı "Titreşim" ayarı kapalıysa [Haptics] sessiz kalır). Titreşim
  /// TAMAMEN buradan yönetilir (bildirim kanalı titreşmez) — böylece ayar anında
  /// etkiler ve alarm durdurulunca ([_finish]/[dispose]) titreşim de anında biter.
  Timer? _buzz;

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
    _pulse();
    // Her ~1.1 sn'de bir "brr-brr" çift darbe (alarm hissi).
    _buzz = Timer.periodic(const Duration(milliseconds: 1100), (_) => _pulse());
  }

  /// Tek bir titreşim atımı: kısa aralıkla iki güçlü darbe.
  void _pulse() {
    Haptics.heavy();
    Future.delayed(const Duration(milliseconds: 130), () {
      if (mounted) Haptics.heavy();
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    _buzz?.cancel();
    _ripple.dispose();
    _shake.dispose();
    super.dispose();
  }

  String get _clockText {
    final h = _now.hour.toString().padLeft(2, '0');
    final m = _now.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final l = AppLocalizations.of(context);
    return PopScope(
      canPop: _allowPop,
      child: Scaffold(
        body: Stack(
          children: [
            // Dalga halkaları
            Positioned.fill(
              child: AnimatedBuilder(
                animation: _ripple,
                builder: (context, _) => CustomPaint(
                  painter: _RipplePainter(progress: _ripple.value),
                ),
              ),
            ),
            // Üstte canlı saat (çalar saat hissi)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Column(
                    children: [
                      Text(
                        _clockText,
                        style: text.headlineLarge?.copyWith(
                          fontSize: 52,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -1,
                        ),
                      ),
                      Text(
                        l.ringAlarmLabel,
                        style: text.labelSmall?.copyWith(
                          color: VigilantColors.primary,
                          letterSpacing: 4,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // Merkez içerik
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(height: 60),
                    // Parlayan zil
                    AnimatedBuilder(
                      animation: _shake,
                      builder: (context, child) => Transform.rotate(
                        angle: math.sin(_shake.value * math.pi * 4) * 0.08,
                        child: child,
                      ),
                      child: Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: VigilantColors.primaryContainer
                                  .withValues(alpha: 0.35),
                              blurRadius: 52,
                              spreadRadius: 8,
                            ),
                          ],
                        ),
                        // ÇALAR SAAT SİMGESİ, maskot fotoğrafı değil.
                        //
                        // Bu ekran uykudan uyandırmak için var ve yarım
                        // saniyede anlaşılmalı; bir çizim, ne olduğunu
                        // anlamak için bakmayı gerektiriyordu. İç içe iki
                        // halka ve marka kırmızısı, sallanan bir zil.
                        child: Container(
                          width: 168,
                          height: 168,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color:
                                VigilantColors.primary.withValues(alpha: 0.12),
                            border: Border.all(
                                color: VigilantColors.primary
                                    .withValues(alpha: 0.45),
                                width: 2),
                          ),
                          child: Center(
                            child: Container(
                              width: 118,
                              height: 118,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: VigilantColors.primary,
                              ),
                              child: const Icon(
                                Icons.alarm_on_rounded,
                                size: 66,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 32),
                    Text(
                      l.ringApproaching,
                      textAlign: TextAlign.center,
                      style: text.headlineMedium
                          ?.copyWith(color: VigilantColors.tertiaryContainer),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      widget.stopName,
                      textAlign: TextAlign.center,
                      style: text.headlineMedium,
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 6),
                      decoration: BoxDecoration(
                        color: VigilantColors.primary.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: VigilantColors.primary.withValues(alpha: 0.3),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.route_outlined,
                              size: 18, color: VigilantColors.primary),
                          const SizedBox(width: 8),
                          Text(
                            l.ringRemainingDistance(
                                widget.distanceText ?? l.ringActive),
                            style: text.labelLarge
                                ?.copyWith(color: VigilantColors.primary),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      l.ringGetOff,
                      textAlign: TextAlign.center,
                      style: text.bodyLarge
                          ?.copyWith(color: VigilantColors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ),
            // Alt aksiyonlar
            Positioned(
              left: 20,
              right: 20,
              bottom: 32,
              child: Column(
                children: [
                  // Kaydırarak durdur — kaza ile kapanmayı önler.
                  SlideToAction(
                    label: l.ringSlideToStop,
                    icon: Icons.alarm_off,
                    height: 64,
                    fillColor: VigilantColors.primary,
                    onConfirmed: () => _finish('stop'),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    height: 60,
                    width: double.infinity,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            backgroundColor: VigilantColors.surfaceContainerLow
                                .withValues(alpha: 0.4),
                            side: const BorderSide(
                                color: VigilantColors.outlineVariant),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(999),
                            ),
                            foregroundColor: VigilantColors.onSurface,
                            textStyle: text.labelLarge,
                          ),
                          onPressed: () => _finish('snooze'),
                          icon: const Icon(Icons.snooze,
                              size: 20, color: VigilantColors.onSurfaceVariant),
                          label: Text(l.ringSnooze(widget.snoozeMinutes)),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _finish(String result) {
    _buzz?.cancel();
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop(result);
    });
  }
}

/// Merkezden yayılan üç kademeli dalga halkası.
class _RipplePainter extends CustomPainter {
  _RipplePainter({required this.progress});

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2 - 60);
    for (var i = 0; i < 3; i++) {
      final t = (progress + i / 3) % 1.0;
      final radius = 100 + t * 220;
      final opacity = (1 - t) * 0.25;
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..color = VigilantColors.primaryContainer.withValues(alpha: opacity),
      );
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = VigilantColors.primary.withValues(alpha: opacity * 0.6),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RipplePainter oldDelegate) =>
      oldDelegate.progress != progress;
}
