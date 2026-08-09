import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'weather_provider.dart';

/// Başlık görsellerinin klasörleri.
///
/// KLASÖR TABANLI: buraya yeni bir fotoğraf atmak yeter, kod değişmez —
/// varlıklar `AssetManifest` ile çalışma anında keşfedilir.
const _dayDir = 'assets/images/hero/day/';
const _nightDir = 'assets/images/hero/night/';

/// Oturum tohumu — uygulama açılışında BİR KEZ üretilir.
///
/// Görsel oturum içinde sabit kalsın diye: her yeniden çizimde değişse göz
/// yorardı. Gündüz→gece geçişinde klasör değişir ama seçim yine bu tohumdan
/// türer, yani rastgelelik "her açılışta" ölçeğinde kalır.
final _sessionSeed = Random().nextInt(1 << 30);

final _heroAssetsProvider =
    FutureProvider<({List<String> day, List<String> night})>((ref) async {
  try {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    List<String> under(String dir) => [
          for (final k in manifest.listAssets())
            if (k.startsWith(dir) && !k.endsWith('/')) k,
        ]..sort(); // sıralı: rastgelelik yalnızca tohumdan gelsin
    return (day: under(_dayDir), night: under(_nightDir));
  } catch (_) {
    return (day: const <String>[], night: const <String>[]);
  }
});

/// Ana sayfada gösterilecek başlık görseli.
///
/// Gündüz/gece klasörü [isNightProvider]'a göre seçilir (canlı gün
/// doğumu/batımı, yoksa sabit kural). Klasör boşsa öteki klasöre düşer;
/// ikisi de boşsa null döner ve çağıran düz zemine geçer.
final heroImageProvider = Provider<String?>((ref) {
  final sets = ref.watch(_heroAssetsProvider).valueOrNull;
  if (sets == null) return null;
  final night = ref.watch(isNightProvider);
  final primary = night ? sets.night : sets.day;
  final fallback = night ? sets.day : sets.night;
  final list = primary.isNotEmpty ? primary : fallback;
  if (list.isEmpty) return null;
  return list[_sessionSeed % list.length];
});
