#!/usr/bin/env python3
"""Metro/tramvay/füniküler hatlarını RESMİ kaynaklardan güncelleyip
`assets/data/lines.json` içine yazar.

Gömülü ray verisi eskiydi (M3 9 durak / gerçekte 20, M9 5 / 14, T5 hiç yoktu).
İki resmi kaynak birleştirilir:

  1) Metro İstanbul API — hat, istasyon ADI ve SIRASI (Order), koordinat YOK
     https://api.ibb.gov.tr/MetroIstanbul/api/MetroMobile/V2/GetStations
  2) İBB Açık Veri GeoJSON — istasyon KOORDİNATLARI (hat adı + istasyon adı)
     "Raylı Sistem İstasyon Noktaları Verisi"

Marmaray ve vapur hatlarına DOKUNULMAZ (onlar zaten doğru).

Kullanım:  python build_rail.py            # lines.json'u günceller
           python build_rail.py --dry-run  # sadece rapor
"""
import argparse
import json
import os
import re
import sys
import unicodedata
import urllib.request

API = ('https://api.ibb.gov.tr/MetroIstanbul/api/MetroMobile/V2/GetStations')
GEOJSON = ('https://data.ibb.gov.tr/dataset/04ec9805-2483-46c7-914f-30c50857a846'
           '/resource/3dc8203f-3613-48a8-85e9-24fffb7821ad/download/'
           'rayli_sistem_istasyon_poi_verisi.geojson')

# Hangi hat kodu hangi StopAlert türüne karşılık gelir.
TYPE_BY_PREFIX = [
    ('M', 'metro'),
    ('T', 'tram'),      # T1..T5 (TF önce kontrol edilir)
    ('F', 'funicular'),
]
FUNICULAR = {'F1', 'F4', 'TF1', 'TF2'}

# Yeni istasyonlar için varsayılan durak-arası süre (saniye).
DEFAULT_SEGMENT = {'metro': 100, 'tram': 90, 'funicular': 120}


def fetch_json(url):
    req = urllib.request.Request(url, headers={'Accept': 'application/json'})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read().decode('utf-8'))


def norm(s):
    """İstasyon adı eşleştirme anahtarı: aksan/boşluk/noktalama duyarsız."""
    s = (s or '').lower()
    s = s.replace('ı', 'i').replace('İ', 'i').replace('ğ', 'g')
    s = s.replace('ü', 'u').replace('ş', 's').replace('ö', 'o').replace('ç', 'c')
    s = unicodedata.normalize('NFKD', s)
    s = ''.join(c for c in s if not unicodedata.combining(c))
    return re.sub(r'[^a-z0-9]', '', s)


def line_type(code):
    if code in FUNICULAR:
        return 'funicular'
    for p, t in TYPE_BY_PREFIX:
        if code.startswith(p):
            return t
    return 'metro'


