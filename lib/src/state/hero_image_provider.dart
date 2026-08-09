import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Ana sayfa başlık görselinin klasörü.
///
/// KLASÖR TABANLI: buraya yeni bir fotoğraf atmak yeter, kod değişmez.
/// Varlıklar `AssetManifest` ile çalışma anında keşfedilir.
const _heroDir = 'assets/images/hero/';

/// Ana sayfada gösterilecek başlık görseli — HER AÇILIŞTA rastgele.
///
/// Sağlayıcı uygulama ömrü boyunca önbelleklenir; yani görsel oturum içinde
/// sabit kalır (her yeniden çizimde değişip göz yormaz) ama uygulama kapanıp
/// açılınca yenilenir.
///
/// Klasör boşsa null döner ve çağıran düz zemine düşer.
final heroImageProvider = FutureProvider<String?>((ref) async {
  try {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final all = [
      for (final k in manifest.listAssets())
        if (k.startsWith(_heroDir) && !k.endsWith('/')) k,
    ]..sort(); // sıralı: rastgelelik yalnızca seçimden gelsin
    if (all.isEmpty) return null;
    return all[Random().nextInt(all.length)];
  } catch (_) {
    return null;
  }
});
