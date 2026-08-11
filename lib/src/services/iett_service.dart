import 'dart:convert';

import 'package:http/http.dart' as http;

/// İETT resmi web servisleri (İBB Açık Veri — kayıt gerekmez, ticari kullanım
/// serbest, ATIF ZORUNLU: bkz. https://data.ibb.gov.tr/license).
///
/// Şu an yalnızca "Duyurular" kullanılıyor. Canlı araç konumu servisi de
/// mevcut ama SAATTE 100 İSTEK ile sınırlı olduğundan bilinçli olarak
/// eklenmedi (çok kullanıcıda sunucu tarafı önbellek/proxy gerekir).
class IettService {
  IettService._();
  static final IettService instance = IettService._();

  static const _duyurularUrl =
      'https://api.ibb.gov.tr/iett/UlasimDinamikVeri/Duyurular.asmx';

  /// Kullanıcıya gösterilmesi gereken atıf (lisans şartı).
  static const attribution = 'Veri: İETT · İBB Açık Veri Portalı';

  List<IettAnnouncement>? _cache;
  DateTime? _cachedAt;

  /// Duyuruların servisten EN SON ne zaman çekildiği.
  ///
  /// Yayında tarih alanı yok — yalnızca "Kayit Saati: 04:06" gibi bir saat
  /// geliyor. Kullanıcı listeye bakınca güncel mi bayat mı ayırt edemiyordu;
  /// ekran bu damgayı gösteriyor.
  DateTime? get lastFetchedAt => _cachedAt;

