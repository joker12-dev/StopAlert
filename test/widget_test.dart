import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:stopalert/main.dart';
import 'package:stopalert/src/util/anim_config.dart';

void main() {
  setUp(() {
    // Onboarding'i tamamlanmış say ki testler doğrudan ana ekrana açılsın.
    SharedPreferences.setMockInitialValues({'onboarding_done_v1': true});
    // Sürekli animasyonları (maskot süzülmesi, iskelet parıltısı) kapat ki
    // pumpAndSettle kilitlenmesin.
    AppAnim.enabled = false;
  });

  testWidgets('Ana ekran açılır ve sekmeler arasında gezinilir',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpWidget(const ProviderScope(child: StopAlertApp()));
    await tester.pumpAndSettle();

    // Ana Sayfa (premium) — üst bölüm öğeleri
    expect(find.text('Merhaba, Yolcu!'), findsOneWidget);
    expect(find.text('Nerede ineceksin?'), findsOneWidget);
    expect(find.text('Yakındaki Duraklar'), findsOneWidget);

    // Favoriler sekmesi
    await tester.tap(find.text('Favoriler'));
    await tester.pumpAndSettle();
    expect(find.text('Favori Rotalar'), findsOneWidget);

    // Profil sekmesi
    await tester.tap(find.text('Profil'));
    await tester.pumpAndSettle();
    expect(find.text('StopAlert Yolcusu'), findsOneWidget);

    // Rotalar (arama) sekmesi
    await tester.tap(find.text('Hatlar'));
    await tester.pumpAndSettle();
    expect(find.text('Nerede İneceksin?'), findsOneWidget);
  });
}
