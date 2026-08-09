#!/usr/bin/env python3
"""İstanbul RAY + DENİZ hatlarını (metro, Marmaray, tramvay, füniküler,
teleferik, vapur)
İBB açık veri GTFS'inden üretir ve İSTANBUL PAKETİNE katar.

KAYNAK: İBB Açık Veri Portalı — "Public Transport GTFS Data"
    https://data.ibb.gov.tr/dataset/public-transport-gtfs-data
Açıklamasında birebir yazıyor: Minibus, Sehir Hatlari, IDO, Turyol,
Dentur Avrasya, **Marmaray (TCDD)** ve **Metro**.

NEDEN BU KAYNAK: Metro İstanbul'un kendi tarife servisi
(`api.ibb.gov.tr/MetroIstanbul/.../GetTimeTable`) katalogda duruyor ama İBB
geçidi JSON gövdeyi bozuyor: skaler gövde arka uca ulaşıp "model null" hatası
veriyor, nesne gövdesi ise geçitte XML ayrıştırma hatasına düşüyor. İstemci
tarafından aşılamadığı için tarife bu GTFS'ten alınıyor.

MEVCUT RAY DOSYASI ÜSTÜN OLABİLİR: İBB GTFS'i yeni açılan metro
uzantılarında geride kalıyor — ölçüldü: M3 20 yerine 9, M9 14 yerine 5, M5 24
yerine 16 durak veriyor; F4 ve T5 hiç yok. Bu yüzden `--rail-json` verilirse
hat başına DAHA ÇOK duraklı kaynak seçilir. Tarife (kalkış saatleri) her
durumda GTFS'ten gelir; eski dosyada zaten yok.

NE ÜRETİR:
  - Ray hatları (yön başına bir varyant) ve SIRALI durakları
  - Duraklar arası GERÇEK süreler (stop_times'tan; tahmin değil)
  - Sefer saatleri: her seferin ilk duraktan kalkışı, gün tipine ayrılmış
    (calendar.csv → I/C/P)

DURAK KİMLİĞİ ÇAKIŞMASI: ray durak kimlikleri İETT'ninkilerle çakışıyor
(ölçüldü: 7 kimlik ortak). Bu yüzden ray durakları RAIL_ID_OFFSET kadar
kaydırılıyor; İETT'nin en büyük kimliği ~900.442 olduğu için 90.000.000
güvenli bir aralık.

Kullanım:
    python build_rail_gtfs.py --gtfs <klasör> --into <istanbul.sqlite>
"""
import argparse
import csv
import json
import math
import os
import sqlite3
import sys

# GTFS route_type -> StopAlert türü. (2 = ağır raylı; bu beslemede Marmaray
# tip 1 geliyor, adından yakalanıyor.)
TYPE_BY_GTFS = {
    '0': 'tram',
    '1': 'metro',
    '2': 'marmaray',
    # 4 = DENİZ. Şehir Hatları, İDO, Turyol, Dentur bu beslemede; eski ray
    # dosyasında 99 vapur hattı vardı ve tip 4 atlanınca hepsi kayboluyordu.
    '4': 'ferry',
    '5': 'tram',
    '6': 'cableCar',
    '7': 'funicular',
}

RAIL_TYPES = set(TYPE_BY_GTFS)

# Ray durak kimlikleri bu kadar kaydırılır (İETT ile çakışmasın).
RAIL_ID_OFFSET = 90_000_000

# Ray HAT kimliği öneki.
#
# ŞART: İETT'de M5, M7 ve F2 KODLU OTOBÜS hatları var (metro bağlantısı
# taşıdıkları için öyle adlandırılmışlar). Önek olmadan ray kayıtları bu beş
# otobüs hattını EZİYORDU — ölçüldü, ilk denemede 5 hat kayboldu.
RAIL_LINE_PREFIX = 'R:'

# Gün tipi kodları — uygulamadaki DayType ile aynı.
DAY_WEEKDAY, DAY_SAT, DAY_SUN = 'I', 'C', 'P'


def norm(s):
    """Arama anahtarı — uygulamadaki transitNorm ile birebir aynı olmalı."""
    out = []
    for ch in (s or ''):
        out.append({'İ': 'i', 'I': 'i', 'ı': 'i', 'Ö': 'o', 'ö': 'o',
                    'Ü': 'u', 'ü': 'u', 'Ş': 's', 'ş': 's', 'Ç': 'c',
                    'ç': 'c', 'Ğ': 'g', 'ğ': 'g'}.get(ch, ch))
    return ''.join(out).lower()


def read_csv(folder, name):
    """İBB dosyaları cp1254 (Windows-1254) kodlu; utf-8 denemesi patlıyor."""
    path = os.path.join(folder, name)
    with open(path, encoding='cp1254', newline='') as f:
        return list(csv.DictReader(f))


