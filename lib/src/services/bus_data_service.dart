import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/transit_city.dart';
import '../data/transit_db.dart';
import '../util/platform_check.dart';

/// İlk açılış veri-hazırlığı aşamaları (dolum ekranı bunları gösterir).
enum BusDataPhase {
  checking, // sürüm kontrol ediliyor
  downloading, // otobüs paketi iniyor (fraction anlamlı)
  verifying, // bütünlük doğrulanıyor
  ready, // DB hazır ve açık
  offline, // indirilemedi + yerel yok: ray/vapur ile devam
  skipped, // mobil değil (test/masaüstü): otobüs katmanı atlanır
}

/// Şehir veri paketlerini Firebase Hosting'den indirir, bütünlüğünü doğrular,
/// cihazda saklar ve [TransitDb]'yi açar. Yeni sürüm yayınlanınca
/// (manifest.version değişince) tazeler.
///
/// StopAlert çevrimdışı (tünel/yeraltı) çalışmalıdır: veri CANLI sorgulanmaz,
/// bir kez indirilip yerelden okunur. Ray/vapur ayrıca APK'da gömülüdür.
///
/// ÇOK ŞEHİR: her şehrin paketi ayrı dosyada (`bus_istanbul.sqlite`) ve aynı
/// anda yalnızca AKTİF şehrin veritabanı açık tutulur (bkz. [TransitCity]).
class BusDataService {
  BusDataService._();
  static final BusDataService instance = BusDataService._();

  static const _base = 'https://stopalert-15716.web.app/data';
  static const _versionKeyPrefix = 'bus_db_version_';

  /// Hangi şehrin veritabanı açık — tekrar tekrar açmayı önler.
  String? _openCityId;

  /// Şehir paketinin manifest adresi. İstanbul eski (şehirsiz) yolda kaldı ki
  /// önceki sürümlerden gelen kurulumlar bozulmasın.
  String _manifestUrl(TransitCity city) => city.id == TransitCities.istanbul.id
      ? '$_base/manifest.json'
      : '$_base/${city.id}/manifest.json';

  String _fileBase(TransitCity city) => city.id == TransitCities.istanbul.id
      ? _base
      : '$_base/${city.id}';

  Future<String> _dbPath([TransitCity? city]) async {
    final dir = await getApplicationSupportDirectory();
    final c = city ?? TransitCities.fallback;
    // İstanbul dosya adı korunuyor: eski kurulumlar yeniden indirmesin.
    return c.id == TransitCities.istanbul.id
        ? '${dir.path}/bus.sqlite'
        : '${dir.path}/bus_${c.id}.sqlite';
  }

  /// İndirilmiş RAY/VAPUR dosyasının yolu — yoksa null.
  ///
  /// Ray verisi de artık paketle iniyor: metro hatları uzadıkça (Akçaray
  /// Kuruçeşme, M9 uzatması...) mağaza güncellemesi beklemek gerekmesin.
  /// APK'daki gömülü kopya SİLİNMEDİ: ilk açılışta ağ yoksa uygulama yine de
  /// ray/vapur hatlarıyla çalışsın diye yedek olarak duruyor.
  Future<String?> railPath([TransitCity? city]) async {
    if (!isMobileDevice) return null;
    try {
      final dir = await getApplicationSupportDirectory();
      final c = city ?? TransitCities.fallback;
      final f = File('${dir.path}/rail_${c.id}.json');
      return await f.exists() ? f.path : null;
    } catch (_) {
      return null;
    }
  }

