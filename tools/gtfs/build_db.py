#!/usr/bin/env python3
"""İETT GTFS -> StopAlert bus.sqlite dönüştürücü.

Girdi (aynı klasör): routes.csv, trips.csv, stops.csv (ayraç ';'),
stop_times.txt (ayraç ',').  Çıktı: bus.sqlite

Şema:
  stops(id INTEGER PK, name TEXT, lat REAL, lon REAL)
  lines(id TEXT PK, code TEXT, name TEXT, type TEXT='bus')
  line_stops(line_id TEXT, seq INTEGER, stop_id INTEGER, seconds INTEGER)
  meta(key TEXT PK, value TEXT)
Her otobüs hattı (route_id) için EN ÇOK duraklı temsili sefer seçilir;
segment süreleri timepoint arrival_time'larından çıkarılır, aradakiler eşit
bölünür, hiç yoksa DEFAULT_SEG saniye.
"""
import csv, sqlite3, sys, os, io, time

DEFAULT_SEG = 90  # timepoint yoksa varsayılan durak-arası süre (sn)

def fix_mojibake(s):
    """UTF-8 baytları cp1252/latin-1 olarak çift-kodlanmışsa düzelt
    (KADIKÃ–Y->KADIKÖY). Mojibake `–`(0x96) gibi karakterler cp1252'de olduğu
    için önce cp1252 denenir. Temiz dizeler değişmeden döner (decode hata verir)."""
    if not s:
        return s
    for enc in ('cp1252', 'latin-1'):
        try:
            return s.encode(enc).decode('utf-8')
        except (UnicodeEncodeError, UnicodeDecodeError):
            continue
    return s

def coord(s):
    s = (s or '').strip()
    if not s:
        return None
    if s.count('.') <= 1:
        try:
            return float(s)
        except ValueError:
            return None
    digits = s.replace('.', '').replace(',', '')
    if len(digits) < 3:
        return None
    try:
        return float(digits[:2] + '.' + digits[2:])
    except ValueError:
        return None

def hms(s):
    s = (s or '').strip()
    if not s:
        return None
    p = s.split(':')
    if len(p) != 3:
        return None
    try:
        return int(p[0]) * 3600 + int(p[1]) * 60 + int(p[2])
    except ValueError:
        return None

_TR_MAP = {'İ': 'i', 'I': 'i', 'ı': 'i', 'Ö': 'o', 'ö': 'o', 'Ü': 'u',
           'ü': 'u', 'Ş': 's', 'ş': 's', 'Ç': 'c', 'ç': 'c', 'Ğ': 'g',
           'ğ': 'g'}


def norm(s):
    """Aksan/Türkçe-duyarsız arama anahtarı: İ/ı→i, Ö→o, Ş→s... sonra küçük harf.
    Dart tarafı (TransitDb.norm) ile birebir aynı olmalı."""
    s = s or ''
    for a, b in _TR_MAP.items():
        s = s.replace(a, b)
    return s.lower()