def secs(hhmmss):
    """'25:30:00' -> saniye. GTFS gece yarısını aşan saatleri 24+ yazar."""
    try:
        h, m, s = (int(x) for x in hhmmss.split(':'))
        return h * 3600 + m * 60 + s
    except Exception:
        return None


def clock(hhmmss):
    """'25:30:00' -> '01:30' (ertesi güne taşan sefer saatleri okunur olsun)."""
    t = secs(hhmmss)
    if t is None:
        return None
    t %= 24 * 3600
    return f'{t // 3600:02d}:{(t % 3600) // 60:02d}'


def meters(a, b):
    """(lat, lon) ikilisi arası mesafe (metre)."""
    r = 6371000.0
    dlat = math.radians(b[0] - a[0])
    dlon = math.radians(b[1] - a[1])
    h = (math.sin(dlat / 2) ** 2 +
         math.cos(math.radians(a[0])) * math.cos(math.radians(b[0])) *
         math.sin(dlon / 2) ** 2)
    return 2 * r * math.asin(min(1.0, math.sqrt(h)))


def legacy_lines(path):
    """Mevcut rail_*.json: kod -> EN UZUN durak dizisine sahip hat."""
    if not path or not os.path.exists(path):
        return {}
    with open(path, encoding='utf-8') as f:
        lines = json.load(f).get('lines', [])
    best = {}
    for l in lines:
        code = (l.get('code') or '').strip()
        stops = [s for s in (l.get('stops') or [])
                 if (s.get('lat') or 0) or (s.get('lon') or 0)]
        if not code or len(stops) < 2:
            continue
        if code not in best or len(stops) > len(best[code][1]):
            best[code] = (l, stops)
    return best


def day_types(cal_row):
    """Bir servis takviminin karşılık geldiği gün tipleri."""
    out = set()
    if any(cal_row.get(d) == '1' for d in
           ('monday', 'tuesday', 'wednesday', 'thursday', 'friday')):
        out.add(DAY_WEEKDAY)
    if cal_row.get('saturday') == '1':
        out.add(DAY_SAT)
    if cal_row.get('sunday') == '1':
        out.add(DAY_SUN)
    return out


