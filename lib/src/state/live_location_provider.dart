import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../util/latlng_guard.dart';
import '../util/platform_check.dart';

/// Kullanıcının ANLIK konumu — haritalardaki mavi nokta bunu izler.
///
/// [currentLocationProvider] tek seferliktir: açılışta bir kez okur ve
/// önbelleğe alır, yani mavi nokta yürürken yerinde donuyordu. Bu sağlayıcı
/// gerçek GPS akışını dinler ve nokta Google Maps'teki gibi kayar.
///
/// `autoDispose` KASITLI: akışı yalnızca haritayı açan ekran dinler, ekran
/// kapanınca GPS bırakılır. Sürekli açık bir konum akışı pil yakar ve
/// StopAlert'in asıl işi (arka plan alarmı) için gereken bütçeyi yer.
///
/// İlk değer son bilinen konumdan gelir: ekran açılır açılmaz nokta doğru
/// yerde durur, ilk taze düzeltme beklenmez.
final liveLocationProvider = StreamProvider.autoDispose<LatLng?>((ref) async* {
  if (!isMobileDevice) {
    yield null;
    return;
  }

  // İzin YOKSA istemez: izin akışı "Başlamadan Önce" ekranında yönetiliyor.
  final permission = await Geolocator.checkPermission();
  if (permission != LocationPermission.always &&
      permission != LocationPermission.whileInUse) {
    yield null;
    return;
  }

  try {
    final last = await Geolocator.getLastKnownPosition();
    if (last != null) {
      final p = safeLatLng(last.latitude, last.longitude);
      if (p != null) yield p;
    }
  } catch (_) {
    // Son bilinen yoksa doğrudan akışa geçilir.
  }

  yield* Geolocator.getPositionStream(
    locationSettings: const LocationSettings(
      accuracy: LocationAccuracy.high,
      // 5 m: yürürken akıcı, dururken sabit. Daha küçüğü GPS gürültüsünde
      // noktayı titretir ve boşuna güç harcar.
      distanceFilter: 5,
    ),
  )
      // Sonlu olmayan düzeltmeyi ELE: NaN'lı bir nokta haritada marker olarak
      // çizilirse flutter_map her karede hata atıp uygulamayı kilitliyor.
      .map((p) => safeLatLng(p.latitude, p.longitude))
      .where((p) => p != null);
});
