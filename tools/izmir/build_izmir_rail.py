#!/usr/bin/env python3
"""İzmir RAY + DENİZ hatlarını (metro, tramvay, İZBAN, vapur) İzmir paketine
(izmir.sqlite) KATAR.

KAYNAKLAR (hepsi CC BY / İzmir Açık Veri, ayrı GTFS zip'leri):
  metro : https://www.izmirmetro.com.tr/gtfs/rail-metro-gtfs.zip     route_type 1
  tram  : https://www.tramizmir.com/gtfs/rail-tramizmir-gtfs.zip     route_type 0
  izban : https://www.izban.com.tr/gtfs/rail-izban-gtfs.zip          route_type 2
  ferry : https://www.izdeniz.com.tr/gtfs/ship-izdeniz-gtfs.zip      route_type 4

Otobüs paketi (build_izmir.py) önce üretilmiş olmalı; bu betik onun ÜZERİNE
ray/deniz satırlarını ekler (mevcut ray satırlarını temizleyip yeniden yazar,
otobüse dokunmaz). İstanbul'daki desenin (tools/rail/build_rail_gtfs.py) İzmir
sürümü:
  - Ray HAT kimliği `R:` önekli (otobüs kodlarını ezmesin).
  - Ray DURAK kimlikleri beslemeye göre ayrı bloklarda kaydırılır (feed'ler
    arası çakışma olmasın): metro 90M, tram 91M, izban 92M, ferry 93M.
  - Süreler stop_times'tan GERÇEK (tahmin değil). Kalkışlar calendar'dan I/C/P.
  - Yön uçlardan türetilir (alfabetik): karşı yönler aynı koda G/D olarak eşlenir.

TÜR seçimi: İZBAN heavy-rail (route_type 2) ama uygulamada 'marmaray' türü
'Marmaray' etiketi gösterirdi (İzmir'e yanlış); bu yüzden İZBAN 'metro' türüyle
ama operator='İZBAN' ile yazılır — hat detayında "Metro · İZBAN" okunur.

Kullanım:
    python build_izmir_rail.py                 # zip'leri indirir, izmir.sqlite'a katar
    python build_izmir_rail.py --offline       # raw_rail/ içindeki zip'lerle
"""
import argparse
import csv
import io
import os
import sqlite3
import sys
import urllib.request
import zipfile
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
RAW = os.path.join(HERE, 'raw_rail')
OUT = os.path.join(HERE, 'izmir.sqlite')

csv.field_size_limit(1 << 24)

# feed -> (url, route_type beklenen, StopAlert türü, operator, durak kaydırma)
FEEDS = {
    'metro': ('https://www.izmirmetro.com.tr/gtfs/rail-metro-gtfs.zip',
              'metro', 'İzmir Metro', 90_000_000),
    'tram': ('https://www.tramizmir.com/gtfs/rail-tramizmir-gtfs.zip',
             'tram', 'İzmir Tramvay', 91_000_000),
    'izban': ('https://www.izban.com.tr/gtfs/rail-izban-gtfs.zip',
              'metro', 'İZBAN', 92_000_000),   # tür 'metro' (etiket sebebiyle)
    'ferry': ('https://www.izdeniz.com.tr/gtfs/ship-izdeniz-gtfs.zip',
              'ferry', 'İzdeniz', 93_000_000),
}

RAIL_LINE_PREFIX = 'R:'


def norm(s):
    out = []
    for ch in (s or ''):
        out.append({'İ': 'i', 'I': 'i', 'ı': 'i', 'Ö': 'o', 'ö': 'o',
                    'Ü': 'u', 'ü': 'u', 'Ş': 's', 'ş': 's', 'Ç': 'c',
                    'ç': 'c', 'Ğ': 'g', 'ğ': 'g'}.get(ch, ch))
    return ''.join(out).lower()


def secs(t):
    try:
        h, m, s = (int(x) for x in t.split(':'))
        return h * 3600 + m * 60 + s
    except Exception:
        return None


def clock(t):
    v = secs(t)
    if v is None:
        return None
    v %= 24 * 3600
    return f'{v // 3600:02d}:{(v % 3600) // 60:02d}'


def download(feed):
    os.makedirs(RAW, exist_ok=True)
    url = FEEDS[feed][0]
    path = os.path.join(RAW, f'{feed}.zip')
    print(f'  indiriliyor {feed}: {url}')
    req = urllib.request.Request(
        url, headers={'User-Agent': 'StopAlert/1.0 (transit alarm; build)'})
    with urllib.request.urlopen(req, timeout=120) as r:
        data = r.read()
    with open(path, 'wb') as f:
        f.write(data)
    return path


