#!/usr/bin/env python3
"""Resmi İETT verisine (fetch_official.py) GTFS'ten DEPAR güzergâhlarını ekler.

Resmi `DurakDetay_GYY` servisi yalnızca ANA gidiş/dönüş güzergâhını verir;
İETT'nin sitesinde ayrıca listelenen "Depar Güzergahları" (garaj/özel sefer)
yalnızca GTFS'te bulunur. Bu script ikisini birleştirir:

    bus_official.sqlite  (resmi: depar=0, yetkili YON/SIRANO/koordinat)
  + GTFS csv'leri        (depar=1 varyantlar)
  = bus.sqlite

Eşleme: GTFS `stop_code` == resmi `DURAKKODU` (doğrulandı).
Normal/depar ayrımı: uç noktaları TERS olarak da bulunan varyant normaldir
(gidiş↔dönüş çifti); kalanlar depar sayılır ve YALNIZCA onlar eklenir.

Kullanım: python merge_depar.py   (aynı klasörde GTFS csv'leri + bus_official.sqlite)
"""
import csv
import os
import shutil
import sqlite3
import sys
import time

DEFAULT_SEG = 90

# METROBÜS: İETT işletir ama kendi yolunda (metro gibi) çalışır; kullanıcı için
# ayrı tür olarak işaretlenir — kaynak veride tür ayrımı yok.
METROBUS_CODES = {'34', '34A', '34AS', '34BZ', '34C', '34G', '34Z', '34K'}

_TR_MAP = {'İ': 'i', 'I': 'i', 'ı': 'i', 'Ö': 'o', 'ö': 'o', 'Ü': 'u',
           'ü': 'u', 'Ş': 's', 'ş': 's', 'Ç': 'c', 'ç': 'c', 'Ğ': 'g',
           'ğ': 'g'}


def norm(s):
    s = s or ''
    for a, b in _TR_MAP.items():
        s = s.replace(a, b)
    return s.lower()


def fix_mojibake(s):
    if not s:
        return s
    for enc in ('cp1252', 'latin-1'):
        try:
            return s.encode(enc).decode('utf-8')
        except (UnicodeEncodeError, UnicodeDecodeError):
            continue
    return s


def coord(s):
    """GTFS bozuk koordinat: '410.191.700.005.564' -> 41.0191700005564"""
    s = (s or '').strip()
    if not s:
        return None
    if s.count('.') <= 1:
        try:
            return float(s)
        except ValueError:
            return None
    d = s.replace('.', '').replace(',', '')
    if len(d) < 3:
        return None
    try:
        return float(d[:2] + '.' + d[2:])
    except ValueError:
        return None


def hms(s):
    p = (s or '').strip().split(':')
    if len(p) != 3:
        return None
    try:
        return int(p[0]) * 3600 + int(p[1]) * 60 + int(p[2])
    except ValueError:
        return None


