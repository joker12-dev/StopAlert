#!/usr/bin/env python3
"""Metro/tramvay/füniküler hatlarını RESMİ kaynaklardan güncelleyip
`assets/data/lines.json` içine yazar.

Gömülü ray verisi eskiydi (M3 9 durak / gerçekte 20, M9 5 / 14, T5 hiç yoktu).
Üç kaynak birleştirilir:

  1) Metro İstanbul API — hat, istasyon ADI ve SIRASI (Order), koordinat YOK
     https://api.ibb.gov.tr/MetroIstanbul/api/MetroMobile/V2/GetStations
  2) İBB Açık Veri GeoJSON — istasyon KOORDİNATLARI (hat adı + istasyon adı)
     "Raylı Sistem İstasyon Noktaları Verisi"
  3) OpenStreetMap / Overpass — yeni açılan istasyonlar (GeoJSON'da yok) ve
     `network` etiketiyle hat doğrulaması

Ad eşleştirme neden bu kadar dikkatli: İstanbul'da AYNI ADLI FARKLI istasyonlar
var. "Göztepe" hem M7'de (Bağcılar) hem Marmaray'da (Kadıköy) — arası 20 km.
"Halkalı" Marmaray'da, "Halkalı Caddesi" M9'da — arası 4 km. Düz alt-dize
eşleşmesi bu istasyonları birbirine karıştırıp hattı haritada paramparça
ediyordu. Bu yüzden eşleştirme üç aşamalı:

  a) sözcük-belirteci benzerliği (bkz. [sim]) — "HISARUSTU-BOGAZICI
     UNIVERSITESI" ile "Boğaziçi Üniversitesi/Hisarüstü" aynı sayılır
  b) hat kodu doğrulaması — OSM `network`/`ref` etiketi hattı söylüyorsa öncelik
  c) coğrafi tutarlılık (bkz. [resolve_line]) — komşu istasyonlardan
     kilometrelerce uzağa düşen aday elenir, yerine ara-değer konur

Marmaray ve vapur hatlarına DOKUNULMAZ (onlar zaten doğru).

Kullanım:  python build_rail.py            # lines.json'u günceller
           python build_rail.py --dry-run  # sadece rapor
"""
import argparse
import json
import math
import os
import re
import sys
import unicodedata
import urllib.parse
import urllib.request

API = ('https://api.ibb.gov.tr/MetroIstanbul/api/MetroMobile/V2/GetStations')
GEOJSON = ('https://data.ibb.gov.tr/dataset/04ec9805-2483-46c7-914f-30c50857a846'
           '/resource/3dc8203f-3613-48a8-85e9-24fffb7821ad/download/'
           'rayli_sistem_istasyon_poi_verisi.geojson')

# İBB GeoJSON'u yeni açılan istasyonları (M3/M5/M9 uzatmaları) içermiyor.
# Üçüncü kaynak olarak OpenStreetMap kullanılır — güncel ve ücretsiz.
# `out center tags`: way olarak çizilmiş istasyonların da merkezi gelir.
OVERPASS = 'https://overpass-api.de/api/interpreter'
BBOX = '(40.75,28.4,41.45,29.6)'
OVERPASS_QUERY = (
    '[out:json][timeout:180];('
    f'node["railway"="station"]{BBOX};'
    f'way["railway"="station"]{BBOX};'
    f'node["railway"="halt"]{BBOX};'
    f'node["railway"="tram_stop"]{BBOX};'
    f'node["public_transport"="station"]{BBOX};'
    f'way["public_transport"="station"]{BBOX};'
    ');out center tags;'
)

# Hangi hat kodu hangi StopAlert türüne karşılık gelir.
TYPE_BY_PREFIX = [
    ('M', 'metro'),
    ('T', 'tram'),      # T1..T5 (TF önce kontrol edilir)
    ('F', 'funicular'),
]
FUNICULAR = {'F1', 'F4', 'TF1', 'TF2'}

# Yeni istasyonlar için varsayılan durak-arası süre (saniye).
DEFAULT_SEGMENT = {'metro': 100, 'tram': 90, 'funicular': 120}

