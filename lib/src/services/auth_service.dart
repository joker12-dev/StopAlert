import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Hesap durumu + anonim hesabı Google/Apple'a BAĞLAMA (veri kaybı olmadan).
///
/// Uygulama anonim oturumla çalışır; uid tüm kullanıcı verisini taşır. Bağlama,
/// aynı uid'i koruyarak (`linkWithProvider`) hesabı kalıcılaştırır — cihaz
/// değişince veriler kaybolmaz. Ekstra SDK gerekmez; firebase_auth'un native
/// federatif akışı Google ve Apple'ı yürütür.
class AuthService {
  AuthService(this._auth);

  final FirebaseAuth _auth;

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

  Future<AuthLinkResult> linkGoogle() => _link(GoogleAuthProvider());
  Future<AuthLinkResult> linkApple() => _link(AppleAuthProvider());

  Future<AuthLinkResult> _link(AuthProvider provider) async {
    final user = _auth.currentUser;
    if (user == null) return AuthLinkResult.error('Oturum bulunamadı.');
    try {
      await user.linkWithProvider(provider);
      return AuthLinkResult.success();
    } on FirebaseAuthException catch (e) {
      switch (e.code) {
        case 'credential-already-in-use':
        case 'email-already-in-use':
          return AuthLinkResult.error(
              'Bu hesap zaten başka bir kayıtta kullanılıyor.');
        case 'provider-already-linked':
          return AuthLinkResult.error('Bu sağlayıcı zaten bağlı.');
        case 'canceled':
        case 'web-context-canceled':
        case 'user-canceled':
          return AuthLinkResult.cancelled();
        default:
          return AuthLinkResult.error(e.message ?? 'Bağlama başarısız.');
      }
    } catch (_) {
      return AuthLinkResult.error('Bağlama başarısız.');
    }
  }

  /// Çıkış: hesabı çöz ve yeniden anonim oturuma dön (uygulama anonim çalışır;
  /// bu cihazdaki veri erişimi biter, bağlı hesaba tekrar girerek dönülür).
  Future<void> signOutToAnonymous() async {
    await _auth.signOut();
    await _auth.signInAnonymously();
  }
}

/// Bağlama sonucu.
class AuthLinkResult {
  const AuthLinkResult._(this.ok, this.cancelled, this.error);

  final bool ok;
  final bool cancelled;
  final String? error;

  factory AuthLinkResult.success() => const AuthLinkResult._(true, false, null);
  factory AuthLinkResult.cancelled() =>
      const AuthLinkResult._(false, true, null);
  factory AuthLinkResult.error(String m) => AuthLinkResult._(false, false, m);
}

final authServiceProvider = Provider((ref) => AuthService(FirebaseAuth.instance));

/// Kullanıcı değişimleri (bağla/çöz/token) — UI bunu izleyip tazelenir.
final userChangesProvider =
    StreamProvider<User?>((ref) => FirebaseAuth.instance.userChanges());
