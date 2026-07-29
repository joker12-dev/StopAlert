import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stopalert/src/screens/permission_gate_screen.dart';

void main() {
  testWidgets('İzin kapısı kendiliğinden kapanmaz; Devam et ile tamamlanır',
      (tester) async {
    var completed = false;
    await tester.pumpWidget(MaterialApp(
      home: PermissionGateScreen(onCompleted: () => completed = true),
    ));
    await tester.pumpAndSettle();

    // Host ortamında tüm izinler "verilmiş" raporlanır; buna rağmen kapı
    // kendiliğinden kapanmamalı (ayarlardan dönüşte kullanıcıyı yarıda
    // bırakan otomatik kapanma regresyonu).
    expect(completed, isFalse);

    // Buton listenin sonunda; lazy ListView'da görünür olana dek kaydır.
    await tester.scrollUntilVisible(find.text('Devam et'), 200);
    await tester.pumpAndSettle();
    expect(completed, isFalse);

    await tester.tap(find.text('Devam et'));
    expect(completed, isTrue);
  });
}
