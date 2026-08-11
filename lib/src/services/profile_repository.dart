import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// Kullanıcının PROFİL kaydı: ayarlar + son aramalar (users/{uid}).
///
/// NEDEN VAR: favoriler ve yolculuk geçmişi zaten Firestore'da tutuluyordu ama
/// takma ad, alarm sesi, alarm eşiği ve son aramalar yalnızca cihazdaydı.
/// Kullanıcı ikinci telefonundan hesabına girince favorileri geliyor, adı ve
/// ayarları gelmiyordu — hesabın yarısı taşınmış oluyordu.
///
/// YAZMA/OKUMA DENGESİ bilinçli:
///  - Yazma her değişiklikte olur (son yazan kazanır). Ayar değişikliği seyrek,
///    çakışma pratikte yok.
///  - Okuma YALNIZCA girişten hemen sonra yapılır. Her açılışta okumak,
///    çevrimdışıyken yapılan yerel değişikliği eski bulut kopyasıyla
///    ezebilirdi.
///
/// Oturum yoksa sessizce geçer: profil senkronu kritik akış değil, alarm
/// kurmayı hiçbir koşulda engellememeli.
class ProfileRepository {
  const ProfileRepository();

  /// Firebase HENÜZ HAZIR OLMAYABİLİR.
  ///
  /// Kurulum başarısızsa (Play Services yok, ilk açılışta ağ yok, test
  /// ortamı) `FirebaseFirestore.instance` fırlatıyor. Profil senkronu
  /// yardımcı bir özellik; son arama kaydetmeyi ya da ayar değiştirmeyi
  /// çökertmesi kabul edilemez — bu yüzden erişim TEK yerden ve korumalı.
  DocumentReference<Map<String, dynamic>>? _doc([String? uid]) {
    try {
      final id = uid ?? FirebaseAuth.instance.currentUser?.uid;
      if (id == null) return null;
      return FirebaseFirestore.instance.collection('users').doc(id);
    } catch (e) {
      debugPrint('[profile] Firebase hazır değil: $e');
      return null;
    }
  }

  /// Ayarları buluta yaz.
  Future<void> saveSettings(Map<String, dynamic> settings) async {
    final doc = _doc();
    if (doc == null) return;
    try {
      await doc.set({
        'settings': settings,
        'settingsAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      // Çevrimdışı: Firestore kuyruklar, bağlantı gelince akar.
      debugPrint('[profile] ayar yazma hatası: $e');
    }
  }

  /// Son aramaları buluta yaz.
  Future<void> saveRecents(List<Map<String, dynamic>> recents) async {
    final doc = _doc();
    if (doc == null) return;
    try {
      await doc.set({
        'recents': recents,
        'recentsAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('[profile] son arama yazma hatası: $e');
    }
  }

  /// Buluttaki profili oku (giriş sonrası geri yükleme).
  ///
  /// Kayıt yoksa ya da okunamıyorsa `null` döner — çağıran yerel veriyi
  /// olduğu gibi bırakır. Boş bir profille üzerine yazmak, kullanıcının
  /// cihazdaki ayarlarını sebepsiz sıfırlardı.
  Future<CloudProfile?> load([String? uid]) async {
    final doc = _doc(uid);
    if (doc == null) return null;
    try {
      final snap = await doc.get();
      final data = snap.data();
      if (data == null) return null;
      final settings = data['settings'];
      final recents = data['recents'];
      return CloudProfile(
        settings: settings is Map<String, dynamic> ? settings : null,
        recents: recents is List
            ? [
                for (final e in recents)
                  if (e is Map<String, dynamic>) e,
              ]
            : null,
      );
    } catch (e) {
      debugPrint('[profile] okuma hatası: $e');
      return null;
    }
  }
}

/// Buluttan okunan profil — alanlar ayrı ayrı boş olabilir.
class CloudProfile {
  const CloudProfile({this.settings, this.recents});

  final Map<String, dynamic>? settings;
  final List<Map<String, dynamic>>? recents;

  bool get isEmpty => settings == null && (recents == null || recents!.isEmpty);
}
