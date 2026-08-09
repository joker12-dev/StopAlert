import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:stopalert/main.dart';
import 'package:stopalert/src/data/sample_lines.dart';
import 'package:stopalert/src/state/journey_provider.dart';
import 'package:stopalert/src/util/anim_config.dart';

/// Asset I/O ve konum, widget testinin sahte-async ortamında çözülmediği için
/// linesProvider örnek veriyle, nearbyStopsProvider sabit bir yakın durakla
/// geçersiz kılınır (navigasyonu test ediyoruz, GTFS/GPS yüklemesini değil).
Widget _app() => ProviderScope(
      overrides: [
        linesProvider.overrideWith((ref) => sampleLines),
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
    // Onboarding'i tamamlanmış say ki testler doğrudan ana ekrana açılsın.
    SharedPreferences.setMockInitialValues({'onboarding_done_v1': true});
    // Sürekli animasyonları kapat (pumpAndSettle kilitlenmesin).
    AppAnim.enabled = false;
  });
  testWidgets('Ana sayfadan arama kutusu HATLAR sekmesini açar',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    // Ana sayfadaki arama kutusu Hatlar sekmesini açar.
    await tester.tap(find.text('İneceğin durağı veya hattı ara...'));
    await tester.pumpAndSettle();
    expect(find.text('Nerede İneceksin?'), findsOneWidget);
  });

  testWidgets('DURAKLAR sekmesinden durak → hat → Alarm Kur akışı',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    // Durak araması artık kendi sekmesinde; Hatlar yalnızca hat listeliyor.
    await tester.tap(find.text('Duraklar'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Ayrılık');
    await tester.pumpAndSettle();

    // Durak künyesi açılır (yaklaşan otobüsler + duraktan geçen hatlar).
    // Kartın kendisine dokun: metinle aramak arama KUTUSUNU da yakalıyor.
    await tester.tap(find.byIcon(Icons.chevron_right_rounded).first);
    await tester.pumpAndSettle();
    expect(find.text('BU DURAKTAN GEÇEN HATLAR'), findsOneWidget);

    // Hattı seçince Alarm Kur açılır.
    await tester.tap(find.byIcon(Icons.alarm_add_rounded).first);
    await tester.pumpAndSettle();
    expect(find.text('Alarm Kur'), findsOneWidget);
    expect(find.text('ALARM TETİKLEME'), findsOneWidget);
  });

  testWidgets('Favori ekranindaki + butonu aramayi acar', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Favoriler'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();

    expect(find.text('Nerede İneceksin?'), findsOneWidget);
  });
}
