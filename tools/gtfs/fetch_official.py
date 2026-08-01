#!/usr/bin/env python3
"""İETT RESMİ web servislerinden otobüs veritabanı üretir (bus.sqlite).

Neden: GTFS dosyalarında koordinatlar bozuk, hat adları mojibake, gidiş/dönüş
ayrımı ve durak sırası tahmin gerektiriyordu. Resmi `DurakDetay_GYY` servisi
bunların HEPSİNİ yetkili biçimde veriyor:
  HATKODU, YON (G/D), SIRANO, DURAKKODU, DURAKADI, X/YKOORDINATI, ILCEADI

Kaynak (kayıtsız, ücretsiz — İBB Açık Veri / İETT Büyük Veri Md.):
  Hat listesi : /iett/UlasimAnaVeri/HatDurakGuzergah.asmx  GetHat_json
  Hat durakları: /iett/ibb/ibb.asmx                        DurakDetay_GYY

DEPAR güzergâhları bu serviste yoktur (yalnızca ana gidiş/dönüş döner); onlar
GTFS'ten `build_db.py` ile eklenir (depar=1).

Kullanım:
    python fetch_official.py            # bus_official.sqlite üretir
    python fetch_official.py --limit 20 # hızlı deneme
"""
import argparse
import html
import json
import os
import re
import sqlite3
import sys
import time
import urllib.error
import urllib.request

BASE = 'https://api.ibb.gov.tr/iett'
HAT_URL = f'{BASE}/UlasimAnaVeri/HatDurakGuzergah.asmx'
DURAK_URL = f'{BASE}/ibb/ibb.asmx'

# İstanbul sınırları — bariz hatalı koordinatları ele.

# METROBÜS: İETT işletir ama kendi yolunda (metro gibi) çalışır; kullanıcı için
# ayrı tür olarak işaretlenir — kaynak veride tür ayrımı yok.
METROBUS_CODES = {'34', '34A', '34AS', '34BZ', '34C', '34G', '34Z', '34K'}

LAT_MIN, LAT_MAX = 40.5, 42.2
LON_MIN, LON_MAX = 27.5, 30.2

_TR_MAP = {'İ': 'i', 'I': 'i', 'ı': 'i', 'Ö': 'o', 'ö': 'o', 'Ü': 'u',
           'ü': 'u', 'Ş': 's', 'ş': 's', 'Ç': 'c', 'ç': 'c', 'Ğ': 'g',
           'ğ': 'g'}


def norm(s):
    """Türkçe-duyarsız arama anahtarı (Dart tarafı `transitNorm` ile aynı)."""
    s = s or ''
    for a, b in _TR_MAP.items():
        s = s.replace(a, b)
    return s.lower()


def soap(url, action, body, retries=3):
    """Tek bir SOAP çağrısı; gövde metnini döndürür."""
    env = (
        '<?xml version="1.0" encoding="utf-8"?>'
        '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">'
        f'<soap:Body>{body}</soap:Body></soap:Envelope>'
    ).encode('utf-8')
    req = urllib.request.Request(url, data=env, method='POST', headers={
        'Content-Type': 'text/xml; charset=utf-8',
        'SOAPAction': f'http://tempuri.org/{action}',
    })
    last = None
    for attempt in range(retries):
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return r.read().decode('utf-8', 'replace')
        except (urllib.error.URLError, OSError) as e:
            last = e
            time.sleep(1.5 * (attempt + 1))
    raise RuntimeError(f'{action} başarısız: {last}')


def get_lines():
    """Tüm otobüs hatları: [(kod, ad, uzunluk_km, sefer_suresi_dk)]"""
    x = soap(HAT_URL, 'GetHat_json',
             '<GetHat_json xmlns="http://tempuri.org/"><HatKodu></HatKodu>'
             '</GetHat_json>')
    m = re.search(r'<GetHat_jsonResult>(.*?)</GetHat_jsonResult>', x, re.S)
    if not m:
        raise RuntimeError('hat listesi boş döndü')
    out = []
    for h in json.loads(html.unescape(m.group(1))):
        code = (h.get('SHATKODU') or '').strip()
        if not code:
            continue
        out.append((
            code,
            (h.get('SHATADI') or code).strip(),
            float(h.get('HAT_UZUNLUGU') or 0),
            float(h.get('SEFER_SURESI') or 0),
        ))
    return out


def get_stop_meta():
    """Tüm durakların yön + ilçe bilgisi: {durak_kodu: (yon, ilce)}.

    `DurakDetay_GYY` yalnızca ilçeyi verir; durağın YÖNÜ (hangi istikamete
    bakıyor — aynı adlı iki durağı ayıran asıl bilgi) yalnızca burada var.
    """
    x = soap(HAT_URL, 'GetDurak_json',
             '<GetDurak_json xmlns="http://tempuri.org/"><DurakKodu></DurakKodu>'
             '</GetDurak_json>')
    m = re.search(r'<GetDurak_jsonResult>(.*?)</GetDurak_jsonResult>', x, re.S)
    if not m:
        return {}
    out = {}
    for s in json.loads(html.unescape(m.group(1))):
        # Durak kodu JSON'da bazen sayı, bazen metin gelir.
        sid = str(s.get('SDURAKKODU') or '').strip()
        if not sid:
            continue
        out[sid] = (str(s.get('SYON') or '').strip(),
                    str(s.get('ILCEADI') or '').strip())
    return out


