import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../util/platform_check.dart';

/// Hesap durumu + anonim hesabı Google/Apple'a BAĞLAMA (veri kaybı olmadan).
///
/// Uygulama anonim oturumla çalışır; uid tüm kullanıcı verisini taşır. Bağlama,
/// aynı uid'i koruyarak hesabı kalıcılaştırır — cihaz değişince veriler
/// kaybolmaz.
///
/// GOOGLE İÇİN YERLİ AKIŞ kullanılır (`google_sign_in`), `linkWithProvider`
/// değil. Sebep: `linkWithProvider` Android'de tarayıcı tabanlı OAuth açıyor
/// ve kullanıcıya "stopalert-15716.firebaseapp.com" alan adını gösteriyordu —
/// hem tanıdık değil hem de tedirgin edici. Yerli akış sistemin kendi hesap
/// seçicisini açar.
/// Google hesap seçildi ama kimlik jetonu gelmedi.
///
/// Neredeyse her zaman yapılandırma sorunudur: derlemeyi imzalayan anahtarın
/// SHA-1'i Firebase'e kayıtlı değilse Google jetonu üretmiyor. Sessiz geçmek
/// yerine adıyla anılıyor ki arayüz doğru şeyi söyleyebilsin.
class MissingIdTokenException implements Exception {
  const MissingIdTokenException();

  @override
  String toString() => 'MissingIdTokenException';
}

class AuthService {
  AuthService(this._auth);

  final FirebaseAuth _auth;

  /// Google'ın SUNUCU (web) istemci kimliği.
  ///
  /// Android'de kimlik jetonu (idToken) alabilmek için şart; uygulama
  /// istemcisi değil WEB istemcisi verilir. Gizli bir değer değildir —
  /// google-services.json içinde APK'da zaten bulunuyor.
  static const _serverClientId =
      '781116536900-ll7hop274oujgnmk8a3c0n4k2r2c5n34.apps.googleusercontent.com';

  static Future<void>? _googleInit;

  User? get user => _auth.currentUser;

  /// Kullanıcı bir sağlayıcıya bağlı mı (anonim değilse true).
  bool get isLinked => (_auth.currentUser?.providerData ?? const []).isNotEmpty;

  /// Bağlı hesabın görünen kimliği (e-posta / ad); yoksa null.
  String? get accountLabel {
    final u = _auth.currentUser;
    if (u == null) return null;
    for (final p in u.providerData) {
      if ((p.email ?? '').isNotEmpty) return p.email;
      if ((p.displayName ?? '').isNotEmpty) return p.displayName;
    }
    return u.email;
  }

  bool hasProvider(String id) =>
      (_auth.currentUser?.providerData ?? const [])
          .any((p) => p.providerId == id);

  /// `initialize` YALNIZCA BİR KEZ çağrılmalı (paket sözleşmesi).
  static Future<void> _ensureGoogleReady() {
    return _googleInit ??=
        GoogleSignIn.instance.initialize(serverClientId: _serverClientId);
  }

  /// Sistemin hesap seçicisini açar ve Firebase kimlik bilgisi üretir.
  /// Google hesabından Firebase kimlik bilgisi üretir.
  ///
  /// Vazgeçme durumunda `authenticate()` zaten fırlatıyor; bu yüzden buradan
  /// null DÖNMEZ. Kimlik jetonu gelmezse [MissingIdTokenException] atılır.
  Future<AuthCredential> _googleCredential() async {
    await _ensureGoogleReady();
    final account = await GoogleSignIn.instance.authenticate();
    final idToken = account.authentication.idToken;
    // JETON YOKSA SESSİZ KALMA.
    //
    // Eskiden null dönüyordu ve çağıran bunu "kullanıcı vazgeçti" sayıp hiçbir
    // şey yapmıyordu: hesap seçiliyor, ekran kapanıyor, hiçbir mesaj çıkmıyor.
    // Oysa bu gerçek bir yapılandırma hatası — imza parmak izi Firebase'de
    // kayıtlı değilse Google jetonu vermiyor.
    if (idToken == null) throw const MissingIdTokenException();
    return GoogleAuthProvider.credential(idToken: idToken);
  }

