# StopAlert – Teknik Plan ve Mimari

> **Vaat:** Toplu taşımada ineceğin durağı asla kaçırmazsın — telefon cepte, ekran kapalı, hatta yer altında bile.
>
> **Ürün felsefesi:** Erken uyandırmak affedilir, uyandırmamak affedilmez. Güvenilirlik = ürünün kendisi.

---

## 1. Platform ve Teknoloji

| Katman | Seçim | Neden |
|---|---|---|
| Uygulama | **Flutter (Dart)** | Tek kod tabanıyla iOS + Android, stabil arka plan konum ekosistemi |
| Arka plan konum | `flutter_background_geolocation` (Transistor Software) | Geofencing + hareket algılama + OEM pil katili savaşı hazır çözülmüş (Android lisansı ~349$, tek seferlik) |
| Sensörler | `sensors_plus` (ivmeölçer), platform kanalları ile hücre/Wi-Fi bilgisi | Yeraltı modeli için |
| Durak/hat verisi | **Drift (SQLite, gömülü)** | GTFS verisi cihazda taşınır — alarm motoru ağa asla bağımlı olmaz |
| Kullanıcı verisi | **Firebase Auth + Cloud Firestore (canlı)** | Profil, yolculuk geçmişi, favoriler ve paylaşım gerçek zamanlı bulutta; Firestore'un yerleşik önbelleği sinyal kesildiğinde okuma/yazmayı tamponlar |
| Bildirim/alarm | `flutter_local_notifications` + Android full-screen intent + iOS time-sensitive/critical alerts | Kilitli ekranda tam ekran alarm |
| Reklam | Google AdMob – **yalnızca "İndin" sayfasında** geçiş reklamı | Kritik akışın dışında, ağ yoksa sessizce atlanır |
| Analitik/crash | Firebase Analytics + Crashlytics | "Alarm çalmadı" vakalarını yakalamak için kritik |

## 2. Veri Kaynağı

- **İBB Açık Veri Portalı – GTFS:** Marmaray, metro, tramvay, otobüs, metrobüs durakları; hat–durak sıralamaları; durak arası planlanan seyahat süreleri.
- GTFS verisi build zamanında işlenip uygulamaya **gömülü SQLite** olarak paketlenir → ilk açılışta internet gerekmez.
- Uygulama içi sessiz güncelleme: haftada bir arka planda yeni GTFS paketi kontrolü (Wi-Fi'da indir).
- v2+: diğer şehirler (Ankara, İzmir) aynı GTFS boru hattıyla eklenir.

## 3. Çekirdek: Konum Motoru (yeraltında bile çalışan model)

Motor, dört katmanlı bir **füzyon tahmincisi**dir. Amaç tam konum değil, **±1 durak hassasiyetinde "kaç durak kaldı"** tahminidir (alarm zaten N durak önce çalar).

### Durum makinesi

```
BEKLEMEDE → YOLCULUK_AKTIF → YAKLAŞIYOR (alarm eşiği) → VARDI (İndin ekranı)
                 ↕
           SINYAL_YOK (yeraltı modu — Katman 1+2 devrede)
```

### Katman 1 — GPS / Geofencing (yer üstü, birincil)

- Hedef durak + "hazırlan" durağı etrafına geofence kurulur; işletim sistemi uygulamayı uyandırır → pil dostu.
- GPS noktaları hat geometrisine snap edilir (map-matching): "hattın neresindeyim → kaç durak kaldı".
- GPS doğruluğu düşerse veya sinyal kesilirse motor otomatik **yeraltı moduna** geçer.

### Katman 2 — Zaman Sayacı / Dead Reckoning (yeraltı omurgası)

- Girdi: son bilinen durak (GPS kaybolmadan önceki konum ya da kullanıcının seçtiği biniş durağı) + GTFS segment süreleri.
- Metroda segment süreleri neredeyse sabittir → sayaç tek başına ~%90 doğru.
- Her segment süresine güven aralığı eklenir; belirsizlik biriktikçe alarm eşiği **öne çekilir** (belirsizlik arttıkça daha erken uyandır).

### Katman 3 — İvmeölçer Durak Sayacı (düzeltici)

- Cepteki telefonun ivmeölçerinden "yavaşlama → duruş → hızlanma" deseni = 1 durak geçildi.
- Sinyal beklemesi filtresi: duruş, beklenen segment-zaman penceresine denk gelmiyorsa **durak sayılmaz** (tünel ortası duruşlar elenir).
- Sayaç (K2) ile sensör (K3) Kalman-benzeri basit bir füzyonla birbirini düzeltir:
  - İkisi uyumlu → güven yüksek, tahmin normal.
  - Çelişki → temkinli olan kazanır (daha erken alarm).

### Katman 4 — Hücre/Wi-Fi Parmak İzi Çapası (v2, crowdsourced)

- İstasyonlarda görülen baz istasyonu (Cell ID) ve İBB Wi-Fi BSSID'leri istasyon başına farklıdır.
- Yolculuk sırasında görülen kimlikler anonim olarak kaydedilir → merkezi parmak izi veritabanı zamanla kendini eğitir.
- Eşleşme bulununca sayaç o istasyona **sıfırlanır** (çapa). Bu katman rekabet hendeğidir.

### Emniyet Kemeri (her koşulda)

- Yolculuk başladığı anda, tüm katmanlardan bağımsız bir **mutlak yedek alarm** kurulur: "en geç tahmini varıştan X dk önce her koşulda çal".
- Tüm sensörler ölse bile kullanıcı en kötü 1 durak erken uyanır.
- Alarm tetikleme yolu ağa **hiçbir zaman** bağımlı değildir (reklam, senkron, hiçbir şey alarmı bekletemez).

## 4. Alarm ve Bildirim Sistemi

- **Kademeli uyarı:** (1) "Hazırlan" bildirimi (N+1 durak kala) → (2) Tam alarm (N durak kala): tam ekran + güçlü titreşim + yüksek ses (sessiz modu deler*) → (3) kullanıcı kapatana kadar tekrar.
- Android: `USE_FULL_SCREEN_INTENT` + foreground service (`location` tipi) + alarm sesi `USAGE_ALARM` kanalından (sessiz moddan etkilenmez).
- iOS: Time-Sensitive notifications v1'de; **Critical Alerts entitlement** başvurusu paralel yürütülür (onay gelince sessiz modu delme iOS'ta da açılır).
- **Güvenilirlik ön kontrolü:** Yolculuk başlamadan uygulama cihazı tarar — pil optimizasyonu, bildirim izni, konum izni, ses düzeyi — riskli ayar varsa kullanıcıyı **önceden** uyarır ve düzeltme ekranına götürür (OEM bazlı yönergeler: Xiaomi/Oppo/Samsung).
- Apple Watch / Wear OS: Faz 4.

