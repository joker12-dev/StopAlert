/// Bir hattın PLANLANAN kalkış saatleri.
library;

/// Sefer takviminin gün tipi.
///
/// İETT üç ayrı takvim yayınlıyor ve saatler gerçekten farklı: hafta içi sık,
/// cumartesi seyrek, pazar daha da seyrek. Tek listede birleştirmek kullanıcıyı
/// yanıltırdı.
enum DayType {
  weekday('I', 'Hafta içi'),
  saturday('C', 'Cumartesi'),
  sunday('P', 'Pazar');

  const DayType(this.code, this.label);

  /// İETT `SGUNTIPI` alanındaki harf.
  final String code;
  final String label;

  static DayType? fromCode(String? code) {
    for (final d in DayType.values) {
      if (d.code == code) return d;
    }
    return null;
  }

  /// Bugün hangi takvim geçerli.
  static DayType forDate(DateTime d) => switch (d.weekday) {
        DateTime.saturday => DayType.saturday,
        DateTime.sunday => DayType.sunday,
        _ => DayType.weekday,
      };
}

/// Tek bir planlanan kalkış.
class Departure {
  const Departure({
    required this.time,
    required this.dayType,
    required this.outbound,
    this.serviceNote = '',
  });

  /// "HH:mm" — İETT'nin verdiği biçim, olduğu gibi korunur.
  final String time;

  final DayType dayType;

  /// Gidiş yönü mü (`SYON` = "G")? Değilse dönüş.
  final bool outbound;

  /// Servis tipi: "Normal", "Gareli" (garaja dönüş), "ÖHO"… Kullanıcıya
  /// yalnızca normal olmayanlarda gösterilir.
  final String serviceNote;

  /// Dakika cinsinden gün içi konum — sıralama ve "sıradaki sefer" için.
  int get minuteOfDay {
    final parts = time.split(':');
    if (parts.length < 2) return 0;
    final h = int.tryParse(parts[0]) ?? 0;
    final m = int.tryParse(parts[1]) ?? 0;
    // İETT gece seferlerini 24'ü aşan saatle vermiyor; 00:xx ertesi gün
    // demek ama listede kendi yerinde durması doğru.
    return h * 60 + m;
  }
}

/// Bir hattın tüm takvimi (üç gün tipi × iki yön).
class Timetable {
  const Timetable({required this.lineCode, required this.departures});

  final String lineCode;
  final List<Departure> departures;

  bool get isEmpty => departures.isEmpty;

  /// Belirli bir gün tipi + yön için sıralı kalkışlar.
  List<Departure> forDay(DayType day, {required bool outbound}) {
    final out = [
      for (final d in departures)
        if (d.dayType == day && d.outbound == outbound) d,
    ]..sort((a, b) => a.minuteOfDay.compareTo(b.minuteOfDay));
    return out;
  }

  /// Bu gün tipinde hiç sefer var mı (yön fark etmeksizin)?
  bool hasDay(DayType day) =>
      departures.any((d) => d.dayType == day);

  /// [now]'dan sonraki ilk kalkış — "sıradaki sefer" rozeti için.
  /// Gün bitmişse null (yarının ilk seferi ayrı bir bilgi, burada verilmez).
  Departure? next(List<Departure> ofDay, DateTime now) {
    final nowMin = now.hour * 60 + now.minute;
    for (final d in ofDay) {
      if (d.minuteOfDay >= nowMin) return d;
    }
    return null;
  }
}
