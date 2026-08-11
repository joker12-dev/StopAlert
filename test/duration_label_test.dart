import 'package:flutter_test/flutter_test.dart';
import 'package:stopalert/src/util/duration_label.dart';

void main() {
  group('minutesLabel', () {
    test('bir saatin altı dakika olarak yazılır', () {
      expect(minutesLabel(0), '0 dk');
      expect(minutesLabel(7), '7 dk');
      expect(minutesLabel(59), '59 dk');
    });

    test('bir saati aşan süre saat + dakika olur', () {
      expect(minutesLabel(75), '1 sa 15 dk');
      expect(minutesLabel(61), '1 sa 1 dk');
      expect(minutesLabel(135), '2 sa 15 dk');
    });

    test('tam saatte gereksiz "0 dk" yazılmaz', () {
      expect(minutesLabel(60), '1 sa');
      expect(minutesLabel(120), '2 sa');
    });

    test('saniyeden etiket dakikaya yuvarlar', () {
      expect(secondsLabel(90), '2 dk');
      expect(secondsLabel(4500), '1 sa 15 dk');
    });
  });
}
