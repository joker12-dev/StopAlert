import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

/// Karayolu rota servisi (OSRM). Verilen ara noktaları YOLLARA oturtan bir
/// polyline döndürür — böylece hat/yürüme rotası düz çizgi yerine gerçek
/// yolları izler (Moovit benzeri görünüm). Ağ yoksa/başarısızsa boş liste
/// döner; çağıran düz çizgiye düşer. Sonuçlar bellek + [_cache] ile tekrar
/// kullanılır.
///
/// NOT: Halka açık `router.project-osrm.org` yalnızca `driving` profili sunar;
/// kısa yürüme mesafelerinde de makul bir yol verir. Üretimde kendi OSRM'imiz
/// ya da ücretli bir rota API'si tercih edilmeli.
class RoutingService {
  RoutingService._();
  static final RoutingService instance = RoutingService._();

  static const _base = 'https://router.project-osrm.org/route/v1';
  final Map<String, List<LatLng>> _cache = {};
  static const _geo = Distance();

  /// Bellekte tutulan azami güzergâh sayısı (ekleme sırasına göre eskiyen atılır).
  static const _maxCached = 12;

  /// [waypoints] üzerinden yol polyline'ı. Çok fazla nokta varsa örneklenir
  /// (OSRM istek sınırı). Başarısızsa boş liste.
  Future<List<LatLng>> route(List<LatLng> waypoints,
      {String profile = 'driving'}) async {
    if (waypoints.length < 2) return const [];
    final pts = _dedupe(_sample(waypoints, 90));
    if (pts.length < 2) return const [];
    final key =
        '$profile:${pts.map((p) => '${p.latitude.toStringAsFixed(4)},${p.longitude.toStringAsFixed(4)}').join(';')}';
    final cached = _cache[key];
    if (cached != null) return cached;
    try {
      final coords =
          pts.map((p) => '${p.longitude},${p.latitude}').join(';');
      // continue_straight=false: OSRM varsayılanı durakta DÜZ DEVAM etmeye
      // zorluyor; durak yolun ters şeridine oturunca U dönüşü yapamayıp
      // bloğun etrafını dolaşıyordu (haritadaki dikdörtgen ilmekler).
      // steps=true: her bacağın kendi geometrisi gelsin — saçma sapan uzayan
      // bacakları [_clean] düz çizgiyle değiştirebilsin.
      final uri = Uri.parse('$_base/$profile/$coords'
          '?overview=full&geometries=geojson&continue_straight=false'
          '&steps=true');
      final res = await http.get(uri).timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return const [];
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      if (j['code'] != 'Ok') return const [];
      final routes = j['routes'] as List;
      if (routes.isEmpty) return const [];
      final poly = cleanRoute(routes.first as Map<String, dynamic>, pts);
      if (poly.length < 2) return const [];
      // Önbellek SINIRLI: bir otobüs güzergâhı binlerce LatLng tutuyor, sınırsız
      // biriktirmek uzun oturumlarda belleği şişiriyordu. En eski atılır.
      if (_cache.length >= _maxCached) _cache.remove(_cache.keys.first);
      _cache[key] = poly;
      return poly;
    } catch (_) {
      return const [];
    }
  }

  /// Bacakları tek tek denetleyip birleştirir.
  ///
  /// OSRM tek yönlü sokaklar yüzünden iki durak arasında bazen bloğun
  /// etrafından dolaşıyor: harita üzerinde küçük dikdörtgen ilmekler ve aynı
  /// yolda gidiş-dönüş çift şerit görünüyor. Gerçek hat öyle gitmiyor — bu
  /// yüzden kuş uçuşu mesafesine göre absürt uzayan bacak düz çizgiyle
  /// değiştirilir. Uzun bacaklarda (köprü, çevre yolu) dolambaç meşrudur,
  /// o yüzden mutlak bir fazlalık eşiği de aranır.
  @visibleForTesting
  List<LatLng> cleanRoute(Map<String, dynamic> route, List<LatLng> pts) {
    final legs = route['legs'] as List?;
    if (legs == null || legs.length != pts.length - 1) {
      return _geometry(route['geometry']);
    }
    final out = <LatLng>[pts.first];
    for (var i = 0; i < legs.length; i++) {
      final leg = legs[i] as Map<String, dynamic>;
      final straight = _distance(pts[i], pts[i + 1]);
      final driven = (leg['distance'] as num?)?.toDouble() ?? 0;
      final detour = driven - straight;
      final absurd = detour > 350 && driven > straight * 3.5;
      if (absurd) {
        out.add(pts[i + 1]);          // düz çizgi: ilmeği çizme
        continue;
      }
      for (final step in (leg['steps'] as List? ?? const [])) {
        final g = _geometry((step as Map<String, dynamic>)['geometry']);
        for (final p in g) {
          if (out.isEmpty || _distance(out.last, p) > 1) out.add(p);
        }
      }
      if (out.isEmpty || _distance(out.last, pts[i + 1]) > 60) {
        out.add(pts[i + 1]);
      }
    }
    return out;
  }

  List<LatLng> _geometry(Object? geom) {
    final coords = (geom is Map) ? geom['coordinates'] as List? : null;
    if (coords == null) return const [];
    return [
      for (final c in coords)
        LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()),
    ];
  }

  double _distance(LatLng a, LatLng b) => _geo.as(LengthUnit.Meter, a, b);

  /// Üst üste binen ara noktaları at — OSRM aynı noktayı iki kez görünce
  /// aralarında sahte bir tur atıyor.
  List<LatLng> _dedupe(List<LatLng> pts) {
    final out = <LatLng>[];
    for (final p in pts) {
      if (out.isEmpty || _distance(out.last, p) > 20) out.add(p);
    }
    return out.length >= 2 ? out : pts;
  }

  /// İki nokta arası yürüme rotası (kısa mesafe — konumdan durağa).
  Future<List<LatLng>> walk(LatLng from, LatLng to) => route([from, to]);

  /// [n]'den fazla nokta varsa uçları koruyarak eşit aralıkta örnekle.
  List<LatLng> _sample(List<LatLng> pts, int n) {
    if (pts.length <= n) return pts;
    final out = <LatLng>[];
    final step = (pts.length - 1) / (n - 1);
    for (var i = 0; i < n; i++) {
      out.add(pts[(i * step).round().clamp(0, pts.length - 1)]);
    }
    return out;
  }
}
