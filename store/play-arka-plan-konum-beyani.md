# Play Console — Arka plan konumu beyanı

> Doldurulacak yer: Politika → Uygulama içeriği → Konum izinleri
> İzinler: `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION`,
> `ACCESS_BACKGROUND_LOCATION`

---

## 1) Uygulamanın amacı (500 karakter sınırı)

StopAlert bir toplu taşıma durak alarmıdır. Kullanıcı bineceği hattı ve
ineceği durağı seçer; uygulama yolculuk boyunca konumu izleyerek durağa
yaklaşıldığında çalar saat gibi tam ekran alarm çalar. Amaç, uyuyan ya da
dikkati dağılan yolcunun durağını kaçırmasını önlemektir. İstanbul ve Kocaeli
için otobüs, metrobüs, metro, Marmaray, tramvay ve vapur hatlarını kapsar.
Rota planlama yapmaz; tek işi ineceğiniz durakta sizi uyarmaktır.

---

## 2) Konum erişimi — arka planı en çok kullanan TEK özellik (500 karakter)

Özellik: Durak Alarmı.

Kullanıcı alarmı kurup yolculuğu başlattığında uygulama, kalan durak ve
mesafeyi hesaplamak için konumu sürekli okur. Yolcu bu sırada telefonu cebine
koyar, ekranı kapatır ya da uygulamadan çıkar; alarmın çalabilmesi için konum
erişimi bu durumlarda da sürmek zorundadır. Aksi hâlde ekran kapanır kapanmaz
takip durur ve alarm hiç çalmaz. Erişim yalnızca yolculuk sürerken olur,
kalıcı bir bildirimle gösterilir ve yolculuk bitince durur.

---

## 3) Video talimatları

30 saniyeyi geçmeyen, YouTube'a **"Liste dışı" (Unlisted)** olarak yüklenmiş
bir ekran kaydı. Play'in aradığı üç şey videoda görünmeli:

1. **Belirgin açıklama** (sistem izin penceresinden ÖNCE),
2. **Özelliğin kendisi** (alarm kurma ve çalma),
3. **Arka planda erişimin neden gerektiği** (ekran kapalıyken de takip).

### Çekim sırası

| sn | Ekran | Not |
|----|-------|-----|
| 0-4 | Uygulama açılır, tanıtım geçilir | |
| 4-10 | **"Alarmın çalışması için izinler gerekli" ekranı** — metin okunacak kadar dursun | **BU ZORUNLU.** Ekranda "KONUM VERİNİ, uygulama kapalıyken veya kullanılmıyorken de toplar" yazıyor; belirgin açıklama budur. |
| 10-14 | "Konum: HER ZAMAN İZİN VER" satırına dokun → **sistem penceresi çıkar** → "Her zaman izin ver" seçilir | Açıklamanın izin penceresinden ÖNCE geldiği net görünmeli |
| 14-20 | Duraklar sekmesi → bir durak seç → hat seç → **Alarm Kur** | |
| 20-25 | Yolculuk başlar, **ekran kilitlenir** — kilit ekranındaki takip bildirimi görünür | Arka plan erişiminin nedeni burada görünüyor |
| 25-30 | Durağa yaklaşınca **tam ekran alarm çalar** | Özelliğin sonucu |

### Video açıklamasına yazılacak metin

> StopAlert, toplu taşımada ineceğiniz durakta sizi uyandıran bir alarm
> uygulamasıdır. Bu video, arka plan konum izninin neden gerekli olduğunu
> gösterir: kullanıcı telefonu cebine koyup ekranı kapattığında da durağa
> olan mesafenin hesaplanması gerekir, aksi hâlde alarm çalmaz. Konum yalnızca
> yolculuk sürerken okunur ve cihazdan dışarı gönderilmez.

---

## 4) Veri Güvenliği formuyla tutarlılık

Beyanın formla çelişmemesi gerekiyor; çelişirse sürüm reddediliyor.

- Konum → **Toplanıyor: Hayır** · **Paylaşılıyor: Hayır**
  (mesafe hesabı cihazda yapılır, konum sunucuya gönderilmez)
- Uygulama içi mesaj/işlem → yok
- Kişisel bilgiler (e-posta, ad) → **Toplanıyor: Evet** (yalnızca Google/Apple
  ile giriş yapılırsa), hesap yönetimi amacıyla, **isteğe bağlı**
- Uygulama etkinliği (yolculuk geçmişi, favoriler) → **Toplanıyor: Evet**
  (yalnızca hesap açılırsa), uygulama işlevi amacıyla
- Cihaz/reklam kimliği → **Toplanıyor: Evet** (AdMob), reklam amacıyla
- Aktarımda şifreleme → **Evet** · Silme talebi → **Evet**
  (Ayarlar → Verilerimi Sil)