## 5. Kullanıcı Akışı

```
Ana ekran
 ├─ Favori rotalar (tek dokunuş başlat)         [Faz 3]
 ├─ Yeni yolculuk: Hat seç → Biniş durağı (GPS önerir) → İniş durağı → BAŞLAT
 └─ Profil: geçmiş yolculuklar, istatistikler, ayarlar

Yolculuk ekranı (kilit ekranı bildirimi + canlı aktivite):
 kalan durak · tahmini süre · şu anki/son bilinen istasyon · güven göstergesi

Alarm → kullanıcı kapatır → "İNDİN" ekranı:
 yolculuk özeti · yolculuğu paylaş · "favorilere ekle?"
 · [geçiş reklamı — yalnızca burada, önden yüklenmişse]
```

### Tasarım ilkeleri

- **Emoji kullanılmaz.** Arayüzdeki tüm görsel dil ikon setinden (Material Symbols / özel çizim) ve tipografiden gelir; metinlerde ve butonlarda emoji yer almaz.
- Tek vurgu rengi + nötr zemin; açık/koyu mod birinci sınıf.
- Alarm ve yolculuk ekranları bir kol mesafesinden okunacak büyüklükte (yorgun/uykulu kullanıcı senaryosu).

## 6. Profil, Yolculuk Geçmişi ve Paylaşım

