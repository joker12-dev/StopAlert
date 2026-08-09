import 'models.dart';

/// Arama sonuçlarındaki TÜR süzgeci.
///
/// Bir sorgu otobüs hattını, metro durağını ve vapur iskelesini aynı listeye
/// döküyordu; "Şişli" yazan kullanıcı ne aradığını biliyor ama listeyi
/// kaydırmak zorunda kalıyordu. Çipler bunu tek dokunuşla daraltır.
///
/// Sıra bilinçli: [tumu] önce, sonra kullanım sıklığına göre.
enum SearchFilter {
  tumu('tumu', 'Tümü'),
  otobus('otobus', 'Otobüs'),
  metro('metro', 'Metro'),
  metrobus('metrobus', 'Metrobüs'),
  marmaray('marmaray', 'Marmaray'),
  tramvay('tramvay', 'Tramvay'),
  vapur('vapur', 'Vapur');

  const SearchFilter(this.id, this.label);

  /// Ayarlara yazılan kalıcı anahtar.
  final String id;
  final String label;

  static SearchFilter fromId(String? id) {
    for (final f in SearchFilter.values) {
      if (f.id == id) return f;
    }
    return SearchFilter.tumu;
  }

  /// Bu süzgeç [type] türündeki sonucu geçirir mi?
  bool accepts(LineType type) => switch (this) {
        SearchFilter.tumu => true,
        SearchFilter.otobus => type == LineType.bus,
        SearchFilter.metrobus => type == LineType.metrobus,
        SearchFilter.metro => type == LineType.metro,
        SearchFilter.marmaray => type == LineType.marmaray,
        // Füniküler ve teleferik kendi çipini hak edecek kadar yaygın değil;
        // kullanıcı için "raylı" oldukları en yakın karşılık tramvay.
        SearchFilter.tramvay => type == LineType.tram ||
            type == LineType.funicular ||
            type == LineType.cableCar,
        SearchFilter.vapur => type == LineType.ferry,
      };

  /// Otobüs DURAKLARI bu süzgeçte görünsün mü?
  ///
  /// Durakların kendi türü yok; hangi hatların uğradığıyla anlamlılar.
  /// "Otobüs" ve "Tümü" dışındaki süzgeçlerde gizlenirler — metro arayan
  /// kullanıcıya otobüs durağı göstermek süzgecin amacını bozar.
  bool get showsBusStops =>
      this == SearchFilter.tumu || this == SearchFilter.otobus;
}
