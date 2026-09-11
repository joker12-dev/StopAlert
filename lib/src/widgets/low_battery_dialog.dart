import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// "Alarmı Başlat"a basıldığında ŞARJ DÜŞÜKSE çıkan uyarı.
///
/// Takip arka planda konum okuduğu için pil tüketir; kullanıcıyı önden uyarır
/// (kulaklık, şarj, yolu ekrandan izleme) ve animasyonlu bir "boşalan pil"
/// görseliyle durumu somutlaştırır. "Yine de başlat" → true, "Vazgeç" → false.
class LowBatteryDialog extends StatefulWidget {
  const LowBatteryDialog({super.key, required this.level});

  /// 0-100 arası yüzde.
  final int level;

  @override
  State<LowBatteryDialog> createState() => _LowBatteryDialogState();
}

class _LowBatteryDialogState extends State<LowBatteryDialog>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1700))
      ..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return AlertDialog(
      backgroundColor: VigilantColors.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 104,
            child: _DrainingBattery(controller: _c, level: widget.level),
          ),
          const SizedBox(height: 18),
          Text('Şarjın az — %${widget.level}',
              textAlign: TextAlign.center,
              style: text.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Text(
            'Takip arka planda konum okur ve pili tüketir. Daha iyi bir deneyim '
            'için kulaklık tak, mümkünse telefonu şarjda tut ve yolunu ekrandan '
            'da izle — alarmı kaçırmazsın.',
            textAlign: TextAlign.center,
            style: text.bodyMedium?.copyWith(
                color: VigilantColors.onSurfaceVariant, height: 1.35),
          ),
        ],
      ),
      actionsAlignment: MainAxisAlignment.spaceBetween,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Vazgeç'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Yine de başlat'),
        ),
      ],
    );
  }
}

/// Sürekli boşalan pil görseli: dolum aşağı iner, renk turuncudan kırmızıya
/// döner, sonra başa sarar.
class _DrainingBattery extends StatelessWidget {
  const _DrainingBattery({required this.controller, required this.level});

  final AnimationController controller;
  final int level;

  @override
  Widget build(BuildContext context) {
    const bodyW = 58.0;
    const bodyH = 92.0;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final t = controller.value; // 0..1 döngü
        // Dolum 0.62 → 0.12 arası boşalır.
        final frac = 0.62 - 0.5 * t;
        final color = Color.lerp(
            const Color(0xFFFFB020), VigilantColors.primary, t)!;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Pil ucu (üstteki küçük çıkıntı).
            Container(
              width: 22,
              height: 6,
              decoration: BoxDecoration(
                color: VigilantColors.onSurfaceVariant,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            const SizedBox(height: 2),
            // Pil gövdesi.
            Container(
              width: bodyW,
              height: bodyH,
              padding: const EdgeInsets.all(5),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: VigilantColors.onSurfaceVariant, width: 2.5),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(7),
                child: Stack(
                  alignment: Alignment.bottomCenter,
                  children: [
                    // Boşalan dolum.
                    FractionallySizedBox(
                      widthFactor: 1,
                      heightFactor: frac.clamp(0.08, 1.0),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: [color, color.withValues(alpha: 0.75)],
                          ),
                        ),
                      ),
                    ),
                    // Ortada şimşek.
                    Center(
                      child: Icon(Icons.bolt_rounded,
                          size: 30,
                          color: VigilantColors.onSurface
                              .withValues(alpha: 0.85)),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
