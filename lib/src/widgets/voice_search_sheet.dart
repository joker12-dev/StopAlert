import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../widgets/mascot.dart';

/// Sesli arama alt sayfası — konuşurken ne duyulduğunu gösterir.
///
/// Yalnızca GÖRSEL katman: dinleme/izin işini çağıran ekran (arama) yürütür,
/// buraya duyulan metin ve durum akar. Kullanıcı "Bitir"e basınca ya da
/// tanıma tamamlanınca kapanır.
class VoiceSearchSheet extends StatelessWidget {
  const VoiceSearchSheet({
    super.key,
    required this.words,
    required this.listening,
    required this.level,
    required this.onStop,
  });

  /// O ana kadar tanınan metin.
  final String words;

  /// Mikrofon hâlâ dinliyor mu.
  final bool listening;

  /// Ses seviyesi (0..1) — halka bunun kadar büyür.
  final double level;

  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: VigilantColors.surfaceVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // Ses seviyesine göre büyüyen halka + mikrofon
            SizedBox(
              height: 132,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    width: 84 + level.clamp(0, 1) * 46,
                    height: 84 + level.clamp(0, 1) * 46,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: VigilantColors.primary.withValues(
                          alpha: listening ? 0.18 : 0.06),
                    ),
                  ),
                  Container(
                    width: 84,
                    height: 84,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: listening
                          ? VigilantColors.primary
                          : VigilantColors.surfaceContainerHigh,
                      boxShadow: listening
                          ? [
                              BoxShadow(
                                  color: VigilantColors.primary
                                      .withValues(alpha: 0.45),
                                  blurRadius: 24),
                            ]
                          : null,
                    ),
                    child: Icon(listening ? Icons.mic : Icons.mic_off,
                        color: listening
                            ? Colors.white
                            : VigilantColors.onSurfaceVariant,
                        size: 36),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text(
              listening ? 'Dinliyorum…' : 'Dinleme durdu',
              style: text.headlineSmall?.copyWith(fontSize: 20),
            ),
            const SizedBox(height: 8),
            // Duyulan metin ya da örnek ipucu
            SizedBox(
              height: 72,
              child: Center(
                child: words.isEmpty
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Mascot(MascotAssets.merhaba, height: 44),
                          const SizedBox(height: 6),
                          Text(
                            'Durak ya da hat adı söyle\nörn. "Kadıköy" veya "MK13"',
                            textAlign: TextAlign.center,
                            style: text.labelMedium?.copyWith(
                                color: VigilantColors.onSurfaceVariant),
                          ),
                        ],
                      )
                    : Text(
                        words,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: text.headlineSmall?.copyWith(
                            fontSize: 22, fontWeight: FontWeight.w700),
                      ),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: listening
                      ? VigilantColors.surfaceContainerHigh
                      : VigilantColors.primary,
                  foregroundColor:
                      listening ? VigilantColors.onSurface : Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                onPressed: onStop,
                child: Text(listening ? 'Bitir' : 'Kapat'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
