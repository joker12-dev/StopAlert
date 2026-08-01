import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../data/models.dart';
import '../data/recent_search.dart';
import '../data/transit_db.dart';
import '../state/journey_provider.dart';
import '../theme/app_theme.dart';
import '../util/insets.dart';
import '../util/haptics.dart';
import '../widgets/glass_panel.dart';
import '../widgets/mascot.dart';
import '../widgets/skeleton.dart';
import '../widgets/voice_search_sheet.dart';
import 'alarm_setup_screen.dart';
import 'line_detail_screen.dart';
import 'stop_lines_screen.dart';

/// Arama ekranı — Stitch "Arama Ekranı (Koyu Mod)" portu.
///
/// Sekme olarak (Rotalar) ya da ana sayfadaki arama kutusundan tam sayfa
/// olarak açılır. Yazmaya başlayınca gerçek hat/durak verisinde arar;
/// boşken tasarımdaki "Son Aramalar" ve "Yakındaki Duraklar" önerilerini gösterir.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key, this.asPage = false});

  /// true ise geri oku gösterir (ana sayfadan push edilmiş tam sayfa hali).
  final bool asPage;

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  String _query = '';
  final _controller = TextEditingController();

  /// Sesli arama — mikrofon izni YALNIZCA butona ilk basıldığında istenir
  /// (uygulama açılışında değil; speech_to_text initialize sırasında sorar).
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _speechReady = false;
  bool _listening = false;

  /// Dinleme panelinin durumu (o ana kadar duyulan metin + ses seviyesi).
  String _heard = '';
  double _level = 0;
  bool _sheetOpen = false;
  bool _sheetListening = false;

  /// Paneli yeniden çizen geri çağırım (panel açıkken atanır).
  void Function({bool? listening}) _setSheet = ({bool? listening}) {};

  @override
  void dispose() {
    _controller.dispose();
    _speech.stop();
    super.dispose();
  }

  /// Sesli arama: mikrofon izni YALNIZCA ilk dokunuşta istenir; dinleme
  /// süresince ne duyulduğunu gösteren bir alt sayfa açılır.
  Future<void> _toggleVoice() async {
    Haptics.light();
    if (_listening) {
      await _stopListening();
      return;
    }
    if (!_speechReady) {
      // İlk dokunuş: mikrofon/konuşma izni burada istenir.
      _speechReady = await _speech.initialize(
        onStatus: (s) {
          if (!mounted) return;
          if (s == 'done' || s == 'notListening') {
            _setSheet(listening: false);
            setState(() => _listening = false);
          }
        },
        onError: (_) {
          if (!mounted) return;
          _setSheet(listening: false);
          setState(() => _listening = false);
        },
      );
      if (!_speechReady) {
        if (mounted) {
          _snack('Sesli arama kullanılamıyor — mikrofon izni gerekiyor.');
        }
        return;
      }
    }

    setState(() {
      _listening = true;
      _heard = '';
      _level = 0;
    });

    // Dinleme paneli: duyulan metni ve ses seviyesini canlı gösterir.
    if (!mounted) return;
    _sheetOpen = true;
    final sheet = showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: VigilantColors.surfaceContainer,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) => StatefulBuilder(
        builder: (context, setSheetState) {
          _setSheet = ({bool? listening}) {
            if (listening != null) _sheetListening = listening;
            setSheetState(() {});
          };
          return VoiceSearchSheet(
            words: _heard,
            listening: _sheetListening,
            level: _level,
            onStop: () => _stopListening(),
          );
        },
      ),
    );
    _sheetListening = true;
    sheet.whenComplete(() => _sheetOpen = false);

    await _speech.listen(
      listenOptions: stt.SpeechListenOptions(localeId: 'tr_TR'),
      onSoundLevelChange: (v) {
        // -2..10 civarı geliyor; 0..1'e sıkıştır.
        _level = ((v + 2) / 12).clamp(0.0, 1.0);
        _setSheet();
      },
      onResult: (r) {
        if (!mounted) return;
        _heard = r.recognizedWords;
        _setSheet();
        setState(() {
          _query = _heard;
          _controller.text = _heard;
          _controller.selection =
              TextSelection.collapsed(offset: _controller.text.length);
        });
        if (r.finalResult) _stopListening();
      },
    );
  }

  /// Dinlemeyi bitir ve paneli kapat (tek çıkış noktası).
  Future<void> _stopListening() async {
    await _speech.stop();
    if (!mounted) return;
    setState(() => _listening = false);
    if (_sheetOpen) {
      _sheetOpen = false;
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final lines = ref.watch(linesProvider).valueOrNull ?? const <TransitLine>[];
    final q = _query.trim().toLowerCase();

    final results = <(TransitLine, Stop)>[];
    if (q.isNotEmpty) {
      for (final line in lines) {
        for (final stop in line.stops) {
          if (stop.name.toLowerCase().contains(q) ||
              line.code.toLowerCase().contains(q)) {
            results.add((line, stop));
          }
        }
      }
    }

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Başlık çubuğu
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: Row(
                children: [
                  if (widget.asPage)
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.arrow_back,
                          color: VigilantColors.onSurfaceVariant),
                    )
                  else
                    const SizedBox(width: 48),
                  Expanded(
                    child: Text(
                      'Nereye Gitmek İstersiniz?',
                      textAlign: TextAlign.center,
                      style: text.headlineSmall?.copyWith(fontSize: 20),
                    ),
                  ),
                  const SizedBox(width: 48),
                ],
              ),
            ),
            const SizedBox(height: 16),
            // Arama girişi
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: GlassPanel(
                borderRadius: 24,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    const Icon(Icons.search, color: VigilantColors.primary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        autofocus: widget.asPage,
                        style: text.bodyLarge,
                        decoration: InputDecoration(
                          border: InputBorder.none,
                          hintText: _listening
                              ? 'Dinliyorum…'
                              : 'Durak veya hat ara...',
                          hintStyle: text.bodyLarge?.copyWith(
                            color: _listening
                                ? VigilantColors.primary
                                : VigilantColors.onSurfaceVariant,
                          ),
                          contentPadding:
                              const EdgeInsets.symmetric(vertical: 16),
                        ),
                        onChanged: (v) => setState(() => _query = v),
                      ),
                    ),
                    // Sesli arama — izin ilk dokunuşta istenir.
                    GestureDetector(
                      onTap: _toggleVoice,
                      behavior: HitTestBehavior.opaque,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Icon(
                          _listening ? Icons.mic : Icons.mic_none,
                          color: _listening
                              ? VigilantColors.primary
                              : VigilantColors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            Expanded(
              child: q.isEmpty
                  ? _SuggestionsView(
                      onStopTap: _openAlarmSetup,
                      onRecentTap: _openRecent,
                    )
                  : _ResultsView(
                      transitResults: results,
                      busAsync: ref.watch(busSearchProvider(_query.trim())),
                      onTransitStop: (line, stop) =>
                          _openAlarmSetup(stop.name, line: line, stop: stop),
                      onBusLine: _openBusLine,
                      onBusStop: _openBusStop,
                    ),
            ),
          ],
        ),
      ),
    );
  }

  void _openAlarmSetup(String stopName, {TransitLine? line, Stop? stop}) {
    if (line != null && stop != null) {
      final notifier = ref.read(journeyDraftProvider.notifier)
        ..reset()
        ..selectLine(line);
      notifier.selectTargetStop(stop.id);
      // Seçim, "Son Aramalar"a kalıcı olarak yazılır.
      ref.read(recentSearchesProvider.notifier).add(RecentSearch(
            stopName: stop.name,
            stopId: stop.id,
            lineId: line.id,
            lineCode: line.code,
            lineTypeName: line.type.name,
          ));
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AlarmSetupScreen(
          stopName: stopName,
          lineLabel: line?.code,
        ),
      ),
    );
  }

  /// Son arama kaydını gerçek hat verisiyle yeniden çözer ve alarma taşır.
  void _openRecent(RecentSearch entry) {
    final lines = ref.read(linesProvider).valueOrNull ?? const <TransitLine>[];
    TransitLine? line;
    Stop? stop;
    for (final l in lines) {
      if (l.id != entry.lineId) continue;
      line = l;
      final i = l.indexOfStop(entry.stopId);
      if (i != -1) stop = l.stops[i];
      break;
    }
    // Hat artık yoksa ada göre çözüm alarm kurulum ekranına kalır.
    if (stop == null) line = null;
    _openAlarmSetup(stop?.name ?? entry.stopName, line: line, stop: stop);
  }

  /// Otobüs hattı seçildi: tek hat sayfasını aç (gidiş/dönüş + duraklar).
  void _openBusLine(TransitLineBrief brief) {
    Haptics.light();
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => LineDetailScreen(code: brief.code)),
    );
  }

  /// Otobüs durağı seçildi (hedef olarak): duraktan geçen hatları TEMİZ tam
  /// ekranda sun; kullanıcı hangi hatla gittiğini seçince o hatla alarma geçilir.
  Future<void> _openBusStop(Stop stop) async {
    Haptics.light();
    final lines = await TransitDb.instance.linesForStop(stop.id);
    if (!mounted) return;
    if (lines.isEmpty) {
      _snack('Bu duraktan geçen hat bulunamadı.');
      return;
    }
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => StopLinesScreen(stop: stop, lines: lines),
    ));
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

