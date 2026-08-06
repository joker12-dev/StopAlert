import 'models.dart';

/// Arama ekranındaki "Son Aramalar" girdisi (cihazda kalıcı tutulur).
class RecentSearch {
  const RecentSearch({
    required this.stopName,
    required this.stopId,
    required this.lineId,
    required this.lineCode,
    required this.lineTypeName,
    this.cityId = '',
  });

  final String stopName;
  final String stopId;
  final String lineId;
  final String lineCode;
  final String lineTypeName;

  /// Kaydın HANGİ ŞEHRİN paketinden geldiği.
  ///
  /// ŞART: aynı kod birden fazla şehirde var (147 hem İstanbul'da hem
  /// Kocaeli'nde). Şehir yazılmazsa kayıt tekrar açılırken AKTİF şehrin
  /// paketinde aranıyor ve ya yanlış şehrin hattı açılıyor ya da hiçbir şey
  /// bulunamayıp sayfa boş geliyordu.
  ///
  /// Boş = eski kayıt (sürüm yükseltmesi); aktif şehir varsayılır.
  final String cityId;

  LineType get lineType =>
      LineType.values.asNameMap()[lineTypeName] ?? LineType.bus;

  Map<String, dynamic> toMap() => {
        'stopName': stopName,
        'stopId': stopId,
        'lineId': lineId,
        'lineCode': lineCode,
        'lineTypeName': lineTypeName,
        'cityId': cityId,
      };

  factory RecentSearch.fromMap(Map<String, dynamic> map) => RecentSearch(
        stopName: map['stopName'] as String? ?? '',
        stopId: map['stopId'] as String? ?? '',
        lineId: map['lineId'] as String? ?? '',
        lineCode: map['lineCode'] as String? ?? '',
        lineTypeName: map['lineTypeName'] as String? ?? 'bus',
        cityId: map['cityId'] as String? ?? '',
      );
}
