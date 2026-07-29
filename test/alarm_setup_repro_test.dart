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
  testWidgets('Ana sayfadan arama kutusuyla Alarm Kur akışı',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    // Ana sayfadaki arama kutusu Rotalar (arama) sekmesini açar.
    await tester.tap(find.text('Durak veya hat ara...'));
    await tester.pumpAndSettle();
    expect(find.text('Nereye Gitmek İstersiniz?'), findsOneWidget);

    // Aramadan gerçek bir durak seçince Alarm Kur açılır.
    await tester.enterText(find.byType(TextField), 'Kadıköy');
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.arrow_forward).first);
    await tester.pumpAndSettle();

    expect(find.text('Alarm Kur'), findsOneWidget);
    expect(find.text('ALARM TETİKLEME'), findsOneWidget);
    // Tetikleme modu seçenekleri görünür (durak sayısı / mesafe).
    expect(find.text('Kalan Durak'), findsOneWidget);
    expect(find.text('Kalan Mesafe'), findsOneWidget);
  });

  testWidgets('Arama sonucundan Alarm Kur acilir', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Rotalar'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Kadıköy');
    await tester.pumpAndSettle();

    // Sonuç kartlarının her birinde sağda arrow_forward ikonu var; ilkine dokun
    // (ekran dışına kayabilecek bir metin yerine kesin görünür ilk sonuç).
    final firstResult = find.byIcon(Icons.arrow_forward).first;
    expect(firstResult, findsOneWidget);
    await tester.tap(firstResult);
    await tester.pumpAndSettle();

    expect(find.text('Alarm Kur'), findsOneWidget);
  });

  testWidgets('Favori yokken bos durum gorunur', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Favoriler'));
    await tester.pumpAndSettle();

    // Firestore test ortaminda bos doner -> bos durum mesaji.
    expect(find.text('Favori Rotalar'), findsOneWidget);
    expect(find.textContaining('Henüz favori rota yok'), findsOneWidget);
  });

  testWidgets('Favori ekranindaki + butonu aramayi acar', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Favoriler'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();

    expect(find.text('Nereye Gitmek İstersiniz?'), findsOneWidget);
  });
}
