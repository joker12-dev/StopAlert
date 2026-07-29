import 'package:flutter/services.dart';

/// Dokunsal (haptik) geri bildirim yardımcı katmanı.
///
/// - [enabled] kullanıcı ayarındaki "Titreşim" tercihiyle senkron tutulur
///   (bkz. settings sağlayıcısı); kapalıysa hiçbir titreşim gönderilmez.
/// - Platform kanalı olmayan ortamlarda (test/masaüstü) sessizce yutulur.
abstract final class Haptics {
  /// Kullanıcı "Titreşim" ayarı. Ayar sağlayıcısı yüklendiğinde güncellenir.
  static bool enabled = true;

  /// Seçim/mod değişimi gibi hafif dokunuşlar (segment seçici, mod seçimi).
  static void selection() => _run(HapticFeedback.selectionClick);

  /// Küçük onay dokunuşu (buton, kaydırma başlangıcı).
  static void light() => _run(HapticFeedback.lightImpact);

  /// Orta şiddet — alarm kurma gibi anlamlı bir aksiyon tamamlandığında.
  static void medium() => _run(HapticFeedback.mediumImpact);

  /// Güçlü darbe — kaydırarak durdurma tamamlandığında.
  static void heavy() => _run(HapticFeedback.heavyImpact);

  static void _run(Future<void> Function() action) {
    if (!enabled) return;
    try {
      action();
    } catch (_) {
      // Haptik desteklenmeyen platform/ortam: yut.
    }
  }
}
