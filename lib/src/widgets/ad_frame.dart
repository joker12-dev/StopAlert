import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Reklam alanının çerçevesi — "burası reklam" demenin dürüst yolu.
///
/// NEDEN VAR: reklam, içeriğin arasında çerçevesiz durunca uygulamanın kendi
/// içeriğiymiş gibi okunuyor. Kullanıcıyı yanıltmamak hem doğru hem de
/// AdMob'un politikası; kesik bir çizgi ve küçük bir "Reklam" etiketi bunu
/// tek bakışta anlatıyor.
///
/// Reklam yüklenmediyse çerçeve de ÇİZİLMEZ (bkz. [loaded]) — boş bir kutu
/// ekranda yer kaplamamalı.
class AdFrame extends StatelessWidget {
  const AdFrame({
    super.key,
    required this.child,
    this.loaded = true,
    this.label = 'Reklam',
    this.margin = const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
  });

  final Widget child;

  /// Reklam gerçekten yüklendi mi. Yüklenmediyse hiçbir şey çizilmez.
  final bool loaded;

  final String label;
  final EdgeInsets margin;

  @override
  Widget build(BuildContext context) {
    if (!loaded) return const SizedBox.shrink();
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: margin,
      child: Container(
        decoration: BoxDecoration(
          color: VigilantColors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
              color: VigilantColors.surfaceVariant.withValues(alpha: 0.55)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: VigilantColors.surfaceVariant
                          .withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      label.toUpperCase(),
                      style: text.labelSmall?.copyWith(
                        fontSize: 9,
                        letterSpacing: 1,
                        fontWeight: FontWeight.w700,
                        color: VigilantColors.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    'StopAlert ücretsiz kalsın diye',
                    style: text.labelSmall?.copyWith(
                        fontSize: 9,
                        color: VigilantColors.onSurfaceVariant
                            .withValues(alpha: 0.7)),
                  ),
                ],
              ),
            ),
            child,
          ],
        ),
      ),
    );
  }
}