class _SuggestionsView extends ConsumerWidget {
  const _SuggestionsView({required this.onStopTap, required this.onRecentTap});

  final void Function(String stopName, {TransitLine? line, Stop? stop})
      onStopTap;
  final void Function(RecentSearch entry) onRecentTap;

  String _fmtMeters(double m) => m >= 1000
      ? '${(m / 1000).toStringAsFixed(1).replaceAll('.', ',')} km'
      : '${m.round()} m';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final recents =
        ref.watch(recentSearchesProvider).valueOrNull ?? const <RecentSearch>[];
    final nearby = ref.watch(nearbyStopsProvider);

    return ListView(
      padding: EdgeInsets.fromLTRB(20, 0, 20, AppInsets.listBottom(context)),
      children: [
        const _SectionLabel(icon: Icons.history, label: 'SON ARAMALAR'),
        const SizedBox(height: 12),
        if (recents.isEmpty)
          Text(
            'Henüz arama yok — seçtiğin duraklar burada listelenecek.',
            style: text.labelMedium
                ?.copyWith(color: VigilantColors.onSurfaceVariant),
          )
        else
          for (var i = 0; i < recents.length; i++) ...[
            if (i > 0) const SizedBox(height: 12),
            _RecentTile(
              name: recents[i].stopName,
              subtitle: recents[i].lineCode,
              icon: lineTypeIcon(recents[i].lineType),
              onTap: () => onRecentTap(recents[i]),
            ),
          ],
        const SizedBox(height: 32),
        const _SectionLabel(
            icon: Icons.near_me_outlined, label: 'YAKINDAKİ DURAKLAR'),
        const SizedBox(height: 12),
        ...nearby.when(
          // İskelet yer tutucular (AppAnim kapalıysa statik — testleri kilitlemez).
          loading: () => const [
            SkeletonTile(),
            SizedBox(height: 12),
            SkeletonTile(),
            SizedBox(height: 12),
            SkeletonTile(),
          ],
          error: (_, __) => [
            Text(
              'Yakındaki duraklar alınamadı.',
              style: text.labelMedium
                  ?.copyWith(color: VigilantColors.onSurfaceVariant),
            ),
          ],
          data: (hits) => hits.isEmpty
              ? [
                  Text(
                    'Konum kapalı — yakındaki durakları görmek için '
                    'konum izni ver.',
                    style: text.labelMedium
                        ?.copyWith(color: VigilantColors.onSurfaceVariant),
                  ),
                ]
              : [
                  for (var i = 0; i < hits.length; i++) ...[
                    if (i > 0) const SizedBox(height: 12),
                    _NearbyTile(
                      name: hits[i].stop.name,
                      meta:
                          '${_fmtMeters(hits[i].meters)} • ${hits[i].line.code}'
                          ' ${hits[i].line.type.label}',
                      onTap: () => onStopTap(
                        hits[i].stop.name,
                        line: hits[i].line,
                        stop: hits[i].stop,
                      ),
                    ),
                  ],
                ],
        ),
      ],
    );
  }
}

