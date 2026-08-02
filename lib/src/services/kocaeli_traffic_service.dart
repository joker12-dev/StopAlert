import 'dart:convert';

import 'package:http/http.dart' as http;

/// Kocaeli anlık trafik yoğunluğu.
///
/// Kaynak: Akıllı Şehir Kocaeli — `api/traffic.php`, kayıt/anahtar
/// gerektirmez ve şu biçimde döner:
///
///     {"success":true,"data":{"congestion":11,"level":"Akıcı",
///      "source":"fcd","fetchedAt":"2026-08-02T23:43:32+00:00"}}
///
/// İstanbul'daki İBB indeksinin karşılığı: ŞEHİR GENELİ bir yoğunluk yüzdesi,
/// yol-bazlı renkli trafik değil.
class KocaeliTrafficService {
  KocaeliTrafficService._();
  static final KocaeliTrafficService instance = KocaeliTrafficService._();

  static const _url = 'https://akillisehirkocaeli.com/api/traffic.php';

  int? _index;
  String? _level;
  DateTime? _at;

  /// Son okunan durum etiketi ("Akıcı", "Yoğun"…) — servis kendi veriyor,
  /// eşiği biz uydurmuyoruz.
  String? get level => _level;

  /// 0-100 yoğunluk. Ağ yoksa son bilinen değer, o da yoksa null.
  Future<int?> index({bool force = false}) async {
    final at = _at;
    if (!force &&
        _index != null &&
        at != null &&
        DateTime.now().difference(at) < const Duration(minutes: 5)) {
      return _index;
    }
    try {
      final res = await http.get(
        Uri.parse(_url),
        headers: const {'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return _index;
      final body = jsonDecode(utf8.decode(res.bodyBytes));
      if (body is! Map<String, dynamic>) return _index;
      final data = body['data'];
      if (data is! Map<String, dynamic>) return _index;
      final v = (data['congestion'] as num?)?.round();
      if (v == null) return _index;
      _index = v.clamp(0, 100);
      _level = (data['level'] as String?)?.trim();
      _at = DateTime.now();
      return _index;
    } catch (_) {
      return _index;
    }
  }
}
