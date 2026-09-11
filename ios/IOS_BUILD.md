# StopAlert — iOS Build Rehberi (Mac)

> **Kod tarafı hazır (Faz 0 · 2026-09):** iOS'ta yerel bildirimler (Darwin
> ayarları), alarm/hatırlatma yolları ve ARKA PLAN konumu artık açık —
> ekran kapalıyken de alarm çalar. `ios/Podfile` hazır (izin makroları +
> platform 15.0). Kalanların hepsi Apple/Mac tarafı; aşağıdaki adımlar.

Windows'ta iOS derlenemez; **Mac + Xcode** şart. Aşağıdaki adımlar bu projeye
özeldir (Firebase, AdMob, arka plan konum, Live Activity, kritik alarm).

## 0) Mac hazırlığı (bir kez)
1. **Xcode**'u App Store'dan kur, aç, "Command Line Tools"u kabul et.
2. Terminal:
   ```bash
   sudo gem install cocoapods        # veya: brew install cocoapods
   git clone <repo>  # ya da projeyi Windows'tan kopyala
   ```
3. **Flutter SDK**'yı Mac'e kur (`git clone flutter`, PATH'e ekle), doğrula:
   ```bash
   flutter doctor      # Xcode + CocoaPods satırları ✓ olmalı
   ```

## 1) Apple hesabı / imzalama
- **Ücretsiz Apple ID:** yalnızca KENDİ cihazında test (7 günde bir yeniden
  imzalama gerekir). Live Activity/kritik alarm/TestFlight ÇALIŞMAZ.
- **Apple Developer Program ($99/yıl):** App Store, TestFlight, push, kritik
  alarm için ŞART. Kaydol: developer.apple.com/programs

## 2) Firebase iOS yapılandırması (ŞART — yoksa açılışta çöker)
1. Firebase Console → proje **stopalert-15716** → ⚙️ → "Uygulama ekle" → iOS.
2. Bundle ID: **`com.originstudios.stopalert`** (Xcode'daki ile birebir aynı).
3. `GoogleService-Info.plist` indir → Xcode'da **Runner** hedefine sürükle
   (Copy items if needed ✓, target: Runner). Dosya `ios/Runner/` içine gitmeli.
4. (Zaten `firebase.json`'da iOS appId kayıtlı; sadece plist eksikti.)
5. **APNs anahtarı (push için ŞART):** `firebase_messaging` eklendi; iOS'a
   bildirim gelmesi için Apple Developer → **Keys → +** → *Apple Push
   Notifications service (APNs)* → indir (`AuthKey_XXXX.p8`, bir kez iner).
   Firebase Console → Proje ayarları → **Cloud Messaging** → iOS →
   *APNs Authentication Key*: `.p8` + **Key ID** + **Team ID** yükle.

## 3) Bağımlılıklar
```bash
cd stopalert
flutter pub get
cd ios && pod install && cd ..
```
Pod hatası olursa: `cd ios && pod repo update && pod install`.
> `ios/Podfile` repoda HAZIR (izin makroları + `platform :ios, '15.0'`).
> Elle düzenlemene gerek yok; `pod install` yeter.

## 4) Xcode imzalama + yetenekler (Capabilities)
`open ios/Runner.xcworkspace` (`.xcodeproj` DEĞİL, **.xcworkspace**).
Runner hedefi → **Signing & Capabilities**:
- **Team**: Apple ID/Developer hesabını seç. "Automatically manage signing" ✓.
- **+ Capability** ile ekle:
  - **Background Modes** → Location updates, Background fetch, Background
    processing, Remote notifications işaretle (Info.plist zaten hazır).
  - **Push Notifications** (FCM/kritik alarm kullanacaksan).
  - **Sign in with Apple** — ZORUNLU: uygulamada Google ile giriş var; Apple
    başka sosyal giriş sunan uygulamada Apple girişini de şart koşuyor, yoksa
    inceleme reddeder. App ID'de de bu yetenek işaretli olmalı.
  - **App Groups** → Live Activity için `group.com.originstudios.stopalert.liveactivity`.
  - **Critical Alerts**: Apple'dan özel izin gerekir → form:
    developer.apple.com/contact/request/notifications-critical-alerts-entitlement
    (onaylanınca entitlement eklenir; sessiz/rahatsız-etme modunu deler).

## 5) Live Activity (kilit ekranı kartı) — opsiyonel ama hazır
Swift kodu `ios/StopAlertWidget/StopAlertLiveActivity.swift` mevcut ama Xcode'da
**Widget Extension hedefi** oluşturman gerekir. Adımlar: `ios/LIVE_ACTIVITY_SETUP.md`.
Kısaca: File → New → Target → Widget Extension → "StopAlretWidget"; App Group
`group.com.originstudios.stopalert.liveactivity`'yi hem Runner'a hem widget'a ekle.

## 6) Çalıştır / derle
```bash
# Cihazı USB ile bağla, güven (Trust) de:
flutter devices
flutter run --release          # cihazda dene (ilk sefer Xcode'da imzalama onayı)

# App Store / TestFlight için imzalı paket:
flutter build ipa              # build/ios/ipa/*.ipa
# sonra: Xcode → Organizer → Distribute App, ya da:
xcrun altool / Transporter ile App Store Connect'e yükle
```
Cihazda "Untrusted Developer" çıkarsa: iPhone → Ayarlar → Genel → VPN ve Cihaz
Yönetimi → geliştiriciye güven.

## 6.5) İzinler (ÖNEMLİ — bildirim izni sorulmuyorsa)
iOS'ta zorunlu izinler ekranı artık gösterilir (bildirim + konum + "Her Zaman").
Ancak `permission_handler` iOS'ta izinleri **derleme-zamanı makrolarıyla** açar.
Bildirim izni sorulmuyorsa `ios/Podfile`'a şunu ekle (post_install içine):
```ruby
post_install do |installer|
  installer.pods_project.targets.each do |target|
    flutter_additional_ios_build_settings(target)
    target.build_configurations.each do |config|
      config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] ||= ['$(inherited)']
      config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] += [
        'PERMISSION_LOCATION=1',
        'PERMISSION_NOTIFICATIONS=1',
      ]
    end
  end
end
```
Sonra: `cd ios && pod install`. (Podfile'ı hiç özelleştirmediysen tüm izinler
zaten derlenir; bu blok yalnızca bildirim sorulmuyorsa gerekir.)

## 7) Bu projeye özel notlar
- **AdMob iOS**: `Info.plist`'te `GADApplicationIdentifier` zaten iOS App ID ile
  dolu. AdMob konsolunda iOS uygulaması + reklam birimleri tanımlı olmalı.
- **Arka plan konum**: `Info.plist`'e konum + `UIBackgroundModes` eklendi. iOS
  kullanıcıdan "Her zaman izin ver" ister; onay şart, yoksa arka plan takip yok.
- **google_mobile_ads / firebase**: min iOS 15+ gerekir. Xcode'da deployment
  target'ı 15.0'a çek (Podfile `platform :ios, '15.0'`).
- **Bildirim sesi (alarm)**: Android'de özel ses var; iOS'ta kritik alarm izni
  alınana kadar normal bildirim sesi/varsayılan çalar.

## Özet checklist
- [ ] Xcode + CocoaPods + Flutter (`flutter doctor`)
- [ ] `GoogleService-Info.plist` Runner'a eklendi
- [ ] `flutter pub get && pod install`
- [ ] Xcode'da Team seçildi + Background Modes/Push capability
- [ ] APNs `.p8` anahtarı Firebase Cloud Messaging'e yüklendi
- [ ] Sign in with Apple yeteneği açık (Google girişi olduğu için zorunlu)
- [ ] (opsiyonel) Live Activity widget target'ı
- [ ] `flutter run --release` cihazda çalıştı