class _ResultsView extends StatelessWidget {
  const _ResultsView({
    required this.transitResults,
    required this.busAsync,
    required this.onTransitStop,
    required this.onBusLine,
    required this.onBusStop,
  });

  final List<(TransitLine, Stop)> transitResults;
  final AsyncValue<BusSearchResults> busAsync;
  final void Function(TransitLine line, Stop stop) onTransitStop;
  final void Function(TransitLineBrief brief) onBusLine;
  final void Function(Stop stop) onBusStop;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final bus = busAsync.valueOrNull ?? const BusSearchResults();
    final busLoading = busAsync.isLoading;
    final nothing = transitResults.isEmpty && bus.isEmpty && !busLoading;

    if (nothing) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // STOPİ "Dikkat!" — sonuç yok.
            const Mascot(MascotAssets.dikkat, height: 110),
            const SizedBox(height: 12),
            Text(
              'Sonuç bulunamadı.',
              style: text.bodyMedium
                  ?.copyWith(color: VigilantColors.onSurfaceVariant),
            ),
          ],
        ),
      );
    }

    final children = <Widget>[];

    // Otobüs hatları — numarayla aramada en alakalı (ör. "500T").
    if (bus.lines.isNotEmpty) {
      children.add(const _SectionLabel(
          icon: Icons.directions_bus_filled_rounded, label: 'OTOBÜS HATLARI'));
      children.add(const SizedBox(height: 12));
      for (final b in bus.lines) {
        children.add(_LineResultTile(brief: b, onTap: () => onBusLine(b)));
        children.add(const SizedBox(height: 12));
      }
      children.add(const SizedBox(height: 20));
    }

    // Ray & vapur durakları (mevcut davranış — durak = hedef).
    if (transitResults.isNotEmpty) {
      children.add(const _SectionLabel(
          icon: Icons.directions_transit_rounded, label: 'RAY & VAPUR'));
      children.add(const SizedBox(height: 12));
      for (final (line, stop) in transitResults) {
        children.add(_TransitResultTile(
            line: line, stop: stop, onTap: () => onTransitStop(line, stop)));
        children.add(const SizedBox(height: 12));
      }
      children.add(const SizedBox(height: 20));
    }

    // Otobüs durakları — durak = hedef; hangi hatla gidileceği seçilir.
    if (bus.stops.isNotEmpty) {
      children.add(const _SectionLabel(
          icon: Icons.location_on_outlined, label: 'OTOBÜS DURAKLARI'));
      children.add(const SizedBox(height: 12));
      for (final s in bus.stops) {
        children.add(_BusStopTile(stop: s, onTap: () => onBusStop(s)));
        children.add(const SizedBox(height: 12));
      }
    }

    if (busLoading && transitResults.isEmpty && bus.isEmpty) {
      children.addAll(const [
        SkeletonTile(),
        SizedBox(height: 12),
        SkeletonTile(),
      ]);
    }

    return ListView(
      padding: EdgeInsets.fromLTRB(20, 0, 20, AppInsets.listBottom(context)),
      children: children,
    );
  }
}

