import 'dart:math' as math;

/// Basit coğrafi koordinat.
class LatLng {
  const LatLng(this.lat, this.lon);

  final double lat;
  final double lon;
}

/// İki nokta arası metre cinsinden Haversine mesafesi.
double haversineMeters(LatLng a, LatLng b) {
  const earthRadius = 6371000.0; // metre
  final dLat = _rad(b.lat - a.lat);
  final dLon = _rad(b.lon - a.lon);
  final lat1 = _rad(a.lat);
  final lat2 = _rad(b.lat);
  final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1) * math.cos(lat2) * math.sin(dLon / 2) * math.sin(dLon / 2);
  return 2 * earthRadius * math.asin(math.min(1, math.sqrt(h)));
}

double _rad(double deg) => deg * math.pi / 180;

/// Bir GPS noktasının hat çizgisi (sıralı duraklar) üzerine izdüşümü.
class LineProjection {
  const LineProjection({
    required this.segmentIndex,
    required this.t,
    required this.snapped,
    required this.offsetMeters,
  });

  /// İzdüşümün düştüğü segment: stops[segmentIndex] -> stops[segmentIndex+1].
  final int segmentIndex;

  /// Segment üzerindeki oran [0,1]: 0 = segment başı, 1 = segment sonu.
  final double t;

  /// Hat üzerine oturtulmuş nokta.
  final LatLng snapped;

  /// GPS noktasının hattan sapması (metre) — düşük değer = hat üzerinde.
  final double offsetMeters;
}

/// [point]'i sıralı [polyline] üzerindeki en yakın segmente oturtur.
///
/// Kısa mesafelerde (birkaç km) düzlem yaklaşımı yeterli doğrulukta; enlem
/// düzeltmesiyle boylam ölçeklenir.
LineProjection projectOntoLine(LatLng point, List<LatLng> polyline) {
  assert(polyline.length >= 2);
  final latScale = math.cos(_rad(point.lat));

  // Yerel düzlem koordinatları (metre benzeri birim).
  double x(LatLng p) => p.lon * latScale;
  double y(LatLng p) => p.lat;

  var bestSeg = 0;
  var bestT = 0.0;
  var bestDist2 = double.infinity;
  late LatLng bestSnap;

  final px = x(point);
  final py = y(point);

  for (var i = 0; i < polyline.length - 1; i++) {
    final ax = x(polyline[i]);
    final ay = y(polyline[i]);
    final bx = x(polyline[i + 1]);
    final by = y(polyline[i + 1]);
    final dx = bx - ax;
    final dy = by - ay;
    final len2 = dx * dx + dy * dy;
    var t = len2 == 0 ? 0.0 : ((px - ax) * dx + (py - ay) * dy) / len2;
    t = t.clamp(0.0, 1.0);
    final sx = ax + t * dx;
    final sy = ay + t * dy;
    final ddx = px - sx;
    final ddy = py - sy;
    final dist2 = ddx * ddx + ddy * ddy;
    if (dist2 < bestDist2) {
      bestDist2 = dist2;
      bestSeg = i;
      bestT = t;
      bestSnap = LatLng(sy, sx / latScale);
    }
  }

  return LineProjection(
    segmentIndex: bestSeg,
    t: bestT,
    snapped: bestSnap,
    offsetMeters: haversineMeters(point, bestSnap),
  );
}
