import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/connectivity_provider.dart';
import '../theme/app_theme.dart';

/// İnternet gerektiren bölümlerin üstünde gösterilen "bağlantı yok" şeridi.
///
/// NEDEN VAR: trafik yoğunluğu, canlı takip, duyurular gibi bölümler veri
/// çekemeyince sessizce boş kalıyordu; kullanıcı uygulamanın mı bozuk olduğunu
/// yoksa kendi bağlantısının mı gittiğini anlayamıyordu. Bağlantı kapalıyken
/// bunu açıkça söyler.
///
/// Bağlantı VARKEN hiçbir şey çizmez (yer kaplamaz). Kaba bir ölçüdür
/// (bkz. [connectivityProvider]); yalnızca ipucu verir, veriyi engellemez.
class OfflineBanner extends ConsumerWidget {
  const OfflineBanner({
    super.key,
    this.message = 'İnternet bağlantısı yok — bu bölüm güncellenemiyor.',
    this.margin = const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
  });

  final String message;
  final EdgeInsets margin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final online = ref.watch(connectivityProvider).valueOrNull ?? true;
    if (online) return const SizedBox.shrink();
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: margin,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: VigilantColors.tertiaryContainer.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: VigilantColors.tertiaryContainer.withValues(alpha: 0.4)),
        ),
        child: Row(
          children: [
            const Icon(Icons.wifi_off_rounded,
                size: 16, color: VigilantColors.tertiaryContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(message,
                  style: text.labelSmall?.copyWith(
                      color: VigilantColors.onSurfaceVariant, height: 1.3)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Küçük "çevrimdışı" rozeti — başlık yanına konur (şerit yerine).
class OfflineDot extends ConsumerWidget {
  const OfflineDot({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final online = ref.watch(connectivityProvider).valueOrNull ?? true;
    if (online) return const SizedBox.shrink();
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: VigilantColors.tertiaryContainer.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.wifi_off_rounded,
              size: 12, color: VigilantColors.tertiaryContainer),
          const SizedBox(width: 4),
          Text('Çevrimdışı',
              style: text.labelSmall?.copyWith(
                  fontSize: 10, color: VigilantColors.tertiaryContainer)),
        ],
      ),
    );
  }
}
