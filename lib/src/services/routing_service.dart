import 'dart:convert';

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

  /// [waypoints] üzerinden yol polyline'ı. Çok fazla nokta varsa örneklenir
  /// (OSRM istek sınırı). Başarısızsa boş liste.
  Future<List<LatLng>> route(List<LatLng> waypoints,
      {String profile = 'driving'}) async {
    if (waypoints.length < 2) return const [];
    final pts = _sample(waypoints, 90);
    final key =
        '$profile:${pts.map((p) => '${p.latitude.toStringAsFixed(4)},${p.longitude.toStringAsFixed(4)}').join(';')}';
    final cached = _cache[key];
    if (cached != null) return cached;
    try {
      final coords =
          pts.map((p) => '${p.longitude},${p.latitude}').join(';');
      final uri = Uri.parse(
          '$_base/$profile/$coords?overview=full&geometries=geojson');
      final res = await http.get(uri).timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return const [];
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      if (j['code'] != 'Ok') return const [];
      final routes = j['routes'] as List;
      if (routes.isEmpty) return const [];
      final geom = (routes.first as Map)['geometry'] as Map<String, dynamic>;
      final coordsList = geom['coordinates'] as List;
      final poly = <LatLng>[
        for (final c in coordsList)
          LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()),
      ];
      _cache[key] = poly;
      return poly;
    } catch (_) {
      return const [];
    }
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