def main(gtfs_dir=None):
    here = os.path.dirname(os.path.abspath(__file__))
    base = gtfs_dir or here          # GTFS csv/txt'lerin bulunduğu klasör
    src = os.path.join(here, 'bus_official.sqlite')
    out = os.path.join(here, 'bus.sqlite')
    if not os.path.exists(src):
        print('HATA: önce fetch_official.py çalıştır (bus_official.sqlite yok)')
        return 1
    t0 = time.time()
    shutil.copy(src, out)
    db = sqlite3.connect(out)

    # --- GTFS: otobüs route'ları + yön etiketi ---
    routes = {}
    with open(os.path.join(base, 'routes.csv'), encoding='utf-8-sig') as f:
        for r in csv.DictReader(f, delimiter=';'):
            if r.get('route_type') != '3':
                continue
            rid = r['route_id'].lstrip('﻿')
            parts = (r.get('route_code') or '').split('_')
            d = parts[1] if len(parts) >= 2 and parts[1] in ('G', 'D') else ''
            routes[rid] = ((r.get('route_short_name') or '').strip() or rid, d)

    trip_route = {}
    with open(os.path.join(base, 'trips.csv'), encoding='utf-8-sig') as f:
        for r in csv.DictReader(f, delimiter=';'):
            rid = r['route_id']
            if rid in routes:
                trip_route[r['trip_id'].lstrip('﻿')] = rid

    # --- GTFS duraklar: stop_id -> (kod, ad, lat, lon) ---
    gstops = {}
    with open(os.path.join(base, 'stops.csv'), encoding='utf-8-sig') as f:
        for r in csv.DictReader(f, delimiter=';'):
            sid = (r.get('stop_id') or '').lstrip('﻿').strip()
            code = (r.get('stop_code') or '').strip()
            lat, lon = coord(r.get('stop_lat')), coord(r.get('stop_lon'))
            if not sid or not code or lat is None or lon is None:
                continue
            if not (40.5 <= lat <= 42.2 and 27.5 <= lon <= 30.2):
                continue
            gstops[sid] = (code, (r.get('stop_name') or '').strip(), lat, lon)

    # --- stop_times: temsili trip seçimi (en çok duraklı) ---
    counts = {}
    with open(os.path.join(base, 'stop_times.txt'), encoding='utf-8',
              errors='replace') as f:
        rd = csv.reader(f)
        next(rd, None)
        for row in rd:
            if row and row[0] in trip_route:
                counts[row[0]] = counts.get(row[0], 0) + 1
    best_trip = {}
    for tid, c in counts.items():
        rid = trip_route[tid]
        if rid not in best_trip or c > best_trip[rid][0]:
            best_trip[rid] = (c, tid)
    rep = {tid: rid for rid, (_, tid) in best_trip.items()}

    seq = {}
    with open(os.path.join(base, 'stop_times.txt'), encoding='utf-8',
              errors='replace') as f:
        rd = csv.reader(f)
        next(rd, None)
        for row in rd:
            if len(row) < 4 or row[0] not in rep:
                continue
            try:
                seq.setdefault(row[0], []).append(
                    (int(row[2]), row[1], hms(row[3])))
            except ValueError:
                continue

    # --- temiz varyantlar (isme göre tekilleştir: tur seferini yarıya indirir) ---
    cands = {}
    for tid, rid in rep.items():
        seen, clean = set(), []
        for (_, sid, arr) in sorted(seq.get(tid, [])):
            g = gstops.get(sid)
            if not g or g[1] in seen or not g[1]:
                continue
            seen.add(g[1])
            clean.append((g, arr))
        if len(clean) >= 2:
            cands[rid] = (routes[rid][0], routes[rid][1], clean)

    # --- normal (resiprok) vs depar ---
    by_code = {}
    for rid, (code, d, clean) in cands.items():
        by_code.setdefault(code, []).append((rid, d, clean))

    line_rows, ls_rows, new_stops = [], [], {}
    added = 0
    for code, variants in by_code.items():
        pairs = {(v[2][0][0][1], v[2][-1][0][1]) for v in variants}
        for (rid, d, clean) in variants:
            first, last = clean[0][0][1], clean[-1][0][1]
            if first != last and (last, first) in pairs:
                continue                     # normal güzergâh: resmi veride var
            lid = f'{code}_DEPAR_{rid}'
            name = f'{first} - {last}'
            ltype = 'metrobus' if code in METROBUS_CODES else 'bus'
            line_rows.append((lid, code, name, norm(name), d, 1, ltype))
            added += 1
            arrs = [a for (_, a) in clean]
            for i, ((scode, sname, lat, lon), _) in enumerate(clean):
                new_stops[int(scode)] = (sname, lat, lon)
                sec = DEFAULT_SEG
                if i > 0:
                    a_i = arrs[i]
                    j = i - 1
                    while j >= 0 and arrs[j] is None:
                        j -= 1
                    if a_i is not None and j >= 0 and arrs[j] is not None:
                        gap = a_i - arrs[j]
                        if gap < 0:
                            gap += 86400
                        if 0 < gap < 21600:
                            sec = max(1, round(gap / (i - j)))
                ls_rows.append((lid, i, int(scode), 0 if i == 0 else sec))

    # Resmi veride olmayan depar duraklarını ekle (ilçe bilgisi yok).
    have = {r[0] for r in db.execute('SELECT id FROM stops')}
    add_stops = [(sid, v[0], norm(v[0]), '', '', v[1], v[2])
                 for sid, v in new_stops.items() if sid not in have]

    db.executemany('INSERT OR IGNORE INTO stops VALUES(?,?,?,?,?,?,?)', add_stops)
    db.executemany('INSERT OR IGNORE INTO lines VALUES(?,?,?,?,?,?,?)', line_rows)
    db.executemany('INSERT INTO line_stops VALUES(?,?,?,?)', ls_rows)
    db.execute("UPDATE meta SET value=? WHERE key='source'",
               ('IETT resmi web servisi + GTFS depar',))
    db.execute("UPDATE meta SET value=(SELECT COUNT(*) FROM lines) WHERE key='lines'")
    db.execute("UPDATE meta SET value=(SELECT COUNT(*) FROM stops) WHERE key='stops'")
    db.commit()
    db.execute('VACUUM')
    n_lines = db.execute('SELECT COUNT(*) FROM lines').fetchone()[0]
    n_stops = db.execute('SELECT COUNT(*) FROM stops').fetchone()[0]
    db.close()
    print(f'DONE ({time.time()-t0:.0f}s): {out}')
    print(f'  eklenen depar güzergâh={added}  yeni durak={len(add_stops)}')
    print(f'  TOPLAM güzergâh={n_lines}  durak={n_stops}  '
          f'boyut={os.path.getsize(out)/1e6:.1f} MB')
    return 0


if __name__ == '__main__':
    import argparse
    p = argparse.ArgumentParser()
    p.add_argument('--gtfs', default=None,
                   help='GTFS csv/txt klasörü (varsayılan: script klasörü)')
    sys.exit(main(gtfs_dir=p.parse_args().gtfs))