# Ad benzerliğinde ayırt edici olmayan sözcükler.
FILLER = {'istasyon', 'istasyonu', 'metro', 'metrosu', 'durak', 'duragi',
          'hatti', 'hat', 've', 'ile'}

# Bir adayın kabul eşiği ve komşu istasyona izin verilen azami boşluk.
MIN_SIM = 0.62
MAX_GAP_KM = 4.0


def fetch_json(url):
    req = urllib.request.Request(url, headers={'Accept': 'application/json'})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read().decode('utf-8'))


def fold(s):
    """Türkçe harfleri ASCII'ye indirger, küçük harfe çevirir."""
    s = (s or '').lower()
    s = s.replace('ı', 'i').replace('İ', 'i').replace('ğ', 'g')
    s = s.replace('ü', 'u').replace('ş', 's').replace('ö', 'o').replace('ç', 'c')
    s = unicodedata.normalize('NFKD', s)
    return ''.join(c for c in s if not unicodedata.combining(c))


def norm(s):
    """İstasyon adı eşleştirme anahtarı: aksan/boşluk/noktalama duyarsız."""
    return re.sub(r'[^a-z0-9]', '', fold(s))


def tokens(s):
    """Ad → anlamlı sözcük listesi. Sıra ve noktalama önemsiz olur."""
    parts = re.split(r'[^a-z0-9]+', fold(s))
    return [p for p in parts if p and p not in FILLER]


def _token_score(t, others):
    """Bir sözcüğün karşı taraftaki en iyi eşleşme puanı."""
    best = 0.0
    for o in others:
        if t == o:
            return 1.0
        # Kısaltmalar: "cad." ↔ "caddesi", "mah." ↔ "mahallesi", "un" ↔ "univ".
        if len(t) >= 3 and len(o) >= 3 and (t.startswith(o) or o.startswith(t)):
            best = max(best, 0.85)
    return best


def sim(a, b):
    """İki sözcük listesi arası simetrik benzerlik (0..1).

    Simetrik olması şart: "halkali" tek başına "halkali cad" ile 0.75 alır ama
    "halkali caddesi" 0.93 alır — böylece doğru olan kazanır.
    """
    if not a or not b:
        return 0.0
    # Yalnızca boşluk/noktalama farkı: "VEYSELKARANI" = "Veysel Karani".
    # Sözcük bazlı puanlama bunu 0.64'e düşürüyordu.
    if ''.join(a) == ''.join(b):
        return 1.0
    sa = sum(_token_score(t, b) for t in a) / len(a)
    sb = sum(_token_score(t, a) for t in b) / len(b)
    return (sa + sb) / 2


def haversine_km(a, b):
    """İki (lat, lon) arası kuş uçuşu mesafe (km)."""
    r = 6371.0
    dlat = math.radians(b[0] - a[0])
    dlon = math.radians(b[1] - a[1])
    h = (math.sin(dlat / 2) ** 2 +
         math.cos(math.radians(a[0])) * math.cos(math.radians(b[0])) *
         math.sin(dlon / 2) ** 2)
    return 2 * r * math.asin(min(1.0, math.sqrt(h)))


def line_type(code):
    if code in FUNICULAR:
        return 'funicular'
    for p, t in TYPE_BY_PREFIX:
        if code.startswith(p):
            return t
    return 'metro'


def code_tags(*values):
    """`network`/`ref` etiketlerinden hat kodu kümesi ("M9;M11" → {M9, M11})."""
    out = set()
    for v in values:
        for part in re.split(r'[^A-Za-z0-9]+', (v or '').upper()):
            if re.fullmatch(r'[A-Z]{1,3}\d{1,2}[A-Z]?', part):
                out.add(part)
    return out