  Future<AuthLinkResult> linkGoogle() async {
    if (!isMobileDevice) {
      return AuthLinkResult.error('Bu cihazda desteklenmiyor.');
    }
    try {
      return _linkCredential(await _googleCredential());
    } on MissingIdTokenException {
      return AuthLinkResult.error(
        'Google kimlik doğrulaması tamamlanamadı. Uygulamanın imza parmak izi '
        'Firebase’de kayıtlı olmayabilir; birkaç dakika sonra tekrar dene.',
      );
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) {
        return AuthLinkResult.cancelled();
      }
      return AuthLinkResult.error(
          e.description ?? 'Google girişi başarısız (${e.code.name}).');
    } catch (e) {
      return AuthLinkResult.error('Google girişi başarısız: $e');
    }
  }

  /// Apple yalnızca iOS'ta; orada federatif akış sistemin kendi sayfasını
  /// açtığı için `linkWithProvider` sorun çıkarmıyor.
  Future<AuthLinkResult> linkApple() async {
    final user = _auth.currentUser;
    if (user == null) return AuthLinkResult.error('Oturum bulunamadı.');
    try {
      await user.linkWithProvider(AppleAuthProvider());
      return AuthLinkResult.success();
    } on FirebaseAuthException catch (e) {
      return _mapError(e, null);
    } catch (_) {
      return AuthLinkResult.error('Bağlama başarısız.');
    }
  }

  Future<AuthLinkResult> _linkCredential(AuthCredential cred) async {
    final user = _auth.currentUser;
    if (user == null) return AuthLinkResult.error('Oturum bulunamadı.');
    try {
      await user.linkWithCredential(cred);
      return AuthLinkResult.success();
    } on FirebaseAuthException catch (e) {
      return _mapError(e, cred);
    }
  }

  AuthLinkResult _mapError(FirebaseAuthException e, AuthCredential? cred) {
    switch (e.code) {
      // Bu hesap BAŞKA bir kayda bağlı. Bağlamak mümkün değil ama GİRİŞ
      // yapmak mümkün — çağıran tarafa kimlik bilgisini geri veriyoruz ki
      // kullanıcıya "o hesaba gir" diyebilsin.
      case 'credential-already-in-use':
      case 'email-already-in-use':
      case 'account-exists-with-different-credential':
        return AuthLinkResult.alreadyInUse(cred);
      case 'provider-already-linked':
        return AuthLinkResult.error('Bu sağlayıcı zaten bağlı.');
      case 'canceled':
      case 'web-context-canceled':
      case 'user-canceled':
        return AuthLinkResult.cancelled();
      default:
        return AuthLinkResult.error(e.message ?? 'Bağlama başarısız.');
    }
  }

  /// VAR OLAN hesaba giriş yap (bağlama değil).
  ///
  /// İkinci bir cihazda kullanıldığında doğru işlem budur: o cihazdaki anonim
  /// oturum terk edilir ve kullanıcı kendi hesabına döner. Anonim oturumdaki
  /// veriler TAŞINMAZ — onlar başka bir uid'e ait; kullanıcıya bu açıkça
  /// söylenmeli.
  Future<AuthLinkResult> signInWithCredential(AuthCredential cred) async {
    try {
      await _auth.signInWithCredential(cred);
      return AuthLinkResult.success();
    } on FirebaseAuthException catch (e) {
      return AuthLinkResult.error(e.message ?? 'Giriş başarısız.');
    }
  }

  /// Google hesabıyla doğrudan GİRİŞ (bağlama denemeden).
  Future<AuthLinkResult> signInGoogle() async {
    if (!isMobileDevice) {
      return AuthLinkResult.error('Bu cihazda desteklenmiyor.');
    }
    try {
      return signInWithCredential(await _googleCredential());
    } on MissingIdTokenException {
      return AuthLinkResult.error(
        'Google kimlik doğrulaması tamamlanamadı. Uygulamanın imza parmak izi '
        'Firebase’de kayıtlı olmayabilir; birkaç dakika sonra tekrar dene.',
      );
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) {
        return AuthLinkResult.cancelled();
      }
      return AuthLinkResult.error(
          e.description ?? 'Google girişi başarısız (${e.code.name}).');
    } catch (e) {
      return AuthLinkResult.error('Google girişi başarısız: $e');
    }
  }

  /// Çıkış: hesabı çöz ve yeniden anonim oturuma dön (uygulama anonim çalışır;
  /// bu cihazdaki veri erişimi biter, bağlı hesaba tekrar girerek dönülür).
  Future<void> signOutToAnonymous() async {
    try {
      await GoogleSignIn.instance.signOut();
    } catch (_) {
      // Google oturumu yoksa/başlatılmadıysa önemsiz.
    }
    await _auth.signOut();
    await _auth.signInAnonymously();
  }
}

class AuthLinkResult {
  const AuthLinkResult._(this.ok, this.cancelled, this.error, this.credential);

  final bool ok;
  final bool cancelled;
  final String? error;

  /// "Zaten kullanılıyor" durumunda GİRİŞ için saklanan kimlik bilgisi.
  final AuthCredential? credential;

  /// Hesap başka bir kayda bağlı — bağlanamaz ama giriş yapılabilir.
  bool get alreadyLinkedElsewhere => credential != null && !ok;

  factory AuthLinkResult.success() =>
      const AuthLinkResult._(true, false, null, null);
  factory AuthLinkResult.cancelled() =>
      const AuthLinkResult._(false, true, null, null);
  factory AuthLinkResult.error(String m) =>
      AuthLinkResult._(false, false, m, null);
  factory AuthLinkResult.alreadyInUse(AuthCredential? cred) => AuthLinkResult._(
        false,
        false,
        'Bu hesap zaten başka bir StopAlert kaydına bağlı.',
        cred,
      );
}

final authServiceProvider = Provider((ref) => AuthService(FirebaseAuth.instance));

final userChangesProvider =
    StreamProvider<User?>((ref) => FirebaseAuth.instance.userChanges());