/// Ray/vapur durak sonucu (durak adı + hat kodu • tür).
class _TransitResultTile extends StatelessWidget {
  const _TransitResultTile(
      {required this.line, required this.stop, required this.onTap});

  final TransitLine line;
  final Stop stop;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final color = lineTypeColor(line.type);
    return GlassPanel(
      borderRadius: 24,
      padding: const EdgeInsets.all(16),
      onTap: onTap,
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: VigilantColors.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(lineTypeIcon(line.type), color: color),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(stop.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w500)),
                const SizedBox(height: 2),
                Text(
                  '${line.code} • ${line.type.label}'
                  '${stop.underground ? ' • Yeraltı' : ''}',
                  style: text.labelMedium
                      ?.copyWith(color: VigilantColors.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const Icon(Icons.arrow_forward,
              color: VigilantColors.primary, size: 20),
        ],
      ),
    );
  }
}

/// Otobüs hattı sonucu (kod + güzergâh adı). Dokununca hedef durak seçilir.
class _LineResultTile extends StatelessWidget {
  const _LineResultTile({required this.brief, required this.onTap});

  final TransitLineBrief brief;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    const color = VigilantColors.primary;
    return GlassPanel(
      borderRadius: 24,
      padding: const EdgeInsets.all(16),
      onTap: onTap,
      child: Row(
        children: [
          Container(
            constraints: const BoxConstraints(minWidth: 48),
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(brief.code,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.labelLarge
                    ?.copyWith(color: color, fontWeight: FontWeight.w800)),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(brief.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w500)),
                const SizedBox(height: 2),
                Text('Otobüs hattı',
                    style: text.labelMedium
                        ?.copyWith(color: VigilantColors.onSurfaceVariant)),
              ],
            ),
          ),
          const Icon(Icons.chevron_right,
              color: VigilantColors.primary, size: 22),
        ],
      ),
    );
  }
}

