import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/iett_service.dart';
import '../theme/app_theme.dart';
import '../util/platform_check.dart';
import 'traffic_gauge.dart';

/// İstanbul anlık trafik yoğunluğu (0-100). Ağ yoksa/başarısızsa null.
final trafficProvider = FutureProvider<int?>((ref) async {
  if (!isMobileDevice) return null; // test/masaüstü: ağ isteği yok
  return IettService.instance.trafficIndex();
});

/// Şehir trafik yoğunlukları — yatay kaydırmalı kartlar.
///
/// Şu an YALNIZCA İstanbul canlıdır (İBB Ulaşım Yönetim Merkezi verisi).
/// Diğer şehirler yer tutucudur: veri kaynağı bağlanana kadar "yakında"
/// olarak, tıklanamaz biçimde gösterilir.
class TrafficStrip extends ConsumerWidget {
  const TrafficStrip({super.key});

  static const _soonCities = ['Kocaeli', 'Sakarya', 'Ankara', 'İzmir', 'Bursa'];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final istanbul = ref.watch(trafficProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.traffic_rounded,
                size: 18, color: VigilantColors.primary),
            const SizedBox(width: 8),
            Text('Trafik Yoğunluğu',
                style: text.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
            const Spacer(),
            if (istanbul.isLoading)
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: VigilantColors.primary),
              ),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          // Yükseklik, en büyük yazı tipi ayarında da taşmayacak kadar geniş.
          height: 164,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(vertical: 2),
            children: [
              _CityCard(
                city: 'İstanbul',
                percent: istanbul.valueOrNull,
                live: true,
              ),
              for (final c in _soonCities) ...[
                const SizedBox(width: 12),
                _CityCard(city: c, percent: null, live: false),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _CityCard extends StatelessWidget {
  const _CityCard({
    required this.city,
    required this.percent,
    required this.live,
  });

  final String city;
  final int? percent;

  /// Gerçek veri bağlı mı (false → "yakında" yer tutucu).
  final bool live;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final p = percent;
    return Opacity(
      opacity: live ? 1 : 0.5,
      child: Container(
        width: 132,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: VigilantColors.surfaceContainer,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: (live && p != null
                    ? TrafficGauge.colorFor(p)
                    : VigilantColors.surfaceVariant)
                .withValues(alpha: live && p != null ? 0.45 : 0.3),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TrafficGauge(percent: live ? p : null),
            const SizedBox(height: 10),
            Text(city,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(
              !live
                  ? 'yakında'
                  : (p == null ? 'veri yok' : TrafficGauge.labelFor(p)),
              style: text.labelSmall?.copyWith(
                color: live && p != null
                    ? TrafficGauge.colorFor(p)
                    : VigilantColors.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
