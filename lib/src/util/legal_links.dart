import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Gizlilik ve kullanım metinlerinin YAYINDAKİ adresleri.
///
/// Metinler uygulamanın içine gömülü değil, web'de duruyor. İki sebebi var:
/// mağazalar (Play Veri Güvenliği, App Store Privacy) herkese açık bir URL
/// istiyor; ve metin değiştiğinde yeni bir uygulama sürümü yayınlamak
/// gerekmiyor.
abstract final class LegalLinks {
  static const privacy = 'https://stopalert-15716.web.app/gizlilik.html';
  static const terms =
      'https://stopalert-15716.web.app/kullanim-kosullari.html';

  /// Adresi cihazın tarayıcısında açar.
  ///
  /// Açılamazsa SESSİZ kalmaz: kullanıcı bir şeye dokundu ve hiçbir şey
  /// olmaması bozuk bir uygulama izlenimi verir.
  static Future<void> open(BuildContext context, String url) async {
    try {
      final ok = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
      if (ok || !context.mounted) return;
    } catch (_) {
      if (!context.mounted) return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('Açılamadı: $url')));
  }
}
