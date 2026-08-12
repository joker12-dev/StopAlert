# StopAlert – Yapılacaklar Listesi

> Fazların detayı için: [PLAN.md](PLAN.md)
> Son gözden geçirme: 2026-08-12 (mağaza öncesi denetim)

## 🚫 MAĞAZAYA ÇIKMADAN ÖNCE ZORUNLU

Bunlar bitmeden yayına çıkılamaz. Sıra, engelleyicilikten kolaya doğru.

- [ ] **Release imzalama anahtarı.** `android/app/build.gradle.kts` hâlâ DEBUG
      anahtarıyla imzalıyor (satır 39). Play Store debug anahtarıyla imzalı APK
      kabul etmez. Upload keystore üret, `android/key.properties` oluştur
      (`.gitignore`'a ekle), `signingConfigs.release` tanımla.
- [x] ~~Sürüm numarası~~ → `1.0.0+1`
- [x] ~~Gizlilik Politikası ve Kullanım Koşulları METİNLERİ~~ — yayında:
      https://stopalert-15716.web.app/gizlilik.html
      https://stopalert-15716.web.app/kullanim-kosullari.html
      Rıza ekranındaki onay satırından ve Ayarlar → Gizlilik'ten bağlı.
- [ ] **Play Console Veri Güvenliği formu.** Toplanan veriler: konum
      (yaklaşık+kesin, arka plan), hesap kimliği (Google/Apple), yolculuk
      geçmişi, reklam kimliği. Formun kodla tutarlı doldurulması gerekiyor.
- [ ] **Arka plan konum gerekçesi videosu (Play).** "Her zaman konum" izni
      isteyen uygulamalar için Google, özelliği gösteren bir video ve yazılı
      gerekçe istiyor.
- [ ] **Mağaza sayfası:** ekran görüntüleri (telefon + 7"/10" tablet), 512px
      ikon, 1024x500 öne çıkan görsel, kısa/uzun açıklama, ASO anahtar
      kelimeleri ("durak alarmı", "Marmaray alarm", "otobüs alarmı").
- [ ] **Saha testi — ALARM GÜVENİLİRLİĞİ.** Uygulamanın tek vaadi bu ve hiç
      saha doğrulaması yapılmadı: Marmaray tünel geçişi (Ayrılık Çeşmesi–
      Kazlıçeşme), tam yeraltı metro hattı, ekran kapalı + cepte senaryosu.
- [ ] **Pil tüketimi ölçümü** (hedef: 1 saatlik yolculukta < %4).

## ⚠️ ÇIKMADAN ÖNCE YAPILMASI ÇOK İYİ OLUR

- [x] ~~Eksik alarm sesi dosyaları~~ — `Klasik Zil` gerçek dosyasına kavuştu;
      dosyasız `Dalga`/`Sinyal` kaldırıldı; yerine CİHAZIN kendi sesleri
      geldi (`Telefon Alarmı`, `Telefon Zili` — sistem URI'si, lisans yok).
- [ ] **Crashlytics + Analytics.** Kurulu değil. Yayından sonra "alarm çalmadı"
      şikâyetini veri olmadan çözmek imkânsız.
- [ ] **Yolculuk hatırlatma bildirimine dokununca** alarm kurulumu hazır
      açılsın (şu an yalnızca uygulamayı açıyor).
- [ ] **iOS derlemesi ve TestFlight.** `ios/IOS_BUILD.md` hazır;
      GoogleService-Info.plist + imzalama kullanıcıda.
- [ ] Kapalı beta (Play Internal Testing).

## ✅ BİTMİŞ (özet)

- **Veri hattı:** İETT GTFS + resmi web servisleri → SQLite paketleri;
  Firebase Hosting'de sürümlü yayın, sha256 doğrulamalı indirme.
  İstanbul (2621 hat / 13.813 durak / 23.866 kalkış) ve Kocaeli.
- **Raylı + deniz:** metro, Marmaray, tramvay, füniküler, teleferik, vapur
  İstanbul paketinde. Marmaray tarifesi TCDD'nin resmi çizelgesinden
  (gece seferleri dâhil). Metro/Marmaray konumu tarifeden üretiliyor.
- **Alarm motoru:** arka plan takibi (lisanssız: foreground_task + geolocator),
  yeraltı modu (ölü hesap + ivmeölçer füzyonu), belirsizlik modeli,
  tam ekran alarm, erteleme, emniyet kemeri zamanlayıcısı.
- **Öğrenme:** segment süreleri cihazda öğreniliyor; anonim bulut katkısı
  rızaya bağlı (varsayılan kapalı).
- **Hesap:** anonim → Google/Apple bağlama, ikinci cihazdan giriş, profil
  (ayarlar + son aramalar) ve favoriler/geçmiş bulutta.
- **Gelir:** AdMob geçiş + yerel (native) reklamlar gerçek kimliklerle.
  Menü banner'ı bilinçli olarak kaldırıldı.
- **KVKK:** rıza ekranı (tanıtımdan sonra, izinden önce), verilerimi sil akışı.
- **Test:** 179 test geçiyor (motor, veri katmanı, tarife, ekran akışları).

## ⏭️ MAĞAZA SONRASINA BIRAKILDI

- [ ] Premium abonelik (reklamsız + sınırsız favori) — RevenueCat
- [ ] Yolculuk paylaşımı (`shared_journeys` + herkese açık link)
- [ ] Hücre/Wi-Fi parmak izi çapası (Faz 4)
- [ ] Apple Watch / Wear OS
- [ ] Otomatik yolculuk algılama
- [ ] Yeni şehirler: Ankara, İzmir
- [ ] CI/CD (GitHub Actions)
