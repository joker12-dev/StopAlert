#!/usr/bin/env python3
"""İzmir toplu taşıma veritabanını (izmir.sqlite) ESHOT açık GTFS'inden üretir.

KAYNAK: İzmir Büyükşehir Belediyesi / ESHOT — Toplu Ulaşım GTFS Verisi.
Lisans CC BY 4.0 (ATIF ZORUNLU). Otobüs GTFS'i:
    https://www.eshot.gov.tr/gtfs/bus-eshot-gtfs.zip
(Portal: acikveri.bizizmir.com/tr/dataset/toplu-ulasim-gtfs-verileri)

Kocaeli'nin aksine İzmir GTFS'inde `stop_times.txt` VAR: durak sırası ve
GERÇEK segment süreleri doğrudan üretilir (site kazıma / geometri izdüşümü
gerekmez). Bu yönüyle İETT (build_db.py) desenine yakındır.

KRİTİK: GTFS `stop_id` ile canlı API `durakId` AYNI kimlik uzayı
(doğrulandı: 10005=Bahribaba, 10030=Konak) — canlı otobüs entegrasyonu
doğrudan bu id ile çalışır.

Çıktı şeması uygulamayla birebir (bkz. transit_db.dart / build_kocaeli.py):
  stops(id, name, name_norm, direction, district, lat, lon)
  lines(id, code, name, name_norm, dir, depar, type, color, operator)
  line_stops(line_id, seq, stop_id, seconds)
  departures(line_id, day, time)      -- gün: I/C/P (hafta içi/cmt/pazar)
  meta(key, value)

Kullanım:  python build_izmir.py            # GTFS indir + üret
           python build_izmir.py --offline # raw/ klasöründeki dosyalarla üret
"""
import argparse
import csv
import io
import os
import sqlite3
import sys
import time
import urllib.request
import zipfile

BUS_GTFS_URL = 'https://www.eshot.gov.tr/gtfs/bus-eshot-gtfs.zip'
ATTRIBUTION = 'Veri: İzmir Büyükşehir Belediyesi / ESHOT (CC BY 4.0)'

HERE = os.path.dirname(os.path.abspath(__file__))
RAW = os.path.join(HERE, 'raw')
OUT = os.path.join(HERE, 'izmir.sqlite')

# Kalabalık paket olmasın: stop_times DEV (88 MB). csv alan sınırını büyüt.
csv.field_size_limit(1 << 24)


def norm(s):
    """Arama anahtarı — uygulamadaki transitNorm ile birebir aynı olmalı."""
    out = []
    for ch in (s or ''):
        out.append({'İ': 'i', 'I': 'i', 'ı': 'i', 'Ö': 'o', 'ö': 'o',
                    'Ü': 'u', 'ü': 'u', 'Ş': 's', 'ş': 's', 'Ç': 'c',
                    'ç': 'c', 'Ğ': 'g', 'ğ': 'g'}.get(ch, ch))
    return ''.join(out).lower()


def download():
    os.makedirs(RAW, exist_ok=True)
    print(f'indiriliyor: {BUS_GTFS_URL}')
    req = urllib.request.Request(
        BUS_GTFS_URL,
        headers={'User-Agent': 'StopAlert/1.0 (transit alarm app; build)'})
    with urllib.request.urlopen(req, timeout=240) as r:
        data = r.read()
    print(f'  {len(data):,} bayt — açılıyor')
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        z.extractall(RAW)
    # ESHOT sürüm tarihi calendar start_date'ten alınır.
    return time.strftime('%Y%m%d')


def read_csv(name):
    path = os.path.join(RAW, name)
    with open(path, encoding='utf-8-sig', newline='') as f:
        return list(csv.DictReader(f))


def secs_between(t0, t1):
    """'HH:MM:SS' iki saat arası saniye (24 saati aşabilir). Bozuksa None."""
    try:
        a = [int(x) for x in t0.split(':')]
        b = [int(x) for x in t1.split(':')]
        return (b[0] * 3600 + b[1] * 60 + b[2]) - (a[0] * 3600 + a[1] * 60 + a[2])
    except Exception:
        return None


def hhmm(t):
    """'06:15:00' -> '06:15' (24+ saatleri de sadeleştirir)."""
    p = (t or '').split(':')
    if len(p) < 2:
        return None
    try:
        return f'{int(p[0]) % 24:02d}:{int(p[1]):02d}'
    except Exception:
        return None


