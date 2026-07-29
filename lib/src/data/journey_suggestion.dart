import 'journey_record.dart';

/// Geçmişten türeyen "otomatik yolculuk" önerisi (saf hesap — test edilebilir).
///
/// Ör: kullanıcı her iş günü ~18:00 aynı rotayı yapıyorsa, o saate yakınken
/// "Bu rotayı sık kullanıyorsun — alarmı kurayım mı?" önerisi üretilir.
class JourneySuggestion {
  const JourneySuggestion({
    required this.lineCode,
    required this.lineTypeName,
    required this.boardingStopName,
    required this.targetStopName,
    required this.occurrences,
  });

  final String lineCode;
  final String lineTypeName;
  final String boardingStopName;
  final String targetStopName;

  /// Bu zaman dilimindeki eşleşen tamamlanmış yolculuk sayısı.
  final int occurrences;

  String get routeKey => '$lineCode|$boardingStopName|$targetStopName';
}

abstract final class JourneySuggester {
  /// [now] civarında (aynı hafta günü, ±[windowHours] saat) en az
  /// [minOccurrences] kez tekrar eden bir rota varsa döndürür. Bugün o rota
  /// zaten yapılmışsa öneri YOK (tekrar hatırlatma yok).
  static JourneySuggestion? suggest(
    List<JourneyRecord> history,
    DateTime now, {
    int minOccurrences = 3,
    int windowHours = 2,
  }) {
    final completed = history
        .where((j) => j.status == 'completed' && j.createdAt != null)
        .toList();
    if (completed.isEmpty) return null;

    final nowMinutes = now.hour * 60 + now.minute;
    final windowMinutes = windowHours * 60;

    // Rotaya göre grupla.
    final groups = <String, List<JourneyRecord>>{};
    for (final j in completed) {
      final key = '${j.lineCode}|${j.boardingStopName}|${j.targetStopName}';
      (groups[key] ??= []).add(j);
    }

    JourneySuggestion? best;
    var bestCount = 0;
    groups.forEach((key, list) {
      // Bugün zaten yapıldıysa önerme.
      final doneToday = list.any((j) {
        final t = j.createdAt!;
        return t.year == now.year && t.month == now.month && t.day == now.day;
      });
      if (doneToday) return;

      // now'a benzer zaman: aynı hafta günü + ±pencere.
      final matching = list.where((j) {
        final t = j.createdAt!;
        if (t.weekday != now.weekday) return false;
        final m = t.hour * 60 + t.minute;
        return (m - nowMinutes).abs() <= windowMinutes;
      }).length;

      if (matching >= minOccurrences && matching > bestCount) {
        bestCount = matching;
        final sample = list.first;
        best = JourneySuggestion(
          lineCode: sample.lineCode,
          lineTypeName: sample.lineTypeName,
          boardingStopName: sample.boardingStopName,
          targetStopName: sample.targetStopName,
          occurrences: matching,
        );
      }
    });
    return best;
  }
}
