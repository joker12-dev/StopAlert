import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../data/models.dart';
import '../data/transit_db.dart';
import '../services/routing_service.dart';
import '../state/journey_provider.dart';
import '../state/live_location_provider.dart';
import '../state/settings_provider.dart';
import '../theme/app_theme.dart';
import '../util/haptics.dart';
import '../util/insets.dart';
import '../util/map_style.dart';
import 'alarm_setup_screen.dart';
import 'line_detail_screen.dart';
import 'stop_lines_screen.dart';

/// Yakındaki Duraklar HARİTASI: üstte harita (yakın duraklar işaretli),
/// altta yüksekliği ayarlanabilen panel (en yakından uzağa liste). Bir durağa
/// dokununca harita o durağa zoomlanır ve konumundan durağa YÜRÜME ROTASI
/// (OSRM, yollardan) çizilir — kullanıcı nereden gideceğini görür.
class NearbyMapScreen extends ConsumerStatefulWidget {
  const NearbyMapScreen({super.key, this.focusStop});

  /// Verilirse harita bu durağa odaklanır ve durak seçili açılır
  /// (durak sayfasındaki "Haritada göster" akışı).
  final Stop? focusStop;

  @override
  ConsumerState<NearbyMapScreen> createState() => _NearbyMapScreenState();
}

class _NearbyMapScreenState extends ConsumerState<NearbyMapScreen> {
  final _map = MapController();
  bool _mapReady = false;

  MapStop? _selected;
  List<LatLng> _walk = const [];
  bool _walkLoading = false;

  /// Seçili otobüs durağından geçen hatlar (panelde rozet olarak listelenir).
  List<TransitLineBrief> _stopLines = const [];
  bool _linesLoading = false;

  /// Arama noktası çevresindeki duraklar + yükleme durumu.
  List<MapStop> _visible = const [];
  bool _loadingStops = false;
  Timer? _debounce;

  /// Aynı anda ikinci bir yükleme başlamasın (hızlı harita hareketinde
  /// üst üste binen sorgular durumu bozuyordu).
  bool _reloading = false;

  /// Alt panelin kapladığı yükseklik — turuncu nokta ekranın değil, GÖRÜNEN
  /// harita alanının ortasına konumlanır (panel arkasına düşmesin).
  double _panelHeight = 0;

  /// Anlık yakınlaşma — durak adlarının yazılıp yazılmayacağını belirler.
  double _zoom = 15;

  /// TURUNCU arama noktası: haritanın merkezi. Haritayı gezdirdikçe taşınır ve
  /// çevresindeki [_radius] metre içindeki duraklar listelenir (mavi nokta =
  /// kullanıcının gerçek konumu, o sabittir).
  ///
  /// setState DEĞİL, ayrı bir dinleyici olmasının sebebi: kaydırma sırasında
  /// bu değer her karede değişiyor ve setState ile 200 durak işareti de her
  /// karede yeniden kuruluyordu. Hızlı savurmada Dart yığını tükenip uygulama
  /// "Out of Memory" ile çöküyordu (cihaz logunda kayıtlı). Artık yalnızca
  /// daire ve turuncu nokta yeniden çizilir.
  final _probe = ValueNotifier<LatLng?>(null);

  /// Arama yarıçapı (metre) — kullanıcı çipten değiştirir.
  double _radius = 500;
  static const _radiusOptions = [250.0, 500.0, 1000.0];

  // Sürüklenebilir panel (Alarm Kur ekranındaki gibi).
  static const _minFraction = 0.28;
  static const _maxFraction = 0.75;
  double _panelFraction = 0.42;
  double _availableHeight = 0;

  /// Kullanıcının ANLIK konumu — canlı GPS akışından (mavi nokta bunu izler).
  ///
  /// Eskiden tek seferlik [currentLocationProvider] okunuyordu ve nokta
  /// açılışta donup kalıyordu; yürürken hareket etmiyordu.
  LatLng? get _userLoc => ref.read(liveLocationProvider).valueOrNull;

  @override
  void dispose() {
    _debounce?.cancel();
    _probe.dispose();
    super.dispose();
  }

