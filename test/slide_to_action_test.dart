import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stopalert/src/util/anim_config.dart';
import 'package:stopalert/src/widgets/slide_to_action.dart';

void main() {
  setUp(() => AppAnim.enabled = false);

  Widget host(VoidCallback onConfirmed) => MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              child: SlideToAction(
                label: 'Durdurmak için kaydır',
                onConfirmed: onConfirmed,
              ),
            ),
          ),
        ),
      );

  testWidgets('uca kadar kaydırınca onaylanır', (tester) async {
    var confirmed = false;
    await tester.pumpWidget(host(() => confirmed = true));
    await tester.pumpAndSettle();

    // Tutamağı (chevron_right) sağ uca kadar sürükle.
    await tester.drag(find.byIcon(Icons.chevron_right), const Offset(280, 0));
    await tester.pumpAndSettle();

    expect(confirmed, isTrue);
    // Onaylanınca tutamak onay işaretine döner.
    expect(find.byIcon(Icons.check), findsOneWidget);
  });

  testWidgets('kısa kaydırma onaylamaz, başa döner', (tester) async {
    var confirmed = false;
    await tester.pumpWidget(host(() => confirmed = true));
    await tester.pumpAndSettle();

    // Yalnızca biraz sürükle (eşik altında).
    await tester.drag(find.byIcon(Icons.chevron_right), const Offset(40, 0));
    await tester.pumpAndSettle();

    expect(confirmed, isFalse);
    expect(find.byIcon(Icons.check), findsNothing);
  });
}