  /// Hat duyuruları (sefer iptali, güzergâh değişikliği vb.).
  /// 5 dakika bellek önbelleği — servise gereksiz yük bindirmez.
  Future<List<IettAnnouncement>> announcements({bool force = false}) async {
    final cached = _cache;
    final at = _cachedAt;
    if (!force &&
        cached != null &&
        at != null &&
        DateTime.now().difference(at) < const Duration(minutes: 5)) {
      return cached;
    }
    const body = '<GetDuyurular_json xmlns="http://tempuri.org/"/>';
    const envelope =
        '<?xml version="1.0" encoding="utf-8"?>'
        '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">'
        '<soap:Body>$body</soap:Body></soap:Envelope>';
    try {
      final res = await http
          .post(
            Uri.parse(_duyurularUrl),
            headers: const {
              'Content-Type': 'text/xml; charset=utf-8',
              'SOAPAction': 'http://tempuri.org/GetDuyurular_json',
            },
            body: envelope,
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return cached ?? const [];
      final xml = utf8.decode(res.bodyBytes);
      final m = RegExp(
        r'<GetDuyurular_jsonResult>(.*?)</GetDuyurular_jsonResult>',
        dotAll: true,
      ).firstMatch(xml);
      if (m == null) return cached ?? const [];
      final list = jsonDecode(_unescape(m.group(1)!)) as List;
      final out = <IettAnnouncement>[];
      for (final e in list) {
        final map = e as Map<String, dynamic>;
        final msg = (map['MESAJ'] as String? ?? '').trim();
        if (msg.isEmpty) continue;
        out.add(IettAnnouncement(
          line: (map['HAT'] as String? ?? '').trim(),
          type: (map['TIP'] as String? ?? '').trim(),
          time: (map['GUNCELLEME_SAATI'] as String? ?? '')
              .replaceFirst('Kayit Saati:', '')
              .trim(),
          message: msg,
        ));
      }
      _cache = out;
      _cachedAt = DateTime.now();
      return out;
    } catch (_) {
      return cached ?? const [];
    }
  }

  static const _trafficUrl =
      'https://api.ibb.gov.tr/tkmservices/api/TrafficData/v1/TrafficIndex';

  int? _trafficIndex;
  DateTime? _trafficAt;

  /// İstanbul ANLIK trafik yoğunluk indeksi (0-100). İBB Ulaşım Yönetim
  /// Merkezi yayınlar; kayıt/anahtar gerekmez, 5 dk'da bir güncellenir.
  ///
  /// NOT: Bu ŞEHİR GENELİ bir yoğunluk yüzdesidir — Google Maps'teki gibi
  /// yol-bazlı renkli trafik değildir (İBB o veriyi API olarak vermiyor).
  Future<int?> trafficIndex({bool force = false}) async {
    final at = _trafficAt;
    if (!force &&
        _trafficIndex != null &&
        at != null &&
        DateTime.now().difference(at) < const Duration(minutes: 5)) {
      return _trafficIndex;
    }
    try {
      // Accept ŞART: servis içerik anlaşması yapıyor; başlık yoksa JSON
      // yerine XML döndürüyor ve ayrıştırma patlıyor.
      final res = await http.get(
        Uri.parse(_trafficUrl),
        headers: const {'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return _trafficIndex;
      final body = utf8.decode(res.bodyBytes).replaceFirst('﻿', '').trim();
      final json = jsonDecode(body);
      // {"Result":47} biçiminde döner.
      final v = json is Map<String, dynamic> ? json['Result'] : null;
      final idx = (v as num?)?.round();
      if (idx == null) return _trafficIndex;
      _trafficIndex = idx.clamp(0, 100);
      _trafficAt = DateTime.now();
      return _trafficIndex;
    } catch (_) {
      return _trafficIndex;
    }
  }

  static const _filoUrl =
      'https://api.ibb.gov.tr/iett/FiloDurum/SeferGerceklesme.asmx';

  /// Bir hattın CANLI araç konumları (İETT filo servisi).
  ///
  /// ⚠️ Bu servis SAATTE 100 İSTEK ile sınırlıdır; doğrudan çağrılmamalı.
  /// Uygulama [LiveBusService] üzerinden gider: o, Firestore'da paylaşımlı bir
  /// önbellek tutar ve aynı hat için tüm kullanıcılar adına tek çekim yapar.
  Future<List<BusVehicle>> vehiclePositions(String lineCode) async {
    final code = lineCode.trim();
    if (code.isEmpty) return const [];
    // NOT: dokümanda parametre adı `HatNo` yazıyor ama WSDL'de `HatKodu`.
    final body = '<GetHatOtoKonum_json xmlns="http://tempuri.org/">'
        '<HatKodu>${_xmlEscape(code)}</HatKodu></GetHatOtoKonum_json>';
    final envelope = '<?xml version="1.0" encoding="utf-8"?>'
        '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">'
        '<soap:Body>$body</soap:Body></soap:Envelope>';
    try {
      final res = await http
          .post(
            Uri.parse(_filoUrl),
            headers: const {
              'Content-Type': 'text/xml; charset=utf-8',
              'SOAPAction': 'http://tempuri.org/GetHatOtoKonum_json',
            },
            body: envelope,
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return const [];
      final xml = utf8.decode(res.bodyBytes);
      final m = RegExp(
        r'<GetHatOtoKonum_jsonResult>(.*?)</GetHatOtoKonum_jsonResult>',
        dotAll: true,
      ).firstMatch(xml);
      if (m == null) return const [];
      final list = jsonDecode(_unescape(m.group(1)!)) as List;
      final out = <BusVehicle>[];
      for (final e in list) {
        final v = e as Map<String, dynamic>;
        final lat = double.tryParse('${v['enlem']}');
        final lon = double.tryParse('${v['boylam']}');
        if (lat == null || lon == null) continue;
        out.add(BusVehicle(
          plate: '${v['kapino'] ?? ''}'.trim(),
          lat: lat,
          lon: lon,
          headingTo: '${v['yon'] ?? ''}'.trim(),
          routeCode: '${v['guzergahkodu'] ?? ''}'.trim(),
          lastSeen: '${v['son_konum_zamani'] ?? ''}'.trim(),
          nearestStopCode: '${v['yakinDurakKodu'] ?? ''}'.trim(),
        ));
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  static String _xmlEscape(String s) =>
      s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

  /// SOAP gövdesindeki XML kaçışlarını çöz (JSON metni gömülü gelir).
  static String _unescape(String s) => s
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');
}

/// Hat üzerinde seyreden tek bir otobüs (canlı konum).
class BusVehicle {
  const BusVehicle({
    required this.plate,
    required this.lat,
    required this.lon,
    required this.headingTo,
    required this.routeCode,
    required this.lastSeen,
    required this.nearestStopCode,
    this.scheduled = false,
  });

  /// Araç kapı numarası (ör. "T1019").
  final String plate;
  final double lat;
  final double lon;

  /// Aracın gittiği yön (son durak adı).
  final String headingTo;

  /// Güzergâh kodu (ör. "MK13_D_D6622") — gidiş/dönüş ayrımı için.
  final String routeCode;
  final String lastSeen;
  final String nearestStopCode;

  /// Konum CANLI DEĞİL, tarifeden üretildi (metro/Marmaray/tramvay/vapur).
  ///
  /// Arayüz bunu görünür kılmak zorunda: kullanıcı canlı konuma güvenip
  /// kapıda beklerken aslında bir plana baktığını bilmeli.
  /// Bkz. `ScheduledVehicles`.
  final bool scheduled;

  Map<String, dynamic> toMap() => {
        'plate': plate,
        'lat': lat,
        'lon': lon,
        'headingTo': headingTo,
        'routeCode': routeCode,
        'lastSeen': lastSeen,
        'nearestStopCode': nearestStopCode,
        'scheduled': scheduled,
      };

  factory BusVehicle.fromMap(Map<String, dynamic> m) => BusVehicle(
        plate: m['plate'] as String? ?? '',
        lat: (m['lat'] as num?)?.toDouble() ?? 0,
        lon: (m['lon'] as num?)?.toDouble() ?? 0,
        headingTo: m['headingTo'] as String? ?? '',
        routeCode: m['routeCode'] as String? ?? '',
        lastSeen: m['lastSeen'] as String? ?? '',
        nearestStopCode: m['nearestStopCode'] as String? ?? '',
        scheduled: m['scheduled'] as bool? ?? false,
      );

  /// Gidiş yönü mü (güzergâh kodundaki `_G_` / `_D_` işaretinden).
  bool get isGidis => routeCode.contains('_G_');
}

/// Tek bir İETT duyurusu.
class IettAnnouncement {
  const IettAnnouncement({
    required this.line,
    required this.type,
    required this.time,
    required this.message,
  });

  /// Duyurunun ilgili olduğu hat (ör. "BOSTANCI - KADIKÖY").
  final String line;

  /// "Sefer", "Günlük" vb.
  final String type;
  final String time;
  final String message;

  /// Sefer iptali gibi doğrudan yolculuğu etkileyen duyuru mu.
  bool get isTrip => type.toLowerCase().startsWith('sefer');
}
