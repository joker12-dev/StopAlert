import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/iett_service.dart';
import '../services/izmir_traffic_service.dart';
import '../services/kocaeli_traffic_service.dart';
import '../theme/app_theme.dart';
import '../util/platform_check.dart';
import 'traffic_gauge.dart';

/// İstanbul anlık trafik yoğunluğu (0-100). Ağ yoksa/başarısızsa null.
final trafficProvider = FutureProvider<int?>((ref) async {
  if (!isMobileDevice) return null; // test/masaüstü: ağ isteği yok
  return IettService.instance.trafficIndex();
});

/// Kocaeli anlık trafik yoğunluğu (0-100) — Akıllı Şehir Kocaeli servisi.
///
/// force: provider'lar session boyunca yalnızca bir kez çalışıp değeri
/// donduruyordu; [TrafficStrip] belirli aralıkla invalidate ediyor ve force
/// ile HER SEFERİNDE taze çekilir (servisin 5 dk önbelleğine takılmaz).
final kocaeliTrafficProvider = FutureProvider<int?>((ref) async {
  if (!isMobileDevice) return null;
  return KocaeliTrafficService.instance.index(force: true);
});

/// İzmir anlık trafik yoğunluğu (0-100) — İZUM travel-times (level + delay/time).
final izmirTrafficProvider = FutureProvider<int?>((ref) async {
  if (!isMobileDevice) return null;
  return IzmirTrafficService.instance.index(force: true);
});

/// Şehir trafik yoğunlukları — yatay kaydırmalı kartlar.
///
/// İstanbul (İBB Ulaşım Yönetim Merkezi) ve Kocaeli (Akıllı Şehir Kocaeli)
/// canlıdır. Kalan şehirler veri kaynağı bağlanana kadar yer tutucudur.
class TrafficStrip extends ConsumerStatefulWidget {
  const TrafficStrip({super.key});

  @override
  ConsumerState<TrafficStrip> createState() => _TrafficStripState();
}

class _TrafficStripState extends ConsumerState<TrafficStrip> {
  static const _soonCities = ['Sakarya', 'Ankara', 'Bursa'];

  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // Trafik CANLI kalsın: belirli aralıkla providers'ı tazele (yoksa session
    // boyunca ilk değerde donuyordu — "hep sabit geliyor").
    _timer = Timer.periodic(const Duration(minutes: 4), (_) {
      if (!mounted) return;
      ref.invalidate(trafficProvider);
      ref.invalidate(kocaeliTrafficProvider);
      ref.invalidate(izmirTrafficProvider);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final istanbul = ref.watch(trafficProvider);
    final kocaeli = ref.watch(kocaeliTrafficProvider);
    final izmir = ref.watch(izmirTrafficProvider);

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
            if (istanbul.isLoading || kocaeli.isLoading || izmir.isLoading)
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
          // Halka (96) + yazılar; en büyük yazı tipi ayarında da taşmaz.
          height: 172,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(vertical: 2),
            children: [
              _CityCard(
                city: 'İstanbul',
                percent: istanbul.valueOrNull,
                live: true,
              ),
              const SizedBox(width: 6),
              _CityCard(
                city: 'Kocaeli',
                percent: kocaeli.valueOrNull,
                live: true,
                // Servis durum etiketini kendi veriyor ("Akıcı", "Yoğun"…);
                // kendi eşiğimizi uydurmak yerine onu gösteriyoruz.
                levelLabel: KocaeliTrafficService.instance.level,
              ),
              const SizedBox(width: 6),
              _CityCard(
                city: 'İzmir',
                percent: izmir.valueOrNull,
                live: true,
              ),
              for (final c in _soonCities) ...[
                const SizedBox(width: 6),
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
    this.levelLabel,
  });

  final String city;
  final int? percent;

  /// Servisin kendi durum etiketi; yoksa yüzdeden türetilir.
  final String? levelLabel;

  /// Gerçek veri bağlı mı (false → "yakında" yer tutucu).
  final bool live;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final p = percent;
    // Sade: kutu/çerçeve yok — büyük halka, altında şehir ve durum.
    return Opacity(
      opacity: live ? 1 : 0.45,
      child: SizedBox(
        width: 116,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TrafficGauge(
                percent: live ? p : null,
                size: 96,
                stroke: 9,
                // Parıltı yalnızca canlı + veri gelmiş halkada.
                sheen: live && p != null),
            const SizedBox(height: 12),
            Text(city,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(
              !live
                  ? 'yakında'
                  : (p == null
                      ? 'veri yok'
                      : (levelLabel?.isNotEmpty ?? false)
                          ? levelLabel!
                          : TrafficGauge.labelFor(p)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
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
