import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stopalert/src/util/map_settle.dart';

/// Harita jesti sürerken yoğun işaret katmanlarının çizilmemesi.
///
/// Bu kozmetik değil: `MarkerLayer.build` kamera her değiştiğinde çalışıyor ve
/// 200 duraklı bir hatta jest başına on binlerce widget kuruluyordu. Cihaz
/// profilinde `_MarkerLayerState.build` toplam CPU'nun %93'ünü yiyordu, ana iş
/// parçacığı dokunuşa yanıt veremeyip uygulama ANR ile çöküyordu.
void main() {
  testWidgets('hareket başlayınca gizler, durunca geri getirir',
      (tester) async {
    final settle = MapSettle(delay: const Duration(milliseconds: 100));
    addTearDown(settle.dispose);

    // Dinleyicinin uyandırılması bir kare gerektiriyor (layout sırasında
    // bildirim yapılmıyor) — bu yüzden gerçek bir widget ağacına bağlanır.
    var builds = 0;
    var lastSettled = true;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ValueListenableBuilder<bool>(
          valueListenable: settle,
          builder: (_, s, __) {
            builds++;
            lastSettled = s;
            return const SizedBox();
          },
        ),
      ),
    );

    expect(lastSettled, isTrue, reason: 'başlangıçta harita duruyor');
    final buildsAtStart = builds;

    settle.touch();
    await tester.pump();                       // kare biter, gizleme yayılır
    expect(lastSettled, isFalse, reason: 'jest sürerken çizilmez');

    // Jest devam ediyor: art arda gelen kamera olayları geri getirmemeli.
    for (var i = 0; i < 5; i++) {
      settle.touch();
      await tester.pump(const Duration(milliseconds: 40));
      expect(lastSettled, isFalse);
    }

    // Parmak kalktı: gecikme dolunca işaretler geri gelir.
    await tester.pump(const Duration(milliseconds: 150));
    expect(lastSettled, isTrue, reason: 'kamera durunca yeniden çizilir');

    // Jest boyunca yeniden çizim sayısı SABİT kalmalı — asıl kazanç bu.
    // (gizle + göster = 2; kamera olayı başına bir tane DEĞİL.)
    expect(builds - buildsAtStart, 2);
  });

  testWidgets('süreklilik: uzun jest boyunca tek gizleme', (tester) async {
    final settle = MapSettle(delay: const Duration(milliseconds: 80));
    addTearDown(settle.dispose);

    var builds = 0;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ValueListenableBuilder<bool>(
          valueListenable: settle,
          builder: (_, __, ___) {
            builds++;
            return const SizedBox();
          },
        ),
      ),
    );
    final start = builds;

    // 60 kamera olayı ≈ bir saniyelik pinch.
    for (var i = 0; i < 60; i++) {
      settle.touch();
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(builds - start, 1, reason: '60 kamera olayı = 1 yeniden çizim');

    await tester.pump(const Duration(milliseconds: 120));
    expect(builds - start, 2);
  });

  test('dispose sonrası zamanlayıcı bildirim yapmaz', () async {
    final settle = MapSettle(delay: const Duration(milliseconds: 20));
    settle.touch();
    settle.dispose();
    // Atılmış bir ValueNotifier'a değer yazmak hata fırlatır; bekleyen
    // zamanlayıcının bunu yapmadığını doğrular.
    await Future<void>.delayed(const Duration(milliseconds: 60));
  });
}
