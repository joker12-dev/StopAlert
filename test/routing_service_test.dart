import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:stopalert/src/services/home_widget_service.dart';
import 'package:stopalert/src/services/routing_service.dart';

/// OSRM yanıtı taklidi: her bacak tek adımdan oluşur.
Map<String, dynamic> _route(List<({double distance, List<LatLng> geom})> legs) =>
    {
      'legs': [
        for (final leg in legs)
          {
            'distance': leg.distance,
            'steps': [
              {
                'geometry': {
                  'coordinates': [
                    for (final p in leg.geom) [p.longitude, p.latitude],
                  ],
                },
              },
            ],
          },
      ],
    };

void main() {
  const d = Distance();
  final svc = RoutingService.instance;

  group('OSRM ilmek temizliği', () {
    // İki durak ~150 m arayken OSRM tek yönlü sokaklar yüzünden bloğun
    // etrafından 900 m dolaşıyordu — haritada dikdörtgen ilmek çıkıyordu.
    test('absürt uzayan bacak düz çizgiyle değiştirilir', () {
      final a = LatLng(41.0450, 28.8060);
      final b = LatLng(41.0463, 28.8062);
      final loop = [
        a,
        LatLng(41.0450, 28.8090), // bloğun etrafı
        LatLng(41.0470, 28.8090),
        LatLng(41.0470, 28.8040),
        b,
      ];
      final out = svc.cleanRoute(
        _route([(distance: 900, geom: loop)]),
        [a, b],
      );

      expect(out.first, a);
      expect(out.last, b);
      // İlmek çizilmemeli: ara noktalar atıldığı için uç uca iki nokta kalır.
      expect(out.length, 2);
    });

    test('makul dolambaç korunur (yol geometrisi çizilir)', () {
      final a = LatLng(41.0450, 28.8060);
      final b = LatLng(41.0530, 28.8060);
      final road = [a, LatLng(41.0490, 28.8065), b];
      // ~890 m kuş uçuşu, 1000 m sürüş: normal bir yol.
      final out = svc.cleanRoute(
        _route([(distance: 1000, geom: road)]),
        [a, b],
      );

      expect(out.length, greaterThan(2));
      expect(d.as(LengthUnit.Meter, out.last, b), lessThan(60));
    });

    test('bacak sayısı uyuşmazsa bütün geometriye düşülür', () {
      final a = LatLng(41.0450, 28.8060);
      final b = LatLng(41.0530, 28.8060);
      final out = svc.cleanRoute({
        'geometry': {
          'coordinates': [
            [a.longitude, a.latitude],
            [b.longitude, b.latitude],
          ],
        },
      }, [
        a,
        b,
      ]);

      expect(out.length, 2);
      expect(out.first.latitude, closeTo(a.latitude, 1e-9));
    });
  });

  group('Widget mesafe biçimi', () {
    test('metre ve kilometre kısa yazılır', () {
      expect(HomeWidgetService.formatDistance(350), '350 m');
      expect(HomeWidgetService.formatDistance(999), '999 m');
      expect(HomeWidgetService.formatDistance(1240), '1,2 km');
      expect(HomeWidgetService.formatDistance(12400), '12 km');
    });

    test('geçersiz mesafe tire gösterir', () {
      expect(HomeWidgetService.formatDistance(-1), '—');
      expect(HomeWidgetService.formatDistance(double.nan), '—');
    });
  });
}
