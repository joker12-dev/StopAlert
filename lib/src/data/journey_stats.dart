import 'journey_record.dart';
import 'models.dart';

/// Yolculuk geçmişinden türeyen özet istatistikler (saf hesap — test edilebilir).
///
/// Profil ekranı ve paylaşılabilir istatistik kartı bunu kullanır.
class JourneyStats {
  const JourneyStats({
    required this.totalJourneys,
    required this.completedJourneys,
    required this.totalSeconds,
    this.mostUsedLineCode,
    this.mostUsedLineName,
    this.mostUsedLineType,
    this.mostUsedCount = 0,
  });

  final int totalJourneys;

  /// Tamamlanan (alarmın işini yaptığı) yolculuk sayısı = "kaç kez uyandırıldın".
  final int completedJourneys;
  final int totalSeconds;
  final String? mostUsedLineCode;
  final String? mostUsedLineName;
  final LineType? mostUsedLineType;
  final int mostUsedCount;

  int get totalMinutes => totalSeconds ~/ 60;

  bool get isEmpty => totalJourneys == 0;

  /// İnsan-okur toplam süre ("2,5 saat" / "18 dk").
  String get totalDurationText {
    final m = totalMinutes;
    if (m < 60) return '$m dk';
    final hours = m / 60;
    return '${hours.toStringAsFixed(m % 60 == 0 ? 0 : 1).replaceAll('.', ',')} saat';
  }

  factory JourneyStats.from(List<JourneyRecord> journeys) {
    if (journeys.isEmpty) {
      return const JourneyStats(
        totalJourneys: 0,
        completedJourneys: 0,
        totalSeconds: 0,
      );
    }
    var total = 0;
    var completed = 0;
    var seconds = 0;
    final counts = <String, int>{};
    final firstByCode = <String, JourneyRecord>{};
    for (final j in journeys) {
      total++;
      if (j.status == 'completed') completed++;
      seconds += j.durationSeconds;
      counts[j.lineCode] = (counts[j.lineCode] ?? 0) + 1;
      firstByCode.putIfAbsent(j.lineCode, () => j);
    }
    String? topCode;
    var topCount = 0;
    counts.forEach((code, c) {
      if (c > topCount) {
        topCount = c;
        topCode = code;
      }
    });
    final rec = topCode == null ? null : firstByCode[topCode];
    return JourneyStats(
      totalJourneys: total,
      completedJourneys: completed,
      totalSeconds: seconds,
      mostUsedLineCode: topCode,
      mostUsedLineName: rec?.lineName,
      mostUsedLineType: rec?.lineType,
      mostUsedCount: topCount,
    );
  }
}
