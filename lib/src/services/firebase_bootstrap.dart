import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import '../../firebase_options.dart';

/// Firebase'i başlatır ve anonim oturum açar.
///
/// KRİTİK: `Firebase.initializeApp` runApp'ten ÖNCE beklenerek (await)
/// çağrılmalı; yoksa okuma sağlayıcıları (favoriler/geçmiş) ilk karede
/// `FirebaseAuth.instance`'ı Firebase hazır olmadan çağırıp kalıcı hata
/// durumuna düşer ve bir daha okumaz. Bu yüzden bu fonksiyon initializeApp'i
/// bekler; ağ gerektiren anonim giriş ise bloklamadan (arka planda) yapılır —
/// authStateChanges uid'i sağlayıcılara iletir.
///
/// Onboarding sürtünmesiz olsun diye kullanıcıdan giriş istenmez; anonim
/// hesap açılır ve tüm kullanıcı verisi bu uid altında Firestore'a yazılır.
/// Faz 3'te bu hesap Google/Apple girişine veri kaybı olmadan yükseltilecek.
Future<void> bootstrapFirebase() async {
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (e) {
    debugPrint('Firebase başlatılamadı (offline devam ediliyor): $e');
    return;
  }

  final auth = FirebaseAuth.instance;
  if (auth.currentUser != null) {
    debugPrint(
        'Firebase hazır (mevcut oturum) — uid: ${auth.currentUser!.uid}');
    return;
  }
  // Anonim giriş ağa bağlıdır; UI'ı bekletmeden başlat.
  auth.signInAnonymously().then((cred) {
    debugPrint('Firebase hazır — uid: ${cred.user?.uid}');
  }).catchError((Object e) {
    debugPrint('Anonim giriş hatası: $e');
  });
}