def build(gtfs, target, rail_json=None):
    routes = read_csv(gtfs, 'routes.csv')
    trips = read_csv(gtfs, 'trips.csv')
    stops_raw = read_csv(gtfs, 'stops.csv')
    calendar = read_csv(gtfs, 'calendar.csv')
    freqs = read_csv(gtfs, 'frequencies.csv')

    rail_routes = {}
    for r in routes:
        rtype = r.get('route_type')
        if rtype not in RAIL_TYPES:
            continue
        code = (r.get('route_short_name') or '').strip()
        if not code:
            continue
        kind = TYPE_BY_GTFS[rtype]
        # Bu beslemede Marmaray tip 1 (metro) geliyor; kullanıcı için ayrı
        # bir taşıt olduğu için addan yakalanıyor.
        if norm(code).startswith('marmaray'):
            kind = 'marmaray'
        rail_routes[r['route_id']] = {
            'code': code,
            'name': (r.get('route_long_name') or code).strip(),
            'type': kind,
            'color': ('#' + (r.get('route_color') or '').strip().upper())
            if len((r.get('route_color') or '').strip()) == 6 else '',
        }
    print(f'ray hattı: {len(rail_routes)}')

    # service_id -> gün tipleri
    days_by_service = {c['service_id']: day_types(c) for c in calendar}

    # Ray seferleri
    rail_trips = {}
    for t in trips:
        if t.get('route_id') not in rail_routes:
            continue
        rail_trips[t['trip_id']] = t
    print(f'ray seferi: {len(rail_trips)}')

    # stop_times TEK GEÇİŞTE okunur (200 bin satır; belleğe almadan grupla).
    by_trip = {}
    with open(os.path.join(gtfs, 'stop_times.csv'),
              encoding='cp1254', newline='') as f:
        for row in csv.DictReader(f):
            tid = row['trip_id']
            if tid not in rail_trips:
                continue
            by_trip.setdefault(tid, []).append(row)
    for v in by_trip.values():
        v.sort(key=lambda x: int(x.get('stop_sequence') or 0))
    print(f'zaman satırı olan sefer: {len(by_trip)}')

    stop_info = {}
    for s in stops_raw:
        try:
            stop_info[s['stop_id']] = (
                (s.get('stop_name') or '').strip(),
                float(s['stop_lat']),
                float(s['stop_lon']),
            )
        except Exception:
            continue

    freq_by_trip = {}
    for f in freqs:
        freq_by_trip.setdefault(f['trip_id'], []).append(f)

    # (route, direction) -> en ÇOK duraklı sefer temsilci sayılır.
    # Kısa/parçalı seferler hattın tamamını temsil etmiyor.
    best = {}
    departures = {}          # (route, dir) -> {gün: set(saat)}
    for tid, t in rail_trips.items():
        st = by_trip.get(tid)
        if not st or len(st) < 2:
            continue
        key = (t['route_id'], (t.get('direction_id') or '0'))
        if key not in best or len(st) > len(by_trip[best[key]]):
            best[key] = tid
        days = days_by_service.get(t.get('service_id'), ())
        windows = freq_by_trip.get(tid)
        if windows:
            # FREKANS TABANLI SEFER (Marmaray, vapur…): GTFS tek bir şablon
            # sefer yazıp gerçek servisi "şu saatler arası her N dakika"
            # olarak veriyor. Şablonun kendi saatini kalkış saymak yanlış
            # olurdu — Marmaray'a günde 3 sefer çıkıyordu; pencereler açılır.
            for w in windows:
                a, b = secs(w['start_time']), secs(w['end_time'])
                head = int(w.get('headway_secs') or 0)
                if a is None or b is None or head <= 0:
                    continue
                t0 = a
                while t0 < b:
                    tm = clock(f'{t0 // 3600:02d}:{(t0 % 3600) // 60:02d}:00')
                    if tm:
                        for d in days:
                            departures.setdefault(key, {}) \
                                .setdefault(d, set()).add(tm)
                    t0 += head
            continue
        first = clock(st[0].get('departure_time') or st[0].get('arrival_time'))
        if first:
            for d in days:
                departures.setdefault(key, {}).setdefault(d, set()).add(first)

    line_rows, ls_rows, dep_rows = [], [], []
    used_stops = {}
    for (route_id, direction), tid in sorted(best.items()):
        meta = rail_routes[route_id]
        st = by_trip[tid]
        seq = []
        for x in st:
            info = stop_info.get(x['stop_id'])
            if info is None:
                continue
            seq.append((int(x['stop_id']) + RAIL_ID_OFFSET, info[0], info[1],
                        info[2], x))
        if len(seq) < 2:
            continue

        yon = 'G' if direction == '0' else 'D'
        lid = f'{RAIL_LINE_PREFIX}{meta["code"]}_{yon}'
        lname = f'{seq[0][1]} - {seq[-1][1]}'
        line_rows.append((lid, meta['code'], lname, norm(lname), yon, 0,
                          meta['type'], meta['color'], 'Metro İstanbul'))

        for i, (sid, name, lat, lon, raw) in enumerate(seq):
            used_stops[sid] = (name, lat, lon)
            if i == 0:
                ls_rows.append((lid, 0, sid, 0))
                continue
            # GERÇEK süre: önceki duraktan kalkış -> bu durağa varış.
            a = secs(seq[i - 1][4].get('departure_time') or
                     seq[i - 1][4].get('arrival_time'))
            b = secs(raw.get('arrival_time') or raw.get('departure_time'))
            gap = (b - a) if (a is not None and b is not None) else None
            if gap is None or gap <= 0:
                gap = 90
            ls_rows.append((lid, i, sid, max(20, min(gap, 1800))))

        for day, times in departures.get((route_id, direction), {}).items():
            for tm in sorted(times):
                dep_rows.append((lid, day, tm))

    # ---- GTFS mi eski dosya mı daha zengin? ----
    #
    # Kalkış saatleri her durumda GTFS'ten gelir ve hat kimliği aynı kaldığı
    # için (R:<kod>_<yön>) durak kaynağı değişse de tarifeye bağlı kalır.
    legacy = legacy_lines(rail_json)
    if legacy:
        stop_count = {}
        for r in ls_rows:
            stop_count[r[0]] = stop_count.get(r[0], 0) + 1
        gtfs_best = {}
        for lid, code, *_ in line_rows:
            gtfs_best[code] = max(gtfs_best.get(code, 0), stop_count.get(lid, 0))

        drop, add_lines, add_ls = set(), [], []
        kept = []
        for code, (leg, stops_l) in legacy.items():
            if len(stops_l) <= gtfs_best.get(code, 0):
                continue                       # GTFS yeterince zengin
            kept.append(code)
            for lid, c, *_ in line_rows:
                if c == code:
                    drop.add(lid)

            kind = leg.get('type') or 'metro'
            total = sum(leg.get('segmentSeconds') or [])
            dists = [meters((stops_l[i]['lat'], stops_l[i]['lon']),
                            (stops_l[i + 1]['lat'], stops_l[i + 1]['lon']))
                     for i in range(len(stops_l) - 1)]
            tot = sum(dists)
            for yon in ('G', 'D'):
                lid = f'{RAIL_LINE_PREFIX}{code}_{yon}'
                seq = stops_l if yon == 'G' else list(reversed(stops_l))
                dd = dists if yon == 'G' else list(reversed(dists))
                lname = f"{seq[0]['name']} - {seq[-1]['name']}"
                add_lines.append((lid, code, lname, norm(lname), yon, 0, kind,
                                  leg.get('color') or '', 'Metro İstanbul'))
                for i, st in enumerate(seq):
                    sid = RAIL_ID_OFFSET + (abs(hash(st['name'])) % 9_000_000)
                    used_stops[sid] = (st['name'], st['lat'], st['lon'])
                    if i == 0:
                        add_ls.append((lid, 0, sid, 0))
                        continue
                    # Toplam süre biliniyorsa MESAFEYE göre dağıt: eski
                    # dosyada metro segmentleri hep aynı değerdi (100 sn).
                    sec = int(total * dd[i - 1] / tot) if (total and tot) else 100
                    add_ls.append((lid, i, sid, max(20, min(sec, 1800))))

        line_rows = [r for r in line_rows if r[0] not in drop] + add_lines
        ls_rows = [r for r in ls_rows if r[0] not in drop] + add_ls
        if kept:
            print(f'  eski dosyadan korunan hat ({len(kept)}): '
                  f'{", ".join(sorted(kept)[:12])}')

    print(f'yön varyantı: {len(line_rows)}  durak: {len(used_stops)}  '
          f'kalkış: {len(dep_rows)}')

    db = sqlite3.connect(target)
    # `departures` tablosu İstanbul paketinde YOK (Kocaeli'de vardı).
    db.execute('''CREATE TABLE IF NOT EXISTS departures(
                    line_id TEXT, day TEXT, time TEXT)''')
    db.execute('CREATE INDEX IF NOT EXISTS idx_dep_line ON departures(line_id)')
    # Yeniden çalıştırmada ray kayıtları TEMİZLENİR; otobüs verisine dokunulmaz.
    old = [r[0] for r in db.execute(
        "SELECT id FROM lines WHERE type <> 'bus' AND type <> 'metrobus'")]
    # Önek değişmiş olabilir: bu çalıştırmada yazacağımız kimlikleri de temizle
    # ki eski satırlar artık kalmasın.
    old = sorted(set(old) | {r[0] for r in line_rows})
    if old:
        marks = ','.join('?' * len(old))
        db.execute(f'DELETE FROM line_stops WHERE line_id IN ({marks})', old)
        db.execute(f'DELETE FROM departures WHERE line_id IN ({marks})', old)
        db.execute(f'DELETE FROM lines WHERE id IN ({marks})', old)
    db.execute('DELETE FROM stops WHERE id >= ?', (RAIL_ID_OFFSET,))

    cols = [r[1] for r in db.execute('PRAGMA table_info(lines)')]
    if 'color' in cols:
        db.executemany('INSERT OR REPLACE INTO lines VALUES(?,?,?,?,?,?,?,?,?)',
                       line_rows)
    else:
        db.executemany('INSERT OR REPLACE INTO lines VALUES(?,?,?,?,?,?,?)',
                       [r[:7] for r in line_rows])
    db.executemany('INSERT INTO line_stops VALUES(?,?,?,?)', ls_rows)
    db.executemany('INSERT INTO departures VALUES(?,?,?)', dep_rows)

    scols = [r[1] for r in db.execute('PRAGMA table_info(stops)')]
    if 'district' in scols:
        db.executemany('INSERT OR REPLACE INTO stops VALUES(?,?,?,?,?,?,?)', [
            (sid, v[0], norm(v[0]), '', '', v[1], v[2])
            for sid, v in used_stops.items()])
    else:
        db.executemany('INSERT OR REPLACE INTO stops VALUES(?,?,?,?,?,?)', [
            (sid, v[0], norm(v[0]), '', v[1], v[2])
            for sid, v in used_stops.items()])
    db.commit()
    db.execute('VACUUM')
    size = os.path.getsize(target) / 1024 / 1024
    print(f'\nBİRLEŞTİRİLDİ: {target}  ({size:.1f} MB)')
    for t in ('lines', 'stops', 'line_stops', 'departures'):
        print(f'  {t}: {db.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0]}')
    db.close()
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--gtfs', required=True, help='GTFS csv klasörü')
    ap.add_argument('--into', required=True, help='İstanbul sqlite (yerinde)')
    ap.add_argument('--rail-json', help='mevcut rail_*.json (daha zenginse korunur)')
    a = ap.parse_args()
    return build(a.gtfs, a.into, a.rail_json)


if __name__ == '__main__':
    sys.exit(main())