  /// Manifestteki `rail` bölümünü indirir (sürüm değiştiyse).
  Future<void> _syncRail(
      Map<String, dynamic> manifest, TransitCity city) async {
    final rail = manifest['rail'];
    if (rail is! Map) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = 'rail_version_${city.id}';
      final remote = rail['version'] as String?;
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/rail_${city.id}.json');
      if (await file.exists() && prefs.getString(key) == remote) return;

      final res = await http
          .get(Uri.parse('${_fileBase(city)}/${rail['file']}'))
          .timeout(const Duration(seconds: 25));
      if (res.statusCode != 200) return;
      final bytes = res.bodyBytes;
      final expectSha = rail['sha256'] as String?;
      if (expectSha != null &&
          sha256.convert(bytes).toString() != expectSha) {
        return;                       // bozuk indirme: gömülü kopya kalsın
      }
      await file.writeAsBytes(bytes, flush: true);
      await prefs.setString(key, remote ?? '');
    } catch (_) {
      // Ağ yok / hata: gömülü kopya kullanılır.
    }
  }

  /// İndirilmiş DB'nin yolu — yoksa null.
  ///
  /// Arka plan isolate'i (widget kısayolu) veritabanını kendisi açmak zorunda:
  /// orada uygulamanın açık bağlantısı yoktur.
  Future<String?> localPath([TransitCity? city]) async {
    if (!isMobileDevice) return null;
    try {
      final path = await _dbPath(city);
      return await File(path).exists() ? path : null;
    } catch (_) {
      return null;
    }
  }

  /// Kurulu TÜM şehirlerin paketlerini aramaya/çözümlemeye açar.
  ///
  /// Arama ve favori çözümü aktif şehirle sınırlı kalmamalı: kullanıcı
  /// Kocaeli'de favori ekleyip İstanbul'a geçtiğinde favorisi çalışmalı.
  Future<void> openAllForLookup() async {
    if (!isMobileDevice) return;
    for (final c in TransitCities.all) {
      if (c.id == _openCityId) continue;          // aktif şehir zaten açık
      final path = await localPath(c);
      if (path != null) await TransitDb.instance.openAux(c.id, path);
    }
  }

  /// Paket cihazda var mı + hangi sürüm (Ayarlar → Veri Paketleri).
  Future<({bool installed, int bytes, String? version})> packageInfo(
      TransitCity city) async {
    if (!isMobileDevice) {
      return (installed: false, bytes: 0, version: null);
    }
    try {
      final file = File(await _dbPath(city));
      if (!await file.exists()) {
        return (installed: false, bytes: 0, version: null);
      }
      final prefs = await SharedPreferences.getInstance();
      return (
        installed: true,
        bytes: await file.length(),
        version: prefs.getString(_versionKeyPrefix + city.id),
      );
    } catch (_) {
      return (installed: false, bytes: 0, version: null);
    }
  }

  /// Paketi cihazdan sil (yer açmak için). Aktif şehrin paketi siliniyorsa
  /// veritabanı da kapatılır.
  Future<void> removePackage(TransitCity city) async {
    if (!isMobileDevice) return;
    try {
      if (_openCityId == city.id) {
        await TransitDb.instance.close();
        _openCityId = null;
      }
      final file = File(await _dbPath(city));
      if (await file.exists()) await file.delete();
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_versionKeyPrefix + city.id);
    } catch (_) {}
  }

  /// Sunucudaki paket bilgisi (boyut/sürüm) — indirmeden önce göstermek için.
  Future<({String? version, int bytes})?> remoteInfo(TransitCity city) async {
    try {
      final res = await http
          .get(Uri.parse(_manifestUrl(city)))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      final m = jsonDecode(res.body) as Map<String, dynamic>;
      return (
        version: m['version'] as String?,
        bytes: (m['bytes'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return null;
    }
  }

  /// Cihazda indirilmiş DB var mı? (Dolum ekranını yalnızca ilk açılışta —
  /// yani yerel DB yokken — göstermek için.) Mobil dışında true (atlanır).
  Future<bool> hasLocal([TransitCity? city]) async {
    if (!isMobileDevice) return true;
    try {
      return File(await _dbPath(city)).exists();
    } catch (_) {
      return false;
    }
  }

  /// Gerekiyorsa indir/doğrula, ardından DB'yi aç. Mobil dışı platformlarda
  /// (test/masaüstü) no-op. Ağ/indirme hatası uygulamayı ENGELLEMEZ.
  Future<void> ensureReady({
    TransitCity? city,
    void Function(BusDataPhase phase, double fraction)? onProgress,
  }) async {
    final target = city ?? TransitCities.fallback;
    if (_openCityId == target.id) {
      onProgress?.call(BusDataPhase.ready, 1);
      return;
    }
    if (!isMobileDevice) {
      onProgress?.call(BusDataPhase.skipped, 1);
      return;
    }
    onProgress?.call(BusDataPhase.checking, 0);
    final path = await _dbPath(target);
    final file = File(path);
    final prefs = await SharedPreferences.getInstance();
    final localVer = prefs.getString(_versionKeyPrefix + target.id);

    Map<String, dynamic>? manifest;
    try {
      final res = await http
          .get(Uri.parse(_manifestUrl(target)))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        manifest = jsonDecode(res.body) as Map<String, dynamic>;
      }
    } catch (_) {
      // ağ yok: yerel DB varsa onunla devam.
    }

    final remoteVer = manifest?['version'] as String?;
    final exists = await file.exists();

    if (manifest != null) await _syncRail(manifest, target);

    if (manifest != null && (!exists || remoteVer != localVer)) {
      final ok = await _download(manifest, target, path, onProgress);
      if (ok) {
        await prefs.setString(_versionKeyPrefix + target.id, remoteVer ?? '');
      }
    }

    if (await file.exists()) {
      try {
        // Şehir değiştiyse önceki veritabanı kapatılır: aynı anda tek paket.
        await TransitDb.instance.close();
        await TransitDb.instance.open(path);
        _openCityId = target.id;
        onProgress?.call(BusDataPhase.ready, 1);
        return;
      } catch (_) {
        // bozuk dosya: sil ki bir sonraki açılış yeniden indirsin.
        try {
          await file.delete();
        } catch (_) {}
      }
    }
    onProgress?.call(BusDataPhase.offline, 1);
  }

  Future<bool> _download(
    Map<String, dynamic> manifest,
    TransitCity city,
    String path,
    void Function(BusDataPhase, double)? onProgress,
  ) async {
    File? tmp;
    try {
      final fileName = manifest['file'] as String;
      final expectSha = manifest['sha256'] as String?;
      final expectBytes = (manifest['bytes'] as num?)?.toInt();
      final req =
          http.Request('GET', Uri.parse('${_fileBase(city)}/$fileName'));
      final resp =
          await http.Client().send(req).timeout(const Duration(seconds: 40));
      if (resp.statusCode != 200) return false;
      final total = resp.contentLength ?? expectBytes ?? 0;

      onProgress?.call(BusDataPhase.downloading, 0);
      final builder = BytesBuilder(copy: false);
      var received = 0;
      await for (final chunk in resp.stream) {
        builder.add(chunk);
        received += chunk.length;
        if (total > 0) {
          onProgress?.call(BusDataPhase.downloading, received / total);
        }
      }
      final bytes = builder.toBytes();

      onProgress?.call(BusDataPhase.verifying, 1);
      if (expectBytes != null && bytes.length != expectBytes) return false;
      if (expectSha != null &&
          sha256.convert(bytes).toString() != expectSha) {
        return false;
      }

      // Atomik yerleştir: önce .tmp'ye yaz, DB'yi kapat, sonra rename.
      tmp = File('$path.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      await TransitDb.instance.close();
      final target = File(path);
      if (await target.exists()) await target.delete();
      await tmp.rename(path);
      return true;
    } catch (_) {
      try {
        await tmp?.delete();
      } catch (_) {}
      return false;
    }
  }
}
