# StopAlert – Yapılacaklar Listesi

> Fazların detayı için: [PLAN.md](PLAN.md)

## Faz 0 – Temel Kurulum
- [ ] Flutter projesini oluştur (iOS + Android hedefli), paket adı/bundle id belirle
- [ ] Proje mimarisini kur (katmanlı: `data / domain / ui`, state management: Riverpod)
- [ ] İBB Açık Veri Portalı'ndan GTFS verisini indir ve incele (Marmaray, metro, tramvay, otobüs)
- [ ] GTFS → SQLite dönüştürme scripti yaz (hatlar, duraklar, durak sıraları, segment süreleri)
- [ ] Gömülü SQLite paketini uygulamaya entegre et (Drift)
- [ ] Hat seçim ekranı (arama + tür filtresi: Marmaray/metro/tramvay/otobüs)
- [ ] Durak seçim ekranı (biniş + iniş; GPS'ten en yakın durağı öner)
- [ ] Temel tema/tasarım sistemi (açık/koyu mod; ikon+tipografi tabanlı, arayüzde emoji kullanılmaz)
- [ ] Firebase projesi kur (Auth + Firestore) ve anonim oturum açma akışı

## Faz 1 – MVP: Yer Üstü Alarmı
- [x] Arka plan konum takibi (LİSANSSIZ): `flutter_foreground_task` + `geolocator` ön plan servisi — `flutter_background_geolocation` lisansı gerekmedi
- [ ] Konum izin akışı (foreground → background izin merdiveni, ret senaryoları)
- [ ] Geofence kurulumu: hedef durak + "hazırlan" durağı çemberleri
- [ ] GPS → hat geometrisine snap (map-matching) ve "kaç durak kaldı" hesabı
- [ ] Yolculuk durum makinesi (BEKLEMEDE / AKTIF / YAKLAŞIYOR / VARDI)
- [ ] Emniyet kemeri: ağdan bağımsız mutlak yedek alarm zamanlayıcısı
- [ ] Tam ekran alarm (Android: full-screen intent + USAGE_ALARM ses kanalı + titreşim deseni)
- [ ] iOS alarm: time-sensitive bildirim + kritik akış; Critical Alerts entitlement başvurusunu gönder
- [ ] Yolculuk ekranı: kalan durak, tahmini süre, son bilinen istasyon, güven göstergesi
- [ ] Kilit ekranı canlı bildirimi (Android ongoing notification / iOS Live Activity)
- [ ] Güvenilirlik ön kontrolü: pil optimizasyonu / izin / ses taraması + OEM bazlı düzeltme yönergeleri (Xiaomi, Oppo, Samsung)
- [ ] "İndin" ekranı: yolculuk özeti + "favorilere ekle?" (reklam alanı şimdilik boş)
- [ ] Yolculuk kaydını Firestore'a canlı yaz (users/{uid}/journeys; çevrimdışı önbellek açık)
- [ ] Firestore güvenlik kuralları (uid-bazlı izolasyon)
- [ ] Crashlytics + Analytics kurulumu ("alarm çalmadı" telemetrisi dahil)
- [ ] Saha testi: otobüs + tramvay + Marmaray yer üstü kesimi (Gebze–Ayrılık Çeşmesi)
- [ ] Kapalı beta (TestFlight + Play Internal Testing)

## Faz 2 – Yeraltı Modu
- [x] Zaman sayacı motoru: son bilinen durak + segment süreleri → kalan durak tahmini (ÖĞRENİLMİŞ > GTFS > varsayılan)
- [x] Belirsizlik modeli: kör seyahat biriktikçe alarm eşiğini öne çek (~3 dk/durak marj + son durak tabanı)
- [x] GPS kaybında otomatik yeraltı moduna geçiş (durum makinesine SINYAL_YOK; taze GPS sondasıyla ayrım)
- [x] İvmeölçer durak sayacı: varyans tabanlı yavaşlama→duruş→hızlanma tespiti (öğrenilen eşiklerle; sensors_plus) — cepte saha doğrulaması bekliyor
- [x] Sinyal beklemesi filtresi (iki katman: dedektörde min duruş süresi + motorda segment-oranı)
- [x] Sayaç + ivmeölçer füzyonu (yalnız ileri/temkinli kazanır: saat ve sayaçtan hedefe yakın olan baskın)
- [~] Segment sürelerini öğrenerek kalibre et — YEREL öğrenme çalışıyor (SegmentLearner, EMA, cihazda kalıcı, buluta hazır); Marmaray/M2/M4 saha ölçümü cihazda
- [ ] Saha testi: Marmaray tünel geçişi (Ayrılık Çeşmesi–Kazlıçeşme) + tam yeraltı metro hattı
- [ ] Pil tüketimi ölçümü ve optimizasyon (hedef: 1 saatlik yolculukta < %4)
- [ ] Store lansmanı: mağaza sayfaları, ekran görüntüleri, ASO ("durak alarmı", "Marmaray alarm" vb.)

## Faz 3 – Profil, Geçmiş ve Gelir
- [x] Profil ekranı: takma ad (kalıcı) + ayarlar (alarm sesi/erteleme/varsayılan tetikleme)
- [x] Geçmiş yolculuklar listesi (tarih/hat/güzergâh/süre; hat türü + durum filtresi, güne göre gruplu)
- [x] İstatistikler: toplam yolculuk, toplam süre, en çok kullanılan hat, "kaç kez uyandırıldın" (JourneyStats + profil özet kartı)
- [x] Favori rotalar: kaydet + ana ekrandan tek dokunuşla başlat (Firestore)
- [ ] Hesap bağlama: Google/Apple (OAuth config gerektirir — HESAP KURULUMU BEKLİYOR)
- [ ] Yolculuk paylaşımı: shared_journeys + herkese açık link (stopalert.app hosting BEKLİYOR)
- [~] Paylaşım görsel kartı: profil özet kartı görsel olarak hazır; gerçek paylaşım (share_plus/görsel export) kaldı
- [~] İstatistik özet kartı paylaşımı: kart hazır; paylaşım mekanizması kaldı
- [x] KVKK: gizlilik & KVKK ekranı + "verilerimi sil" akışı (bulut kayıt + cihaz ayar/öğrenme temizliği)
- [~] AdMob entegrasyonu: **yalnızca İndin sayfasında** geçiş reklamı — KOD hazır (google_mobile_ads, AdService); şu an GOOGLE TEST kimlikleri, gerçek reklam birimi/App ID beklemede
  - [x] Yolculuk başlarken reklamı arka planda önden yükle (alarm_setup → preloadInterstitial)
  - [x] Yüklenmemişse sessizce atla (asla bekletme, asla alarm akışına dokunma)
  - [x] Sıklık sınırı: günde en fazla 2 gösterim (cihazda sayaç)
- [ ] Premium (abonelik/tek seferlik): reklamsız + sınırsız favori + gelecek özellikler; ödeme entegrasyonu (RevenueCat)

## Faz 4 – Hendek ve Genişleme
- [ ] Hücre/Wi-Fi parmak izi toplama (anonim, rıza ile) + istasyon eşleştirme servisi
- [ ] Parmak izi çapası: eşleşince zaman sayacını istasyona sıfırla
- [ ] iOS Critical Alerts (entitlement onayı geldiyse) — sessiz modu delme
- [ ] Apple Watch uygulaması (bildirim + haptic alarm)
- [ ] Wear OS uygulaması
- [ ] Otomatik yolculuk algılama ("her iş günü 18:00'de Marmaray'a biniyorsun → alarmı kurayım mı?")
- [ ] Yeni şehirler: Ankara, İzmir GTFS entegrasyonu
- [x] Gerçek segment sürelerini kullanıcı yolculuklarından öğrenme — YEREL + BULUT hazır: anonim `segment_stats` toplama (sum/count increment) + hat seçilince tohumlama; rıza anahtarı (Ayarlar→Öğrenme→Anonim katkı). NOT: `firestore.rules` DEPLOY edilmeli; üretimde Cloud Functions ile sunucu-tarafı toplama önerilir

## Sürekli / Yatay İşler
- [ ] CI/CD (GitHub Actions: test + build + dağıtım)
- [ ] Birim testleri: konum motoru füzyon mantığı %90+ kapsam (en kritik kod)
- [ ] "Alarm güvenilirlik matrisi" test protokolü: cihaz × OEM × ekran durumu × sinyal durumu kombinasyonları
- [ ] Beta kullanıcı geri bildirim kanalı (uygulama içi form)
