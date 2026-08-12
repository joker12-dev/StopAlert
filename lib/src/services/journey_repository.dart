import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../data/favorite_route.dart';
import '../data/journey_record.dart';

/// Yolculuk geçmişini Firestore'da tutar (users/{uid}/journeys).
///
/// Oturum yoksa (anonim giriş henüz gelmediyse) yazma sessizce atlanır ve
/// akış boş döner — geçmiş kritik akış değildir, uygulama çalışmaya devam eder.
class JourneyRepository {
  JourneyRepository(this._db, this._auth);

  final FirebaseFirestore _db;
  final FirebaseAuth _auth;

  CollectionReference<Map<String, dynamic>>? _collectionFor(String? uid) {
    if (uid == null) return null;
    return _db.collection('users').doc(uid).collection('journeys');
  }

  Future<void> save(JourneyRecord record) async {
    final col = _collectionFor(_auth.currentUser?.uid);
    if (col == null) return;
    try {
      await col.add(record.toMap());
    } catch (e) {
      // Çevrimdışı: Firestore yerel önbelleğe kuyruklar; bağlantı gelince akar.
      debugPrint('[journeys] kayıt hatası: $e');
    }
  }

  /// Son [limit] yolculuğu canlı akışla getirir (sınırsız çekmemek için).
  Stream<List<JourneyRecord>> watch(String uid, {int limit = 50}) {
    final col = _collectionFor(uid);
    if (col == null) return Stream.value(const []);
    return col
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .snapshots()
        .map((snap) => snap.docs.map(JourneyRecord.fromDoc).toList())
        .handleError((Object e) => debugPrint('[journeys] okuma hatası: $e'));
  }
}

/// Favori rotaları Firestore'da tutar (users/{uid}/favorites).
class FavoritesRepository {
  FavoritesRepository(this._db, this._auth);

  final FirebaseFirestore _db;
  final FirebaseAuth _auth;

  CollectionReference<Map<String, dynamic>>? _collectionFor(String? uid) {
    if (uid == null) return null;
    return _db.collection('users').doc(uid).collection('favorites');
  }

  /// Rotayı favorilere ekler — AYNISI VARSA HİÇBİR ŞEY YAPMAZ.
  ///
  /// Aynı hattın aynı biniş-iniş çifti ikinci kez eklenebiliyordu: kullanıcı
  /// aynı yolculuğu her tekrarladığında listeye bir kopya daha düşüyor ve
  /// favoriler birkaç günde aynı rotanın kopyalarıyla doluyordu.
  ///
  /// Dönen değer: kayıt gerçekten eklendi mi (false = zaten vardı).
  Future<bool> add(FavoriteRoute route) async {
    final col = _collectionFor(_auth.currentUser?.uid);
    if (col == null) return false;
    try {
      final existing = await col
          .where('lineId', isEqualTo: route.lineId)
          .where('boardingStopId', isEqualTo: route.boardingStopId)
          .where('targetStopId', isEqualTo: route.targetStopId)
          .limit(1)
          .get();
      if (existing.docs.isNotEmpty) return false;
      await col.add(route.toMap());
      return true;
    } catch (e) {
      debugPrint('[favorites] ekleme hatası: $e');
      return false;
    }
  }

  Future<void> remove(String id) async {
    final col = _collectionFor(_auth.currentUser?.uid);
    if (col == null || id.isEmpty) return;
    try {
      await col.doc(id).delete();
    } catch (e) {
      debugPrint('[favorites] silme hatası: $e');
    }
  }

  /// Favorileri canlı akışla getirir (limitli).
  Stream<List<FavoriteRoute>> watch(String uid, {int limit = 100}) {
    final col = _collectionFor(uid);
    if (col == null) return Stream.value(const []);
    return col
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .snapshots()
        .map((snap) => snap.docs.map(FavoriteRoute.fromDoc).toList())
        .handleError((Object e) => debugPrint('[favorites] okuma hatası: $e'));
  }
}
