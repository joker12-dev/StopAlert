import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../data/timetable.dart';
import '../data/transit_db.dart';
import '../engine/arrival_estimator.dart';
import '../services/bus_data_service.dart';
import '../services/live_bus_service.dart';
import '../services/segment_learning_store.dart';
import '../services/timetable_service.dart';
import 'city_provider.dart';
import 'journey_provider.dart';

/// En yakın durağa yaklaşan en erken sefer — ana sayfa kartı için.
class NearestBus {
  const NearestBus({
    required this.code,
    required this.direction,
    required this.minutes,
    required this.imminent,
    this.scheduled = false,
  });

  /// Hat kodu (ör. "34A").
  final String code;

  /// Hattın adı/yönü (ör. "Cevizlibağ - Söğütlüçeşme").
  final String direction;

  /// Orta tahmin — dakika.
  final int minutes;

  /// ~2 dk içindeyse "şimdi" gösterilir.
  final bool imminent;

  /// Canlı araç yerine TARİFEYE dayalı (ray/vapur). UI takvim ikonu gösterir.
  final bool scheduled;
}

/// En yakın durağa yaklaşan en erken sefer (yoksa null).
///
/// OTOBÜS durağında: geçen lastikli hatların CANLI araçlarından varış hesaplanır
/// (bkz. [ArrivalEstimator]). RAY/VAPUR durağında: o hattın TARİFESİNDEN sıradaki
/// sefer bulunur. Veri yoksa null; ağ hatası akışı bozmaz.
final nearestApproachingBusProvider = FutureProvider<NearestBus?>((ref) async {
  final hits = await ref.watch(nearbyStopsProvider.future);
  if (hits.isEmpty) return null;
  final hit = hits.first;
  final stop = hit.stop;
  final city = ref.read(activeCityProvider);

  // RAY/VAPUR durağı: canlı konum yok → sıradaki tarifeli sefer.
  if (!isBusId(stop.id)) {
    final line = hit.line;
    if (line == null) return null;
    try {
      final table = await TimetableService.instance
          .forLine(line.code, city: city, type: line.type);
      if (table.isEmpty) return null;
      final rows = table.forDay(DayType.forDate(DateTime.now()),
          outbound: line.id.contains('_G'));
      if (rows.isEmpty) return null;
      final next = ScheduledArrivals.fromSchedule(
        line: line,
        targetStopId: stop.id,
        departures: rows,
        limit: 1,
      );
      if (next.isEmpty) return null;
      return NearestBus(
        code: line.code,
        direction: line.name,
        minutes: (next.first.secondsAway / 60).round(),
        imminent: next.first.secondsAway <= 90,
        scheduled: true,
      );
    } catch (_) {
      return null;
    }
  }

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