class Gazetteer:
    """Tüm kaynaklardaki istasyonlar — ada göre aday koordinat üretir."""

    def __init__(self):
        self.entries = []      # (tokens, (lat, lon), {hat kodları}, kaynak, güven)

    def add(self, name, lat, lon, codes=(), source='', trust=1.0):
        t = tokens(name)
        if t:
            self.entries.append((t, (float(lat), float(lon)), set(codes),
                                 source, trust))

    def candidates(self, code, name, limit=8):
        """[(puan, (lat, lon), kaynak)] — puan yüksek olan daha olası."""
        want = tokens(name)
        out = []
        for t, pos, codes, source, trust in self.entries:
            s = sim(want, t)
            if s < MIN_SIM:
                continue
            # Hat kodu eşleşmesi en güçlü kanıt: aynı adlı Göztepe'lerden
            # network=M7 olanı seçilir.
            score = s * trust + (0.6 if code in codes else 0.0)
            out.append((score, pos, source))
        # Puan eşitliğinde koordinata göre sırala: her çalıştırmada aynı sonuç
        # çıksın (Overpass eleman sırası istekten isteğe değişiyor).
        out.sort(key=lambda r: (-r[0], r[1]))
        # Aynı noktayı tekrar tekrar önermeyelim (kaynaklar örtüşüyor).
        picked = []
        for score, pos, source in out:
            if any(haversine_km(pos, p) < 0.15 for _, p, _ in picked):
                continue
            picked.append((score, pos, source))
            if len(picked) >= limit:
                break
        return picked


def interpolate(stops, i):
    """Koordinatı bulunamayan istasyon için komşulardan ara-değer.

    Metro istasyonları hat boyunca sıralı olduğundan, iki komşu arasındaki
    doğrusal ara-değer birkaç yüz metre yanılır — koordinatsız bırakıp
    istasyonu tamamen silmekten çok daha iyidir.

    Hattın UCUNDAKİ istasyonda ara-değer yapılamaz; orada son iki durağın
    yönünde ötelenir. Yoksa uç durak komşusunun ÜSTÜNE kopyalanıyordu
    (M6'nın Hisarüstü'sü Etiler'in aynı noktasına düşmüştü).
    """
    known = [j for j, p in enumerate(stops) if p]
    if not known:
        return None
    left = next((j for j in range(i - 1, -1, -1) if stops[j]), None)
    right = next((j for j in range(i + 1, len(stops)) if stops[j]), None)
    if left is not None and right is not None:
        a, b = stops[left], stops[right]
        f = (i - left) / (right - left)
        return (a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f)

    # Tek yanlı: bilinen en yakın İKİ noktanın yönünde ötele.
    anchor = left if left is not None else right
    rest = [j for j in known if j != anchor]
    if not rest:
        return stops[anchor]
    other = min(rest, key=lambda j: abs(j - anchor))
    a, b = stops[other], stops[anchor]       # a → b yönü hattın gidiş yönü
    step = (i - anchor) / (anchor - other)
    return (b[0] + (b[0] - a[0]) * step, b[1] + (b[1] - a[1]) * step)


