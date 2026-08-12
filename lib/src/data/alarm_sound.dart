/// Alarm sesi seçenekleri.
///
/// ÖNEMLİ: seçim eskiden hiçbir yere BAĞLI DEĞİLDİ — dört ad da bildirimde
/// aynı `stopalert_alarm` kaynağını çalıyordu, yani ayar tamamen görseldi.
/// Burada ad → kaynak eşlemesi kuruldu.
///
/// NEDEN "SES PAKETİ" İNDİRMİYORUZ: bir alarm uygulaması için en iyi ses
/// zaten telefonun kendi alarm sesidir — kullanıcı onu tanıyor, uyandırıcı
/// olduğu denenmiş, lisansı yok ve APK'yı büyütmüyor. Bu yüzden listede
/// CİHAZIN kendi alarm/zil sesleri var; paketle gelen sesler yalnızca marka
/// sesi ve tek bir dijital çalar saat.
///
/// YENİ PAKET SESİ EKLEMEK: aynı dosyayı İKİ yere koy —
///   `android/app/src/main/res/raw/<resource>.<ext>`  (bildirim çalar)
///   `assets/sounds/<resource>.<ext>`                 (uygulama içi önizleme)
/// sonra buraya bir [AlarmSound] satırı ekle.
library;

/// Sesin nereden geldiği.
enum AlarmSoundSource {
  /// Uygulamayla gelen dosya (res/raw + assets).
  bundled,

  /// Cihazın sistem sesi (content:// URI). Dosya taşınmaz.
  system,
}

class AlarmSound {
  const AlarmSound(
    this.label,
    this.resource, {
    this.extension = 'wav',
    this.source = AlarmSoundSource.bundled,
    this.systemUri = '',
  });

  /// Cihazın kendi sesini kullanan seçenek.
  const AlarmSound.system(this.label, this.systemUri)
      : resource = fallback,
        extension = 'wav',
        source = AlarmSoundSource.system;

  /// Kullanıcıya görünen ad.
  final String label;

  /// Android raw kaynağı / asset adı (uzantısız).
  final String resource;

  /// Dosya uzantısı — raw kaynağında uzantı yok ama asset yolunda gerekli.
  final String extension;

  final AlarmSoundSource source;

  /// Sistem sesinin içerik adresi (yalnızca [AlarmSoundSource.system]).
  ///
  /// Android bu adresleri sabit tutuyor:
  ///   `content://settings/system/alarm_alert`        → varsayılan ALARM
  ///   `content://settings/system/ringtone`           → varsayılan ZİL
  ///   `content://settings/system/notification_sound` → bildirim sesi
  final String systemUri;

  /// Uygulama içi önizlemenin çalacağı yol.
  String get assetPath => 'sounds/$resource.$extension';

  /// Kendi dosyası var mı (arayüz "varsayılan çalar" notunu buna bakıyor).
  ///
  /// Sistem sesleri de gerçek bir ses çalıyor; not YALNIZCA dosyası olmayan
  /// yer tutucu seçenekler için anlamlıydı ve artık öyle bir seçenek yok.
  bool get hasOwnFile => true;

  static const fallback = 'stopalert_alarm';

  /// Sırayı bozma: kayıtlı ayarlar ADA göre çözülüyor.
  static const all = <AlarmSound>[
    AlarmSound('Radar', fallback),
    AlarmSound('Klasik Zil', 'klasik_zil', extension: 'mp3'),
    // CİHAZIN KENDİ SESLERİ: kullanıcının telefonunda ne seçiliyse o çalar.
    AlarmSound.system('Telefon Alarmı', 'content://settings/system/alarm_alert'),
    AlarmSound.system('Telefon Zili', 'content://settings/system/ringtone'),
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
