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
      'https://api.ibb.gov.tr/tkmservices/api/TrafficData/v1/'
      'TrafficIndexHistory/1/5M';

  int? _trafficIndex;
  DateTime? _trafficAt;

  /// İstanbul ANLIK trafik yoğunluk indeksi (0-100). İBB Ulaşım Yönetim
  /// Merkezi 5 dakikada bir yayınlar; kayıt/anahtar gerekmez.
  ///
  /// NOT: Bu ŞEHİR GENELİ bir indekstir — Google Maps'teki gibi yol-bazlı
  /// renkli trafik değildir (İBB o veriyi API olarak yayınlamıyor).
  Future<int?> trafficIndex({bool force = false}) async {
    final at = _trafficAt;
    if (!force &&
        _trafficIndex != null &&
        at != null &&
        DateTime.now().difference(at) < const Duration(minutes: 5)) {
      return _trafficIndex;
    }
    try {
      final res = await http
          .get(Uri.parse(_trafficUrl))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return _trafficIndex;
      final list = jsonDecode(utf8.decode(res.bodyBytes)) as List;
      if (list.isEmpty) return _trafficIndex;
      // İlk kayıt en güncel olan.
      final v = (list.first as Map<String, dynamic>)['TrafficIndex'];
      final idx = (v as num?)?.round();
      if (idx == null) return _trafficIndex;
      _trafficIndex = idx.clamp(0, 100);
      _trafficAt = DateTime.now();
      return _trafficIndex;
    } catch (_) {
      return _trafficIndex;
    }
  }

  /// SOAP gövdesindeki XML kaçışlarını çöz (JSON metni gömülü gelir).
  static String _unescape(String s) => s
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');
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