class Feed:
    """Bir GTFS zip'ini (kök ya da tek alt klasör) okur."""

    def __init__(self, path):
        self.zf = zipfile.ZipFile(path)
        names = self.zf.namelist()
        # ferry zip'i tek bir alt klasöre gömülü (ship-izdeniz-gtfs/).
        self.prefix = ''
        roots = {n.split('/', 1)[0] for n in names if '/' in n}
        if not any(n.endswith('routes.txt') and '/' not in n for n in names):
            for r in roots:
                if f'{r}/routes.txt' in names:
                    self.prefix = r + '/'
                    break

    def rows(self, name):
        try:
            raw = self.zf.read(self.prefix + name)
        except KeyError:
            return []
        text = raw.decode('utf-8-sig', errors='replace')
        return list(csv.DictReader(io.StringIO(text)))

    def raw_lines(self, name):
        try:
            raw = self.zf.read(self.prefix + name)
        except KeyError:
            return []
        return raw.decode('utf-8-sig', errors='replace').splitlines()


def parse_stops(feed_obj, feed_name):
    """stop_id -> (name, lat, lon). Ferry stops.txt lat/lon'u ONDALIK VİRGÜLLÜ
    yazıp CSV'yi bozuyor ('38,4186,27,1258') → elle ayrıştırılır."""
    out = {}
    if feed_name == 'ferry':
        lines = feed_obj.raw_lines('stops.txt')
        for ln in lines[1:]:
            p = [x.strip() for x in ln.split(',')]
            # stop_id,stop_name,lat_int,lat_frac,lon_int,lon_frac,zone
            if len(p) < 6 or not p[0]:
                continue
            sid = p[0]
            # ad virgül içermiyor (doğrulandı); son 5 alan lat/lon/zone.
            name = p[1]
            try:
                lat = float(f'{p[-5]}.{p[-4]}')
                lon = float(f'{p[-3]}.{p[-2]}')
            except (ValueError, IndexError):
                continue
            out[sid] = (name, lat, lon)
        return out
    for s in feed_obj.rows('stops.txt'):
        try:
            out[s['stop_id']] = ((s.get('stop_name') or '').strip(),
                                 float(s['stop_lat']), float(s['stop_lon']))
        except (ValueError, KeyError, TypeError):
            continue
    return out


def day_types(cal_row):
    out = set()
    if any(cal_row.get(d) == '1' for d in
           ('monday', 'tuesday', 'wednesday', 'thursday', 'friday')):
        out.add('I')
    if cal_row.get('saturday') == '1':
        out.add('C')
    if cal_row.get('sunday') == '1':
        out.add('P')
    return out


def tram_code(long_name, route_id):
    n = long_name or route_id
    for w in ('Tramvayı', 'Ring Hat', 'İç Hat', 'Dış Hat', 'Hattı', 'Hat',
              'Mavi', 'Kırmızı', 'Turuncu', 'Yeşil', 'Sarı', '(', ')'):
        n = n.replace(w, ' ')
    n = ' '.join(n.split())
    return n or route_id


def short_place(name):
    """Kod için kısa yer adı: 'Bostanlı İskelesi' -> 'Bostanlı'."""
    n = name or ''
    for w in (' İskelesi', ' Iskelesi', ' İsk.', ' Vapur İskelesi', ' İstasyonu'):
        n = n.replace(w, '')
    return n.strip() or name


