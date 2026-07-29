import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Hesap/veri işlemleri — KVKK "verilerimi sil" akışını yürütür.
class AccountService {
  AccountService(this._db, this._auth);

  final FirebaseFirestore _db;
  final FirebaseAuth _auth;

  /// Cihazda saklanan tüm kullanıcı verisi anahtarları (öğrenme dahil).
  static const _localKeys = [
    'app_settings_v1',
    'segment_learning_v1',
    'recent_searches',
  ];

  /// Bulut (Firestore yolculuk + favori) ve cihaz (ayar/öğrenme/son arama)
  /// verisini siler. Onboarding bayrağı korunur (uygulama sıfırdan açılmaz).
  Future<void> deleteAllData() async {
    final uid = _auth.currentUser?.uid;
    if (uid != null) {
      final user = _db.collection('users').doc(uid);
      await _deleteCollection(user.collection('journeys'));
      await _deleteCollection(user.collection('favorites'));
    }
    final prefs = await SharedPreferences.getInstance();
    for (final key in _localKeys) {
      await prefs.remove(key);
    }
  }

  Future<void> _deleteCollection(
    CollectionReference<Map<String, dynamic>> col,
  ) async {
    try {
      final snap = await col.get();
      // Firestore batch en fazla 500 işlem; parça parça sil.
      for (var i = 0; i < snap.docs.length; i += 400) {
        final batch = _db.batch();
        for (final doc in snap.docs.skip(i).take(400)) {
          batch.delete(doc.reference);
        }
        await batch.commit();
      }
    } catch (e) {
      debugPrint('[account] silme hatası: $e');
      rethrow;
    }
  }
}

final accountServiceProvider = Provider(
  (ref) => AccountService(FirebaseFirestore.instance, FirebaseAuth.instance),
);
