/// Alarm sesi seçenekleri.
///
/// ÖNEMLİ: seçim eskiden hiçbir yere BAĞLI DEĞİLDİ — dört ad da bildirimde
/// aynı `stopalert_alarm` kaynağını çalıyordu, yani ayar tamamen görseldi.
/// Burada ad → dosya eşlemesi kuruldu; henüz dosyası olmayan seçenekler
/// varsayılana düşüyor ve bu, [hasOwnFile] ile görünür kılınıyor.
///
/// YENİ SES EKLEMEK: aynı adlı dosyayı İKİ yere koy —
///   `android/app/src/main/res/raw/<resource>.wav`   (bildirim çalar)
///   `assets/sounds/<resource>.wav`                  (uygulama içi önizleme)
/// sonra buradaki [resource] alanını doldur.
library;

class AlarmSound {
  const AlarmSound(this.label, this.resource, {this.hasOwnFile = true});

  /// Kullanıcıya görünen ad.
  final String label;

  /// Android raw kaynağı / asset adı (uzantısız).
  final String resource;

  /// Kendi dosyası var mı? false ise varsayılan ses çalar.
  final bool hasOwnFile;

  String get assetPath => 'sounds/$resource.wav';

  static const fallback = 'stopalert_alarm';

  /// Sırayı bozma: kayıtlı ayarlar ADA göre çözülüyor.
  static const all = <AlarmSound>[
    AlarmSound('Radar', fallback),
    // Aşağıdakilerin dosyası HENÜZ YOK; varsayılana düşüyorlar.
    AlarmSound('Klasik Zil', fallback, hasOwnFile: false),
    AlarmSound('Dalga', fallback, hasOwnFile: false),
    AlarmSound('Sinyal', fallback, hasOwnFile: false),
  ];

  static AlarmSound byLabel(String? label) {
    for (final s in all) {
      if (s.label == label) return s;
    }
    return all.first;
  }

  /// Kendi dosyası olmayan seçenek var mı (ayarlar ekranında not gösterilir).
  static bool get anyMissing => all.any((s) => !s.hasOwnFile);
}