def build(version):
    print('routes/trips/stops/calendar okunuyor…')
    routes = {r['route_id']: r for r in read_csv('routes.txt')}
    stops_raw = {r['stop_id']: r for r in read_csv('stops.txt')}
    calendar = read_csv('calendar.txt')

    # service_id -> hangi gün tipleri (I=hafta içi, C=cumartesi, P=pazar).
    day_of_service = {}
    for c in calendar:
        codes = []
        if any(c.get(d) == '1' for d in
               ('monday', 'tuesday', 'wednesday', 'thursday', 'friday')):
            codes.append('I')
        if c.get('saturday') == '1':
            codes.append('C')
        if c.get('sunday') == '1':
            codes.append('P')
        day_of_service[c['service_id']] = codes

    # trips: trip_id -> (route_id, service_id, direction_id)
    trip_meta = {}
    for t in read_csv('trips.txt'):
        trip_meta[t['trip_id']] = (
            t['route_id'], t.get('service_id', ''),
            (t.get('direction_id') or '0'))
    print(f'  route={len(routes)}  stop={len(stops_raw)}  trip={len(trip_meta)}')

    # ---- stop_times PASS 1: her trip'in durak sayısı + ilk kalkış saati ----
    print('stop_times pass 1 (sayım + kalkış)…')
    trip_count = {}
    trip_firstdep = {}
    stp = os.path.join(RAW, 'stop_times.txt')
    with open(stp, encoding='utf-8', errors='replace', newline='') as f:
        rd = csv.DictReader(f)
        for r in rd:
            tid = r['trip_id']
            trip_count[tid] = trip_count.get(tid, 0) + 1
            if r.get('stop_sequence') in ('1', '0') and tid not in trip_firstdep:
                trip_firstdep[tid] = r.get('departure_time') or r.get('arrival_time')

    # (route_id, dir) -> en çok duraklı temsili trip.
    rep = {}
    for tid, (rid, _sv, d) in trip_meta.items():
        key = (rid, d)
        cnt = trip_count.get(tid, 0)
        if cnt < 2:
            continue
        if key not in rep or cnt > rep[key][1]:
            rep[key] = (tid, cnt)
    rep_trips = {tid for tid, _ in rep.values()}
    print(f'  temsili trip: {len(rep_trips)}  (hat-yön varyantı)')

    # ---- stop_times PASS 2: temsili trip'lerin sıralı durak + süreleri ----
    print('stop_times pass 2 (sıralı duraklar)…')
    seq_rows = {}   # tid -> [(seq, stop_id, arr, dep)]
    with open(stp, encoding='utf-8', errors='replace', newline='') as f:
        rd = csv.DictReader(f)
        for r in rd:
            tid = r['trip_id']
            if tid not in rep_trips:
                continue
            try:
                seq_rows.setdefault(tid, []).append((
                    int(r['stop_sequence']), r['stop_id'],
                    r.get('arrival_time', ''), r.get('departure_time', '')))
            except (ValueError, KeyError):
                continue

    # ---- DB ----
    if os.path.exists(OUT):
        os.remove(OUT)
    db = sqlite3.connect(OUT)
    db.executescript('''
      PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF;
      CREATE TABLE stops(id INTEGER PRIMARY KEY, name TEXT, name_norm TEXT,
                         direction TEXT, district TEXT, lat REAL, lon REAL);
      CREATE TABLE lines(id TEXT PRIMARY KEY, code TEXT, name TEXT,
                         name_norm TEXT, dir TEXT, depar INTEGER, type TEXT,
                         color TEXT, operator TEXT);
      CREATE TABLE line_stops(line_id TEXT, seq INTEGER, stop_id INTEGER,
                              seconds INTEGER);
      CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
      CREATE TABLE departures(line_id TEXT, day TEXT, time TEXT);
      CREATE INDEX idx_dep_line ON departures(line_id);
    ''')

    line_rows, ls_rows = [], []
    used_stops = {}
    seen_ids = set()
    # (route_id,dir) -> line_id  (departures'ı bağlamak için)
    line_id_of = {}

    for (rid, d), (tid, _cnt) in sorted(rep.items()):
        route = routes.get(rid)
        if not route:
            continue
        rows = sorted(seq_rows.get(tid, []))
        if len(rows) < 2:
            continue
        code = (route.get('route_short_name') or '').strip() or rid
        yon = 'G' if str(d) == '0' else 'D'
        lid = f'{code}_{yon}'
        n = 2
        while lid in seen_ids:
            lid = f'{code}_{yon}{n}'
            n += 1
        seen_ids.add(lid)
        line_id_of[(rid, d)] = lid

        # sıralı duraklar + gerçek segment süreleri
        seq_stops = []
        for seq, sid, arr, dep in rows:
            s = stops_raw.get(sid)
            if not s:
                continue
            try:
                lat = float(s['stop_lat'])
                lon = float(s['stop_lon'])
            except (ValueError, KeyError):
                continue
            seq_stops.append((int(sid) if sid.isdigit() else sid,
                              s.get('stop_name', '').strip(), lat, lon, arr, dep))
        if len(seq_stops) < 2:
            continue

        # AD YÖNE ÖZEL: route_long_name gidiş/dönüşte AYNI ("A - B") oluyor ve
        # kullanıcı iki yönü ayırt edemiyordu; bu yönün GERÇEK ilk→son durağını
        # yaz (gidiş "A - B", dönüş "B - A").
        lname = f'{seq_stops[0][1]} - {seq_stops[-1][1]}'
        line_rows.append((lid, code, lname, norm(lname), yon, 0, 'bus', '',
                          'ESHOT'))
        prev_dep = seq_stops[0][5] or seq_stops[0][4]
        for k, (sid, name, lat, lon, arr, dep) in enumerate(seq_stops):
            used_stops.setdefault(sid, (name, lat, lon))
            if k == 0:
                sec = 0
            else:
                dt = secs_between(prev_dep, arr)
                sec = int(max(20, min(600, dt))) if dt and dt > 0 else 45
            prev_dep = dep or arr
            ls_rows.append((lid, k, sid, sec))

    # ---- departures: her trip'in ilk kalkışı, gün tipine göre ----
    dep_rows = []
    for tid, (rid, sv, d) in trip_meta.items():
        lid = line_id_of.get((rid, d))
        if not lid:
            continue
        t = hhmm(trip_firstdep.get(tid))
        if not t:
            continue
        for day in day_of_service.get(sv, ()):
            dep_rows.append((lid, day, t))
    # aynı (lid,day,time) tekrarını at
    dep_rows = list({r for r in dep_rows})

    db.executemany('INSERT OR IGNORE INTO lines VALUES(?,?,?,?,?,?,?,?,?)',
                   line_rows)
    db.executemany('INSERT INTO line_stops VALUES(?,?,?,?)', ls_rows)
    db.executemany('INSERT INTO departures VALUES(?,?,?)', dep_rows)

    # ---- durak yönü: hatlardan türet (Kocaeli ile aynı yöntem) ----
    from collections import Counter
    last_name = {r[0]: r[2].split(' - ')[-1].strip() for r in line_rows}
    seq_max, votes = {}, {}
    for lid, k, sid, sec in ls_rows:
        seq_max[lid] = max(seq_max.get(lid, 0), k)
    for lid, k, sid, sec in ls_rows:
        if k >= seq_max.get(lid, 0):
            continue
        dest = last_name.get(lid, '')
        if dest:
            votes.setdefault(sid, Counter())[dest] += 1

    def direction_of(sid):
        c = votes.get(sid)
        return c.most_common(1)[0][0] if c else ''

    db.executemany('INSERT OR IGNORE INTO stops VALUES(?,?,?,?,?,?,?)', [
        (sid, v[0], norm(v[0]), direction_of(sid), '', v[1], v[2])
        for sid, v in used_stops.items()
    ])
    db.executescript('''
      CREATE INDEX ix_stops_lat ON stops(lat);
      CREATE INDEX ix_stops_lon ON stops(lon);
      CREATE INDEX ix_ls_line ON line_stops(line_id);
      CREATE INDEX ix_ls_stop ON line_stops(stop_id);
    ''')
    for k, v in [('city', 'izmir'), ('source', ATTRIBUTION),
                 ('version', version), ('lines', str(len(line_rows))),
                 ('stops', str(len(used_stops)))]:
        db.execute('INSERT INTO meta VALUES(?,?)', (k, v))
    db.commit()
    db.execute('VACUUM')
    db.close()

    size = os.path.getsize(OUT) / 1024 / 1024
    print(f'\nYAZILDI: {OUT}  ({size:.1f} MB)')
    print(f'  hat(yön): {len(line_rows)}  durak: {len(used_stops)}  '
          f'kalkış: {len(dep_rows)}')
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--offline', action='store_true',
                    help='indirmeden, mevcut raw/ ile üret')
    a = ap.parse_args()
    version = time.strftime('%Y%m%d')
    if not a.offline:
        version = download()
    return build(version)


if __name__ == '__main__':
    sys.exit(main())
