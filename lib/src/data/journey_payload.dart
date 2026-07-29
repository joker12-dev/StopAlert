import 'dart:convert';

import 'models.dart';

/// Bir yolculuğun tamamını taşıyan, serileştirilebilir paket.
///
/// UI ile arka plan takip servisi (ayrı isolate) arasında ve "uygulama
/// yeniden açıldığında kaldığı yerden devam" senaryosunda kullanılır.
class JourneyPayload {
  const JourneyPayload({
    required this.line,
    required this.boardingStopId,
    required this.targetStopId,
    required this.alarmDistanceMeters,
    this.alarmStopsThreshold = 2,
    this.snoozeMinutes = 5,
    this.vibrate = true,
  });

  final TransitLine line;
  final String boardingStopId;
  final String targetStopId;

  /// 0 = mesafe tetikleyicisi kapalı (yalnızca durak sayısı kullanılır).
  final double alarmDistanceMeters;

  /// 0 = durak sayısı tetikleyicisi kapalı (yalnızca mesafe kullanılır).
  final int alarmStopsThreshold;

  /// Kullanıcının ertele süresi (dakika) — alarm ekranındaki "Ertele".
  final int snoozeMinutes;

  /// Alarm çalarken cihaz titreşsin mi (Ayarlar → Titreşim).
  final bool vibrate;

  Stop? get targetStop {
    final i = line.indexOfStop(targetStopId);
    return i == -1 ? null : line.stops[i];
  }

  String get targetStopName => targetStop?.name ?? '';

  String encode() => jsonEncode({
        'line': line.toJson(),
        'boardingStopId': boardingStopId,
        'targetStopId': targetStopId,
        'alarmDistanceMeters': alarmDistanceMeters,
        'alarmStopsThreshold': alarmStopsThreshold,
        'snoozeMinutes': snoozeMinutes,
        'vibrate': vibrate,
      });

  static JourneyPayload? tryDecode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return JourneyPayload(
        line: TransitLine.fromJson(json['line'] as Map<String, dynamic>),
        boardingStopId: json['boardingStopId'] as String,
        targetStopId: json['targetStopId'] as String,
        alarmDistanceMeters:
            (json['alarmDistanceMeters'] as num?)?.toDouble() ?? 500,
        alarmStopsThreshold:
            (json['alarmStopsThreshold'] as num?)?.toInt() ?? 2,
        snoozeMinutes: (json['snoozeMinutes'] as num?)?.toInt() ?? 5,
        vibrate: json['vibrate'] as bool? ?? true,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Servisten UI'a akan anlık durum (JSON üzerinden).
class TrackingUpdate {
  const TrackingUpdate({
    required this.state,
    required this.stopsRemaining,
    required this.etaSeconds,
    required this.distanceMeters,
    required this.currentStopName,
    required this.nextStopName,
    required this.lat,
    required this.lon,
    required this.alarmActive,
    this.confidence = 1,
  });

  final String state; // active | approaching | arrived
  final int stopsRemaining;
  final int etaSeconds;
  final double distanceMeters;
  final String currentStopName;
  final String nextStopName;
  final double lat;
  final double lon;
  final bool alarmActive;

  /// 0..1 — GPS'in hatta ne kadar oturduğuna dair güven (1 = yüksek).
  final double confidence;

  String encode() => jsonEncode({
        'state': state,
        'stopsRemaining': stopsRemaining,
        'etaSeconds': etaSeconds,
        'distanceMeters': distanceMeters,
        'currentStopName': currentStopName,
        'nextStopName': nextStopName,
        'lat': lat,
        'lon': lon,
        'alarmActive': alarmActive,
        'confidence': confidence,
      });

  static TrackingUpdate? tryDecode(Object? raw) {
    if (raw is! String) return null;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return TrackingUpdate(
        state: j['state'] as String,
        stopsRemaining: (j['stopsRemaining'] as num).toInt(),
        etaSeconds: (j['etaSeconds'] as num).toInt(),
        distanceMeters: (j['distanceMeters'] as num).toDouble(),
        currentStopName: j['currentStopName'] as String? ?? '',
        nextStopName: j['nextStopName'] as String,
        lat: (j['lat'] as num).toDouble(),
        lon: (j['lon'] as num).toDouble(),
        alarmActive: j['alarmActive'] as bool? ?? false,
        confidence: (j['confidence'] as num?)?.toDouble() ?? 1,
      );
    } catch (_) {
      return null;
    }
  }
}