def resolve_line(code, names, gaz):
    """Hattın istasyon koordinatlarını coğrafi tutarlılıkla çözer.

    Ad benzerliği tek başına yetmiyor (bkz. modül başlığı), o yüzden döngü:
    çıpa koy → boşlukları çıpalara yakınlığa göre doldur → komşularından
    kilometrelerce kopan noktayı YASAKLA → yasaklıyı hariç tutup baştan seç.
    Böylece M7'nin Kadıköy'e düşen "Göztepe"si elenip yerine gerçek Bağcılar
    Göztepe'si (OSM'de var) geçer; hiç adayı kalmayana ara-değer konur.
    """
    cands = [gaz.candidates(code, nm) for nm in names]
    n = len(names)
    pos = [None] * n
    src = [''] * n
    banned = [[] for _ in range(n)]

    def usable(i):
        return [c for c in cands[i]
                if not any(haversine_km(c[1], b) < 0.15 for b in banned[i])]

    def put_anchors():
        """Puanı yüksek ve rakipsiz adayları sabitle."""
        for i in range(n):
            if pos[i] is not None:
                continue
            c = usable(i)
            if not c:
                continue
            top = c[0][0]
            rival = c[1][0] if len(c) > 1 else 0.0
            if top >= 1.2 or (top >= 0.95 and top - rival >= 0.2):
                pos[i], src[i] = c[0][1], c[0][2]

    def fill_geometric():
        """Boş istasyonlara, çıpalardan kestirilen konuma en yakın adayı koy."""
        changed = False
        for i in range(n):
            if pos[i] is not None:
                continue
            guess = interpolate(pos, i)
            if guess is None:
                continue
            best = None
            for score, p, s in usable(i):
                d = haversine_km(p, guess)
                if d > MAX_GAP_KM * 2:
                    continue
                # Puan ağır basar, mesafe ince ayar: gerçek bir kaynak, tahmine
                # tam oturan zayıf bir adaydan (çoğu kez eski ara-değer) üstün.
                rank = score - d / 8.0
                if best is None or rank > best[0]:
                    best = (rank, p, s)
            if best:
                pos[i], src[i] = best[1], best[2]
                changed = True
        return changed

    def prune_outliers():
        """Şüpheli noktayı yasakla: komşulardan çok uzak VEYA üst üste."""
        hit = False
        for i in range(n):
            if pos[i] is None:
                continue
            neigh = [pos[j] for j in (i - 1, i + 1) if 0 <= j < n and pos[j]]
            if not neigh:
                continue
            d = min(haversine_km(pos[i], q) for q in neigh)
            # Aynı hattın iki durağı 50 m'ye sığmaz — biri yanlış kopyalanmış.
            if d > MAX_GAP_KM or d < 0.05:
                banned[i].append(pos[i])
                pos[i], src[i] = None, ''
                hit = True
        return hit

    put_anchors()
    # Hiç çıpa yoksa (küçük hat, zayıf adaylar): en yüksek puanlıyı tohum yap.
    if not any(p is not None for p in pos):
        seed = max((i for i in range(n) if cands[i]),
                   key=lambda i: cands[i][0][0], default=None)
        if seed is not None:
            pos[seed], src[seed] = cands[seed][0][1], cands[seed][0][2]

    for _ in range(6):
        while fill_geometric():
            pass
        if not prune_outliers():
            break
        put_anchors()

    # Adayı tükenen istasyona komşularından ara-değer.
    filled = []
    for i in range(n):
        if pos[i] is None:
            pos[i] = interpolate(pos, i)
            if pos[i]:
                src[i] = 'ara-değer'
                filled.append(names[i])
    return pos, src, filled


