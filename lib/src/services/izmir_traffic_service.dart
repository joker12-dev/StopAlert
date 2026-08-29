import 'dart:convert';
import 'dart:io';

/// İzmir anlık trafik yoğunluğu.
///
/// Kaynak: İZUM (İzmir Ulaşım Merkezi) `v1/workspaces/travel-times` — kayıt/
/// anahtar gerektirmez ve şu biçimde döner (şehir genelinde ~190 segment):
///
///     [{ "from": {"name","lat","lng"},
///        "to":  [{ "time":317, "delay":107, "level":2, "name","lat","lng" }, …] }, …]
///
/// İETT/Kocaeli indekslerinin karşılığı ŞEHİR GENELİ bir yüzdedir; bu servis
/// yalnızca `level` sayısını değil, `delay/time` (yolculuğun ne kadar
/// uzadığı) oranını da hesaba katar. Segment başına:
///
///     yoğunluk = 0.60 · (level / 3)  +  0.40 · (delay / time)
///
/// Şehir yüzdesi bunların ortalamasıdır (0-100). `level` çoğunlukla 1 (normal)
/// ve `delay` 0 olduğundan sakin bir şehir düşük yüzde verir; gerçek gecikme
/// olan koridorlar ortalamayı yukarı çeker.
class IzmirTrafficService {
  IzmirTrafficService._();
  static final IzmirTrafficService instance = IzmirTrafficService._();

  static const _host = 'izum.izmir.bel.tr';
  static const _url = 'https://izum.izmir.bel.tr/v1/workspaces/travel-times';

  int? _index;
  DateTime? _at;

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
      final body = await _fetch();
      if (body == null) return _index;
      final decoded = jsonDecode(body);
      if (decoded is! List) return _index;

      var sum = 0.0;
      var n = 0;
      for (final node in decoded) {
        if (node is! Map) continue;
        final tos = node['to'];
        if (tos is! List) continue;
        for (final seg in tos) {
          if (seg is! Map) continue;
          final time = (seg['time'] as num?)?.toDouble() ?? 0;
          final delay = (seg['delay'] as num?)?.toDouble() ?? 0;
          final level = (seg['level'] as num?)?.toDouble() ?? 0;
          // level 0-3 → 0..1; delay/time → 0..1 (üst sınır 1'de kırpılır ki
          // tek bir uçuk segment şehir ortalamasını patlatmasın).
          final levelScore = (level / 3).clamp(0.0, 1.0);
          final delayRatio = time > 0 ? (delay / time).clamp(0.0, 1.0) : 0.0;
          sum += 0.60 * levelScore + 0.40 * delayRatio;
          n++;
        }
      }
      if (n == 0) return _index;
      _index = (sum / n * 100).round().clamp(0, 100);
      _at = DateTime.now();
      return _index;
    } catch (_) {
      return _index;
    }
  }

  /// Ham gövdeyi çeker. İZUM ara sertifika zincirini EKSİK gönderiyor; bazı
  /// cihazlarda TLS doğrulaması "unable to verify the first certificate" ile
  /// düşüyor. Bu yüzden sertifika doğrulaması YALNIZCA bu host için esnetilir:
  /// uç herkese açık, kimlik doğrulaması ve kişisel veri yok — en kötü
  /// ihtimalle yanlış bir trafik yüzdesi gelir, alarm akışına dokunmaz.
  Future<String?> _fetch() async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..badCertificateCallback = (cert, host, port) => host == _host;
    try {
      // Cache-buster: CDN/ara katman bayat kopya sunmasın diye.
      final uri = Uri.parse('$_url?_=${DateTime.now().millisecondsSinceEpoch}');
      final req = await client.getUrl(uri);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final res = await req.close().timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return null;
      return await res.transform(utf8.decoder).join();
    } finally {
      client.close();
    }
  }
}
