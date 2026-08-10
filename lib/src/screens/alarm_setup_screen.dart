import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../data/journey_payload.dart';
import '../data/models.dart';
import '../services/ad_service.dart';
import '../services/cloud_learning_service.dart';
import '../services/location_service.dart';
import '../services/telemetry.dart';
import '../services/permission_service.dart';
import '../state/journey_provider.dart';
import '../state/live_location_provider.dart';
import '../state/settings_provider.dart';
import '../data/alarm_sound.dart';
import '../services/alarm_sound_preview.dart';
import '../services/journey_reminder.dart';
import '../theme/app_theme.dart';
import '../util/haptics.dart';
import '../util/platform_check.dart';
import '../widgets/mascot.dart';
import '../widgets/route_map.dart';
import 'live_tracking_screen.dart';
import 'permission_gate_screen.dart';

/// Alarm Kur — Stitch "Alarm Kur (Harita Odaklı)" portu.
/// Üst yarıda gerçek harita (OpenStreetMap), altta tetiklenme mesafesi ve
/// alarm ayarları paneli.
class AlarmSetupScreen extends ConsumerStatefulWidget {
  const AlarmSetupScreen({super.key, required this.stopName, this.lineLabel});

  final String stopName;
  final String? lineLabel;

  @override
  ConsumerState<AlarmSetupScreen> createState() => _AlarmSetupScreenState();
}

class _AlarmSetupScreenState extends ConsumerState<AlarmSetupScreen> {
  // Sürüklenebilir panel: yüksekliği ekranın bir oranı olarak tutulur ve
  // [_minFraction, _maxFraction] arasında sürüklenir. Harita bu oranla
  // ters orantılı küçülüp büyür; ayrıca panelin yuvarlak köşeleri haritayı
  // [_overlap] px örtsün diye harita panelin biraz altına gömülür.
  static const _minFraction = 0.34;
  static const _maxFraction = 0.80;
  static const _overlap = 62.0;

  // Tetikleme/ses/titreşim TEK kaynaktan (Ayarlar) okunur ve yazılır; böylece
  // Alarm Kur ↔ Ayarlar çift yönlü senkron olur.
  static const _stopOptions = AppSettings.stopLabels;
  static const _stopValues = AppSettings.stopValues;
  LatLng? _location;
  double _panelFraction = 0.52;
  double _availableHeight = 0;