def main():
    base = os.path.dirname(os.path.abspath(__file__))
    t0 = time.time()

    # ---- routes (bus only) ----
    routes = {}
    with open(os.path.join(base, 'routes.csv'), encoding='utf-8-sig') as f:
        for r in csv.DictReader(f, delimiter=';'):
            if r.get('route_type') != '3':
                continue
            rid = r['route_id'].lstrip('﻿')
            short = (r.get('route_short_name') or '').strip()
            long = fix_mojibake((r.get('route_long_name') or '').strip())
            # route_code ör. "MK13_G_D0" → G=gidiş, D=dönüş.
            rcode = (r.get('route_code') or '')
            parts = rcode.split('_')
            direction = parts[1] if (len(parts) >= 2 and parts[1] in ('G', 'D')) else ''
            routes[rid] = (short, long, direction)
    print(f'bus routes: {len(routes)}')

    # ---- trips: route_id -> [trip_id...] ----
    trip_route = {}
    with open(os.path.join(base, 'trips.csv'), encoding='utf-8-sig') as f:
        for r in csv.DictReader(f, delimiter=';'):
            tid = r['trip_id'].lstrip('﻿')
            rid = r['route_id']
            if rid in routes:
                trip_route[tid] = rid
    print(f'trips mapped to bus routes: {len(trip_route)}')

    # ---- stop_times pass 1: her trip'in durak sayısı ----
    trip_count = {}
    with open(os.path.join(base, 'stop_times.txt'), encoding='utf-8', errors='replace') as f:
        rd = csv.reader(f)
        next(rd, None)  # header
        for row in rd:
            if not row:
                continue
            tid = row[0]
            if tid in trip_route:
                trip_count[tid] = trip_count.get(tid, 0) + 1
    print(f'pass1 done ({time.time()-t0:.0f}s), trips with stops: {len(trip_count)}')

    # ---- her route için en çok duraklı temsili trip ----
    best = {}  # route_id -> (count, trip_id)
    for tid, cnt in trip_count.items():
        rid = trip_route[tid]
        if rid not in best or cnt > best[rid][0]:
            best[rid] = (cnt, tid)
    rep_trips = {tid: rid for rid, (_, tid) in best.items()}
    print(f'representative trips: {len(rep_trips)}')

    # ---- stop_times pass 2: temsili trip'lerin sıralı durakları ----
    seq = {}  # trip_id -> list[(stop_sequence, stop_id, arr_sec)]
    with open(os.path.join(base, 'stop_times.txt'), encoding='utf-8', errors='replace') as f:
        rd = csv.reader(f)
        next(rd, None)
        for row in rd:
            if len(row) < 4:
                continue
            tid = row[0]
            if tid not in rep_trips:
                continue
            try:
                ss = int(row[2])
            except ValueError:
                continue
            seq.setdefault(tid, []).append((ss, row[1], hms(row[3])))
    print(f'pass2 done ({time.time()-t0:.0f}s)')

    # ---- stops ----
    stops = {}
    with open(os.path.join(base, 'stops.csv'), encoding='utf-8-sig') as f:
        for r in csv.DictReader(f, delimiter=';'):
            sid = (r.get('stop_id') or '').lstrip('﻿').strip()
            if not sid:
                continue
            lat = coord(r.get('stop_lat'))
            lon = coord(r.get('stop_lon'))
            if lat is None or lon is None:
                continue
            if not (40.5 <= lat <= 42.2 and 27.5 <= lon <= 30.2):
                continue
            # stop_desc genelde "direction: AVCILAR" — aynı adlı durakları
            # ayırmak için yön bilgisini çıkar.
            desc = (r.get('stop_desc') or '').strip()
            direction = ''
            if 'direction:' in desc.lower():
                direction = desc.split(':', 1)[1].strip()
            stops[sid] = (r.get('stop_name', '').strip(), lat, lon, direction)
    print(f'valid stops: {len(stops)}')

    # ---- SQLite yaz ----
    out = os.path.join(base, 'bus.sqlite')
    if os.path.exists(out):
        os.remove(out)
    db = sqlite3.connect(out)
    db.executescript('''
      PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF;
      CREATE TABLE stops(id INTEGER PRIMARY KEY, name TEXT, name_norm TEXT, direction TEXT, lat REAL, lon REAL);
      CREATE TABLE lines(id TEXT PRIMARY KEY, code TEXT, name TEXT, name_norm TEXT, dir TEXT, depar INTEGER, type TEXT);
      CREATE TABLE line_stops(line_id TEXT, seq INTEGER, stop_id INTEGER, seconds INTEGER);
      CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
    ''')

    # 1) Her route_id için temsili seferin TEMİZ durak dizisi: koordinatlı +
    #    ilk-görülen (gidiş-dönüş tekrarını atar; 51→26 sorunu).
    candidates = {}  # route_id -> (code, dir, clean_pts=[(sid, arr)])
    for tid, rid in rep_trips.items():
        rows = sorted(seq.get(tid, []), key=lambda x: x[0])
        # İSME göre ilk-görülen tekilleştirme: bir tur (git-dön) seferinde
        # dönüş durakları FARKLI stop_id (karşı yaka) taşıdığından id'ye göre
        # yakalanmaz; ada göre tekilleştirmek turu tek yöne indirir.
        seen = set()
        clean = []
        for (_, sid, arr) in rows:
            if sid not in stops:
                continue
            nm = stops[sid][0]
            if not nm or nm in seen:
                continue
            seen.add(nm)
            clean.append((sid, arr))
        if len(clean) < 2:
            continue
        candidates[rid] = ((routes[rid][0] or rid), routes[rid][2], clean)

    # 2) VARYANTLARI KORU ama tekrarları at: aynı hat no + aynı uç noktalar
    #    (biniş→iniş) → tek temsilci (en uzun). Farklı uç noktalı varyantlar
    #    (MK13'ün Olimpiyatköy-İGTOT / Aşık Veysel-… gibi) ayrı kalır. dir (G/D)
    #    hat detay sayfasında gidiş/dönüş ayrımı için taşınır.
    best = {}  # (code, first_sid, last_sid) -> (route_id, dir, clean_pts)
    for rid, (code, dir_, clean) in candidates.items():
        key = (code, clean[0][0], clean[-1][0])
        cur = best.get(key)
        if cur is None or len(clean) > len(cur[2]):
            best[key] = (rid, dir_, clean)

    used_stops = set()
    line_rows = []
    ls_rows = []
    kept_lines = 0

    # Kod başına varyantları grupla; NORMAL (gidiş↔dönüş resiprok) ile DEPAR
    # (garaj/özel sefer) ayrımını uç nokta adlarından yap.
    by_code = {}
    for (code, _fs, _ls), (rid, dir_, clean) in best.items():
        fn = stops[clean[0][0]][0]
        ln = stops[clean[-1][0]][0]
        by_code.setdefault(code, []).append((rid, dir_, clean, fn, ln))

    for code, variants in by_code.items():
        namepairs = {(v[3], v[4]) for v in variants}
        for (rid, dir_, clean, fn, ln) in variants:
            # Normal = uç noktaları başka bir varyantta TERS yönde de var
            # (gidiş↔dönüş çifti). Aksi halde depar.
            is_depar = 0 if (fn != ln and (ln, fn) in namepairs) else 1
            name = f'{fn} - {ln}' if (fn and ln) else code
            line_rows.append((rid, code, name, norm(name), dir_, is_depar, 'bus'))
            kept_lines += 1
            arrs = [a for (_, a) in clean]
            for i, (sid, _) in enumerate(clean):
                used_stops.add(sid)
                sec = 0 if i == 0 else _segment_seconds(arrs, i)
                ls_rows.append((rid, i, int(sid), sec))

    db.executemany('INSERT OR IGNORE INTO lines VALUES(?,?,?,?,?,?,?)', line_rows)
    db.executemany('INSERT INTO line_stops VALUES(?,?,?,?)', ls_rows)
    # stops: (id, name, name_norm, direction, lat, lon) — tüm duraklar.
    stop_rows = [(int(sid), v[0], norm(v[0]), v[3], v[1], v[2])
                 for sid, v in stops.items()]
    db.executemany('INSERT OR IGNORE INTO stops VALUES(?,?,?,?,?,?)', stop_rows)
    db.executescript('''
      CREATE INDEX ix_stops_lat ON stops(lat);
      CREATE INDEX ix_stops_lon ON stops(lon);
      CREATE INDEX ix_ls_line ON line_stops(line_id);
    ''')
    db.execute('INSERT INTO meta VALUES(?,?)', ('source', 'IETT GTFS data.ibb.gov.tr'))
    db.execute('INSERT INTO meta VALUES(?,?)', ('version', time.strftime('%Y%m%d')))
    db.execute('INSERT INTO meta VALUES(?,?)', ('lines', str(kept_lines)))
    db.execute('INSERT INTO meta VALUES(?,?)', ('stops', str(len(stop_rows))))
    db.commit()
    db.execute('VACUUM')
    db.close()
    sz = os.path.getsize(out)
    print(f'\nDONE ({time.time()-t0:.0f}s): {out}')
    print(f'  lines={kept_lines}  stops={len(stop_rows)}  line_stops={len(ls_rows)}')
    print(f'  size={sz/1e6:.1f} MB')


def _segment_seconds(arrs, i):
    """i. durağın bir önceki duraktan süresi. Timepoint boşluklarını eşit böl."""
    a_i = arrs[i]
    if a_i is not None:
        # geriye en yakın dolu timepoint'i bul
        j = i - 1
        while j >= 0 and arrs[j] is None:
            j -= 1
        if j >= 0 and arrs[j] is not None:
            gap = a_i - arrs[j]
            if gap < 0:
                gap += 24 * 3600  # gece yarısı taşması
            span = i - j
            if 0 < gap < 6 * 3600 and span > 0:
                return max(1, round(gap / span))
    return DEFAULT_SEG


if __name__ == '__main__':
    main()
