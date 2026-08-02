import 'dart:math' as math;

import 'geo.dart';

/// Canlı otobüs konumlarını iki gerçek ölçüm ARASINDA yürüten ölü hesap.
///
/// NEDEN GEREKLİ: İETT filo servisi saniyelik akış vermiyor. Ölçtük — bütün
/// araçlar tek bir ortak zaman damgası taşıyor ve toplu halde ~60 saniyede bir
/// güncelleniyor (90 sn'lik yoklamada 27 istekten yalnızca biri yeni veri
/// getirdi). Yani daha sık istek atmak (proxy, ücretli havuz, ne olursa) aynı
/// yanıtı tekrar tekrar indirmekten başka bir şey yapmaz.
///
/// Bu yüzden akıcı hareket İSTEMCİDE üretilir: aracın güzergâh çizgisi
/// üzerindeki ilerlemesi ölçülür, iki ölçüm arasında bu hızla yürütülür, yeni
/// ölçüm gelince sıçratmadan üzerine oturtulur (Moovit/Google Maps yöntemi).
///
/// Güzergâh çizgisi dışına asla çıkılmaz: konum her zaman polyline üzerinde
/// bir noktadır, dolayısıyla otobüs binalara girmez.
class BusDeadReckoning {
  BusDeadReckoning({List<LatLng> route = const []}) {
    setRoute(route);
  }

  /// Güzergâh çizgisi ve her düğüme kadarki kümülatif mesafe (metre).
  List<LatLng> _route = const [];
  List<double> _cum = const [];

  final Map<String, _Track> _tracks = {};

  /// Şehir içi otobüs için makul hız aralığı (m/sn) — 0..80 km/sa.
  static const _maxSpeed = 22.0;

  /// Hiç ölçüm yokken varsayılan ilerleme hızı (~20 km/sa).
  static const _defaultSpeed = 5.5;

  /// Yeni ölçüm gelmezse bu kadar süreden fazla ileri sarma. Kaynak ~60 sn'de
  /// bir güncellendiği için biraz üstü; ötesinde araç DURDURULUR — uydurma bir
  /// konumu sürdürmektense olduğu yerde bırakmak dürüst olanı.
  static const _maxExtrapolation = Duration(seconds: 75);

  /// Yeni ölçüm gelince oraya bu sürede yumuşakça kayılır (sıçrama olmasın).
  static const _blend = Duration(milliseconds: 1200);

  bool get hasRoute => _route.length >= 2;

  void setRoute(List<LatLng> route) {
    _route = route;
    if (route.length < 2) {
      _cum = const [];
      return;
    }
    final cum = List<double>.filled(route.length, 0);
    for (var i = 1; i < route.length; i++) {
      cum[i] = cum[i - 1] + haversineMeters(route[i - 1], route[i]);
    }
    _cum = cum;
    _tracks.clear(); // eski güzergâhın ilerleme değerleri artık geçersiz
  }

  /// Yeni ölçüm partisi. [seenAt] araçların ortak `son_konum_zamani` değeri;
  /// çözümlenemiyorsa [now] kullanılır.
  ///
  /// [positions] plaka/kapı no -> gerçek konum.
  void observe(Map<String, LatLng> positions, DateTime now, {DateTime? seenAt}) {
    if (!hasRoute) return;
    final stamp = seenAt ?? now;
    for (final entry in positions.entries) {
      final s = _distanceAlong(entry.value);
      final t = _tracks[entry.key];
      if (t == null) {
        _tracks[entry.key] = _Track(s: s, at: stamp, shownS: s, wallAt: now);
        continue;
      }
      // Aynı fotoğraf tekrar geldi: hiçbir şey yapma (hız bozulmasın).
      if (!stamp.isAfter(t.at)) continue;

      final dt = stamp.difference(t.at).inMilliseconds / 1000.0;
      final ds = s - t.s;
      if (dt > 0.5 && ds >= 0) {
        // Ölçülen hız; ani değişimleri yumuşat (yarı yarıya harmanla).
        final measured = (ds / dt).clamp(0.0, _maxSpeed);
        t.speed = t.speed == null ? measured : (t.speed! * 0.5 + measured * 0.5);
      } else if (ds < 0) {
        // Geri gitti: sefer başa döndü ya da izdüşüm zıpladı — hızı unut.
        t.speed = null;
      }
      // Şu an ekranda görünen yerden yeni ölçüme yumuşak geçiş.
      t.blendFrom = t.shownS;
      t.blendAt = now;
      t.s = s;
      t.at = stamp;
      t.wallAt = now;
    }
    // Artık bildirilmeyen araçları unut (sefer bitti / hat değiştirdi).
    _tracks.removeWhere((k, _) => !positions.containsKey(k));
  }

