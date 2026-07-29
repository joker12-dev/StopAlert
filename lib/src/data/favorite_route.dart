import 'package:cloud_firestore/cloud_firestore.dart';

import 'models.dart';

/// Kaydedilmiş favori rota (Firestore: users/{uid}/favorites).
/// Tek dokunuşla yeniden başlatmak için hat ve durak kimliklerini tutar.
class FavoriteRoute {
  const FavoriteRoute({
    this.id = '',
    required this.lineId,
    required this.lineCode,
    required this.lineName,
    required this.lineTypeName,
    required this.boardingStopId,
    required this.boardingStopName,
    required this.targetStopId,
    required this.targetStopName,
    this.createdAt,
  });

  final String id;
  final String lineId;
  final String lineCode;
  final String lineName;
  final String lineTypeName;
  final String boardingStopId;
  final String boardingStopName;
  final String targetStopId;
  final String targetStopName;
  final DateTime? createdAt;

  LineType get lineType => LineType.fromName(lineTypeName);
  String get label => '$boardingStopName → $targetStopName';

  Map<String, dynamic> toMap() => {
        'lineId': lineId,
        'lineCode': lineCode,
        'lineName': lineName,
        'lineTypeName': lineTypeName,
        'boardingStopId': boardingStopId,
        'boardingStopName': boardingStopName,
        'targetStopId': targetStopId,
        'targetStopName': targetStopName,
        'createdAt': FieldValue.serverTimestamp(),
      };

  factory FavoriteRoute.fromDoc(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final d = doc.data();
    return FavoriteRoute(
      id: doc.id,
      lineId: d['lineId'] as String? ?? '',
      lineCode: d['lineCode'] as String? ?? '',
      lineName: d['lineName'] as String? ?? '',
      lineTypeName: d['lineTypeName'] as String? ?? 'bus',
      boardingStopId: d['boardingStopId'] as String? ?? '',
      boardingStopName: d['boardingStopName'] as String? ?? '',
      targetStopId: d['targetStopId'] as String? ?? '',
      targetStopName: d['targetStopName'] as String? ?? '',
      createdAt: (d['createdAt'] as Timestamp?)?.toDate(),
    );
  }
}
