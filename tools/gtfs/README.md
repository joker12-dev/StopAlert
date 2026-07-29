# İETT GTFS → StopAlert otobüs veritabanı

Otobüs (İETT) durak/hat verisini indirilebilir bir SQLite'a dönüştürür.
Uygulama bu DB'yi **ilk açılışta indirir** (Firebase Hosting'den) ve yakın durak /
arama / rota sorgularını buradan yapar. Ray/vapur verisi ayrıca
`assets/data/lines.json`'da kalır.

## Kaynak (kamuya açık, login yok)
data.ibb.gov.tr → "IETT GTFS Data" (`8540e256-...`). Gerekli dosyalar:
`routes.csv`, `trips.csv`, `stops.csv` (ayraç `;`), `stop_times.txt` (ayraç `,`,
`stop_times.zip` içinde). Son güncelleme: 2026-04-21. "Güncellenmeyecek" notu var.

## Veri tuhaflıkları (dönüştürücü bunları ele alır)
- CSV ayracı `;` (stop_times `,`), dosyalarda BOM → `utf-8-sig`.
- Enlem/boylam bozuk: `410.191.700.005.564` → noktaları at, 2 haneden sonra ondalık
  = `41.0191700005564`. İstanbul bbox ile doğrulanır.
- `routes.csv` hat adları cp1252/UTF-8 çift-kodlu (mojibake) → güvenilmez.
  Bu yüzden hat adı **temiz durak adlarından** (ilk → son durak) türetilir.
- Hat başına EN ÇOK duraklı temsili sefer seçilir (yön/varyant başına bir rota).

## Çalıştırma
```
# routes.csv, trips.csv, stops.csv, stop_times.zip'i bu klasöre indir/çıkar
python build_db.py         # -> bus.sqlite (~5.7MB)
```

## Yayınlama (Firebase Hosting)
```
# bus.sqlite'i firebase_hosting/data/bus_<VER>.sqlite olarak kopyala + manifest.json güncelle
firebase deploy --only hosting --project stopalert-15716
```
Çıktı URL'leri:
- https://stopalert-15716.web.app/data/manifest.json
- https://stopalert-15716.web.app/data/bus_<VER>.sqlite

## Şema
```
stops(id INTEGER PK, name, lat, lon)              -- tüm İETT durakları (~15.4k)
lines(id TEXT PK, code, name, type='bus')          -- ~2.87k temsili hat
line_stops(line_id, seq, stop_id, seconds)         -- sıralı duraklar + segment sn
meta(key, value)                                   -- version/lines/stops/source
```
Segment `seconds`: timepoint arrival_time farklarından; boşluklar eşit bölünür,
hiç yoksa 90 sn.
