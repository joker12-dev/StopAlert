import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

/// Otobüs (İETT) veri paketini Firebase Hosting'den İLK AÇILIŞTA indirir,
/// bütünlüğünü doğrular, cihazda saklar ve [TransitDb]'yi açar. Yeni sürüm
/// yayınlanınca (manifest.version değişince) arka planda tazeler.
///
/// StopAlert çevrimdışı (tünel/yeraltı) çalışmalıdır: veri CANLI sorgulanmaz,
/// bir kez indirilip yerelden okunur. Ray/vapur ayrıca APK'da gömülüdür.
class BusDataService {
  BusDataService._();
  static final BusDataService instance = BusDataService._();

  static const _base = 'https://stopalert-15716.web.app/data';
  static const _versionKey = 'bus_db_version_v1';

  bool _done = false;

  Future<String> _dbPath() async {
    final dir = await getApplicationSupportDirectory();
    return '${dir.path}/bus.sqlite';
  }

  /// Cihazda indirilmiş DB var mı? (Dolum ekranını yalnızca ilk açılışta —
  /// yani yerel DB yokken — göstermek için.) Mobil dışında true (atlanır).
  Future<bool> hasLocal() async {
    if (!isMobileDevice) return true;
    try {
      return File(await _dbPath()).exists();
    } catch (_) {
      return false;
    }
  }

  /// Gerekiyorsa indir/doğrula, ardından DB'yi aç. Mobil dışı platformlarda
  /// (test/masaüstü) no-op. Ağ/indirme hatası uygulamayı ENGELLEMEZ.
  Future<void> ensureReady({
    void Function(BusDataPhase phase, double fraction)? onProgress,
  }) async {
    if (_done) {
      onProgress?.call(BusDataPhase.ready, 1);
      return;
    }
    if (!isMobileDevice) {
      onProgress?.call(BusDataPhase.skipped, 1);
      return;
    }
    onProgress?.call(BusDataPhase.checking, 0);
    final path = await _dbPath();
    final file = File(path);
    final prefs = await SharedPreferences.getInstance();
    final localVer = prefs.getString(_versionKey);

    Map<String, dynamic>? manifest;
    try {
      final res = await http
          .get(Uri.parse('$_base/manifest.json'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        manifest = jsonDecode(res.body) as Map<String, dynamic>;
      }
    } catch (_) {
      // ağ yok: yerel DB varsa onunla devam.
    }

    final remoteVer = manifest?['version'] as String?;
    final exists = await file.exists();

    if (manifest != null && (!exists || remoteVer != localVer)) {
      final ok = await _download(manifest, path, onProgress);
      if (ok) await prefs.setString(_versionKey, remoteVer ?? '');
    }

    if (await file.exists()) {
      try {
        await TransitDb.instance.open(path);
        _done = true;
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
    String path,
    void Function(BusDataPhase, double)? onProgress,
  ) async {
    File? tmp;
    try {
      final fileName = manifest['file'] as String;
      final expectSha = manifest['sha256'] as String?;
      final expectBytes = (manifest['bytes'] as num?)?.toInt();
      final req = http.Request('GET', Uri.parse('$_base/$fileName'));
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
