import '../data/timetable.dart';

/// Segment sürelerinin KOŞULLANDIĞI zaman dilimi.
///
/// NEDEN: aynı iki durak arası 147'de gece 03:00'te ~90 saniye, akşam 18:00'de
/// ~240 saniye sürer. Tek bir ortalama ikisini de yanlış tahmin eder ve bu
/// hata, tahmin boru hattındaki diğer her şeyden (ölü hesap, durak bekleme
/// payı, filtre inceliği) büyüktür.
///
/// Dilimler bilinçli KABA: kullanıcı başına örnek sayısı azdır, 24 saatlik
/// kovaya bölünce her kova boş kalır. Beş bant × üç gün tipi = 15 kova;
/// trafiğin gerçek desenini yakalayacak kadar ince, dolmayacak kadar değil.
/// (Kalabalık öğrenme bunları çok daha hızlı doldurur.)
enum TimeBand {
  /// 00:00-06:00 — akıcı.
  gece('n', 0, 6, 'Gece'),

  /// 06:00-10:00 — sabah zirvesi.
  sabahZirve('m', 6, 10, 'Sabah zirvesi'),

  /// 10:00-16:00 — gündüz.
  gunduz('d', 10, 16, 'Gündüz'),

  /// 16:00-20:00 — akşam zirvesi (günün en yavaşı).
  aksamZirve('e', 16, 20, 'Akşam zirvesi'),

  /// 20:00-24:00 — akşam.
  aksam('l', 20, 24, 'Akşam');

  const TimeBand(this.code, this.startHour, this.endHour, this.label);

  /// Depolama anahtarındaki tek harf.
  final String code;
  final int startHour;
  final int endHour;
  final String label;

  static TimeBand forHour(int hour) {
    for (final b in TimeBand.values) {
      if (hour >= b.startHour && hour < b.endHour) return b;
    }
    return TimeBand.gece; // 24 ve ötesi olmamalı; güvenli varsayılan
  }
}

/// Gün tipi + saat bandı ikilisi.
class TimeBucket {
  const TimeBucket(this.day, this.band);

  final DayType day;
  final TimeBand band;

  /// Anahtar eki: "Im" = iş günü sabah zirvesi.
  String get code => '${day.code}${band.code}';

  String get label => '${day.label} · ${band.label}';

  static TimeBucket of(DateTime t) =>
      TimeBucket(DayType.forDate(t), TimeBand.forHour(t.hour));

  static TimeBucket? fromCode(String? code) {
    if (code == null || code.length != 2) return null;
    final day = DayType.fromCode(code[0]);
    if (day == null) return null;
    for (final b in TimeBand.values) {
      if (b.code == code[1]) return TimeBucket(day, b);
    }
    return null;
  }

  /// Aynı gün tipindeki KOMŞU bantlar — kova boşsa buradan devam edilir.
  /// Zirve saatleri birbirine, gece/akşam birbirine daha yakındır; sıra
  /// bilinçli olarak "trafik yoğunluğu benzerliğine" göre verilmiştir.
  List<TimeBand> get neighbours => switch (band) {
        TimeBand.gece => const [TimeBand.aksam, TimeBand.gunduz],
        TimeBand.sabahZirve => const [TimeBand.aksamZirve, TimeBand.gunduz],
        TimeBand.gunduz => const [TimeBand.aksam, TimeBand.sabahZirve],
        TimeBand.aksamZirve => const [TimeBand.sabahZirve, TimeBand.gunduz],
        TimeBand.aksam => const [TimeBand.gunduz, TimeBand.gece],
      };

  @override
  bool operator ==(Object other) =>
      other is TimeBucket && other.day == day && other.band == band;

  @override
  int get hashCode => Object.hash(day, band);

  @override
  String toString() => code;
}