def endpoints(seq):
    """(ilk ad, dönüş ad). Gidiş-dönüş (ilk==son) ise ortadaki durağı al."""
    first = seq[0][1]
    last = seq[-1][1]
    if first == last and len(seq) > 2:
        last = seq[len(seq) // 2][1]
    return first, last


def build_feed(feed_name, path, out):
    _url, kind, operator, offset = FEEDS[feed_name]
    fe = Feed(path)
    routes = {r['route_id']: r for r in fe.rows('routes.txt')}
    calendar = fe.rows('calendar.txt')
    days_by_service = {c['service_id']: day_types(c) for c in calendar}
    stop_info = parse_stops(fe, feed_name)

    # trips: trip_id -> (route_id, service_id, dir)
    trip_meta = {}
    for t in fe.rows('trips.txt'):
        trip_meta[t['trip_id']] = (
            t.get('route_id', ''), t.get('service_id', ''),
            (t.get('direction_id') or '0'))

    # stop_times TAMAMI (bu beslemeler küçük) — trip'e göre grupla + sırala.
    by_trip = defaultdict(list)
    for r in fe.rows('stop_times.txt'):
        tid = r.get('trip_id')
        if tid not in trip_meta:
            continue
        try:
            by_trip[tid].append((
                int(r['stop_sequence']), r['stop_id'],
                r.get('arrival_time', ''), r.get('departure_time', '')))
        except (ValueError, KeyError):
            continue
    for v in by_trip.values():
        v.sort()

    # rep: (route_id, dir) -> en çok duraklı trip.  departures: aynı anahtar.
    rep = {}
    departures = defaultdict(lambda: defaultdict(set))
    for tid, (rid, sv, d) in trip_meta.items():
        st = by_trip.get(tid)
        if not st or len(st) < 2:
            continue
        key = (rid, d)
        if key not in rep or len(st) > len(by_trip[rep[key]]):
            rep[key] = tid
        first = clock(st[0][3] or st[0][2])
        if first:
            for day in days_by_service.get(sv, ()):
                departures[key][day].add(first)

    # rep'leri işleyip hat/durak/kalkış satırları üret.
    lines_out = []   # (rid, dir, code, yon_pref, name, color, seq_stops, deps)
    for (rid, d), tid in rep.items():
        route = routes.get(rid, {})
        st = by_trip[tid]
        seq = []
        for _seqno, sid, arr, dep in st:
            info = stop_info.get(sid)
            if not info:
                continue
            seq.append((offset + int(sid) if str(sid).isdigit()
                        else offset, info[0], info[1], info[2], arr, dep))
        if len(seq) < 2:
            continue
        short = (route.get('route_short_name') or '').strip()
        long_name = (route.get('route_long_name') or '').strip()
        if short:
            code = short
        elif feed_name == 'tram':
            code = tram_code(long_name, rid)
        else:
            a, b = endpoints(seq)
            ends = sorted([short_place(a), short_place(b)], key=str.upper)
            code = f'{ends[0]}–{ends[1]}'
        color = ('#' + (route.get('route_color') or '').strip().upper()) \
            if len((route.get('route_color') or '').strip()) == 6 else ''
        name = long_name or f'{seq[0][1]} - {seq[-1][1]}'
        # Yön: uçların alfabetik sırası (karşı yönleri G/D eşler).
        fa, fb = endpoints(seq)
        yon = 'G' if fa.upper() <= fb.upper() else 'D'
        lines_out.append(
            (rid, d, code, yon, name, color, seq, departures.get((rid, d), {})))

    return kind, operator, lines_out


def merge(all_feeds):
    if not os.path.exists(OUT):
        print(f'HATA: {OUT} yok — önce build_izmir.py çalıştır.', file=sys.stderr)
        return 1
    db = sqlite3.connect(OUT)
    db.execute('''CREATE TABLE IF NOT EXISTS departures(
                    line_id TEXT, day TEXT, time TEXT)''')
    db.execute('CREATE INDEX IF NOT EXISTS idx_dep_line ON departures(line_id)')

    # Eski ray kayıtlarını temizle (otobüse dokunma): tür bus/metrobus DIŞI
    # olan ya da R: önekli hatlar + 90M üstü duraklar.
    old = [r[0] for r in db.execute(
        "SELECT id FROM lines WHERE id LIKE 'R:%'")]
    if old:
        marks = ','.join('?' * len(old))
        db.execute(f'DELETE FROM line_stops WHERE line_id IN ({marks})', old)
        db.execute(f'DELETE FROM departures WHERE line_id IN ({marks})', old)
        db.execute(f'DELETE FROM lines WHERE id IN ({marks})', old)
    db.execute('DELETE FROM stops WHERE id >= 90000000')

    line_rows, ls_rows, dep_rows, used_stops = [], [], [], {}
    seen = set()
    for kind, operator, lines_out in all_feeds:
        for rid, d, code, yon, name, color, seq, deps in lines_out:
            lid = f'{RAIL_LINE_PREFIX}{code}_{yon}'
            n = 2
            while lid in seen:
                lid = f'{RAIL_LINE_PREFIX}{code}_{yon}{n}'
                n += 1
            seen.add(lid)
            lname = name if ' - ' in name else f'{seq[0][1]} - {seq[-1][1]}'
            line_rows.append((lid, code, lname, norm(lname), yon, 0, kind,
                              color, operator))
            prev_dep = seq[0][5] or seq[0][4]
            for k, (sid, sname, lat, lon, arr, dep) in enumerate(seq):
                used_stops[sid] = (sname, lat, lon)
                if k == 0:
                    sec = 0
                else:
                    g = secs(arr or dep)
                    p = secs(prev_dep)
                    sec = (g - p) if (g is not None and p is not None) else None
                    sec = int(max(20, min(1800, sec))) if sec and sec > 0 else 90
                prev_dep = dep or arr
                ls_rows.append((lid, k, sid, sec))
            for day, times in deps.items():
                for tm in sorted(times):
                    dep_rows.append((lid, day, tm))

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
    size = os.path.getsize(OUT) / 1024 / 1024
    print(f'\nBİRLEŞTİRİLDİ: {OUT}  ({size:.1f} MB)')
    by_type = db.execute(
        "SELECT type, COUNT(*) FROM lines GROUP BY type ORDER BY type")
    for t, c in by_type.fetchall():
        print(f'  {t}: {c} hat-yön')
    for tbl in ('lines', 'stops', 'departures'):
        n = db.execute(f'SELECT COUNT(*) FROM {tbl}').fetchone()[0]
        print(f'  toplam {tbl}: {n}')
    db.close()
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--offline', action='store_true',
                    help='indirmeden raw_rail/*.zip ile')
    a = ap.parse_args()
    feeds = []
    for name in FEEDS:
        path = os.path.join(RAW, f'{name}.zip')
        if not a.offline:
            path = download(name)
        if not os.path.exists(path):
            print(f'  atlandı (zip yok): {name}')
            continue
        kind, operator, lines_out = build_feed(name, path, OUT)
        print(f'  {name}: {len(lines_out)} hat-yön ({kind}/{operator})')
        feeds.append((kind, operator, lines_out))
    return merge(feeds)


if __name__ == '__main__':
    sys.exit(main())
