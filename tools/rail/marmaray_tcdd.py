# -*- coding: utf-8 -*-
"""Marmaray tarifesini TCDD'nin resmi ilk/son tren çizelgesinden kurar.

NEDEN GTFS YETMİYOR: İBB'nin GTFS setinde Marmaray tek servis takvimine
(`service_id` 311) bağlı ve takvimi 2024-12-31'de bitmiş. Sonuç olarak hafta
içi, cumartesi ve pazar birebir aynı çıkıyor — oysa TCDD cuma→cumartesi ve
cumartesi→pazar gecelerinde servisi 01:20'ye kadar uzatıyor. GTFS bunu hiç
bilmiyor.

KAYNAK: TCDD Taşımacılık "Marmaray İlk ve Son Trenlerin İstasyonlardan Kalkış
Saatleri" çizelgesi (05.05.2026 basımı):
  - Halkalı → Gebze : ilk 05:58, son 23:28, hafta sonu gecesi son 01:28
  - Gebze → Halkalı : ilk 06:05, son 23:20, hafta sonu gecesi son 01:20
  - Halkalı-Gebze-Halkalı arası 15 dakika aralıkla
  - Cuma→cumartesi ve cumartesi→pazar gecelerinde 22:50'den sonraki trenler
    30 dakika aralıkla

MODELLENMEYEN: Ataköy-Pendik arasındaki 8 dakikalık sıklaştırma. O seferler
hattın tamamını gitmiyor, uygulamanın hat modelinde ise bir yön varyantının
TEK durak dizisi var ve kalkışlar ilk duraktan sayılıyor. Kısa seferi tam hat
kalkışı gibi yazmak, Halkalı'da olmayan bir treni varmış gibi gösterirdi.
Eksik göstermek, olmayanı vaat etmekten iyidir.

Gece yarısını aşan kalkışlar ERTESİ GÜNE yazılır: cumartesi sabahı 01:28'de
kalkan tren, uygulamanın gün modelinde cumartesiye aittir.
"""

# Yön varyantı -> (ilk kalkış, hafta içi son, hafta sonu gecesi son)
SERVICE = {
    'R:Marmaray_D': ('05:58', '23:28', '01:28'),   # Halkalı → Gebze
    'R:Marmaray_G': ('06:05', '23:20', '01:20'),   # Gebze → Halkalı
}

HEADWAY_MIN = 15
LATE_HEADWAY_MIN = 30

# Bu saatten sonrası hafta sonu gecelerinde seyrekleşir (TCDD dipnotu).
LATE_AFTER = '22:50'


def _mins(hhmm):
    h, m = hhmm.split(':')
    return int(h) * 60 + int(m)


def _clock(total):
    total %= 24 * 60
    return f'{total // 60:02d}:{total % 60:02d}'


def departures(line_id, day):
    """`line_id` yön varyantı ve `day` (I/C/P) için kalkış saatleri.

    Hafta sonu gecesi uzatması cumartesi ve pazara yazılır: cuma gecesi
    01:20'de kalkan tren takvimde cumartesiye düşer.
    """
    spec = SERVICE.get(line_id)
    if not spec:
        return []
    first, last_weekday, last_weekend = spec
    start = _mins(first)
    late_from = _mins(LATE_AFTER)

    if day == 'I':
        end = _mins(last_weekday)
        return [_clock(t) for t in range(start, end + 1, HEADWAY_MIN)]

    # Hafta sonu: son trenden GERİYE doğru 30'ar dakika, 22:50'ye kadar.
    # İleriye doğru kurmak son treni 01:28'e denk getirmiyordu.
    end = _mins(last_weekend) + 24 * 60
    late = []
    t = end
    while t - LATE_HEADWAY_MIN > late_from:
        late.append(t)
        t -= LATE_HEADWAY_MIN
    late.append(t)
    late.reverse()

    # Seyrek servisin başladığı andan geriye 15'er dakika.
    dense = list(range(late[0] % (24 * 60), start - 1, -HEADWAY_MIN))
    dense.reverse()
    return [_clock(x) for x in dense] + [_clock(x) for x in late[1:]]


def rows():
    """(line_id, day, time) üçlüleri — `departures` tablosuna yazılmaya hazır."""
    out = []
    for line_id in SERVICE:
        for day in ('I', 'C', 'P'):
            for time in departures(line_id, day):
                out.append((line_id, day, time))
    return out


if __name__ == '__main__':
    import sys
    sys.stdout.reconfigure(encoding='utf-8')
    for lid in SERVICE:
        for day in ('I', 'C', 'P'):
            d = departures(lid, day)
            print(f'{lid} {day}: {len(d)} sefer  {d[0]} → {d[-1]}')
