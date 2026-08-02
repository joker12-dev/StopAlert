import 'package:flutter_test/flutter_test.dart';
import 'package:stopalert/src/engine/bus_dead_reckoning.dart';
import 'package:stopalert/src/engine/geo.dart';

/// 41. paralelde doğuya uzanan düz güzergâh — nokta arası ~100 m.
///
/// Düz seçildi ki "kaç metre ilerledi" beklentisi elle hesaplanabilsin.
List<LatLng> _straightRoute({int points = 120}) {
  const lat = 41.0;
  const lon0 = 29.0;
  // 1 derece boylam ≈ 111320 * cos(41°) ≈ 84.0 km → 100 m ≈ 0.00119 derece.
  const step = 100 / (111320 * 0.7547);
  return [for (var i = 0; i < points; i++) LatLng(lat, lon0 + step * i)];
}

void main() {
  final route = _straightRoute();
  final start = route.first;

  /// Güzergâh başından itibaren kaç metre ilerlemiş.
  double along(BusFix f) => haversineMeters(start, f.point);

  /// [meters] kadar ilerideki gerçek konum.
  LatLng at(double meters) {
    const step = 100 / (111320 * 0.7547);
    return LatLng(41.0, 29.0 + step * (meters / 100));
  }

  final t0 = DateTime(2026, 8, 2, 12, 0, 0);

  BusDeadReckoning engine() => BusDeadReckoning(route: route);

  group('İki ölçüm arasında ilerleme', () {
    test('ölçülen hızla güzergâh üzerinde yürür', () {
      final dr = engine();
      dr.observe({'A': at(0)}, t0, seenAt: t0);
      // 100 sn'de 550 m → 5,5 m/sn.
      final t1 = t0.add(const Duration(seconds: 100));
      dr.observe({'A': at(550)}, t1, seenAt: t1);

      // Harmanlama (1,2 sn) bittikten sonra: 550 + 5,5 * 30 ≈ 715 m.
      final fix = dr.positionsAt(t1.add(const Duration(seconds: 30)))['A']!;
      expect(along(fix), closeTo(715, 25));
    });

    test('ölçüm gelmezse sonsuza kadar sürmez (75 sn üstü donar)', () {
      final dr = engine();
      dr.observe({'A': at(0)}, t0, seenAt: t0);
      final t1 = t0.add(const Duration(seconds: 100));
      dr.observe({'A': at(550)}, t1, seenAt: t1);

      final capped = dr.positionsAt(t1.add(const Duration(minutes: 10)))['A']!;
      // 550 + 5,5 * 75 ≈ 962 m — 10 dakikalık hayali yolculuk değil.
      expect(along(capped), closeTo(962, 30));
    });

    test('aynı fotoğraf tekrar gelirse hız bozulmaz', () {
      final dr = engine();
      dr.observe({'A': at(0)}, t0, seenAt: t0);
      final t1 = t0.add(const Duration(seconds: 100));
      dr.observe({'A': at(550)}, t1, seenAt: t1);

      final before = along(dr.positionsAt(t1.add(const Duration(seconds: 30)))['A']!);
      // İETT ~60 sn'de bir yayınlıyor: arada aynı damga tekrar tekrar gelir.
      dr.observe({'A': at(550)}, t1.add(const Duration(seconds: 20)), seenAt: t1);
      final after = along(dr.positionsAt(t1.add(const Duration(seconds: 30)))['A']!);

      expect(after, closeTo(before, 1));
      expect(dr.speedKmh('A'), closeTo(19.8, 1)); // 5,5 m/sn
    });

    test('yeni ölçüm sıçratmaz, yumuşak geçer', () {
      final dr = engine();
      dr.observe({'A': at(0)}, t0, seenAt: t0);
      final t1 = t0.add(const Duration(seconds: 100));
      dr.observe({'A': at(550)}, t1, seenAt: t1);
      final shown = along(dr.positionsAt(t1.add(const Duration(seconds: 40)))['A']!);

      // Araç beklenenden geride çıktı (trafiğe takılmış): ~600 m.
      final t2 = t1.add(const Duration(seconds: 40));
      dr.observe({'A': at(600)}, t2, seenAt: t2);

      // Harmanın hemen başında hâlâ eski konuma yakın olmalı — ışınlanmamalı.
      final justAfter = along(dr.positionsAt(t2.add(const Duration(milliseconds: 60)))['A']!);
      expect((justAfter - shown).abs(), lessThan(40));
    });
  });

  group('Güzergâh disiplini', () {
    test('hattan sapmış ölçüm çizgiye oturtulur', () {
      final dr = engine();
      // Enlemi kaydır: ~300 m kuzeyde bir ölçüm (GPS hatası / yan sokak).
      final off = LatLng(41.0027, at(500).lon);
      dr.observe({'A': off}, t0, seenAt: t0);

      final fix = dr.positionsAt(t0)['A']!;
      expect(fix.point.lat, closeTo(41.0, 1e-6)); // çizgi üzerinde
      expect(along(fix), closeTo(500, 20));
    });

    test('yön açısı gidiş yönünü verir (doğuya ≈ 90°)', () {
      final dr = engine();
      dr.observe({'A': at(500)}, t0, seenAt: t0);
      expect(dr.positionsAt(t0)['A']!.bearing, closeTo(90, 3));
    });

    test('güzergâh sonunu aşmaz', () {
      final dr = engine();
      dr.observe({'A': at(11500)}, t0, seenAt: t0);
      final t1 = t0.add(const Duration(seconds: 60));
      dr.observe({'A': at(11800)}, t1, seenAt: t1);

      final fix = dr.positionsAt(t1.add(const Duration(seconds: 70)))['A']!;
      expect(along(fix), lessThanOrEqualTo(11900 + 1));
    });
  });

  group('Filo değişimi', () {
    test('bildirilmeyen araç takipten düşer', () {
      final dr = engine();
      dr.observe({'A': at(0), 'B': at(300)}, t0, seenAt: t0);
      expect(dr.positionsAt(t0).keys, containsAll(['A', 'B']));

      final t1 = t0.add(const Duration(seconds: 60));
      dr.observe({'A': at(400)}, t1, seenAt: t1); // B seferi bitirdi
      expect(dr.positionsAt(t1).containsKey('B'), isFalse);
    });

    test('güzergâh yokken sessizce boş döner', () {
      final dr = BusDeadReckoning();
      dr.observe({'A': at(0)}, t0, seenAt: t0);
      expect(dr.hasRoute, isFalse);
      expect(dr.positionsAt(t0), isEmpty);
    });

    test('güzergâh değişince eski ilerlemeler atılır', () {
      final dr = engine();
      dr.observe({'A': at(500)}, t0, seenAt: t0);
      dr.setRoute(_straightRoute(points: 40));
      expect(dr.positionsAt(t0), isEmpty);
    });
  });
}
