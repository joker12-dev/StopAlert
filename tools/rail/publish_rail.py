#!/usr/bin/env python3
"""Ray/vapur hat verisini (lines.json) indirilebilir paket olarak yayınlar.

NEDEN: Metro hatları uzuyor, yeni istasyon açılıyor (Akçaray Kuruçeşme,
M9 uzatması...). Veri APK'ya gömülü kaldığı sürece her değişiklik için
mağaza güncellemesi gerekiyordu. Artık şehir paketiyle birlikte indiriliyor
ve `build_rail.py` çalıştırılıp bu betikle yayınlandığında kullanıcılara
uygulama güncellemesi olmadan ulaşıyor.

Gömülü kopya APK'da KALIR (91 KB): ilk açılışta ağ yoksa uygulama ray/vapur
hatlarıyla yine de çalışsın diye. İndirilen sürüm varsa o kazanır.

Kimlikler DEĞİŞMEZ (M1A, T1, Marmaray2…): favoriler, geçmiş ve widget
kısayolları hat kimliğiyle saklandığı için kimlik değiştirmek onları bozardı.

Kullanım:  python publish_rail.py          # firebase_hosting'e hazırla
"""
import hashlib
import json
import os
import shutil
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..'))
SRC = os.path.join(ROOT, 'assets', 'data', 'lines.json')
HOSTING = os.path.join(ROOT, 'firebase_hosting', 'data')

# Ray/vapur verisi şehir başına: şu an yalnızca İstanbul'unki ayrı dosyada.
# (Kocaeli'nin tramvay/vapur hatları kendi sqlite paketinin içinde geliyor.)
CITY_DIR = {'istanbul': HOSTING}          # İstanbul eski/şehirsiz yolda


def main(city='istanbul'):
    if not os.path.exists(SRC):
        print(f'HATA: {SRC} yok')
        return 1
    out_dir = CITY_DIR.get(city) or os.path.join(HOSTING, city)
    os.makedirs(out_dir, exist_ok=True)

    doc = json.load(open(SRC, encoding='utf-8'))
    lines = doc.get('lines', [])
    stops = sum(len(l.get('stops') or []) for l in lines)
    version = time.strftime('%Y%m%d')

    # Eski ray dosyalarını temizle.
    for f in os.listdir(out_dir):
        if f.startswith('rail_') and f.endswith('.json'):
            os.remove(os.path.join(out_dir, f))

    name = f'rail_{version}.json'
    dst = os.path.join(out_dir, name)
    shutil.copy2(SRC, dst)
    data = open(dst, 'rb').read()

    # Şehir manifestine `rail` bölümü eklenir (sqlite bilgisi korunur).
    mpath = os.path.join(out_dir, 'manifest.json')
    manifest = json.load(open(mpath, encoding='utf-8')) if \
        os.path.exists(mpath) else {}
    manifest['rail'] = {
        'version': version,
        'file': name,
        'bytes': len(data),
        'sha256': hashlib.sha256(data).hexdigest(),
        'lines': len(lines),
        'stops': stops,
    }
    with open(mpath, 'w', encoding='utf-8') as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)

    print(f'YAZILDI: {dst}  ({len(data)/1024:.0f} KB)')
    print(f'  hat: {len(lines)}  durak: {stops}  sürüm: {version}')
    print(f'  manifest güncellendi: {mpath}')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else 'istanbul'))