/// Otobüs durağı sonucu. Dokununca hangi hatla gidileceği seçilir.
class _BusStopTile extends StatelessWidget {
  const _BusStopTile({required this.stop, required this.onTap});

  final Stop stop;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return GlassPanel(
      borderRadius: 24,
      padding: const EdgeInsets.all(16),
      onTap: onTap,
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: VigilantColors.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Icon(Icons.directions_bus_filled_rounded,
                color: VigilantColors.onSurfaceVariant),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(stop.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w500)),
                const SizedBox(height: 2),
                Text(
                    stop.contextLabel.isNotEmpty
                        ? 'Otobüs · ${stop.contextLabel}'
                        : 'Otobüs durağı',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.labelMedium
                        ?.copyWith(color: VigilantColors.onSurfaceVariant)),
              ],
            ),
          ),
          const Icon(Icons.arrow_forward,
              color: VigilantColors.primary, size: 20),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16, color: VigilantColors.onSurfaceVariant),
        const SizedBox(width: 8),
        Text(
          label,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: VigilantColors.onSurfaceVariant,
                letterSpacing: 1.2,
              ),
        ),
      ],
    );
  }
}

class _RecentTile extends StatelessWidget {
  const _RecentTile({
    required this.name,
    required this.icon,
    required this.onTap,
    this.subtitle,
  });

  final String name;
  final String? subtitle;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return GlassPanel(
      borderRadius: 24,
      padding: const EdgeInsets.all(16),
      onTap: onTap,
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: VigilantColors.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(icon, color: VigilantColors.onSurfaceVariant),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                ),
                if (subtitle != null && subtitle!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      subtitle!,
                      style: text.labelMedium
                          ?.copyWith(color: VigilantColors.onSurfaceVariant),
                    ),
                  ),
              ],
            ),
          ),
          const Icon(Icons.north_west,
              size: 18, color: VigilantColors.onSurfaceVariant),
        ],
      ),
    );
  }
}

class _NearbyTile extends StatelessWidget {
  const _NearbyTile({
    required this.name,
    required this.meta,
    required this.onTap,
  });

  final String name;
  final String meta;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return GlassPanel(
      borderRadius: 24,
      padding: const EdgeInsets.all(16),
      onTap: onTap,
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: VigilantColors.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: VigilantColors.primary.withValues(alpha: 0.3),
              ),
              boxShadow: [
                BoxShadow(
                  color: VigilantColors.accentBlue.withValues(alpha: 0.2),
                  blurRadius: 15,
                ),
              ],
            ),
            child: const Icon(Icons.location_on, color: VigilantColors.primary),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    style:
                        text.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
                const SizedBox(height: 4),
                Row(
                  children: [
                    const Icon(Icons.directions_walk,
                        size: 14, color: VigilantColors.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        meta,
                        overflow: TextOverflow.ellipsis,
                        style: text.labelMedium
                            ?.copyWith(color: VigilantColors.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Icon(Icons.arrow_forward,
              color: VigilantColors.primary, size: 20),
        ],
      ),
    );
  }
}
