#!/usr/bin/env python3
"""Kocaeli toplu taşıma veritabanını (kocaeli.sqlite) resmi açık veriden üretir.

KAYNAK: Kocaeli Büyükşehir Belediyesi Açık Veri Portalı — "Toplu Ulaşım GTFS
Verisi" (Ulaşım Dairesi Başkanlığı / Toplu Taşıma Şube Müdürlüğü).
Lisans CC BY: ticari kullanım serbest, ATIF ZORUNLU.
    https://veri.kocaeli.bel.tr/datasets/e2a87342-d39a-4742-ae25-165e10d2bc72

Portalın herkese açık ucundan indirilir (`/api/public/OpenDataPublic/...`);
kimlik doğrulama gerektirmez.

NEDEN BU KAYNAK: Belediyenin web sitesinde duran `kocaeli-gtfs.zip` dosyası
12 Eylül 2018'den beri güncellenmemiş — içinde Akçaray T1 hâlâ "OTOGAR-
SEKAPARK" (11 durak) yazıyor, oysa hat bugün "OTOGAR-KURUÇEŞME" (16 durak).
Alarm kuran bir uygulamada var olmayan durağı göstermek kabul edilemez, o
yüzden yalnızca portal beslemesi kullanılır.

DURAK SIRASI NASIL ÜRETİLİR: Bu beslemede `stop_times.txt` YOK, yani "hangi
hat hangi durağa hangi sırayla uğrar" bilgisi hazır gelmiyor. İki kaynak
birleştirilir:

  1. YETKİLİ SIRA — belediyenin hat sayfası `kocaeli.bel.tr/hatlar/<KOD>/`
     her yön için sıralı durak tablosu veriyor (sıra no, DURAK NO, ad,
     koordinat). Oradaki "Durak No" ile GTFS `stop_id` BİREBİR aynı (aynı
     kimlik, aynı koordinat — doğrulandı), yani iki kaynak tek kimlik uzayını
     paylaşıyor. robots.txt bu yolu açıkça serbest bırakıyor.

  2. YEDEK — sitede sayfası olmayan hatlar (vapur/teleferik kodları farklı)
     için duraklar güzergâh geometrisine izdüşürülüp çizgi boyunca mesafeye
     göre sıralanır (bkz. [stops_along_shape]).

Yalnızca izdüşüm kullanılmıyor çünkü yetersiz: tramvay bulvar boyunca gittiği
için yanındaki OTOBÜS durakları da eşiğe giriyor ve T1'e 16 yerine 32 durak
çıkıyordu. Alarm kuran bir uygulamada uğranmayan durağı listelemek kabul
edilemez, o yüzden sıra mümkün olan her yerde yetkili kaynaktan alınır.

Kullanım:  python build_kocaeli.py            # indir + üret
           python build_kocaeli.py --offline  # önceden inen dosyalarla üret
"""
import argparse
import csv
import json
import math
import os
import shutil
import sqlite3
import ssl
import sys
import time
import urllib.request

DATASET_ID = 'e2a87342-d39a-4742-ae25-165e10d2bc72'
API = 'https://kavisacikveri.kocaeli.bel.tr/api/public/OpenDataPublic'
ATTRIBUTION = 'Veri: Kocaeli Büyükşehir Belediyesi Açık Veri Portalı (CC BY)'

HERE = os.path.dirname(os.path.abspath(__file__))
RAW = os.path.join(HERE, 'raw')
OUT = os.path.join(HERE, 'kocaeli.sqlite')

# GTFS route_type -> StopAlert hat türü.
TYPE_BY_GTFS = {
    '0': 'tram',
    '1': 'metro',
    '2': 'marmaray',
    '3': 'bus',
    '4': 'ferry',
    '5': 'tram',
    '6': 'cableCar',
    '7': 'funicular',
}

# Durak, güzergâh çizgisine en fazla bu kadar uzakta olabilir (metre).
# Dar tutuldu: yol kenarındaki başka hatlara ait duraklar sızmasın.
SNAP_METERS = 40.0

