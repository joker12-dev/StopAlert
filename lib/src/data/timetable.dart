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
  ///
  /// 24'ü AŞABİLİR: gece yarısını geçen seferler "24:28"/"25:28" olarak
  /// yazılıyor (GTFS'in yöntemi). Bu sayede listenin sonuna düşüyorlar ve
  /// "cuma gecesi 01:28 treni" cuma sayfasında kalıyor.
  int get minuteOfDay {
    final parts = time.split(':');
    if (parts.length < 2) return 0;
    final h = int.tryParse(parts[0]) ?? 0;
    final m = int.tryParse(parts[1]) ?? 0;
    return h * 60 + m;
  }

  /// Kalkış GECE YARISINDAN SONRA mı (yani takvim gününün ertesi sabahı).
  bool get isNextDay => minuteOfDay >= 24 * 60;

  /// Kullanıcıya gösterilecek saat — 24+ biçimi normale çevrilir.
  ///
  /// "25:28" kimseye bir şey anlatmıyor; ekranda "01:28" yazıp yanına
  /// "ertesi gün" rozeti koymak doğru olanı.
  String get displayTime {
    if (!isNextDay) return time;
    final total = minuteOfDay % (24 * 60);
    final h = (total ~/ 60).toString().padLeft(2, '0');
    final m = (total % 60).toString().padLeft(2, '0');
    return '$h:$m';
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
    var nowMin = now.hour * 60 + now.minute;
    // GECE YARISINDAN SONRA, gün hâlâ DÜNÜN takvim günü sayılır: saat 00:40'ta
    // "sıradaki sefer" dünkü listenin 24:58 kaydıdır. Saati de aynı ölçeğe
    // taşımazsak 00:40 listenin en başına düşer ve ilk sabah seferini
    // "sıradaki" sanırdık.
    if (nowMin < 3 * 60) nowMin += 24 * 60;
    for (final d in ofDay) {
      if (d.minuteOfDay >= nowMin) return d;
    }
    return null;
  }
}
