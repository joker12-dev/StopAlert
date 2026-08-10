import '../data/models.dart';
import '../data/transit_db.dart';
import '../data/timetable.dart';
import '../services/iett_service.dart';
import 'arrival_estimator.dart';

/// Tarifeden ÜRETİLMİŞ araç konumları (metro, Marmaray, tramvay, vapur).
///
/// NEDEN VAR: bu araçların canlı konumu hiçbir açık kaynakta yayınlanmıyor —
/// ne İBB'de ne TCDD'de. Elde olan iki şey var: seferin ilk duraktan kalkış
/// saati ve hattın durak-arası süreleri (toplam yolculuk süresinden dağıtılmış).
/// İkisi birleşince "şu an bu sefer nerede olmalı" sorusu cevaplanabiliyor.
///
/// BU BİR TAHMİN DEĞİL, PLANIN OKUNMASIDIR. Gecikmeyi, arızayı, iptal edilen
/// seferi bilmez. Bu yüzden üretilen araçlar [BusVehicle.scheduled] ile
/// işaretlenir ve arayüz bunları canlı araçtan AYRI gösterir — kullanıcı neye
/// baktığını bilmeli.
///
/// Doğruluğu şuna dayanıyor: raylı sistem trafikten etkilenmez, sefer aralığı
/// dakikalıktır ve gerçek sapma genelde ±1-2 dk'dır. Otobüs için aynı yaklaşım
/// kabul edilemezdi; orada canlı konum zaten var.
class ScheduledVehicles {
  const ScheduledVehicles._();

  /// Yolun sonuna gelmiş seferi bu kadar süre daha göster: son durakta
  /// bekleyen aracı bir anda yok etmek haritada "kayboldu" hissi veriyor.
  static const _tailSeconds = 60;

  /// [line] varyantı için ŞU AN yolda olması gereken seferler.
  ///
  /// [departures] bu varyanta ve bugüne ait kalkışlar olmalı (bkz.
  /// [Timetable.forDay]). Sonuç, hattın duraklarının arasına yerleştirilmiş
  /// noktalar hâlinde döner.
  static List<BusVehicle> forLine({
    required TransitLine line,
    required List<Departure> departures,
    DateTime? now,
    int limit = 40,
  }) {
    final clock = now ?? DateTime.now();
    final stops = line.stops;
    if (stops.length < 2 || departures.isEmpty) return const [];

    final seconds = ArrivalEstimator.segmentSecondsFor(line);
    // Kalkıştan itibaren her durağa varış anı (saniye).
    final cumulative = <double>[0];
    for (var i = 0; i < seconds.length && i < stops.length - 1; i++) {
      cumulative.add(cumulative.last + seconds[i]);
    }
    final total = cumulative.last;
    if (total <= 0) return const [];

    final gidis = line.id.contains('_G');
    final out = <BusVehicle>[];

    for (final d in departures) {
      final hm = _parseClock(d.time);
      if (hm == null) continue;

      // İKİ GÜN DENENİR: gece yarısını aşan seferler. 23:50'de kalkan bir
      // Marmaray 00:20'de hâlâ yolda; yalnızca bugüne bakmak onu yok sayardı.
      for (final dayShift in const [0, -1]) {
        final departAt = DateTime(clock.year, clock.month, clock.day)
            .add(Duration(days: dayShift, hours: hm.$1, minutes: hm.$2));
        final elapsed = clock.difference(departAt).inSeconds;
        if (elapsed < 0 || elapsed > total + _tailSeconds) continue;

        final pos = _positionAt(stops, cumulative, elapsed.toDouble());
        if (pos == null) continue;
        out.add(BusVehicle(
          // Kapı numarası yerine SEFER SAATİ: kullanıcı bunu tarifedeki
          // satırla eşleştirebilir, uydurma bir plaka ise yanıltıcı olurdu.
          plate: '${d.time} seferi',
          lat: pos.$1,
          lon: pos.$2,
          headingTo: stops.last.name,
          routeCode: '${line.code}_${gidis ? 'G' : 'D'}_TARIFE',
          lastSeen: _stamp(clock),
          // Canlı akışla AYNI biçim: arayüz durak satırını ham kimlikle
          // eşleştiriyor, ön ek bırakılırsa hiçbir durak eşleşmezdi.
          nearestStopCode: _rawStopId(stops[pos.$3].id),
          scheduled: true,
        ));
        break;
      }
      if (out.length >= limit) break;
    }
    return out;
  }

  /// Kalkıştan [elapsed] saniye sonra konum: (lat, lon, yaklaşılan durak).
  static (double, double, int)? _positionAt(
      List<Stop> stops, List<double> cumulative, double elapsed) {
    for (var i = 0; i < cumulative.length - 1; i++) {
      final a = cumulative[i];
      final b = cumulative[i + 1];
      if (elapsed > b) continue;
      final span = b - a;
      // Süresi sıfır olan segmentte oran hesaplanamaz; başlangıçta kalır.
      final t = span <= 0 ? 0.0 : ((elapsed - a) / span).clamp(0.0, 1.0);
      final from = stops[i];
      final to = stops[i + 1];
      return (
        from.lat + (to.lat - from.lat) * t,
        from.lon + (to.lon - from.lon) * t,
        i + 1,
      );
    }
    final last = stops.length - 1;
    return (stops[last].lat, stops[last].lon, last);
  }

  /// Durak kimliğinden paket ön ekini ayıklar (`bus:12345` → `12345`).
  static String _rawStopId(String id) =>
      id.startsWith(kBusPrefix) ? id.substring(kBusPrefix.length) : id;

  static (int, int)? _parseClock(String time) {
    final parts = time.split(':');
    if (parts.length < 2) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) return null;
    return (h, m);
  }

  /// İETT'nin damga biçimi — arayüz "kaç sn önce" hesabını buradan yapıyor.
  static String _stamp(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }
}