Kullanıcı verisi **canlı olarak Cloud Firestore'da** tutulur (yerel-önce değil, bulut-önce). Firestore'un yerleşik disk önbelleği sayesinde tünelde sinyal kesildiğinde yazımlar kuyruklanır, bağlantı gelince otomatik senkronlanır — alarm motoru ise bu veritabanına hiçbir zaman bağımlı değildir (GTFS gömülü SQLite'ta).

### Firestore veri modeli

```
users/{uid}                  takma_ad, foto_url, olusturma_ts, ayarlar{}
users/{uid}/journeys/{jid}   hat_id, binis_durak, inis_durak, baslangic_ts,
                             bitis_ts, durum, alarm_ts, kullanilan_katmanlar,
                             guven_skoru, paylasildi: bool
users/{uid}/favorites/{fid}  hat_id, binis_durak, inis_durak, etiket, sira
shared_journeys/{sid}        owner_uid, journey_snapshot{}, olusturma_ts,
                             goruntulenme    → herkese açık paylaşım linki
fingerprints/{istasyon_id}   cell_id/bssid sayaçları   [Faz 4, anonim]
```

### Kimlik

- Onboarding'de **anonim Firebase Auth** ile sessizce oturum açılır (sürtünmesiz başlangıç, veri yine de buluta akar).
- Kullanıcı isterse Google/Apple hesabı bağlar → anonim hesap yükseltilir, veri kaybolmaz, cihazlar arası taşınır.

### Yolculuk paylaşımı

- "İndin" ekranında ve geçmiş listesinde **Paylaş**: yolculuk özeti (hat, güzergâh, süre, tarih) `shared_journeys` koleksiyonuna kopyalanır, kısa link üretilir (Firebase Dynamic Links yerine kendi `stopalert.app/j/{sid}` link yapısı).
- Paylaşım görseli: uygulama, yolculuk kartını görsel olarak üretir (harita çizgisi + istatistik) → WhatsApp/Instagram'a hazır. Emoji içermez; marka tipografisi ve ikonlarla.
- İstatistik kartı paylaşımı: "Bu ay 42 yolculuk, 31 saat" tarzı özet kart — viral kanal.
- Gizlilik: paylaşım her zaman kullanıcı eliyle, yolculuk bazında; varsayılan gizli.

### Profil ekranı

- **Geçmiş yolculuklar:** tarih, hat, güzergâh, süre; arama/filtreleme; tek tek paylaş/sil.
- **İstatistikler:** toplam yolculuk, toplam süre, en çok kullanılan hat, "kaç kez uyandırıldın" sayacı.
- **Ayarlar:** alarm tipi (titreşim/ses/tam ekran), kaç durak önce, ses düzeyi, tema.
- KVKK: konum geçmişi kullanıcının kendi profilinde; parmak izi verisi anonim; açık rıza ekranı + "hesabımı ve verilerimi sil" akışı; Firestore güvenlik kuralları uid-bazlı izolasyon.

## 7. Gelir Modeli

- **v1:** tamamen reklamsız ve ücretsiz → önce yorum ortalaması ve güven inşa edilir.
- **v1.1+ Reklam:** Yalnızca **"İndin" sayfasında** geçiş reklamı.
  - Reklam yolculuk *başlarken* arka planda önden yüklenir (cache).
  - Yüklenmemişse (sinyal yok vs.) sessizce atlanır — asla beklenmez, asla kritik akışı kilitlemez.
  - Sıklık sınırı: günde en fazla 2 gösterim.
- **Faz 3+ Premium** (yıllık düşük abonelik veya tek seferlik): reklamsız + favoriler sınırsız + otomatik yolculuk algılama + akıllı saat + çoklu durak.

## 8. Yol Haritası (Fazlar)

| Faz | Kapsam | Çıktı |
|---|---|---|
| **0 – Temel** | Flutter projesi, GTFS boru hattı, gömülü SQLite, hat/durak seçim UI, Firebase projesi + anonim auth | Durak seçilebilen iskelet uygulama |
| **1 – MVP** | Katman 1 (GPS+geofence) + emniyet kemeri alarmı, tam ekran alarm, güvenilirlik ön kontrolü, Firestore'a canlı yolculuk kaydı | Yer üstünde kusursuz çalışan alarm (kapalı beta) |
| **2 – Yeraltı** | Katman 2 (zaman sayacı) + Katman 3 (ivmeölçer), durum makinesi füzyonu, Marmaray/metro saha testleri | "Yer altında bile çalışır" iddiası gerçek (store lansmanı) |
| **3 – Profil & Gelir** | Profil ekranı, istatistikler, favoriler, yolculuk paylaşımı (link + görsel kart), Google/Apple hesap bağlama, İndin sayfası reklamı, premium | Gelir açık, kullanıcı bağlılığı, viral paylaşım kanalı |
| **4 – Hendek** | Katman 4 parmak izi crowdsourcing, Apple Watch/Wear OS, otomatik yolculuk algılama, iOS Critical Alerts | Kopyalanması zor ürün |

## 9. Riskler ve Önlemler

| Risk | Önlem |
|---|---|
| OEM pil katilleri alarmı öldürür | Transistor kütüphanesi + yolculuk öncesi cihaz taraması + OEM bazlı yönerge ekranları |
| Tünelde sayaç kayması | Belirsizlik büyüdükçe alarmı öne çek; ivmeölçer düzeltmesi; emniyet kemeri |
| iOS arka plan kısıtları | Foreground konum izni + Live Activity; Critical Alerts başvurusu erken yapılır |
| GTFS süre verisi eksik/yanlış | Saha ölçümleriyle kalibrasyon; kullanıcı yolculuklarından anonim gerçek süre öğrenimi |
| Reklam SDK'sı alarm akışını yavaşlatır | Reklam yalnızca İndin ekranında, önden yüklü, zaman aşımında atlanır |
| KVKK / konum verisi hassasiyeti | v1 tamamen yerel; buluta yalnızca açık rıza ile; anonimleştirme |

## 10. Başarı Ölçütleri

- **Kuzey yıldızı:** başarıyla uyandırılan yolculuk oranı ≥ %99,5 (alarm çaldı ve kullanıcı doğru durakta indi).
- Store puanı ≥ 4,6 · Crash-free oranı ≥ %99,8 · "alarm çalmadı" destek bildirimi < binde 1.
- Yeraltı tahmin hatası ≤ 1 durak (%95 yolculukta).