# Ardışık iki durak bu kadar yakınsa aynı durak sayılır (çift kayıt).
MIN_GAP_METERS = 60.0

_CTX = ssl.create_default_context()
_CTX.check_hostname = False
_CTX.verify_mode = ssl.CERT_NONE
_HEADERS = {
    'User-Agent': 'StopAlert/1.0 (transit alarm app; data build script)',
    'Accept': 'application/json',
    'Referer': 'https://veri.kocaeli.bel.tr/',
}


def fetch(url, timeout=240):
    req = urllib.request.Request(url, headers=_HEADERS)
    with urllib.request.urlopen(req, timeout=timeout, context=_CTX) as r:
        return r.read()


def download_feed():
    """Veri setinin ekli GTFS dosyalarını indirir; sürüm bilgisini döndürür."""
    meta = json.loads(fetch(f'{API}/{DATASET_ID}').decode('utf-8'))
    os.makedirs(RAW, exist_ok=True)
    print(f"veri seti: {meta['title']}  ({meta['licenseName']})")
    print(f"  yayınlayan: {meta['departmentName']} / {meta['directorateName']}")
    print(f"  son güncelleme: {meta['lastUpdated'][:10]}")
    for a in meta['attachments']:
        path = os.path.join(RAW, a['fileName'])
        data = fetch(f"{API}/attachments/{a['id']}/download")
        with open(path, 'wb') as f:
            f.write(data)
        print(f"  indi {a['fileName']:16} {len(data):>10,} bayt")
    return meta['lastUpdated'][:10].replace('-', '')


def read_csv(name):
    path = os.path.join(RAW, name)
    if not os.path.exists(path):
        return []
    with open(path, encoding='utf-8-sig', newline='') as f:
        return list(csv.DictReader(f))


def norm(s):
    """Arama anahtarı — uygulamadaki transitNorm ile birebir aynı olmalı."""
    out = []
    for ch in (s or ''):
        out.append({'İ': 'i', 'I': 'i', 'ı': 'i', 'Ö': 'o', 'ö': 'o',
                    'Ü': 'u', 'ü': 'u', 'Ş': 's', 'ş': 's', 'Ç': 'c',
                    'ç': 'c', 'Ğ': 'g', 'ğ': 'g'}.get(ch, ch))
    return ''.join(out).lower()


def meters(a, b):
    """(lat, lon) ikilisi arası mesafe (metre)."""
    r = 6371000.0
    dlat = math.radians(b[0] - a[0])
    dlon = math.radians(b[1] - a[1])
    h = (math.sin(dlat / 2) ** 2 +
         math.cos(math.radians(a[0])) * math.cos(math.radians(b[0])) *
         math.sin(dlon / 2) ** 2)
    return 2 * r * math.asin(min(1.0, math.sqrt(h)))


class Shape:
    """Güzergâh çizgisi — nokta izdüşümü ve çizgi boyunca mesafe hesabı."""

    def __init__(self, points):
        self.pts = points
        self.cum = [0.0] * len(points)
        for i in range(1, len(points)):
            self.cum[i] = self.cum[i - 1] + meters(points[i - 1], points[i])
        self.length = self.cum[-1] if self.cum else 0.0
        # Kaba ön eleme için sınırlayıcı kutu.
        self.min_lat = min(p[0] for p in points)
        self.max_lat = max(p[0] for p in points)
        self.min_lon = min(p[1] for p in points)
        self.max_lon = max(p[1] for p in points)

    def project(self, p):
        """(çizgi boyunca mesafe, çizgiye uzaklık) — ikisi de metre."""
        lat_scale = math.cos(math.radians(p[0]))
        px, py = p[1] * lat_scale, p[0]
        best = (0.0, float('inf'))
        for i in range(len(self.pts) - 1):
            a, b = self.pts[i], self.pts[i + 1]
            ax, ay = a[1] * lat_scale, a[0]
            bx, by = b[1] * lat_scale, b[0]
            dx, dy = bx - ax, by - ay
            len2 = dx * dx + dy * dy
            t = 0.0 if len2 == 0 else ((px - ax) * dx + (py - ay) * dy) / len2
            t = max(0.0, min(1.0, t))
            sx, sy = ax + t * dx, ay + t * dy
            d = meters(p, (sy, sx / lat_scale if lat_scale else sx))
            if d < best[1]:
                seg = self.cum[i + 1] - self.cum[i]
                best = (self.cum[i] + seg * t, d)
        return best


