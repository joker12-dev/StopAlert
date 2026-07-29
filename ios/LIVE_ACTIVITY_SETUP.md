# iOS Live Activity — Kurulum (Mac + Xcode gerekir)

StopAlert'in canlı yolculuk kartını (kilit ekranı + Dynamic Island) çalıştırmak
için, Xcode'da **bir kez** bir Widget Extension target'ı eklemen gerekir.
Dart tarafı (başlat/güncelle/bitir) hazır: `lib/src/services/live_activity_service.dart`.

Gereksinim: **iOS 16.1+**, Xcode 15+, gerçek cihaz (Dynamic Island için iPhone 14 Pro+).

## 1) Widget Extension target ekle
1. `ios/Runner.xcworkspace`'i Xcode'da aç.
2. **File → New → Target… → Widget Extension** seç.
3. İsim: **StopAlertWidget**. Dil: Swift.
   - "Include Configuration Intent" → **KAPALI**.
   - "Include Live Activity" seçeneği çıkarsa **AÇIK**.
4. "Activate scheme?" → Activate.

## 2) Bizim widget kodunu koy
1. Xcode'un otomatik ürettiği `StopAlertWidget.swift` / bundle dosyalarını **sil**
   (ya da içeriğini değiştir) — `@main` yalnızca bizim bundle'da kalmalı.
2. `ios/StopAlertWidget/StopAlertLiveActivity.swift` dosyasını projeye ekle:
   **Add Files to "Runner"…** → dosyayı seç → **Target: StopAlertWidget** işaretli
   olsun (Runner değil).
3. Widget target'ının **Deployment Target**'ını **iOS 16.1**'e çek.

## 3) App Group (paylaşımlı veri)
Runner ile widget aynı App Group'u paylaşmalı:
1. **Runner** target → Signing & Capabilities → **+ Capability → App Groups** →
   `group.com.originstudios.stopalert.liveactivity` ekle.
2. **StopAlertWidget** target → aynı App Group'u ekle.

> Bu id, `LiveActivityService.appGroupId` ve `StopAlertLiveActivity.swift` içindeki
> `sharedDefault` suiteName ile BİREBİR aynı olmalı.

## 4) Info.plist
`ios/Runner/Info.plist` içinde zaten var:
```
<key>NSSupportsLiveActivities</key><true/>
```

## 5) Derle & test
- Gerçek cihazda `flutter run` (release/debug).
- Bir yolculuk başlat → kilit ekranında/Dynamic Island'da kart çıkmalı; kalan
  durak, sonraki durak ve ETA yolculuk ilerledikçe güncellenir; varış/iptalde kapanır.
- İlk kullanımda iOS "Canlı Etkinliklere izin ver?" diye sorabilir.

## Notlar / sınırlar
- **Uygulama tamamen askıya alınırsa** güncelleme durur (kart son durumu gösterir).
  Her zaman taze güncelleme için ileride **APNs push** tabanlı güncelleme eklenir
  (`apns-push-type: liveactivity`). MVP'de uygulama ön planda/aktifken güncellenir.
- Android'de karşılığı, ön plan servisinin kalıcı bildirimidir (zaten var).
- Tasarım tamamen SwiftUI — renk, halka, metinler `StopAlertLiveActivity.swift`
  içinden serbestçe değiştirilebilir.
