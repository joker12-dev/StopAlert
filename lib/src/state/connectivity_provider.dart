import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Cihazda internet bağlantısı VAR MI (kaba ölçü).
///
/// NEDEN KABA: `connectivity_plus` yalnızca ARABİRİM durumunu bilir (Wi-Fi/
/// mobil bağlı mı), gerçekten internete çıkılıyor mu değil. Kaptif portal ya
/// da veri kotası bitmiş bir bağlantı "bağlı" görünür. Bu yüzden bunu tek
/// başına "veri gelmeyecek" kanıtı olarak KULLANMIYORUZ; yalnızca kullanıcıya
/// "bağlantın kapalı görünüyor" ipucu vermek için. Ekranlar veriyi yine
/// dener; gerçek başarısızlıkta kendi boş/hata durumlarını gösterir.
///
/// `false` = hiçbir arabirim bağlı değil (uçak modu, kapalı Wi-Fi + veri).
final connectivityProvider = StreamProvider<bool>((ref) async* {
  final conn = Connectivity();
  bool online(List<ConnectivityResult> r) =>
      r.any((c) => c != ConnectivityResult.none);

  // İlk değeri hemen ver: akış yalnızca DEĞİŞİMde tetikleniyor, ekran açılışta
  // beklemesin.
  try {
    yield online(await conn.checkConnectivity());
  } catch (_) {
    yield true; // ölçemedik: engelleme, çevrimiçi varsay
  }
  yield* conn.onConnectivityChanged.map(online);
});
