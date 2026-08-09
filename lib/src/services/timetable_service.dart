import 'dart:convert';

import 'package:http/http.dart' as http;

import '../data/models.dart';
import '../data/timetable.dart';
import '../data/transit_city.dart';
import '../data/transit_db.dart';

/// Hat sefer saatleri (İETT "Planlanan Sefer Saati" servisi).
///
/// NEDEN İNDİRİLEN PAKETTE DEĞİL: İstanbul'da 2400 hat × ~300 kalkış =
/// yüz binlerce satır eder; paket bugün 7 MB, bu onu katlardı. Üstelik
/// takvim mevsimlik değişiyor ve paket sürümüne bağlamak saatleri
/// eskitirdi. Kullanıcı sefer saatine hattı açtığında bakar — o an tek bir
/// çağrı yapmak hem küçük hem güncel.
///
/// Yanıt oturum boyunca bellekte tutulur: aynı hatta ileri-geri gidip
/// gelmek servisi tekrar yormasın.
class TimetableService {
  TimetableService._();
  static final TimetableService instance = TimetableService._();

  static const _url =
      'https://api.ibb.gov.tr/iett/UlasimAnaVeri/PlanlananSeferSaati.asmx';
  static const _action = 'http://tempuri.org/GetPlanlananSeferSaati_json';

  final Map<String, Timetable> _cache = {};

  /// [lineCode] için takvim.
  ///
  /// İKİ KAYNAK VAR:
  ///  - İstanbul: İETT'nin canlı servisi (veri çok, pakete sığmaz).
  ///  - Kocaeli: kalkış saatleri PAKETE GÖMÜLÜ (belediyenin hat sayfasından
  ///    derleme sırasında çıkarılıyor; eşdeğer bir servis yok).
  ///
  /// Ağ/veri yoksa BOŞ takvim döner — çağıran "saat bilgisi yok" gösterir.
  Future<Timetable> forLine(String lineCode,
      {TransitCity? city, LineType? type}) async {
    final code = lineCode.trim();
    if (code.isEmpty) return Timetable(lineCode: code, departures: const []);
    final cacheKey = '${city?.id ?? ''}|${type?.name ?? ''}|$code';
    final hit = _cache[cacheKey];
    if (hit != null) return hit;

    final target = city ?? TransitCities.istanbul;
    // RAY/DENİZ hatları İETT servisinde YOK — metro, Marmaray, tramvay ve
    // vapur saatleri İBB'nin GTFS setinden derlenip PAKETE gömülü. Otobüs
    // dışındaki her tür doğrudan pakete sorulur.
    final rail = type != null && type != LineType.bus &&
        type != LineType.metrobus;
    // İETT servisi yalnızca İstanbul otobüsleri için. Ötekiler pakete bakar.
    if (rail || target.id != TransitCities.istanbul.id) {
      final packaged = await _fromPackage(code, target, type: type);
      _cache[cacheKey] = packaged;
      return packaged;
    }

    final body = '<GetPlanlananSeferSaati_json xmlns="http://tempuri.org/">'
        '<HatKodu>${_xmlEscape(code)}</HatKodu>'
        '</GetPlanlananSeferSaati_json>';
    final envelope = '<?xml version="1.0" encoding="utf-8"?>'
        '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">'
        '<soap:Body>$body</soap:Body></soap:Envelope>';
    try {
      final res = await http
          .post(
            Uri.parse(_url),
            headers: const {
              'Content-Type': 'text/xml; charset=utf-8',
              'SOAPAction': _action,
            },
            body: envelope,
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) {
        return Timetable(lineCode: code, departures: const []);
      }
      final xml = utf8.decode(res.bodyBytes);
      final m = RegExp(
        r'<GetPlanlananSeferSaati_jsonResult>(.*?)'
        r'</GetPlanlananSeferSaati_jsonResult>',
        dotAll: true,
      ).firstMatch(xml);
      if (m == null) return Timetable(lineCode: code, departures: const []);

      final list = jsonDecode(_unescape(m.group(1)!)) as List;
      final table = Timetable(
        lineCode: code,
        departures: parseRows(list.cast<Map<String, dynamic>>()),
      );
      _cache[cacheKey] = table;
      return table;
    } catch (_) {
      return Timetable(lineCode: code, departures: const []);
    }
  }

  /// İndirilen paketteki `departures` tablosundan takvim kurar.
  static Future<Timetable> _fromPackage(String code, TransitCity city,
      {LineType? type}) async {
    final rows = await TransitDb.instance
        .departuresForCode(code, cityId: city.id, type: type?.name);
    final out = <Departure>[];
    for (final (lineId, day, time) in rows) {
      final d = DayType.fromCode(day);
      if (d == null || !_timePattern.hasMatch(time)) continue;
      out.add(Departure(
        time: time,
        dayType: d,
        // Yön varyantı kimliğinde kodlu: "10_G" gidiş, "10_D" dönüş.
        outbound: lineId.contains('_G'),
      ));
    }
    return Timetable(lineCode: code, departures: out);
  }

  /// Servis satırlarını modele çevirir. Ayrı ve görünür: ayrıştırma
  /// kuralları ağ olmadan sınanabilsin.
  static List<Departure> parseRows(List<Map<String, dynamic>> rows) {
    final out = <Departure>[];
    for (final r in rows) {
      final day = DayType.fromCode('${r['SGUNTIPI'] ?? ''}'.trim());
      // Bilinmeyen gün tipi ATLANIR: hangi takvime ait olduğu belli olmayan
      // bir saati kullanıcıya göstermek yanlış bilgi vermek olur.
      if (day == null) continue;
      final time = '${r['DT'] ?? ''}'.trim();
      if (!_timePattern.hasMatch(time)) continue;
      final service = '${r['SSERVISTIPI'] ?? ''}'.trim();
      out.add(Departure(
        time: time,
        dayType: day,
        outbound: '${r['SYON'] ?? ''}'.trim().toUpperCase() == 'G',
        // "Normal" bilgi taşımıyor; yalnızca istisnalar not edilir
        // (ör. "Gareli" = garaja dönüş seferi).
        serviceNote: service.toLowerCase() == 'normal' ? '' : service,
      ));
    }
    return out;
  }

  static final _timePattern = RegExp(r'^\d{1,2}:\d{2}$');

  static String _xmlEscape(String s) =>
      s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

  static String _unescape(String s) => s
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');
}
