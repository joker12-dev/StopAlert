import 'package:cloud_firestore/cloud_firestore.dart';

import 'models.dart';

/// Tamamlanan bir yolculuğun kaydı (Firestore: users/{uid}/journeys).
class JourneyRecord {
  const JourneyRecord({
    this.id = '',
    required this.lineCode,
    required this.lineName,
    required this.lineTypeName,
    required this.boardingStopName,
    required this.targetStopName,
    required this.durationSeconds,
    required this.stopsTraveled,
    required this.status,
    this.createdAt,
  });

  final String id;
  final String lineCode;
  final String lineName;
  final String lineTypeName;
  final String boardingStopName;
  final String targetStopName;
  final int durationSeconds;
  final int stopsTraveled;

  /// completed | cancelled
  final String status;
  final DateTime? createdAt;

  LineType get lineType => LineType.fromName(lineTypeName);

  Map<String, dynamic> toMap() => {
        'lineCode': lineCode,
        'lineName': lineName,
        'lineTypeName': lineTypeName,
        'boardingStopName': boardingStopName,
        'targetStopName': targetStopName,
        'durationSeconds': durationSeconds,
        'stopsTraveled': stopsTraveled,
        'status': status,
        'createdAt': FieldValue.serverTimestamp(),
      };

  factory JourneyRecord.fromDoc(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final d = doc.data();
    return JourneyRecord(
      id: doc.id,
      lineCode: d['lineCode'] as String? ?? '',
      lineName: d['lineName'] as String? ?? '',
      lineTypeName: d['lineTypeName'] as String? ?? 'bus',
      boardingStopName: d['boardingStopName'] as String? ?? '',
      targetStopName: d['targetStopName'] as String? ?? '',
      durationSeconds: (d['durationSeconds'] as num?)?.toInt() ?? 0,
      stopsTraveled: (d['stopsTraveled'] as num?)?.toInt() ?? 0,
      status: d['status'] as String? ?? 'completed',
      createdAt: (d['createdAt'] as Timestamp?)?.toDate(),
    );
  }
}