def main(dry_run=False):
    here = os.path.dirname(os.path.abspath(__file__))
    lines_path = os.path.normpath(
        os.path.join(here, '..', '..', 'assets', 'data', 'lines.json'))

    # --- 1) Hat + istasyon sırası ---
    raw = fetch_json(API)
    stations = raw.get('Data') if isinstance(raw, dict) else raw
    by_line = {}
    for s in stations:
        if s.get('IsActive') is False:
            continue
        code = (s.get('LineName') or '').strip()
        name = (s.get('Name') or '').strip()
        if not code or not name:
            continue
        by_line.setdefault(code, []).append(
            (int(s.get('Order') or 0), name))
    for c in by_line:
        by_line[c].sort(key=lambda r: r[0])
    print(f'API: {len(stations)} istasyon, {len(by_line)} hat')

    # --- 2) Koordinatlar (hat kodu + istasyon adı) ---
    geo = fetch_json(GEOJSON)
    coords = {}          # (hat_kodu, norm_ad) -> (lat, lon)
    coords_any = {}      # norm_ad -> (lat, lon)   (hat eşleşmezse yedek)
    for f in geo.get('features', []):
        p = f.get('properties') or {}
        if 'mevcut' not in (p.get('PROJE_ASAMA') or '').lower():
            continue                       # yapım aşamasındakileri alma
        proje = (p.get('PROJE_ADI') or '').strip()
        m = re.match(r'^([A-Z]+\d+[A-Z]?)\b', proje)
        code = m.group(1) if m else ''
        name = (p.get('ISTASYON') or '').strip()
        g = f.get('geometry') or {}
        c = g.get('coordinates') or []
        if not name or len(c) < 2:
            continue
        lat, lon = float(c[1]), float(c[0])
        key = norm(name)
        if code:
            coords[(code, key)] = (lat, lon)
        coords_any.setdefault(key, (lat, lon))
    print(f'GeoJSON: {len(coords)} kodlu + {len(coords_any)} adlı istasyon')

    # --- 3) lines.json: ray hatlarını değiştir, diğerlerini koru ---
    doc = json.load(open(lines_path, encoding='utf-8'))
    old = doc['lines']
    keep = [l for l in old if l['type'] in ('marmaray', 'ferry', 'cableCar')]
    old_by_code = {l['code']: l for l in old}

    # Eski veriden koordinat yedeği: kaynaklar arasında ad farkı olsa da
    # (ör. API "DAVUTPASA" / GeoJSON "Davutpaşa - YTÜ") istasyon kaybolmasın.
    old_coords = {}
    for l in old:
        for s in l.get('stops', []):
            if s.get('lat') or s.get('lon'):
                old_coords.setdefault(norm(s['name']), (s['lat'], s['lon']))
                old_coords.setdefault((l['code'], norm(s['name'])),
                                      (s['lat'], s['lon']))

    def find_coord(code, name):
        """Tam ad → kısmi ad → eski veri sırasıyla koordinat ara."""
        key = norm(name)
        pos = coords.get((code, key)) or coords_any.get(key)
        if pos:
            return pos
        # Kısmi eşleşme: "emniyet" ⊂ "emniyetfatih", "bakirkoyincirli" ⊃ "bakirkoy"
        if len(key) >= 5:
            for (c, k), v in coords.items():
                if c == code and (key in k or k in key):
                    return v
            for k, v in coords_any.items():
                if len(k) >= 5 and (key in k or k in key):
                    return v
        return old_coords.get((code, key)) or old_coords.get(key)

    new_lines = []
    report = []
    for code, rows in sorted(by_line.items()):
        ltype = line_type(code)
        stops = []
        missing = 0
        for i, (_, name) in enumerate(rows):
            pos = find_coord(code, name)
            if pos is None:
                missing += 1
                continue                    # koordinatsız istasyonu alma
            stops.append({
                'id': f'{code}-{i}',
                'name': name,
                'lat': pos[0],
                'lon': pos[1],
                'underground': ltype == 'metro',
            })
        prev_n = len((old_by_code.get(code) or {}).get('stops') or [])
        # GÜVENLİK: yeni veri eskisinden azsa hattı GÜNCELLEME. Kaynaklardaki
        # ad uyuşmazlığı yüzünden mevcut veriyi bozmak kabul edilemez.
        if len(stops) < 2 or len(stops) < prev_n:
            report.append((code, len(rows), len(stops),
                           f'KORUNDU (eski {prev_n} durak daha iyi)'))
            if code in old_by_code:
                new_lines.append(old_by_code[code])
            continue
        seg = DEFAULT_SEGMENT.get(ltype, 100)
        prev = old_by_code.get(code)
        new_lines.append({
            'id': code,
            'code': code,
            'name': (prev or {}).get('name') or code,
            'type': ltype,
            'stops': stops,
            'segmentSeconds': [seg] * (len(stops) - 1),
        })
        before = len((prev or {}).get('stops') or [])
        report.append((code, len(rows), len(stops),
                       f'{before} -> {len(stops)}' + (f'  ({missing} koordinatsız)' if missing else '')))

    doc['lines'] = new_lines + keep
    print('\n--- HAT RAPORU ---')
    for code, api_n, used, note in report:
        print(f'  {code:<5} API={api_n:>3}  yazılan={used:>3}   {note}')
    print(f'\nray hatları: {len(new_lines)}  korunan (marmaray/vapur/teleferik): {len(keep)}')

    if dry_run:
        print('\n(dry-run: dosya yazılmadı)')
        return 0
    with open(lines_path, 'w', encoding='utf-8') as f:
        json.dump(doc, f, ensure_ascii=False, separators=(',', ':'))
    print(f'\nYAZILDI: {lines_path}  ({os.path.getsize(lines_path)/1024:.0f} KB)')
    return 0


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('--dry-run', action='store_true')
    sys.exit(main(dry_run=ap.parse_args().dry_run))