def main(dry_run=False, verbose=False):
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
        by_line.setdefault(code, []).append((int(s.get('Order') or 0), name))
    for c in by_line:
        by_line[c].sort(key=lambda r: r[0])
    print(f'API: {len(stations)} istasyon, {len(by_line)} hat')

    gaz = Gazetteer()

    # --- 2) İBB GeoJSON koordinatları (en güvenilir kaynak) ---
    geo = fetch_json(GEOJSON)
    n_geo = 0
    for f in geo.get('features', []):
        p = f.get('properties') or {}
        if 'mevcut' not in (p.get('PROJE_ASAMA') or '').lower():
            continue                       # yapım aşamasındakileri alma
        proje = (p.get('PROJE_ADI') or '').strip()
        m = re.match(r'^([A-Z]+\d+[A-Z]?)\b', proje)
        name = (p.get('ISTASYON') or '').strip()
        g = f.get('geometry') or {}
        c = g.get('coordinates') or []
        if not name or len(c) < 2:
            continue
        gaz.add(name, c[1], c[0],
                codes={m.group(1)} if m else (), source='ibb', trust=1.0)
        n_geo += 1
    print(f'GeoJSON: {n_geo} istasyon')

    # --- 3) OpenStreetMap (yeni istasyonlar + network doğrulaması) ---
    n_osm = 0
    try:
        # Overpass Content-Type ve User-Agent olmadan 406 döndürüyor.
        req = urllib.request.Request(
            OVERPASS,
            data=urllib.parse.urlencode({'data': OVERPASS_QUERY}).encode('utf-8'),
            method='POST',
            headers={
                'Content-Type': 'application/x-www-form-urlencoded',
                'User-Agent': 'StopAlert/1.0 (transit app; data build script)',
            })
        with urllib.request.urlopen(req, timeout=240) as r:
            els = json.loads(r.read().decode('utf-8')).get('elements', [])
        for e in els:
            t = e.get('tags') or {}
            name = t.get('name')
            lat = e.get('lat') or (e.get('center') or {}).get('lat')
            lon = e.get('lon') or (e.get('center') or {}).get('lon')
            if not name or lat is None or lon is None:
                continue
            gaz.add(name, lat, lon,
                    codes=code_tags(t.get('network'), t.get('ref'),
                                    t.get('line')),
                    source='osm', trust=0.95)
            n_osm += 1
        print(f'OSM: {n_osm} istasyon')
    except Exception as e:
        print(f'OSM alınamadı ({e}); yalnızca İBB kaynakları kullanılacak')

    # --- 4) lines.json: ray hatlarını değiştir, diğerlerini koru ---
    doc = json.load(open(lines_path, encoding='utf-8'))
    old = doc['lines']
    keep = [l for l in old if l['type'] in ('marmaray', 'ferry', 'cableCar')]
    old_by_code = {l['code']: l for l in old}

    # Eski veri SON ÇARE yedeği: kaynaklarda hiç bulunmayan istasyon için.
    # Güven kasten çok düşük (0.3): lines.json'un kendisi bir önceki üretimin
    # çıktısı, yani hatalı koordinat içerebilir. Kod bonusuyla toplasa bile
    # (0.3 + 0.6 = 0.9) adı tutan bir OSM/İBB kaydını (0.95+) geçemez —
    # aksi halde yanlış koordinat her çalıştırmada kendini yeniden üretiyordu.
    # Hat kodu bonusu KASTEN verilmez: eski kayıt bağımsız bir kaynak değil,
    # bu betiğin önceki çıktısı. Bonus alsaydı kendi hatasını doğrulardı.
    for l in old:
        for s in l.get('stops', []):
            if s.get('lat') or s.get('lon'):
                gaz.add(s['name'], s['lat'], s['lon'],
                        source='eski', trust=0.3)

    new_lines = []
    report = []
    for code, rows in sorted(by_line.items()):
        ltype = line_type(code)
        names = [n for _, n in rows]
        pos, src, filled = resolve_line(code, names, gaz)

        stops = []
        for i, name in enumerate(names):
            if pos[i] is None:
                continue                    # koordinatsız istasyonu alma
            stops.append({
                'id': f'{code}-{i}',
                'name': name,
                'lat': round(pos[i][0], 6),
                'lon': round(pos[i][1], 6),
                'underground': ltype == 'metro',
            })
        if verbose:
            print(f'\n[{code}]')
            for i, name in enumerate(names):
                p = pos[i]
                where = f'{p[0]:.5f},{p[1]:.5f}' if p else 'YOK'
                print(f'   {name:<34} {where:<20} {src[i]}')

        prev = old_by_code.get(code)
        prev_n = len((prev or {}).get('stops') or [])
        # GÜVENLİK: yeni veri eskisinden azsa hattı GÜNCELLEME. Kaynaklardaki
        # ad uyuşmazlığı yüzünden mevcut veriyi bozmak kabul edilemez.
        if len(stops) < 2 or len(stops) < prev_n:
            report.append((code, len(rows), len(stops),
                           f'KORUNDU (eski {prev_n} durak daha iyi)'))
            if prev:
                new_lines.append(prev)
            continue
        seg = DEFAULT_SEGMENT.get(ltype, 100)
        new_lines.append({
            'id': code,
            'code': code,
            'name': (prev or {}).get('name') or code,
            'type': ltype,
            'stops': stops,
            'segmentSeconds': [seg] * (len(stops) - 1),
        })
        note = f'{prev_n} -> {len(stops)}'
        if filled:
            note += f'  (ara-değer: {", ".join(filled)})'
        report.append((code, len(rows), len(stops), note))

    doc['lines'] = new_lines + keep
    print('\n--- HAT RAPORU ---')
    for code, api_n, used, note in report:
        print(f'  {code:<5} API={api_n:>3}  yazılan={used:>3}   {note}')
    print(f'\nray hatları: {len(new_lines)}  '
          f'korunan (marmaray/vapur/teleferik): {len(keep)}')

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
    ap.add_argument('--verbose', action='store_true',
                    help='her istasyonun seçilen koordinatını ve kaynağını yaz')
    a = ap.parse_args()
    sys.exit(main(dry_run=a.dry_run, verbose=a.verbose))