  /// [now] anında ekranda gösterilecek konumlar (ve yön açıları).
  ///
  /// Ölçümler arasında çağrıldıkça araç güzergâh üzerinde ilerler.
  Map<String, BusFix> positionsAt(DateTime now) {
    if (!hasRoute) return const {};
    final out = <String, BusFix>{};
    _tracks.forEach((plate, t) {
      final elapsed = now.difference(t.wallAt);
      final capped = elapsed > _maxExtrapolation ? _maxExtrapolation : elapsed;
      final speed = t.speed ?? _defaultSpeed;
      var s = t.s + speed * (capped.inMilliseconds / 1000.0);
      s = s.clamp(0.0, _cum.last);

      // Yeni ölçüm sonrası sıçramayı yumuşat.
      final bAt = t.blendAt;
      if (bAt != null) {
        final k = now.difference(bAt).inMilliseconds / _blend.inMilliseconds;
        if (k < 1) {
          final e = _easeOut(k.clamp(0.0, 1.0));
          s = t.blendFrom! + (s - t.blendFrom!) * e;
        } else {
          t.blendAt = null;
        }
      }
      t.shownS = s;
      out[plate] = BusFix(point: _pointAt(s), bearing: _bearingAt(s));
    });
    return out;
  }

  /// Bir aracın anlık tahmini hızı (km/sa) — bilinmiyorsa null.
  double? speedKmh(String plate) {
    final s = _tracks[plate]?.speed;
    return s == null ? null : s * 3.6;
  }

  /// Ölçüm konumunun güzergâh başından itibaren mesafesi (metre).
  double _distanceAlong(LatLng p) {
    final proj = projectOntoLine(p, _route);
    final i = proj.segmentIndex;
    final segLen = _cum[i + 1] - _cum[i];
    return _cum[i] + segLen * proj.t;
  }

  /// Güzergâh başından [s] metre ilerideki nokta.
  LatLng _pointAt(double s) {
    if (s <= 0) return _route.first;
    if (s >= _cum.last) return _route.last;
    var lo = 0;
    var hi = _cum.length - 1;
    while (lo + 1 < hi) {
      final mid = (lo + hi) ~/ 2;
      if (_cum[mid] <= s) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final segLen = _cum[lo + 1] - _cum[lo];
    final t = segLen <= 0 ? 0.0 : (s - _cum[lo]) / segLen;
    final a = _route[lo];
    final b = _route[lo + 1];
    return LatLng(a.lat + (b.lat - a.lat) * t, a.lon + (b.lon - a.lon) * t);
  }

  /// [s] noktasındaki gidiş yönü (derece, kuzey = 0) — simgeyi döndürmek için.
  double _bearingAt(double s) {
    final a = _pointAt(math.max(0, s - 15));
    final b = _pointAt(math.min(_cum.last, s + 15));
    final dLon = (b.lon - a.lon) * math.cos(a.lat * math.pi / 180);
    final dLat = b.lat - a.lat;
    if (dLon == 0 && dLat == 0) return 0;
    return (math.atan2(dLon, dLat) * 180 / math.pi + 360) % 360;
  }

  static double _easeOut(double t) => 1 - math.pow(1 - t, 3).toDouble();
}

/// Ekranda gösterilecek tek araç konumu.
class BusFix {
  const BusFix({required this.point, required this.bearing});

  final LatLng point;

  /// Güzergâh yönü (derece) — otobüs simgesi bu açıyla döner.
  final double bearing;
}

/// Tek aracın izlenen durumu.
class _Track {
  _Track({
    required this.s,
    required this.at,
    required this.shownS,
    required this.wallAt,
  });

  /// Son ÖLÇÜLEN güzergâh mesafesi (metre) ve o ölçümün zaman damgası.
  double s;
  DateTime at;

  /// Ölçümün alındığı yerel saat — ileri sarma bundan hesaplanır. (Servisin
  /// damgası cihaz saatiyle aynı olmayabilir; ilerlemeyi yerel saatle sürdürüp
  /// hızı servis damgasıyla ölçmek ikisinin de hatasını dışarıda bırakır.)
  DateTime wallAt;

  /// En son ekranda gösterilen mesafe — yeni ölçüme buradan harmanlanır.
  double shownS;

  double? speed; // m/sn
  double? blendFrom;
  DateTime? blendAt;
}