  /// TURUNCU noktanın coğrafi konumu: ekranın tam ortası DEĞİL, alt panelin
  /// üstünde kalan GÖRÜNEN harita alanının ortası. Böylece nokta panelin
  /// arkasına gizlenmez ve kullanıcı neyi aradığını görür.
  LatLng _probeLatLng() {
    final cam = _map.camera;
    final size = cam.nonRotatedSize;
    if (_panelHeight <= 0 || size.height <= 0) return cam.center;
    // Görünen alanın ortası, ekran merkezinden panelin yarısı kadar yukarıda.
    final y = (size.height - _panelHeight) / 2;
    try {
      return cam.screenOffsetToLatLng(Offset(size.width / 2, y));
    } catch (_) {
      return cam.center;
    }
  }

  /// Durak işareti + (yakınlaşınca) adı.
  ///
  /// Adlar eskiden yalnızca dokununca görünüyordu; kullanıcı hangi durağın
  /// hangisi olduğunu tek tek dokunarak bulmak zorunda kalıyordu. Uzak
  /// zoom'da yazılmaz — 200 durak etiketi haritayı okunmaz yapar.
  Marker _stopMarker(MapStop m) {
    final selected = _isSelected(m);
    final showLabel = _zoom >= _labelZoom;
    final dotBox = selected ? 38.0 : 20.0;
    final height = showLabel ? dotBox + 34 : dotBox;
    return Marker(
      point: LatLng(m.stop.lat, m.stop.lon),
      width: showLabel ? 128 : dotBox,
      height: height,
      // Yuvarlağın MERKEZİ koordinata otursun (etiket kutuyu uzatıyor).
      alignment: showLabel
          ? Alignment(0, dotBox / height - 1)
          : Alignment.center,
      child: GestureDetector(
        onTap: () => _selectStop(m),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: dotBox,
              height: dotBox,
              child: _StopMarker(selected: selected, isBus: m.isBus),
            ),
            if (showLabel)
              Flexible(
                child: Container(
                  margin: const EdgeInsets.only(top: 2),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: selected
                        ? VigilantColors.primary
                        : Colors.black.withValues(alpha: 0.72),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    m.stop.name,
                    maxLines: 2,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 9.5,
                      height: 1.15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Durak adlarının yazıldığı yakınlaşma eşiği.
  static const _labelZoom = 15.0;

  /// [point]'i ekranın değil, GÖRÜNEN harita alanının (panelin üstünde kalan
  /// kısım) ortasına getirir.
  ///
  /// Düz `move` kullanınca nokta ekran ortasına geliyor ama alt panel ekranın
  /// ~%42'sini kapattığı için kullanıcının mavi noktası panelin dibinde
  /// kalıyordu. Kamerayı panelin yarısı kadar yukarı kaydırmak gerekiyor.
  void _centerOnVisible(LatLng point, double zoom) {
    _map.move(point, zoom);
    if (_panelHeight <= 0) return;
    try {
      final cam = _map.camera;
      final size = cam.nonRotatedSize;
      if (size.height <= 0) return;
      // Görünen alanın ortasındaki koordinat...
      final visibleCenter = cam.screenOffsetToLatLng(
          Offset(size.width / 2, (size.height - _panelHeight) / 2));
      // ...noktaya eşit olacak şekilde kamerayı ötele.
      _map.move(
        LatLng(
          cam.center.latitude + (point.latitude - visibleCenter.latitude),
          cam.center.longitude + (point.longitude - visibleCenter.longitude),
        ),
        zoom,
      );
    } catch (_) {
      // Kamera henüz ölçülmediyse düz ortalama yeterli.
    }
  }

  /// Harita OYNARKEN turuncu noktayı anında taşı (veri yükleme bekler).
  void _updateProbeLive() {
    if (!_mapReady || !mounted) return;
    try {
      final p = _probeLatLng();
      if (_probe.value == p) return;
      _probe.value = p;
    } catch (_) {
      // kamera henüz hazır değil
    }
  }

  /// Veri yüklemesi yalnızca hareket durunca yapılır (sorgu israfı olmasın).
  void _scheduleReload() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _reloadVisible);
  }

  /// TURUNCU arama noktasının (harita merkezi) [_radius] metre çevresindeki
  /// durakları yükle. Tüm şehri belleğe almak yerine yalnızca bu daireyi
  /// sorgular (otobüs = indeksli SQLite bbox + daire filtresi).
  Future<void> _reloadVisible() async {
    if (!_mapReady || !mounted || _reloading) return;
    // Kamera yalnızca harita çizildikten sonra okunabilir; hızlı hareket/çıkış
    // sırasında erişim hata verebiliyor.
    final LatLng probe;
    try {
      probe = _probeLatLng();
    } catch (_) {
      return;
    }
    _reloading = true;
    _probe.value = probe;
    setState(() => _loadingStops = true);

    const distance = Distance();
    final r = _radius;
    final out = <MapStop>[];

    // Ray/vapur — bellekteki hatlar; daire içi, aynı adlı durak tekilleştirilir.
    final lines = ref.read(linesProvider).valueOrNull ?? const <TransitLine>[];
    final rail = <String, MapStop>{};
    for (final line in lines) {
      for (final s in line.stops) {
        if (s.lat == 0 && s.lon == 0) continue;
        final d = distance.as(LengthUnit.Meter, probe, LatLng(s.lat, s.lon));
        if (d > r) continue;
        final key = s.name.toLowerCase();
        final cur = rail[key];
        if (cur == null || d < cur.meters) {
          rail[key] = MapStop(stop: s, meters: d, line: line);
        }
      }
    }
    out.addAll(rail.values);

    // Otobüs — daireyi çevreleyen dikdörtgeni sorgula, sonra daireye kırp.
    if (TransitDb.instance.isReady) {
      final dLat = r / 111000.0;
      final cosLat = math.cos(probe.latitude * math.pi / 180).abs();
      final dLon = r / (111000.0 * (cosLat < 0.01 ? 0.01 : cosLat));
      final busStops = await TransitDb.instance.stopsInBounds(
        probe.latitude - dLat,
        probe.latitude + dLat,
        probe.longitude - dLon,
        probe.longitude + dLon,
        limit: 300,
      );
      final bus = <String, MapStop>{};
      for (final s in busStops) {
        final d = distance.as(LengthUnit.Meter, probe, LatLng(s.lat, s.lon));
        if (d > r) continue;
        final key = '${s.name.toLowerCase()}|${s.direction.toLowerCase()}';
        final cur = bus[key];
        if (cur == null || d < cur.meters) {
          bus[key] = MapStop(stop: s, meters: d, line: null);
        }
      }
      out.addAll(bus.values);
    }

    out.sort((a, b) => a.meters.compareTo(b.meters));
    _reloading = false;
    if (!mounted) return;
    setState(() {
      _visible = out.take(200).toList();
      _loadingStops = false;
    });
  }

  /// Harita görünümünü seç (Gece / Canlı / Uydu / Sade) — seçim Ayarlar'a
  /// kalıcı yazılır, tüm haritalarda geçerli olur.
  Future<void> _pickMapStyle() async {
    Haptics.light();
    final chosen = await showModalBottomSheet<MapTileStyle>(
      context: context,
      backgroundColor: VigilantColors.surfaceContainer,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        final t = Theme.of(context).textTheme;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: VigilantColors.surfaceVariant,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Text('Harita Görünümü',
                    style: t.headlineSmall?.copyWith(fontSize: 20)),
                const SizedBox(height: 12),
                for (final s in MapTileStyle.values)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      switch (s) {
                        MapTileStyle.gece => Icons.dark_mode_rounded,
                        MapTileStyle.canli => Icons.palette_rounded,
                        MapTileStyle.uydu => Icons.satellite_alt_rounded,
                        MapTileStyle.sade => Icons.light_mode_rounded,
                      },
                      color: AppMapStyle.style == s
                          ? VigilantColors.primary
                          : VigilantColors.onSurfaceVariant,
                    ),
                    title: Text(s.label, style: t.bodyMedium),
                    trailing: AppMapStyle.style == s
                        ? const Icon(Icons.check_rounded,
                            color: VigilantColors.primary)
                        : null,
                    onTap: () => Navigator.of(context).pop(s),
                  ),
              ],
            ),
          ),
        );
      },
    );
    if (chosen == null || !mounted) return;
    Haptics.selection();
    setState(() => AppMapStyle.style = chosen);
    await ref.read(settingsProvider.notifier).setMapStyle(chosen.name);
  }

  void _setRadius(double r) {
    if (_radius == r) return;
    Haptics.selection();
    setState(() => _radius = r);
    _reloadVisible();
  }

  /// Kullanıcının konumu kapsam dışındaysa (ör. Kocaeli) en yakın durağa git.
  Future<void> _goToNearest() async {
    final nearest = ref.read(nearbyMapProvider).valueOrNull;
    if (nearest == null || nearest.isEmpty || !_mapReady) return;
    Haptics.light();
    final s = nearest.first.stop;
    _centerOnVisible(LatLng(s.lat, s.lon), 15);
    await _reloadVisible();
  }

  /// Durağa dokunulunca: haritayı O DURAĞA yakınlaştır ve panelde durak
  /// bilgilerini + o duraktan geçen hatları göster.
  ///
  /// Yürüme rotası ARTIK OTOMATİK ÇİZİLMEZ — kullanıcı istemediği hâlde
  /// konumundan rota oluşuyordu; artık panelden "Yol tarifi" ile istenir.
  Future<void> _selectStop(MapStop m) async {
    Haptics.light();
    setState(() {
      _selected = m;
      _walk = const [];
      _walkLoading = false;
      _stopLines = const [];
      _linesLoading = m.isBus;
    });
    if (_mapReady) {
      try {
        _centerOnVisible(LatLng(m.stop.lat, m.stop.lon), 16.5);
      } catch (_) {
        // Kamera hesabı başarısızsa haritayı bozma; seçim yine de geçerli.
      }
    }
    // Otobüs durağıysa geçen hatları getir (panelde rozet olarak listelenir).
    if (m.isBus) {
      final lines = await TransitDb.instance.linesForStop(m.stop.id);
      if (!mounted) return;
      setState(() {
        _stopLines = lines;
        _linesLoading = false;
      });
    }
  }

  /// Seçimi temizle: harita işaretleri ve panel eski hâline döner.
  void _clearSelection() {
    Haptics.light();
    setState(() {
      _selected = null;
      _walk = const [];
      _walkLoading = false;
      _stopLines = const [];
      _linesLoading = false;
    });
  }

  /// Kullanıcının konumundan seçili durağa YÜRÜME rotası (istek üzerine).
  Future<void> _drawWalk(MapStop m) async {
    final user = _userLoc;
    if (user == null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
            content: Text('Yol tarifi için konum izni gerekiyor.')));
      return;
    }
    Haptics.light();
    setState(() => _walkLoading = true);
    final target = LatLng(m.stop.lat, m.stop.lon);
    final walk = await RoutingService.instance.walk(user, target);
    if (!mounted) return;
    setState(() {
      _walk = walk;
      _walkLoading = false;
    });
    // Rota çizildiyse ikisini birlikte sığdır (çok yakınsa zoom bozulmasın).
    const d = Distance();
    if (_mapReady && d.as(LengthUnit.Meter, user, target) > 60) {
      try {
        _map.fitCamera(CameraFit.bounds(
          bounds: LatLngBounds.fromPoints([user, target]),
          padding: EdgeInsets.fromLTRB(60, 90, 60, _panelHeight + 20),
        ));
      } catch (_) {}
    }
  }

  void _startAlarm(MapStop m) {
    Haptics.light();
    final line = m.line;
    if (line != null) {
      // Ray/vapur: hat belli → doğrudan Alarm Kur (durak = hedef).
      ref.read(journeyDraftProvider.notifier)
        ..reset()
        ..selectLine(line)
        ..selectTargetStop(m.stop.id);
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) =>
            AlarmSetupScreen(stopName: m.stop.name, lineLabel: line.code),
      ));
    } else {
      // Otobüs: bu duraktan geçen hatları seçtir.
      _openBusStop(m.stop);
    }
  }

  Future<void> _openBusStop(Stop stop) async {
    final lines = await TransitDb.instance.linesForStop(stop.id);
    if (!mounted) return;
    if (lines.isEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
            const SnackBar(content: Text('Bu duraktan geçen hat bulunamadı.')));
      return;
    }
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => StopLinesScreen(stop: stop, lines: lines),
    ));
  }

  String _fmt(double m) => m >= 1000
      ? '${(m / 1000).toStringAsFixed(1).replaceAll('.', ',')} km'
      : '${m.round()} m';

  bool _isSelected(MapStop m) => _selected?.stop.id == m.stop.id;

  /// Çizilecek işaretler: görünen alandakiler + (listede yoksa) seçili durak.
  List<MapStop> _markerStops(List<MapStop> visible) {
    final sel = _selected;
    if (sel == null || visible.any((m) => m.stop.id == sel.stop.id)) {
      return visible;
    }
    return [...visible, sel];
  }

  @override
  Widget build(BuildContext context) {
    // Akışı İZLE: her yeni konumda mavi nokta yeniden çizilsin.
    ref.watch(liveLocationProvider);
    final text = Theme.of(context).textTheme;
    // Panel + markerlar GÖRÜNEN alandan gelir (viewport/chunk yükleme).
    final stops = _visible;
    // Yakın duraklar yalnızca "en yakına git" kısayolu için okunur.
    final nearest = ref.watch(nearbyMapProvider).valueOrNull ?? const <MapStop>[];
    final user = _userLoc;
    final center = user ??
        (nearest.isNotEmpty
            ? LatLng(nearest.first.stop.lat, nearest.first.stop.lon)
            : const LatLng(41.0082, 28.9784));

    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          _availableHeight = constraints.maxHeight;
          final panelH = _availableHeight * _panelFraction;
          _panelHeight = panelH; // turuncu noktanın hizası buna göre
          return Stack(
            children: [
              // Harita
              Positioned.fill(
                child: FlutterMap(
                  mapController: _map,
                  options: MapOptions(
                    initialCenter: center,
                    initialZoom: 15,
                    minZoom: 3,
                    maxZoom: 18,
                    backgroundColor: VigilantColors.surfaceContainerLowest,
                    onMapReady: () {
                      _mapReady = true;
                      final focus = widget.focusStop;
                      if (focus != null) {
                        // Durak sayfasından gelindi: o durağa odaklan + seç.
                        final target = LatLng(focus.lat, focus.lon);
                        _centerOnVisible(target, 16);
                        final m = user == null
                            ? 0.0
                            : const Distance()
                                .as(LengthUnit.Meter, user, target);
                        _selectStop(MapStop(stop: focus, meters: m));
                      } else if (user != null) {
                        _centerOnVisible(user, 15);
                      }
                      _reloadVisible(); // ilk parçayı yükle
                    },
                    // Kaydırma SIRASINDA turuncu nokta anında taşınır; ağır
                    // durak sorgusu ise hareket durunca (debounce) yapılır.
                    onPositionChanged: (cam, __) {
                      _updateProbeLive();
                      _scheduleReload();
                      // Etiket eşiği geçildiyse yeniden çiz (her karede değil).
                      final was = _zoom >= _labelZoom;
                      _zoom = cam.zoom;
                      if (mounted && was != (_zoom >= _labelZoom)) {
                        setState(() {});
                      }
                    },
                  ),
                  children: [
                    TileLayer(
                      keepBuffer: AppMapStyle.keepBuffer,
                      panBuffer: AppMapStyle.panBuffer,
                      urlTemplate: AppMapStyle.urlTemplate,
                      subdomains: AppMapStyle.subdomains,
                      userAgentPackageName: 'com.originstudios.stopalert',
                      retinaMode: AppMapStyle.supportsRetina &&
                          RetinaMode.isHighDensity(context),
                    ),
                    if (AppMapStyle.needsLabelOverlay)
                      TileLayer(
                        keepBuffer: AppMapStyle.keepBuffer,
                        panBuffer: AppMapStyle.panBuffer,
                        urlTemplate: AppMapStyle.labelOverlayUrl,
                        subdomains: AppMapStyle.labelSubdomains,
                        userAgentPackageName: 'com.originstudios.stopalert',
                        retinaMode: AppMapStyle.supportsRetina &&
                            RetinaMode.isHighDensity(context),
                      ),
                    // TURUNCU arama dairesi (haritayı gezdirdikçe taşınır)
                    ValueListenableBuilder<LatLng?>(
                      valueListenable: _probe,
                      builder: (context, p, _) => CircleLayer(circles: [
                        if (p != null)
                        CircleMarker(
                          point: p,
                          radius: _radius,
                          useRadiusInMeter: true,
                          color: VigilantColors.tertiaryContainer
                              .withValues(alpha: 0.12),
                          borderColor: VigilantColors.tertiaryContainer
                              .withValues(alpha: 0.8),
                          borderStrokeWidth: 2,
                        ),
                      ]),
                    ),
                    // Yürüme rotası (yollardan)
                    if (_walk.length >= 2)
                      PolylineLayer(polylines: [
                        Polyline(
                          points: _walk,
                          strokeWidth: 5,
                          color: VigilantColors.accentBlue,
                          borderStrokeWidth: 1.5,
                          borderColor: Colors.white.withValues(alpha: 0.4),
                        ),
                      ]),
                    // Durak işaretleri (yalnızca görünen alandakiler). Seçili
                    // durak listede olmasa da (kaydırıldıysa) işaretli kalır.
                    MarkerLayer(
                      markers: [
                        for (final m in _markerStops(stops))
                          _stopMarker(m),
                      ],
                    ),
                    if (user != null)
                      MarkerLayer(markers: [
                        Marker(
                          point: user,
                          width: 26,
                          height: 26,
                          child: const _UserDot(),
                        ),
                      ]),
                    // Turuncu arama noktası (dairenin merkezi) — en üstte
                    ValueListenableBuilder<LatLng?>(
                      valueListenable: _probe,
                      builder: (context, p, _) => MarkerLayer(markers: [
                        if (p != null)
                          Marker(
                            point: p,
                            width: 22,
                            height: 22,
                            child: const _ProbeDot(),
                          ),
                      ]),
                    ),
                  ],
                ),
              ),
              // Üst çubuk — Positioned (Stack'in tüm çocukları konumlanmalı ki
              // Stack tüm ekranı doldursun; aksi halde SafeArea'ya küçülür).
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    child: Row(
                      children: [
                        _RoundBtn(
                            icon: Icons.arrow_back,
                            onTap: () => Navigator.of(context).pop()),
                        const SizedBox(width: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(
                            color: VigilantColors.surfaceContainer
                                .withValues(alpha: 0.9),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text('Yakındaki Duraklar',
                              style: text.labelLarge
                                  ?.copyWith(fontWeight: FontWeight.w700)),
                        ),
                        const Spacer(),
                        // Harita görünümü: Gece / Canlı / Uydu / Sade
                        _RoundBtn(
                          icon: Icons.layers_rounded,
                          onTap: _pickMapStyle,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // Alt panel
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: panelH,
                child: _panel(text, stops, nearest.isNotEmpty),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _panel(TextTheme text, List<MapStop> stops, bool hasNearest) {
    return Container(
      decoration: BoxDecoration(
        color: VigilantColors.surfaceContainerLow,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.5),
              blurRadius: 28,
              offset: const Offset(0, -6)),
        ],
      ),
      child: Column(
        children: [
          // Sürükleme tutamağı
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragUpdate: (d) {
              if (_availableHeight == 0) return;
              setState(() {
                _panelFraction =
                    (_panelFraction - d.delta.dy / _availableHeight)
                        .clamp(_minFraction, _maxFraction);
              });
            },
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Center(
                child: Container(
                  width: 44,
                  height: 5,
                  decoration: BoxDecoration(
                    color: VigilantColors.surfaceVariant,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            ),
          ),
          // Bir durak seçiliyse panel TAMAMEN durak detayına döner; geri
          // butonuyla listeye dönülür.
          if (_selected case final sel?) ...[
            Expanded(child: _stopDetail(text, sel)),
          ] else ...[
          // Arama noktası özeti + yarıçap seçimi
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
            child: Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: VigilantColors.tertiaryContainer,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Bu noktanın çevresinde ${stops.length} durak',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.labelMedium
                        ?.copyWith(color: VigilantColors.onSurfaceVariant),
                  ),
                ),
                if (_loadingStops)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: VigilantColors.primary),
                  ),
              ],
            ),
          ),
          // Yarıçap çipleri
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
            child: Row(
              children: [
                for (final r in _radiusOptions) ...[
                  _RadiusChip(
                    label: r >= 1000
                        ? '${(r / 1000).toStringAsFixed(0)} km'
                        : '${r.round()} m',
                    selected: _radius == r,
                    onTap: () => _setRadius(r),
                  ),
                  const SizedBox(width: 8),
                ],
                const Spacer(),
                Text('haritayı gezdir',
                    style: text.labelSmall
                        ?.copyWith(color: VigilantColors.onSurfaceVariant)),
              ],
            ),
          ),
          Expanded(
            child: _loadingStops && stops.isEmpty
                ? const Center(
                    child: CircularProgressIndicator(
                        color: VigilantColors.primary))
                : stops.isEmpty
                    ? _empty(text, hasNearest)
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                        itemCount: stops.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, i) {
                          final m = stops[i];
                          return _StopTile(
                            m: m,
                            distanceText: _fmt(m.meters),
                            selected: _isSelected(m),
                            onTap: () => _selectStop(m),
                          );
                        },
                      ),
          ),
          ],
        ],
      ),
    );
  }

  /// Seçili durağın detay paneli: geri butonu, durak bilgileri, o duraktan
  /// geçen hatlar ve eylemler (alarm kur / yol tarifi).
  Widget _stopDetail(TextTheme text, MapStop sel) {
    final s = sel.stop;
    return ListView(
      padding: EdgeInsets.fromLTRB(16, 0, 16, AppInsets.pageBottom(context)),
      children: [
        // Başlık: geri + durak adı
        Row(
          children: [
            GestureDetector(
              onTap: _clearSelection,
              behavior: HitTestBehavior.opaque,
              child: Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: VigilantColors.surfaceContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.arrow_back,
                    size: 20, color: VigilantColors.onSurface),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(s.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodyLarge
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  if (s.contextLabel.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(s.contextLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.labelMedium?.copyWith(
                              color: VigilantColors.onSurfaceVariant)),
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // Mesafe + tür
        Row(
          children: [
            _chip(text, Icons.directions_walk_rounded, _fmt(sel.meters)),
            const SizedBox(width: 8),
            _chip(
                text,
                sel.isBus
                    ? Icons.directions_bus_filled_rounded
                    : lineTypeIcon(sel.line!.type),
                sel.isBus ? 'Otobüs durağı' : sel.line!.type.label),
          ],
        ),
        const SizedBox(height: 16),
        // Buradan geçen hatlar
        if (sel.isBus) ...[
          Text('Buradan geçen hatlar',
              style: text.labelLarge?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          if (_linesLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: VigilantColors.primary),
              ),
            )
          else if (_stopLines.isEmpty)
            Text('Hat bilgisi bulunamadı.',
                style: text.labelMedium
                    ?.copyWith(color: VigilantColors.onSurfaceVariant))
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final l in _stopLines)
                  GestureDetector(
                    onTap: () {
                      Haptics.light();
                      Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => LineDetailScreen(code: l.code)));
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: VigilantColors.primary.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                            color: VigilantColors.primary
                                .withValues(alpha: 0.35)),
                      ),
                      child: Text(l.code,
                          style: text.labelLarge?.copyWith(
                              color: VigilantColors.primary,
                              fontWeight: FontWeight.w800)),
                    ),
                  ),
              ],
            ),
          const SizedBox(height: 16),
        ],
        // Eylemler
        Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 46,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: VigilantColors.primary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: () => _startAlarm(sel),
                  icon: const Icon(Icons.alarm_add_rounded, size: 18),
                  label: const Text('Alarm Kur'),
                ),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              height: 46,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: VigilantColors.onSurface,
                  side: BorderSide(
                      color: VigilantColors.surfaceVariant
                          .withValues(alpha: 0.6)),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: _walkLoading ? null : () => _drawWalk(sel),
                icon: _walkLoading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: VigilantColors.accentBlue))
                    : const Icon(Icons.directions_walk_rounded,
                        size: 18, color: VigilantColors.accentBlue),
                label: Text(_walk.length >= 2 ? 'Yol çizildi' : 'Yol tarifi'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _chip(TextTheme text, IconData icon, String label) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: VigilantColors.surfaceContainer,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: VigilantColors.onSurfaceVariant),
            const SizedBox(width: 6),
            Text(label,
                style: text.labelMedium
                    ?.copyWith(color: VigilantColors.onSurfaceVariant)),
          ],
        ),
      );

  /// Boş durum — görünen alanda durak yok. Çok uzaktaysa "yakınlaş", kapsam
  /// dışındaysa "en yakın durağa git" kısayolu sunar.
  Widget _empty(TextTheme text, bool hasNearest) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.explore_off_rounded,
                size: 34, color: VigilantColors.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              'Turuncu noktanın çevresinde durak yok. Haritayı gezdir, '
              'yarıçapı büyüt ya da en yakın durağa git.',
              textAlign: TextAlign.center,
              style: text.bodyMedium
                  ?.copyWith(color: VigilantColors.onSurfaceVariant),
            ),
            if (hasNearest) ...[
              const SizedBox(height: 14),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: VigilantColors.primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: _goToNearest,
                icon: const Icon(Icons.near_me_rounded, size: 18),
                label: const Text('En yakın durağa git'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StopTile extends StatelessWidget {
  const _StopTile({
    required this.m,
    required this.distanceText,
    required this.selected,
    required this.onTap,
  });

  final MapStop m;
  final String distanceText;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final sub = m.isBus
        ? (m.stop.contextLabel.isNotEmpty
            ? 'Otobüs · ${m.stop.contextLabel}'
            : 'Otobüs durağı')
        : '${m.line!.code} · ${m.line!.type.label}';
    return Material(
      color: selected
          ? VigilantColors.primary.withValues(alpha: 0.12)
          : VigilantColors.surfaceContainer,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: (m.isBus
                          ? VigilantColors.primary
                          : lineTypeColor(m.line!.type))
                      .withValues(alpha: 0.15),
                ),
                child: Icon(
                    m.isBus
                        ? Icons.directions_bus_filled_rounded
                        : lineTypeIcon(m.line!.type),
                    size: 20,
                    color: m.isBus
                        ? VigilantColors.primary
                        : lineTypeColor(m.line!.type)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(m.stop.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.labelMedium?.copyWith(
                            color: VigilantColors.onSurfaceVariant)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(distanceText,
                      style: text.labelLarge?.copyWith(
                          color: VigilantColors.primary,
                          fontWeight: FontWeight.w700)),
                  const Icon(Icons.chevron_right,
                      size: 18, color: VigilantColors.onSurfaceVariant),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StopMarker extends StatelessWidget {
  const _StopMarker({required this.selected, required this.isBus});

  final bool selected;
  final bool isBus;

  @override
  Widget build(BuildContext context) {
    final color = isBus ? VigilantColors.primary : VigilantColors.secondary;
    if (selected) {
      return Container(
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2.5),
          boxShadow: [
            BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 14),
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.4),
                blurRadius: 6,
                offset: const Offset(0, 2)),
          ],
        ),
        child: Icon(
            isBus
                ? Icons.directions_bus_filled_rounded
                : Icons.location_on,
            color: Colors.white,
            size: 20),
      );
    }
    // Seçili olmayan durak: beyaz halkalı renkli nokta + hafif gölge —
    // uydu/renkli döşemelerde de net okunur.
    return Container(
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.45),
              blurRadius: 4,
              offset: const Offset(0, 1)),
        ],
      ),
    );
  }
}

