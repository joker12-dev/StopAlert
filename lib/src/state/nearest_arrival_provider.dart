import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../data/transit_db.dart';
import '../engine/arrival_estimator.dart';
import '../services/bus_data_service.dart';
import '../services/live_bus_service.dart';
import '../services/segment_learning_store.dart';
import 'city_provider.dart';
import 'journey_provider.dart';

/// En yakın durağa YAKLAŞAN en erken otobüs — ana sayfa kartı için.
class NearestBus {
  const NearestBus({
    required this.code,
    required this.direction,
    required this.minutes,
    required this.imminent,
  });

  /// Hat kodu (ör. "34A").
  final String code;

  /// Hattın adı/yönü (ör. "Cevizlibağ - Söğütlüçeşme").
  final String direction;

  /// Orta tahmin — dakika.
  final int minutes;

  /// ~2 dk içindeyse "şimdi" gösterilir.
  final bool imminent;
}

/// En yakın OTOBÜS durağına yaklaşan en erken canlı otobüs (yoksa null).
///
/// [nearbyStopsProvider] ile en yakın durak alınır; durak otobüs durağıysa
/// geçen lastikli hatların canlı araçlarından bu durağa varış hesaplanır
/// (bkz. [ArrivalEstimator]) ve en erken olanı döndürülür. Ray/vapur durağı
/// ya da canlı araç yoksa null. Ağ hatası akışı bozmaz; null döner.
final nearestApproachingBusProvider = FutureProvider<NearestBus?>((ref) async {
  final hits = await ref.watch(nearbyStopsProvider.future);
  if (hits.isEmpty) return null;
  final stop = hits.first.stop;
  // Yalnızca otobüs durağı: ray/vapur durağında "yaklaşan otobüs" olmaz.
  if (!isBusId(stop.id)) return null;

  final city = ref.read(activeCityProvider);

  List<TransitLineBrief> briefs;
  try {
    await BusDataService.instance.openAllForLookup();
    briefs = await TransitDb.instance.linesForStopAnyCity(stop.id);
  } catch (_) {
    return null;
  }
  final rubber = [
    for (final b in briefs)
      if (b.type == LineType.bus || b.type == LineType.metrobus) b,
  ];
  if (rubber.isEmpty) return null;

  final learner = await SegmentLearningStore.load();
  ArrivalEstimate? best;
  TransitLine? bestLine;
  TransitLineBrief? bestBrief;

  // En fazla birkaç hat sorgulanır (canlı istek pahalı).
  for (final brief in rubber.take(8)) {
    try {
      final line = await TransitDb.instance.buildLine(brief.id);
      if (line == null || line.indexOfStop(stop.id) <= 0) continue;
      final all = await LiveBusService.instance
          .vehicles(brief.code, city: city, lineId: line.id);
      // Yalnızca BU yöndeki araçlar (karşı yön yanlış otobüs demektir).
      final isGidis = line.id.endsWith('_G');
      final sameWay = [
        for (final v in all)
          if (v.routeCode.contains('_G_') || v.routeCode.contains('_D_'))
            if (v.isGidis == isGidis) v,
      ];
      if (sameWay.isEmpty) continue;

      final ests = ArrivalEstimator.forStop(
        line: line,
        targetStopId: stop.id,
        vehicles: sameWay,
        learner: learner,
      );
      for (final e in ests) {
        if (e.seconds > 30 * 60) continue; // yarım saatten uzağı gösterme
        if (best == null || e.seconds < best.seconds) {
          best = e;
          bestLine = line;
          bestBrief = brief;
        }
      }
    } catch (_) {
      // Bu hat atlanır; ötekiler denenir.
    }
  }

  if (best == null || bestLine == null || bestBrief == null) return null;
  return NearestBus(
    code: bestBrief.code,
    direction: bestLine.name,
    minutes: (best.seconds / 60).round(),
    imminent: best.maxSeconds <= 120,
  );
});
