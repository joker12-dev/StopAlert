import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../data/journey_payload.dart';
import '../data/models.dart';
import '../data/transit_db.dart';
import 'bus_data_service.dart';
import 'home_widget_service.dart';
import 'tracking_service.dart';

/// Widget kısayoluna basılınca ARKA PLANDA çalışan giriş noktası.
///
/// Uygulama açılmaz: hat verisi yeniden kurulur, yolculuk yükü hazırlanır ve
/// ön plan takip servisi doğrudan başlatılır. Android'in "arka planda ön plan
/// servisi başlatma" kısıtı widget etkileşiminde muaf tutulur, bu yüzden bu
/// yol çalışır.
///
/// Bu fonksiyon AYRI BİR ISOLATE'te koşar: uygulamanın sağlayıcıları,
/// Riverpod durumu ve açık veritabanı burada YOKTUR; her şey sıfırdan
/// kurulur. Bir aksilikte sessizce çıkılır — kullanıcı widget'taki sade
/// "Alarm kur" düğmesiyle uygulamadan devam edebilir.
@pragma('vm:entry-point')
Future<void> homeWidgetBackgroundCallback(Uri? uri) async {
  if (uri == null || uri.path != HomeWidgetService.pathStartAlarm) return;
  WidgetsFlutterBinding.ensureInitialized();

  final index = int.tryParse(uri.queryParameters['i'] ?? '') ?? 0;
  final ids = await HomeWidgetService.shortcutAt(index);
  if (ids == null) return;

  final line = await _resolveLine(ids.lineId);
  if (line == null) return;
  if (line.indexOfStop(ids.targetStopId) == -1) return;

  // Biniş durağı kaybolduysa hattın başından başlat: kullanıcı zaten yolda
  // olabilir, motor binişi kendi yakalar.
  final boarding = line.indexOfStop(ids.boardingStopId) != -1
      ? ids.boardingStopId
      : line.stops.first.id;
  if (boarding == ids.targetStopId) return;

  await TrackingController.start(JourneyPayload(
    line: line,
    boardingStopId: boarding,
    targetStopId: ids.targetStopId,
    // Kısayolda ayar ekranı yok; uygulamanın varsayılanlarıyla başlar.
    alarmDistanceMeters: 500,
  ));
}

/// Hattı kimliğinden yeniden kurar: otobüs indirilen SQLite'tan, ray/vapur
/// gömülü `lines.json`'dan.
Future<TransitLine?> _resolveLine(String lineId) async {
  try {
    if (isBusId(lineId)) {
      if (!TransitDb.instance.isReady) {
        final path = await BusDataService.instance.localPath();
        if (path == null) return null;
        await TransitDb.instance.open(path);
      }
      return TransitDb.instance.buildLine(lineId);
    }
    final raw = await rootBundle.loadString('assets/data/lines.json');
    final json = jsonDecode(raw) as Map<String, dynamic>;
    for (final l in json['lines'] as List) {
      final map = l as Map<String, dynamic>;
      if (map['id'] == lineId) return TransitLine.fromJson(map);
    }
  } catch (_) {
    // Veri paketi yok / dosya okunamadı: kısayol sessizce çalışmaz.
  }
  return null;
}
