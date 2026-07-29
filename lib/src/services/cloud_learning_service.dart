import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../engine/segment_learner.dart';
import 'segment_learning_store.dart';

/// Anonim "kalabalık" segment-süresi öğrenmesi (Firestore `segment_stats`).
///
/// - **Katkı** ([flushQueue]): cihazdaki bulut kuyruğunu toplu ortalamaya
///   (sumSeconds/count) ATOMİK `increment` ile ekler — YALNIZCA kullanıcı
///   rıza verdiyse. Kimlik/uid yazılmaz (anonim).
/// - **Tohumlama** ([seedLocalFromLine]): bir hattın buluttaki ortalamalarını
///   yerel modele YALNIZCA kişisel veri yoksa ekler (yerel > kalabalık).
///
/// NOT: MVP istemci-tarafı toplama. Üretimde abuse'a karşı sunucu tarafı
/// (Cloud Functions) toplama tercih edilmeli.
class CloudLearningService {
  CloudLearningService(this._db, this._auth);

  final FirebaseFirestore _db;
  final FirebaseAuth _auth;

  CollectionReference<Map<String, dynamic>> get _col =>
      _db.collection('segment_stats');

  static String _docId(String lineId, String fromId, String toId) =>
      SegmentLearner.keyFor(lineId, fromId, toId).replaceAll('/', '_');

  /// Rıza varsa kuyruğu gönderir; rıza yoksa kuyruğu sessizce temizler.
  Future<void> flushQueue({required bool consent}) async {
    if (!consent) {
      await SegmentLearningStore.clearCloudQueue();
      return;
    }
    try {
      if (_auth.currentUser == null) return; // anonim oturum henüz yok — sonra
      final obs = await SegmentLearningStore.drainCloudQueue();
      if (obs.isEmpty) return;
      // Aynı segmenti tek yazımda topla.
      final grouped = <String,
          ({String lineId, String fromId, String toId, double sum, int n})>{};
      for (final o in obs) {
        if (o.fromId.isEmpty || o.toId.isEmpty) continue;
        final id = _docId(o.lineId, o.fromId, o.toId);
        final g = grouped[id];
        grouped[id] = g == null
            ? (
                lineId: o.lineId,
                fromId: o.fromId,
                toId: o.toId,
                sum: o.seconds,
                n: 1
              )
            : (
                lineId: g.lineId,
                fromId: g.fromId,
                toId: g.toId,
                sum: g.sum + o.seconds,
                n: g.n + 1
              );
      }
      if (grouped.isEmpty) return;
      final batch = _db.batch();
      grouped.forEach((id, g) {
        batch.set(
          _col.doc(id),
          {
            'lineId': g.lineId,
            'fromId': g.fromId,
            'toId': g.toId,
            'sumSeconds': FieldValue.increment(g.sum),
            'count': FieldValue.increment(g.n),
            'updatedAt': FieldValue.serverTimestamp(),
          },
          SetOptions(merge: true),
        );
      });
      await batch.commit();
    } catch (e) {
      // Kuyruk zaten drain edildi; kayıp kabul edilir (yerel model sağlam).
      debugPrint('[cloud-learn] katkı hatası: $e');
    }
  }

  /// Bir hattın buluttaki ortalamalarını yerel modele tohumlar (kişisel yoksa).
  Future<void> seedLocalFromLine(TransitLine line) async {
    try {
      if (_auth.currentUser == null) return;
      final snap = await _col.where('lineId', isEqualTo: line.id).get();
      if (snap.docs.isEmpty) return;
      final learner = await SegmentLearningStore.load();
      var changed = false;
      for (final doc in snap.docs) {
        final d = doc.data();
        final from = d['fromId'] as String? ?? '';
        final to = d['toId'] as String? ?? '';
        final count = (d['count'] as num?)?.toInt() ?? 0;
        final sum = (d['sumSeconds'] as num?)?.toDouble() ?? 0;
        if (from.isEmpty || to.isEmpty || count <= 0) continue;
        final before = learner.learnedSegmentCount;
        learner.seedIfAbsent(line.id, from, to, sum / count, count);
        if (learner.learnedSegmentCount != before) changed = true;
      }
      if (changed) await SegmentLearningStore.save(learner);
    } catch (e) {
      debugPrint('[cloud-learn] tohumlama hatası: $e');
    }
  }
}

final cloudLearningServiceProvider = Provider(
  (ref) =>
      CloudLearningService(FirebaseFirestore.instance, FirebaseAuth.instance),
);
