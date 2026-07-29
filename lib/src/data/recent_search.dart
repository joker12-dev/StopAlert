import 'models.dart';

/// Arama ekranındaki "Son Aramalar" girdisi (cihazda kalıcı tutulur).
class RecentSearch {
  const RecentSearch({
    required this.stopName,
    required this.stopId,
    required this.lineId,
    required this.lineCode,
    required this.lineTypeName,
  });

  final String stopName;
  final String stopId;
  final String lineId;
  final String lineCode;
  final String lineTypeName;

  LineType get lineType =>
      LineType.values.asNameMap()[lineTypeName] ?? LineType.bus;

  Map<String, dynamic> toMap() => {
        'stopName': stopName,
        'stopId': stopId,
        'lineId': lineId,
        'lineCode': lineCode,
        'lineTypeName': lineTypeName,
      };

  factory RecentSearch.fromMap(Map<String, dynamic> map) => RecentSearch(
        stopName: map['stopName'] as String? ?? '',
        stopId: map['stopId'] as String? ?? '',
        lineId: map['lineId'] as String? ?? '',
        lineCode: map['lineCode'] as String? ?? '',
        lineTypeName: map['lineTypeName'] as String? ?? 'bus',
      );
}
