import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:stopalert/main.dart';
import 'package:stopalert/src/data/journey_record.dart';
import 'package:stopalert/src/data/sample_lines.dart';
import 'package:stopalert/src/state/journey_provider.dart';
import 'package:stopalert/src/util/anim_config.dart';

/// Geçmiş boş + sabit bir yakın durak: ana sayfanın boş durumunu ve yakındaki
/// duraklar bölümünü doğrular (GTFS/GPS yüklemesini değil).
Widget _app() => ProviderScope(
      overrides: [
        linesProvider.overrideWith((ref) => sampleLines),
        journeysStreamProvider
            .overrideWith((ref) => Stream.value(const <JourneyRecord>[])),
        nearbyStopsProvider.overrideWith(
          (ref) => [
            NearbyStopHit(
              line: marmaray,
              stop: marmaray.stops[27], // Ayrılık Çeşmesi
              meters: 350,
            ),
          ],
        ),
      ],
      child: const StopAlertApp(),
    );

void main() {
  setUp(() {
    // Rıza ekranı uygulamanın İLK kapısı; testler ana akışı denediği
    // için onay verilmiş sayılır.
    SharedPreferences.setMockInitialValues(
        {'onboarding_done_v1': true, 'consent_accepted_v1': true});
    AppAnim.enabled = false;
  });

  testWidgets('Geçmiş boşken boş durum + Yolculuk Yap + yakın duraklar',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    // Yakındaki duraklar kartı üstte; kaydırmadan görünür.
    expect(find.text('Yakındaki Duraklar'), findsOneWidget);
    expect(find.text('Ayrılık Çeşmesi'), findsOneWidget);

    // Boş durum listenin altında; sona kaydır.
    await tester.scrollUntilVisible(
      find.text('Henüz yolculuk yapmadınız'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Henüz yolculuk yapmadınız'), findsOneWidget);
    expect(find.text('Yolculuk Yap'), findsOneWidget);
  });

  testWidgets('Yolculuk Yap butonu aramayı açar', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    // Sona kadar kaydır: buton, alt navigasyonun üstünde net görünür konuma otursun.
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -1000));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Yolculuk Yap'));
    await tester.pumpAndSettle();

    // DURAKLAR sekmesine gider, Hatlar'a değil: alarm kurmanın yolu duraktan
    // geçiyor ve hat listesi arada fazladan bir adımdı.
    expect(find.text('Durak ara…'), findsOneWidget);
  });

  testWidgets('Yakındaki durak dokunuşu Alarm Kur açar', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    // Yakın durak kartı üstte; doğrudan dokun.
    await tester.tap(find.text('Ayrılık Çeşmesi'));
    await tester.pumpAndSettle();

    expect(find.text('Alarm Kur'), findsOneWidget);
  });
}