/// Arama yarıçapı çipi (250 m / 500 m / 1 km).
class _RadiusChip extends StatelessWidget {
  const _RadiusChip(
      {required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: selected
              ? VigilantColors.tertiaryContainer.withValues(alpha: 0.18)
              : VigilantColors.surfaceContainer,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected
                ? VigilantColors.tertiaryContainer
                : VigilantColors.surfaceVariant.withValues(alpha: 0.4),
          ),
        ),
        child: Text(label,
            style: text.labelMedium?.copyWith(
              color: selected
                  ? VigilantColors.tertiaryContainer
                  : VigilantColors.onSurfaceVariant,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            )),
      ),
    );
  }
}

/// Turuncu arama noktası — haritanın merkezinde durur, harita gezdirildikçe
/// taşınır; çevresindeki daire içindeki duraklar listelenir.
class _ProbeDot extends StatelessWidget {
  const _ProbeDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: VigilantColors.tertiaryContainer,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: [
          BoxShadow(
              color: VigilantColors.tertiaryContainer.withValues(alpha: 0.7),
              blurRadius: 10),
        ],
      ),
    );
  }
}

class _UserDot extends StatelessWidget {
  const _UserDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: VigilantColors.accentBlue,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: [
          BoxShadow(
              color: VigilantColors.accentBlue.withValues(alpha: 0.7),
              blurRadius: 10),
        ],
      ),
    );
  }
}

class _RoundBtn extends StatelessWidget {
  const _RoundBtn({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: VigilantColors.surfaceContainer.withValues(alpha: 0.9),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 42,
          height: 42,
          child: Icon(icon, color: VigilantColors.onSurface, size: 20),
        ),
      ),
    );
  }
}