  @override
  void initState() {
    super.initState();
    _loadLocation();
    // Hat seçilmeden gelinen girişlerde (ana sayfa/öneri kartları) durak
    // adını gerçek hat verisinde çözmeyi dene; böylece alarm gerçek rota ile
    // kurulabilir.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _resolveLineIfNeeded();
      // Buluttaki (kalabalık) segment sürelerini yerel modele arka planda
      // tohumla — yolculuk başlayınca servis zenginleşmiş yerel modeli okur.
      // (Firebase hazır değilse — ör. testte — sessizce atla.)
      try {
        final line = ref.read(journeyDraftProvider).line;
        if (line != null) {
          unawaited(
              ref.read(cloudLearningServiceProvider).seedLocalFromLine(line));
        }
      } catch (_) {}
    });
  }

  void _resolveLineIfNeeded() {
    final draft = ref.read(journeyDraftProvider);
    if (draft.line != null && draft.targetStopId != null) return;
    final lines = ref.read(linesProvider).valueOrNull;
    if (lines == null) return;
    final wanted = widget.stopName.toLowerCase();
    // Raylı sistem önceliği: marmaray > metro > tram > diğerleri.
    const order = [
      LineType.marmaray,
      LineType.metro,
      LineType.tram,
      LineType.funicular,
      LineType.ferry,
      LineType.cableCar,
      LineType.bus,
    ];
    for (final type in order) {
      for (final line in lines) {
        if (line.type != type) continue;
        for (final stop in line.stops) {
          if (stop.name.toLowerCase() == wanted) {
            ref.read(journeyDraftProvider.notifier)
              ..reset()
              ..selectLine(line)
              ..selectTargetStop(stop.id);
            setState(() {});
            return;
          }
        }
      }
    }
  }

  Future<void> _loadLocation() async {
    final loc = await LocationService().currentLocation();
    if (mounted && loc != null) setState(() => _location = loc);
  }

  static const _distanceMeters = AppSettings.distanceMeters;

  /// Kullanıcının konumuna en yakın durağın indeksi; konum yoksa -1.
  int _nearestStopIndex(TransitLine line) {
    final loc = _location;
    if (loc == null) return -1;
    const distance = Distance();
    var best = double.infinity;
    var idx = -1;
    for (var i = 0; i < line.stops.length; i++) {
      final s = line.stops[i];
      if (s.lat == 0 && s.lon == 0) continue;
      final d = distance.as(LengthUnit.Meter, loc, LatLng(s.lat, s.lon));
      if (d < best) {
        best = d;
        idx = i;
      }
    }
    return idx;
  }

  Future<void> _startJourney() async {
    final notifier = ref.read(journeyDraftProvider.notifier);
    final draft = ref.read(journeyDraftProvider);
    final line = draft.line;
    final targetId = draft.targetStopId;

    if (line == null || targetId == null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
          content:
              Text('Bu durak için hat verisi bulunamadı — aramadan gerçek bir '
                  'durak seçerek dene.'),
        ));
      return;
    }

    // Biniş durağı = kullanıcının GERÇEK konumuna en yakın durak. Böylece
    // rota "sen neredeysen → hedef" olur ve harita/işaretler konumla örtüşür.
    // Konum yoksa hedefe birkaç durak uzağı yedek olarak seçilir.
    var boardingId = draft.boardingStopId;
    if (boardingId == null) {
      final ti = line.indexOfStop(targetId);
      var bi = _nearestStopIndex(line);
      if (bi == -1 || bi == ti) {
        bi = ti >= 6 ? ti - 6 : (ti + 6).clamp(0, line.stops.length - 1);
      }
      if (bi != ti) {
        boardingId = line.stops[bi].id;
        notifier.selectBoardingStop(boardingId);
      }
    }
    if (boardingId == null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
          content: Text('Biniş durağı belirlenemedi — tekrar dene.'),
        ));
      return;
    }

    if (!await _ensureTrackingPermissions()) return;
    if (!mounted) return;

    // Ses taraması: alarm USAGE_ALARM kanalından çalar; kanal kısıksa
    // kullanıcıyı şimdiden uyar (yolculuğu engellemez).
    final volume = await PermissionService().alarmVolumePercent();
    if (!mounted) return;
    if (volume >= 0 && volume < 30) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(
            'Alarm ses düzeyi %$volume — durağı duyabilmen için '
            'sesi açman önerilir.',
          ),
        ));
    }

    // Tetikleme/ses/titreşim tercihleri TEK kaynaktan (Ayarlar) okunur.
    final s = ref.read(settingsProvider).valueOrNull ?? const AppSettings();
    final stopsMode = s.defaultTriggerMode == 0;
    final di = s.defaultDistanceIndex.clamp(0, _distanceMeters.length - 1);
    final si = s.defaultStopsIndex.clamp(0, _stopValues.length - 1);
    final payload = JourneyPayload(
      line: line,
      boardingStopId: boardingId,
      targetStopId: targetId,
      alarmDistanceMeters: stopsMode ? 0 : _distanceMeters[di],
      alarmStopsThreshold: stopsMode ? _stopValues[si] : 0,
      snoozeMinutes: s.snoozeMinutes,
      // Titreşim tercihini alarma taşı (panel anahtarı ayarla ortak).
      vibrate: s.vibration,
    );

    // Alarm kuruldu — anlamlı bir dokunsal onay.
    Haptics.medium();
    Telemetry.log('alarm_set', {
      'mode': stopsMode ? 'stops' : 'distance',
      'line': line.code,
    });
    // İndin ekranındaki geçiş reklamını arka planda ÖNDEN yükle (plan gereği
    // reklam yalnızca varış ekranında ve alarm akışına dokunmadan).
    AdService.instance.preloadInterstitial();

    // ALIŞKANLIK HATIRLATMASI: yarın aynı saatte "bu alarmı kur" bildirimi.
    // Alarm akışını bekletmesin diye beklenmiyor.
    unawaited(JourneyReminder.onJourneyStarted(payload));

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => LiveTrackingScreen(payload: payload),
      ),
    );
  }

  Future<bool> _ensureTrackingPermissions() async {
    if (!isAndroidDevice) return true;
    final service = PermissionService();
    var report = await service.check();
    if (report.criticalGranted) return true;
    if (!mounted) return false;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PermissionGateScreen(
          onCompleted: () {
            if (Navigator.of(context).canPop()) {
              Navigator.of(context).pop();
            }
          },
        ),
      ),
    );

    report = await service.check();
    if (report.criticalGranted) return true;
    if (mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
          content: Text(
            '"Her zaman izin ver" ve tam ekran alarm izni olmadan '
            'arka plan alarmı başlatılamaz.',
          ),
        ));
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final draft = ref.watch(journeyDraftProvider);
    // Tetikleme/ses/titreşim doğrudan Ayarlar'dan okunur (çift yönlü senkron).
    final settings =
        ref.watch(settingsProvider).valueOrNull ?? const AppSettings();
    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          _availableHeight = constraints.maxHeight;
          final panelHeight = _availableHeight * _panelFraction;
          // Harita panelin [_overlap] px altına gömülür; böylece panelin
          // yuvarlak köşeleri haritanın üstüne biner, köşeler sırıtmaz.
          final mapHeight = _availableHeight - panelHeight + _overlap;
          return Stack(
            children: [
              // Harita katmanı (üstte, panelin altına doğru uzanır)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: mapHeight,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: RouteMap(
                        line: draft.line,
                        boardingStopId: draft.boardingStopId,
                        targetStopId: draft.targetStopId,
                        // Canlı akış varsa onu kullan; yoksa açılıştaki tek
                        // seferlik konum (izin yok/akış henüz gelmedi).
                        currentLocation:
                            ref.watch(liveLocationProvider).valueOrNull ??
                                _location,
                      ),
                    ),
                    SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 8),
                        child: Column(
                          children: [
                            Row(
                              children: [
                                _CircleButton(
                                  icon: Icons.arrow_back,
                                  onTap: () => Navigator.of(context).pop(),
                                ),
                                Expanded(
                                  child: Text(
                                    'Alarm Kur',
                                    textAlign: TextAlign.center,
                                    style: text.headlineSmall?.copyWith(
                                      shadows: [
                                        const Shadow(
                                            color: Colors.black, blurRadius: 8),
                                      ],
                                    ),
                                  ),
                                ),
                                _CircleButton(
                                  icon: Icons.my_location,
                                  onTap: _loadLocation,
                                ),
                              ],
                            ),
                            if (draft.line case final line?) ...[
                              const SizedBox(height: 10),
                              _LineInfoChip(line: line),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // Sürüklenebilir alt panel
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                height: panelHeight,
                child: _buildPanel(text, settings),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Seçili hatta, kullanıcının konumuna en yakın durağı ve mesafesini gösterir
  /// (ör. "En yakın durak · Gebze · 10,2 km"). Konum yoksa gizlenir.
  Widget _buildNearestStop(TextTheme text) {
    final line = ref.read(journeyDraftProvider).line;
    final loc = _location;
    if (line == null || loc == null) return const SizedBox.shrink();

    const distance = Distance();
    Stop? nearest;
    var bestMeters = double.infinity;
    for (final s in line.stops) {
      if (s.lat == 0 && s.lon == 0) continue;
      final d = distance.as(LengthUnit.Meter, loc, LatLng(s.lat, s.lon));
      if (d < bestMeters) {
        bestMeters = d;
        nearest = s;
      }
    }
    if (nearest == null) return const SizedBox.shrink();

    final dStr = bestMeters >= 1000
        ? '${(bestMeters / 1000).toStringAsFixed(1).replaceAll('.', ',')} km'
        : '${bestMeters.round()} m';

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          const Icon(Icons.near_me_outlined,
              size: 16, color: VigilantColors.secondary),
          const SizedBox(width: 6),
          Expanded(
            child: RichText(
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              text: TextSpan(
                style: text.labelMedium
                    ?.copyWith(color: VigilantColors.onSurfaceVariant),
                children: [
                  const TextSpan(text: 'En yakın durak: '),
                  TextSpan(
                    text: nearest.name,
                    style: const TextStyle(
                      color: VigilantColors.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  TextSpan(text: '  ·  $dStr'),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Kullanıcıya en yakın duraktan hedefe: gerçek tahmini süre (GTFS segment
  /// sürelerinden) ve hat boyu kalan mesafe. Konum/hat yoksa "—".
  ({String eta, String dist}) _routeEstimate() {
    final draft = ref.read(journeyDraftProvider);
    final line = draft.line;
    final loc = _location;
    final targetId = draft.targetStopId;
    if (line == null || loc == null || targetId == null) {
      return (eta: '—', dist: '—');
    }
    const distance = Distance();
    var nearestIdx = -1;
    var best = double.infinity;
    for (var i = 0; i < line.stops.length; i++) {
      final s = line.stops[i];
      if (s.lat == 0 && s.lon == 0) continue;
      final d = distance.as(LengthUnit.Meter, loc, LatLng(s.lat, s.lon));
      if (d < best) {
        best = d;
        nearestIdx = i;
      }
    }
    final ti = line.indexOfStop(targetId);
    if (nearestIdx == -1 || ti == -1 || nearestIdx == ti) {
      return (eta: '—', dist: '—');
    }
    final eta = line.estimatedTravelTime(line.stops[nearestIdx].id, targetId);
    final lo = nearestIdx < ti ? nearestIdx : ti;
    final hi = nearestIdx < ti ? ti : nearestIdx;
    var meters = 0.0;
    for (var i = lo; i < hi; i++) {
      final a = line.stops[i];
      final b = line.stops[i + 1];
      if ((a.lat != 0 || a.lon != 0) && (b.lat != 0 || b.lon != 0)) {
        meters += distance.as(
            LengthUnit.Meter, LatLng(a.lat, a.lon), LatLng(b.lat, b.lon));
      }
    }
    final etaMin = eta.inMinutes;
    return (
      eta: etaMin < 1 ? '<1 dk' : '$etaMin dk',
      dist: meters >= 1000
          ? '${(meters / 1000).toStringAsFixed(1).replaceAll('.', ',')} km'
          : '${meters.round()} m',
    );
  }

  /// Alarm sesini Alarm Kur sayfasından seç (Ayarlar ile ortak, kalıcı).
  Future<void> _pickSound(String current) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: VigilantColors.surfaceContainer,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        final text = Theme.of(context).textTheme;
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
                Text('Alarm Sesi',
                    style: text.headlineSmall?.copyWith(fontSize: 20)),
                const SizedBox(height: 12),
                for (final snd in AlarmSound.all)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      snd.label == current
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off,
                      color: snd.label == current
                          ? VigilantColors.primary
                          : VigilantColors.onSurfaceVariant,
                    ),
                    title: Text(snd.label, style: text.bodyMedium),
                    subtitle: snd.hasOwnFile
                        ? null
                        : Text('kendi sesi henüz yok — varsayılan çalar',
                            style: text.labelSmall?.copyWith(
                                color: VigilantColors.onSurfaceVariant)),
                    // DİNLE: seçmeden önce duymak, seçtikten sonra pişman
                    // olmaktan iyidir.
                    trailing: ValueListenableBuilder<String?>(
                      valueListenable: AlarmSoundPreview.playing,
                      builder: (context, playing, _) {
                        final on = playing == snd.label;
                        return IconButton(
                          tooltip: on ? 'Durdur' : 'Dinle',
                          icon: Icon(
                              on
                                  ? Icons.stop_circle_outlined
                                  : Icons.play_circle_outline,
                              color: VigilantColors.primary),
                          onPressed: () {
                            Haptics.light();
                            AlarmSoundPreview.toggle(snd);
                          },
                        );
                      },
                    ),
                    onTap: () => Navigator.of(context).pop(snd.label),
                  ),
              ],
            ),
          ),
        );
      },
    );
    if (choice != null) {
      Haptics.selection();
      await ref.read(settingsProvider.notifier).setAlarmSound(choice);
    }
    // Sayfa kapanınca önizleme sürmesin: alarm sesleri uzun ve tekrarlı.
    await AlarmSoundPreview.stop();
  }

  Widget _buildPanel(TextTheme text, AppSettings settings) {
    final est = _routeEstimate();
    return Container(
      decoration: BoxDecoration(
        color: VigilantColors.surfaceContainerLow,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.5),
            blurRadius: 30,
            offset: const Offset(0, -8),
          ),
        ],
      ),
      child: Column(
        children: [
          // Sürükleme tutamağı — dikey sürükleme panel yüksekliğini değiştirir.
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
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Center(
                child: Container(
                  width: 48,
                  height: 6,
                  decoration: BoxDecoration(
                    color: VigilantColors.surfaceVariant,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.stopName +
                                (widget.lineLabel != null
                                    ? '  •  ${widget.lineLabel}'
                                    : ''),
                            style: text.bodyLarge
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          _buildNearestStop(text),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    // STOPİ eşlikçi: "iyi yolculuklar" pozu.
                    const Mascot(MascotAssets.iyiYolculuklar, height: 60),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  'ALARM TETİKLEME',
                  style: text.labelMedium?.copyWith(
                    color: VigilantColors.onSurfaceVariant,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 12),
                _TriggerSelector(
                  mode: settings.defaultTriggerMode,
                  onModeChanged: (i) {
                    Haptics.selection();
                    ref.read(settingsProvider.notifier).setDefaultTrigger(mode: i);
                  },
                  distances: AppSettings.distanceLabels,
                  selectedDistance: settings.defaultDistanceIndex,
                  onDistanceChanged: (i) {
                    Haptics.selection();
                    ref
                        .read(settingsProvider.notifier)
                        .setDefaultTrigger(distanceIndex: i);
                  },
                  stopOptions: _stopOptions,
                  selectedStop: settings.defaultStopsIndex,
                  onStopChanged: (i) {
                    Haptics.selection();
                    ref
                        .read(settingsProvider.notifier)
                        .setDefaultTrigger(stopsIndex: i);
                  },
                  etaText: est.eta,
                  distanceText: est.dist,
                ),
                const SizedBox(height: 24),
                Text(
                  'ALARM AYARLARI',
                  style: text.labelMedium?.copyWith(
                    color: VigilantColors.onSurfaceVariant,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  decoration: BoxDecoration(
                    color: VigilantColors.surfaceContainer,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Column(
                    children: [
                      _SettingRow(
                        icon: Icons.music_note_outlined,
                        title: 'Ses Tonu',
                        subtitle: settings.alarmSound,
                        trailing: const Icon(Icons.chevron_right,
                            color: VigilantColors.onSurfaceVariant),
                        onTap: () => _pickSound(settings.alarmSound),
                      ),
                      Divider(
                        height: 1,
                        color: Colors.white.withValues(alpha: 0.05),
                      ),
                      _SettingRow(
                        icon: Icons.vibration,
                        title: 'Titreşim',
                        trailing: Switch(
                          value: settings.vibration,
                          onChanged: (v) {
                            // Titreşim tercihi kalıcıdır (Ayarlar ile ortak).
                            ref.read(settingsProvider.notifier).setVibration(v);
                            Haptics.selection();
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  height: 56,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: VigilantColors.primary,
                      foregroundColor: VigilantColors.onPrimary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      textStyle: text.labelLarge,
                    ),
                    onPressed: _startJourney,
                    child: const Text('Alarmı Başlat'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Harita üstünde hattı özetleyen buzlu cam rozeti (hat ikonu + kod + durak).
class _LineInfoChip extends StatelessWidget {
  const _LineInfoChip({required this.line});

  final TransitLine line;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final color = lineTypeColor(line.type);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: VigilantColors.surfaceContainer.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 12),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(lineTypeIcon(line.type), size: 15, color: color),
                const SizedBox(width: 5),
                Text(
                  line.code,
                  style: text.labelMedium
                      ?.copyWith(color: color, fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              '${line.stops.length} durak',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.labelMedium
                  ?.copyWith(color: VigilantColors.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _CircleButton extends StatelessWidget {
  const _CircleButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: VigilantColors.surfaceContainerHighest.withValues(alpha: 0.8),
        ),
        child: Icon(icon, color: VigilantColors.onSurface, size: 20),
      ),
    );
  }
}

class _TriggerSelector extends StatelessWidget {
  const _TriggerSelector({
    required this.mode,
    required this.onModeChanged,
    required this.distances,
    required this.selectedDistance,
    required this.onDistanceChanged,
    required this.stopOptions,
    required this.selectedStop,
    required this.onStopChanged,
    required this.etaText,
    required this.distanceText,
  });

  /// 0 = kalan durak sayısı, 1 = kalan mesafe.
  final int mode;
  final ValueChanged<int> onModeChanged;
  final List<String> distances;
  final int selectedDistance;
  final ValueChanged<int> onDistanceChanged;
  final List<String> stopOptions;
  final int selectedStop;
  final ValueChanged<int> onStopChanged;
  final String etaText;
  final String distanceText;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final stopsMode = mode == 0;
    final hint = stopsMode
        ? 'Hedefe ${stopOptions[selectedStop]} kala alarm çalacak.'
        : 'Hedefe ${distances[selectedDistance]} kala alarm çalacak.';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: VigilantColors.surfaceContainer,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        children: [
          // Mod seçimi: alarma "kaç durak kala" mı, "kaç metre kala" mı?
          _SegmentRow(
            labels: const ['Kalan Durak', 'Kalan Mesafe'],
            selected: mode,
            onChanged: onModeChanged,
          ),
          const SizedBox(height: 10),
          // Seçili modun eşik değerleri.
          _SegmentRow(
            labels: stopsMode ? stopOptions : distances,
            selected: stopsMode ? selectedStop : selectedDistance,
            onChanged: stopsMode ? onStopChanged : onDistanceChanged,
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              const Icon(Icons.notifications_active_outlined,
                  size: 16, color: VigilantColors.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  hint,
                  style: text.labelMedium
                      ?.copyWith(color: VigilantColors.onSurfaceVariant),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Divider(height: 1, color: Colors.white.withValues(alpha: 0.06)),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _InfoChip(
                  icon: Icons.schedule,
                  label: 'Tahmini Varış',
                  value: etaText,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _InfoChip(
                  icon: Icons.route_outlined,
                  label: 'Toplam Mesafe',
                  value: distanceText,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Eşit genişlikte segmentli seçici — seçili segment yer değiştirmez,
/// yalnızca dolgusu kayar (kayma/zıplama yok).
class _SegmentRow extends StatelessWidget {
  const _SegmentRow({
    required this.labels,
    required this.selected,
    required this.onChanged,
  });

  final List<String> labels;
  final int selected;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      height: 48,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: VigilantColors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++)
            Expanded(
              child: GestureDetector(
                onTap: () => onChanged(i),
                behavior: HitTestBehavior.opaque,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  decoration: BoxDecoration(
                    color: i == selected
                        ? VigilantColors.primary
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: i == selected
                        ? [
                            BoxShadow(
                              color: VigilantColors.accentBlue
                                  .withValues(alpha: 0.35),
                              blurRadius: 12,
                            ),
                          ]
                        : null,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    labels[i],
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.labelLarge?.copyWith(
                      color: i == selected
                          ? VigilantColors.onPrimary
                          : VigilantColors.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: VigilantColors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: VigilantColors.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.labelMedium?.copyWith(
                    color: VigilantColors.onSurfaceVariant,
                    fontSize: 11,
                  ),
                ),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.labelLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingRow extends StatelessWidget {
  const _SettingRow({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: VigilantColors.surfaceContainerHighest,
              ),
              child: Icon(icon, color: VigilantColors.onSurface, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: text.bodyMedium),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      style: text.labelMedium
                          ?.copyWith(color: VigilantColors.primary),
                    ),
                ],
              ),
            ),
            trailing,
          ],
        ),
      ),
    );
  }
}