def stops_along_shape(shape, candidates, ltype='bus'):
    """Güzergâhtaki durakları SIRAYLA döndürür.

    `stop_times.txt` olmadığı için sıra buradan üretilir: her durak çizgiye
    izdüşürülür, çizgiye uzaklığı eşiği aşanlar elenir, kalanlar çizgi boyunca
    katedilen mesafeye göre sıralanır. Üst üste binen duraklar (aynı noktada
    iki kayıt) tekilleştirilir.
    """
    # VAPUR: güzergâh kıyıyı takip ettiği için sahildeki OTOBÜS durakları da
    # eşiğe giriyordu (Değirmendere-Gölcük hattına 17 durak çıkmıştı, oysa iki
    # iskele arası). Deniz hatlarında yalnızca İSKELE duraklarına bakılır.
    if ltype == 'ferry':
        candidates = [c for c in candidates if 'iskele' in norm(c[1])]

    hits = []
    for sid, name, lat, lon in candidates:
        along, dist = shape.project((lat, lon))
        if dist <= (250.0 if ltype == 'ferry' else SNAP_METERS):
            hits.append((along, sid, name, lat, lon))
    hits.sort()

    out = []
    for along, sid, name, lat, lon in hits:
        if out:
            prev = out[-1]
            if along - prev[0] < MIN_GAP_METERS:
                continue                      # aynı durağın ikinci kaydı
            if norm(name) == norm(prev[2]):
                continue                      # ardışık aynı ad
        out.append((along, sid, name, lat, lon))
    return out


SITE = 'https://www.kocaeli.bel.tr/hatlar'

# Hat sayfasındaki durak satırı: sıra no | DURAK NO | <a ...place/lat,lon>ad</a>
_STOP_ROW = None


def _stop_row_re():
    global _STOP_ROW
    if _STOP_ROW is None:
        import re
        _STOP_ROW = re.compile(
            r'<tr[^>]*>\s*<td[^>]*>\s*(\d+)\s*</td>\s*<td[^>]*>\s*([^<]*?)\s*'
            r'</td>\s*<td[^>]*>\s*<a[^>]*class="hat_durak"[^>]*'
            r'href="[^"]*place/([\d.\-]+),([\d.\-]+)"[^>]*>'
            r'(?:<i[^>]*></i>)?\s*([^<]+?)\s*</a>', re.S)
    return _STOP_ROW


def site_directions(code):
    """Hattın YETKİLİ sıralı durakları: [[(stop_id, ad, lat, lon), ...], ...].

    Her yön ayrı bir tablo. Sayfa yoksa/tablo bulunamazsa boş liste döner ve
    çağıran yedek yönteme (izdüşüm) düşer.
    """
    import re
    try:
        html = fetch(f'{SITE}/{code}/', timeout=45).decode('utf-8', 'replace')
    except Exception:
        return []
    import html as htmlmod
    out = []
    for table in re.findall(r'<table.*?</table>', html, re.S):
        rows = _stop_row_re().findall(table)
        if len(rows) < 2:
            continue
        dir_stops = []
        for _seq, stop_no, lat, lon, name in rows:
            if not stop_no.isdigit():
                continue
            try:
                dir_stops.append((int(stop_no), htmlmod.unescape(name).strip(),
                                  float(lat), float(lon)))
            except ValueError:
                continue
        if len(dir_stops) >= 2:
            out.append(dir_stops)
    return out


