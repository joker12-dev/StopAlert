import 'package:flutter_test/flutter_test.dart';
import 'package:stopalert/src/util/greeting.dart';

void main() {
  group('greetingForHour', () {
    test('sabah günaydın', () {
      expect(greetingForHour(5), 'Günaydın');
      expect(greetingForHour(9), 'Günaydın');
      expect(greetingForHour(10), 'Günaydın');
    });

    test('öğle saatlerinin kendi selamı var', () {
      expect(greetingForHour(11), 'İyi öğlenler');
      expect(greetingForHour(14), 'İyi öğlenler');
    });

    test('öğleden sonra iyi günler', () {
      expect(greetingForHour(15), 'İyi günler');
      expect(greetingForHour(17), 'İyi günler');
    });

    test('akşam iyi akşamlar', () {
      expect(greetingForHour(18), 'İyi akşamlar');
      expect(greetingForHour(21), 'İyi akşamlar');
    });

    test('gece iyi geceler — gece yarısını aşan saatler dâhil', () {
      expect(greetingForHour(22), 'İyi geceler');
      expect(greetingForHour(0), 'İyi geceler');
      expect(greetingForHour(4), 'İyi geceler');
    });

    test('günün 24 saati bir karşılık üretir', () {
      for (var h = 0; h < 24; h++) {
        expect(greetingForHour(h).isNotEmpty, isTrue, reason: 'saat $h');
      }
    });
  });
}
