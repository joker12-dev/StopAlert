import 'package:flutter_test/flutter_test.dart';
import 'package:stopalert/src/data/models.dart';
import 'package:stopalert/src/data/search_filter.dart';

/// Arama sonucu tür süzgeci.
///
/// Tek bir sorgu otobüs hattını, metro durağını ve vapur iskelesini aynı
/// listeye döküyordu. Çipler bunu daraltır; buradaki kurallar hangi türün
/// hangi çipte göründüğünü sabitliyor.
void main() {
  test('Tümü her türü geçirir', () {
    for (final t in LineType.values) {
      expect(SearchFilter.tumu.accepts(t), isTrue, reason: t.name);
    }
    expect(SearchFilter.tumu.showsBusStops, isTrue);
  });

  test('Otobüs ve Metrobüs AYRI çiplerdir', () {
    // İETT verisinde ikisi de otobüs kaynağından gelir ama kullanıcı için
    // metrobüs ayrı bir taşıt — karışırsa 34'ü ararken 34 otobüsleri boğar.
    expect(SearchFilter.otobus.accepts(LineType.bus), isTrue);
    expect(SearchFilter.otobus.accepts(LineType.metrobus), isFalse);
    expect(SearchFilter.metrobus.accepts(LineType.metrobus), isTrue);
    expect(SearchFilter.metrobus.accepts(LineType.bus), isFalse);
  });

  test('raylı türler kendi çipine düşer', () {
    expect(SearchFilter.metro.accepts(LineType.metro), isTrue);
    expect(SearchFilter.marmaray.accepts(LineType.marmaray), isTrue);
    expect(SearchFilter.vapur.accepts(LineType.ferry), isTrue);
    expect(SearchFilter.metro.accepts(LineType.marmaray), isFalse);
  });

  test('füniküler ve teleferik Tramvay çipinde toplanır', () {
    // Kendi çipini hak edecek kadar yaygın değiller; kullanıcı için en yakın
    // karşılık raylı/tramvay.
    expect(SearchFilter.tramvay.accepts(LineType.tram), isTrue);
    expect(SearchFilter.tramvay.accepts(LineType.funicular), isTrue);
    expect(SearchFilter.tramvay.accepts(LineType.cableCar), isTrue);
  });

  test('otobüs DURAKLARI yalnızca Tümü ve Otobüs çipinde', () {
    // Durakların türü yok; metro arayan kullanıcıya otobüs durağı göstermek
    // süzgecin amacını bozar.
    expect(SearchFilter.otobus.showsBusStops, isTrue);
    expect(SearchFilter.metro.showsBusStops, isFalse);
    expect(SearchFilter.vapur.showsBusStops, isFalse);
  });

  test('kalıcı kimlik çözümlemesi; bilinmeyen değer Tümü olur', () {
    for (final f in SearchFilter.values) {
      expect(SearchFilter.fromId(f.id), f);
    }
    expect(SearchFilter.fromId('yok'), SearchFilter.tumu);
    expect(SearchFilter.fromId(null), SearchFilter.tumu);
  });
}