def build(version):
    routes = read_csv('routes.txt')
    stops_raw = read_csv('stops.txt')
    trips = read_csv('trips.txt')
    if not routes or not stops_raw or not trips:
        print('HATA: GTFS dosyaları eksik (önce --offline olmadan çalıştır)')
        return 1

    # --- şekiller ---
    shapes_pts = {}
    path = os.path.join(RAW, 'shapes.txt')
    with open(path, encoding='utf-8-sig', newline='') as f:
        for row in csv.DictReader(f):
            try:
                shapes_pts.setdefault(row['shape_id'], []).append((
                    int(row['shape_pt_sequence']),
                    float(row['shape_pt_lat']),
                    float(row['shape_pt_lon'])))
            except (ValueError, KeyError):
                continue
    shapes = {}
    for sid, pts in shapes_pts.items():
        pts.sort()
        line = [(a, b) for _, a, b in pts]
        if len(line) >= 2:
            shapes[sid] = Shape(line)
    print(f'şekil: {len(shapes)}')

    # --- duraklar (kaba ızgara indeksi: her şekil için aday süzmek üzere) ---
    all_stops = []
    for s in stops_raw:
        try:
            all_stops.append((int(s['stop_id']), s['stop_name'].strip(),
                              float(s['stop_lat']), float(s['stop_lon'])))
        except (ValueError, KeyError):
            continue
    grid = {}
    CELL = 0.01                                   # ~1.1 km
    for st in all_stops:
        grid.setdefault((int(st[2] / CELL), int(st[3] / CELL)), []).append(st)
    print(f'durak: {len(all_stops)}')

    def near_shape(shape):
        """Şeklin sınırlayıcı kutusuna düşen durak adayları."""
        out = []
        pad = 0.002
        for gy in range(int((shape.min_lat - pad) / CELL),
                        int((shape.max_lat + pad) / CELL) + 1):
            for gx in range(int((shape.min_lon - pad) / CELL),
                            int((shape.max_lon + pad) / CELL) + 1):
                out.extend(grid.get((gy, gx), ()))
        return out

    # --- hat başına (yön, şekil): en çok sefere sahip şekil temsilci olur ---
    by_route = {}
    for t in trips:
        key = (t['route_id'], t.get('direction_id', '0'))
        sid = t.get('shape_id') or ''
        if not sid:
            continue
        by_route.setdefault(key, {}).setdefault(sid, 0)
        by_route[key][sid] += 1

    route_by_id = {r['route_id']: r for r in routes}

    if os.path.exists(OUT):
        os.remove(OUT)
    db = sqlite3.connect(OUT)
    db.executescript('''
      PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF;
      CREATE TABLE stops(id INTEGER PRIMARY KEY, name TEXT, name_norm TEXT,
                         direction TEXT, district TEXT, lat REAL, lon REAL);
      CREATE TABLE lines(id TEXT PRIMARY KEY, code TEXT, name TEXT,
                         name_norm TEXT, dir TEXT, depar INTEGER, type TEXT);
      CREATE TABLE line_stops(line_id TEXT, seq INTEGER, stop_id INTEGER,
                              seconds INTEGER);
      CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
    ''')

    line_rows, ls_rows = [], []
    used_stops = {}
    seen_ids = set()
    from_site = from_shape = skipped = 0
    t0 = time.time()

    # Hat KODU başına işlenir: site sayfası kod bazlı ve iki yönü birden verir.
    codes = {}
    for (route_id, direction) in by_route:
        route = route_by_id.get(route_id)
        if not route:
            continue
        code = (route.get('route_short_name') or '').strip() or route_id
        codes.setdefault(code, []).append((route_id, direction))

    def add_line(code, yon, ltype, stops_seq, seconds):
        """stops_seq: [(stop_id, ad, lat, lon)]  seconds: [0, s1, s2, ...]"""
        lid = f'{code}_{yon}'
        n = 2
        while lid in seen_ids:
            lid = f'{code}_{yon}{n}'
            n += 1
        seen_ids.add(lid)
        lname = f'{stops_seq[0][1]} - {stops_seq[-1][1]}'
        line_rows.append((lid, code, lname, norm(lname), yon, 0, ltype))
        for k, (sid, name, lat, lon) in enumerate(stops_seq):
            used_stops[sid] = (name, lat, lon)
            ls_rows.append((lid, k, sid, seconds[k]))

    for i, (code, variants) in enumerate(sorted(codes.items()), 1):
        route = route_by_id[variants[0][0]]
        ltype = TYPE_BY_GTFS.get(route.get('route_type', '3'), 'bus')
        speed = {'bus': 5.0, 'tram': 7.0, 'ferry': 8.0,
                 'funicular': 4.0, 'cableCar': 4.0}.get(ltype, 5.0)

        # 1) YETKİLİ: belediyenin hat sayfası.
        dirs = site_directions(code)
        if dirs:
            for d, stops_seq in enumerate(dirs[:2]):
                secs = [0]
                for k in range(1, len(stops_seq)):
                    a = stops_seq[k - 1]
                    b = stops_seq[k]
                    dist = meters((a[2], a[3]), (b[2], b[3]))
                    secs.append(int(max(20, min(600, round(dist / speed)))))
                add_line(code, 'G' if d == 0 else 'D', ltype, stops_seq, secs)
            from_site += 1
            time.sleep(0.15)                       # siteye nazik ol
            continue

        # 2) YEDEK: güzergâh geometrisine izdüşüm (vapur/teleferik).
        for route_id, direction in variants:
            shape_id = max(by_route[(route_id, direction)].items(),
                           key=lambda kv: kv[1])[0]
            shape = shapes.get(shape_id)
            if shape is None or shape.length < 200:
                skipped += 1
                continue
            ordered = stops_along_shape(shape, near_shape(shape), ltype)
            if len(ordered) < 2:
                skipped += 1
                continue
            seq = [(sid, name, lat, lon)
                   for _along, sid, name, lat, lon in ordered]
            secs = [0]
            for k in range(1, len(ordered)):
                gap = ordered[k][0] - ordered[k - 1][0]
                secs.append(int(max(20, min(600, round(gap / speed)))))
            add_line(code, 'G' if str(direction) == '0' else 'D',
                     ltype, seq, secs)
            from_shape += 1
        if i % 25 == 0:
            print(f'  {i}/{len(codes)} hat  (site={from_site} '
                  f'geometri={from_shape})  {time.time()-t0:.0f}s')

    db.executemany('INSERT OR IGNORE INTO lines VALUES(?,?,?,?,?,?,?)',
                   line_rows)
    db.executemany('INSERT INTO line_stops VALUES(?,?,?,?)', ls_rows)
    db.executemany('INSERT OR IGNORE INTO stops VALUES(?,?,?,?,?,?,?)', [
        (sid, v[0], norm(v[0]), '', '', v[1], v[2])
        for sid, v in used_stops.items()
    ])
    db.executescript('''
      CREATE INDEX ix_stops_lat ON stops(lat);
      CREATE INDEX ix_stops_lon ON stops(lon);
      CREATE INDEX ix_ls_line ON line_stops(line_id);
      CREATE INDEX ix_ls_stop ON line_stops(stop_id);
    ''')
    for k, v in [('city', 'kocaeli'),
                 ('source', ATTRIBUTION),
                 ('version', version),
                 ('lines', str(len(line_rows))),
                 ('stops', str(len(used_stops)))]:
        db.execute('INSERT INTO meta VALUES(?,?)', (k, v))
    db.commit()
    db.execute('VACUUM')
    db.close()

    size = os.path.getsize(OUT) / 1024 / 1024
    print(f'\nYAZILDI: {OUT}  ({size:.1f} MB)')
    print(f'  hat(yön): {len(line_rows)}  durak: {len(used_stops)}')
    print(f'  yetkili (site): {from_site} hat   yedek (geometri): {from_shape} '
          f'yön   atlanan: {skipped}')
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--offline', action='store_true',
                    help='indirmeden, mevcut raw/ klasörüyle üret')
    a = ap.parse_args()
    version = time.strftime('%Y%m%d')
    if not a.offline:
        version = download_feed()
    return build(version)


if __name__ == '__main__':
    sys.exit(main())