def _tag(row, name):
    m = re.search(f'<{name}>(.*?)</{name}>', row, re.S)
    return html.unescape(m.group(1)).strip() if m else ''


def get_stops(code):
    """Hattın durakları: {yon: [(sirano, durakkodu, ad, ilce, lat, lon)]}"""
    x = soap(DURAK_URL, 'DurakDetay_GYY',
             '<DurakDetay_GYY xmlns="http://tempuri.org/">'
             f'<hat_kodu>{html.escape(code)}</hat_kodu></DurakDetay_GYY>')
    out = {}
    for row in re.findall(r'<Table>(.*?)</Table>', x, re.S):
        try:
            lat = float(_tag(row, 'YKOORDINATI'))
            lon = float(_tag(row, 'XKOORDINATI'))
            seq = int(_tag(row, 'SIRANO'))
        except ValueError:
            continue
        if not (LAT_MIN <= lat <= LAT_MAX and LON_MIN <= lon <= LON_MAX):
            continue
        sid = _tag(row, 'DURAKKODU')
        name = _tag(row, 'DURAKADI')
        if not sid or not name:
            continue
        yon = _tag(row, 'YON') or 'G'
        out.setdefault(yon, []).append(
            (seq, sid, name, _tag(row, 'ILCEADI'), lat, lon))
    for yon in out:
        out[yon].sort(key=lambda r: r[0])
    return out


def build(limit=None, out_path=None):
    base = os.path.dirname(os.path.abspath(__file__))
    out_path = out_path or os.path.join(base, 'bus_official.sqlite')
    t0 = time.time()

    lines = get_lines()
    if limit:
        lines = lines[:limit]
    print(f'hat listesi: {len(lines)}')

    meta = get_stop_meta()          # {durak_kodu: (yon, ilce)}
    print(f'durak meta (yon+ilce): {len(meta)}')

    if os.path.exists(out_path):
        os.remove(out_path)
    db = sqlite3.connect(out_path)
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

    stops = {}       # sid -> (name, ilce, lat, lon)
    line_rows = []
    ls_rows = []
    failed = []

    for i, (code, name, km, minutes) in enumerate(lines, 1):
        try:
            dirs = get_stops(code)
        except Exception as e:                      # tek hat düşerse devam et
            failed.append((code, str(e)[:60]))
            continue
        for yon, rows in dirs.items():
            if len(rows) < 2:
                continue
            # Aynı durak adı tekrarını (nadir) at — sıra korunur.
            seen = set()
            clean = []
            for (seq, sid, sname, ilce, lat, lon) in rows:
                if sname in seen:
                    continue
                seen.add(sname)
                clean.append((sid, sname, ilce, lat, lon))
            if len(clean) < 2:
                continue
            lid = f'{code}_{yon}'
            first, last = clean[0][1], clean[-1][1]
            lname = f'{first} - {last}'
            ltype = 'metrobus' if code in METROBUS_CODES else 'bus'
            line_rows.append((lid, code, lname, norm(lname), yon, 0, ltype))
            # Segment süresi: resmi sefer süresi / segment sayısı (saniye).
            segs = len(clean) - 1
            sec = int(round(minutes * 60 / segs)) if (minutes > 0 and segs) else 90
            sec = max(20, min(sec, 600))
            for k, (sid, sname, ilce, lat, lon) in enumerate(clean):
                stops[sid] = (sname, ilce, lat, lon)
                ls_rows.append((lid, k, int(sid), 0 if k == 0 else sec))
        if i % 50 == 0:
            print(f'  {i}/{len(lines)} hat  ({time.time()-t0:.0f}s)')
        time.sleep(0.05)                            # servise nazik ol

    db.executemany('INSERT OR IGNORE INTO lines VALUES(?,?,?,?,?,?,?)', line_rows)
    db.executemany('INSERT INTO line_stops VALUES(?,?,?,?)', ls_rows)
    db.executemany('INSERT OR IGNORE INTO stops VALUES(?,?,?,?,?,?,?)', [
        (int(sid), v[0], norm(v[0]), meta.get(sid, ('', ''))[0],
         meta.get(sid, ('', ''))[1] or v[1], v[2], v[3])
        for sid, v in stops.items()
    ])
    db.executescript('''
      CREATE INDEX ix_stops_lat ON stops(lat);
      CREATE INDEX ix_stops_lon ON stops(lon);
      CREATE INDEX ix_ls_line ON line_stops(line_id);
      CREATE INDEX ix_ls_stop ON line_stops(stop_id);
    ''')
    for k, v in [('source', 'IETT resmi web servisi (api.ibb.gov.tr)'),
                 ('version', time.strftime('%Y%m%d')),
                 ('lines', str(len(line_rows))),
                 ('stops', str(len(stops)))]:
        db.execute('INSERT INTO meta VALUES(?,?)', (k, v))
    db.commit()
    db.execute('VACUUM')
    db.close()

    print(f'\nDONE ({time.time()-t0:.0f}s): {out_path}')
    print(f'  guzergah={len(line_rows)}  durak={len(stops)}  '
          f'line_stops={len(ls_rows)}  boyut={os.path.getsize(out_path)/1e6:.1f} MB')
    if failed:
        print(f'  BAŞARISIZ {len(failed)} hat: {failed[:5]}')


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--limit', type=int, default=None)
    p.add_argument('--out', default=None)
    a = p.parse_args()
    sys.exit(build(limit=a.limit, out_path=a.out))
