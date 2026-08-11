import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart' show TemplateType;
import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../data/models.dart';
import '../data/recent_search.dart';
import '../data/search_filter.dart';
import '../data/transit_city.dart';
import '../data/transit_db.dart';
import '../state/city_provider.dart';
import '../state/journey_provider.dart';
import '../state/settings_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/native_ad_slot.dart';
import '../util/insets.dart';
import '../util/haptics.dart';
import '../widgets/glass_panel.dart';
import '../widgets/mascot.dart';
import '../widgets/skeleton.dart';
import '../widgets/voice_search_sheet.dart';
import 'alarm_setup_screen.dart';
import 'recent_searches_screen.dart';
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
    // Duraklar sekmesinden taşınan sorgu (ör. orada "147" arandı).
    final pending = ref.watch(pendingLineQueryProvider);
    if (pending != null && pending.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _controller.text = pending;
        setState(() => _query = pending);
        ref.read(pendingLineQueryProvider.notifier).state = null;
      });
    }
    final q = _query.trim().toLowerCase();
    // Süzgeç AYARLARDAN gelir: uygulama kapanıp açılınca seçim korunur.
    final filter = (ref.watch(settingsProvider).valueOrNull ??
            const AppSettings())
        .searchFilterValue;

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
                      'Nerede İneceksin?',
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
                              : 'İneceğin durağı veya hattı ara...',
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
            // TÜR ÇİPLERİ — yalnızca yazmaya başlayınca. Boş ekranda yer
            // kaplamalarının anlamı yok; süzgeç sonuç varken işe yarar.
            if (q.isNotEmpty) ...[
              const SizedBox(height: 14),
              _FilterChips(
                selected: filter,
                onSelected: (f) {
                  Haptics.selection();
                  ref.read(settingsProvider.notifier).setSearchFilter(f);
                },
              ),
            ],
            const SizedBox(height: 24),
            Expanded(
              child: q.isEmpty
                  ? _SuggestionsView(
                      onStopTap: _openAlarmSetup,
                      onRecentTap: _openRecent,
                    )
                  : _ResultsView(
                      railLines: _railLines(q, filter),
                      transitResults: results,
                      busAsync: ref.watch(busSearchProvider(_query.trim())),
                      activeCity: ref.watch(activeCityProvider),
                      filter: filter,
                      onTransitStop: (line, stop) =>
                          _openAlarmSetup(stop.name, line: line, stop: stop),
                      onBusLine: _openBusLine,
                      onRailLine: _openRailLine,
                      onBusStop: _openBusStop,
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// Ray/vapur hattını aç (hat sayfası: yön, duraklar, alarm).
  void _openRailLine(TransitLine line) {
    Haptics.light();
    ref.read(recentSearchesProvider.notifier).add(RecentSearch(
          stopName: line.name,
          stopId: '',
          lineId: line.id,
          lineCode: line.code,
          lineTypeName: line.type.name,
          cityId: ref.read(activeCityProvider).id,
        ));
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => LineDetailScreen(code: line.code, type: line.type),
    ));
  }

  /// Sorguya uyan RAY/VAPUR hatları.
  ///
  /// Bunlar indirilen SQLite paketinde DEĞİL, ayrı listede (lines.json) —
  /// bu yüzden Hatlar aramasında Marmaray/metro hiç çıkmıyordu.
  List<TransitLine> _railLines(String q, SearchFilter filter) {
    if (q.isEmpty) return const [];
    final n = transitNorm(q);
    final compact = compactLineCode(q);
    final out = <TransitLine>[];
    final seen = <String>{};
    for (final l in ref.read(linesProvider).valueOrNull ??
        const <TransitLine>[]) {
      if (!filter.accepts(l.type)) continue;
      final hit = compactLineCode(l.code).contains(compact) ||
          transitNorm(l.name).contains(n);
      if (!hit || !seen.add(l.code)) continue;
      out.add(l);
    }
    out.sort((a, b) => a.code.compareTo(b.code));
    return out;
  }

  /// [cityId] verilmezse aktif şehir damgalanır. Son arama kaydından gelen
  /// çağrılarda kaydın KENDİ şehri geçilir; aksi halde başka şehirden açılan
  /// bir hat, tekrar yazılırken aktif şehre kaymış oluyordu.
  void _openAlarmSetup(String stopName,
      {TransitLine? line, Stop? stop, String? cityId}) {
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
            cityId: cityId ?? ref.read(activeCityProvider).id,
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
  ///
  /// İki tür kayıt var: DURAKLI (hat + hedef durak → doğrudan alarm kurulumu)
  /// ve DURAKSIZ (yalnızca hat → hat sayfası). Duraksız kayıt `stopId` boş
  /// olanıdır; kullanıcı aramada "147"ye dokunduğunda böyle yazılır.
  Future<void> _openRecent(RecentSearch entry) async {
    // Kayıt HANGİ ŞEHİRDEN geldiyse oradan çözülür. Aktif şehirden çözmek,
    // aynı kodun iki şehirde bulunduğu durumda (147) yanlış hattı açıyor,
    // bulunamadığında da sayfayı boş bırakıyordu.
    final active = ref.read(activeCityProvider);
    final entryCity = entry.cityId.isEmpty ? active : TransitCities.byId(entry.cityId);
    final other = entryCity.id == active.id ? null : entryCity;

    if (entry.stopId.isEmpty) {
      Haptics.light();
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => LineDetailScreen(
            code: entry.lineCode,
            city: other,
            type: entry.lineType,
          ),
        ),
      );
      return;
    }
    // Otobüs hatları gömülü listede değil, indirilen DB'de.
    if (isBusId(entry.lineId)) {
      final line =
          await TransitDb.instance.buildLine(entry.lineId, cityId: other?.id);
      if (!mounted) return;
      final i = line?.indexOfStop(entry.stopId) ?? -1;
      if (line != null && i != -1) {
        _openAlarmSetup(line.stops[i].name,
            line: line, stop: line.stops[i], cityId: entryCity.id);
        return;
      }
      _openAlarmSetup(entry.stopName, cityId: entryCity.id);
      return;
    }
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
    _openAlarmSetup(stop?.name ?? entry.stopName,
        line: line, stop: stop, cityId: entryCity.id);
  }

  /// Otobüs hattı seçildi: tek hat sayfasını aç (gidiş/dönüş + duraklar).
  /// Otobüs hattı seçildi. AKTİF ŞEHİR DEĞİŞMEZ: hat sayfası doğrudan o
  /// şehrin paketinden okur. Kullanıcı yalnızca bakmak için şehir
  /// değiştirmek zorunda kalmasın — şehir Ayarlar'dan bilinçli seçilir.
  Future<void> _openBusLine(TransitLineBrief brief, TransitCity city) async {
    Haptics.light();
    // Hat seçimi de "Son Aramalar"a yazılır: kullanıcı 147'yi arayıp açtıysa
    // ertesi gün tekrar aramak zorunda kalmamalı. Durak henüz seçilmediği
    // için kayıt DURAKSIZ olur (bkz. [_openRecent]).
    ref.read(recentSearchesProvider.notifier).add(RecentSearch(
          stopName: brief.name.isEmpty ? brief.code : brief.name,
          stopId: '',
          lineId: brief.id,
          lineCode: brief.code,
          lineTypeName: brief.type.name,
          // ŞEHRİ YAZ: aynı kod iki şehirde olabiliyor (147). Yazılmazsa
          // kayıt tekrar açılırken yanlış şehrin hattına gidiyordu.
          cityId: city.id,
        ));
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LineDetailScreen(
          code: brief.code,
          city: city.id == ref.read(activeCityProvider).id ? null : city,
          type: brief.type,
        ),
      ),
    );
  }

  /// Otobüs durağı seçildi (hedef olarak): duraktan geçen hatları TEMİZ tam
  /// ekranda sun; kullanıcı hangi hatla gittiğini seçince o hatla alarma geçilir.
  Future<void> _openBusStop(Stop stop, TransitCity city) async {
    Haptics.light();
    final other =
        city.id == ref.read(activeCityProvider).id ? null : city;
    final lines =
        await TransitDb.instance.linesForStop(stop.id, cityId: other?.id);
    if (!mounted) return;
    if (lines.isEmpty) {
      _snack('Bu duraktan geçen hat bulunamadı.');
      return;
    }
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) =>
          StopLinesScreen(stop: stop, lines: lines, city: other),
    ));
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

/// Arama girişinde gösterilen son arama sayısı.
const _recentPreviewCount = 3;

class _SuggestionsView extends ConsumerWidget {
  const _SuggestionsView({required this.onStopTap, required this.onRecentTap});

  final void Function(String stopName, {TransitLine? line, Stop? stop})
      onStopTap;
  final void Function(RecentSearch entry) onRecentTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final recents =
        ref.watch(recentSearchesProvider).valueOrNull ?? const <RecentSearch>[];

    return ListView(
      padding: EdgeInsets.fromLTRB(20, 0, 20, AppInsets.listBottom(context)),
      children: [
        // Listede yalnızca EN SON 3 kayıt durur: bu bölüm arama ekranının
        // girişi, arşivi değil. Tamamı "Tümünü gör" ile ayrı sayfada.
        _SectionLabel(
          icon: Icons.history,
          label: 'SON ARAMALAR',
          trailing: recents.length > _recentPreviewCount
              ? TextButton(
                  onPressed: () {
                    Haptics.light();
                    Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) =>
                          RecentSearchesScreen(onOpen: onRecentTap),
                    ));
                  },
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(
                    'Tümünü gör',
                    style: text.labelMedium
                        ?.copyWith(color: VigilantColors.primary),
                  ),
                )
              : null,
        ),
        const SizedBox(height: 12),
        if (recents.isEmpty)
          Text(
            'Henüz arama yok — seçtiğin duraklar burada listelenecek.',
            style: text.labelMedium
                ?.copyWith(color: VigilantColors.onSurfaceVariant),
          )
        else
          for (var i = 0;
              i < recents.length && i < _recentPreviewCount;
              i++) ...[
            if (i > 0) const SizedBox(height: 12),
            _RecentTile(
              name: recents[i].stopName,
              subtitle: recents[i].lineCode,
              icon: lineTypeIcon(recents[i].lineType),
              onTap: () => onRecentTap(recents[i]),
            ),
          ],
        // YAKINDAKİ DURAKLAR buradan kaldırıldı: duraklar artık kendi
        // sekmesinde (Duraklar), orada hem yakındakiler hem arama var.
      ],
    );
  }
}

class _ResultsView extends StatelessWidget {
  const _ResultsView({
    required this.railLines,
    required this.transitResults,
    required this.busAsync,
    required this.activeCity,
    required this.filter,
    required this.onTransitStop,
    required this.onBusLine,
    required this.onRailLine,
    required this.onBusStop,
  });

  /// Ray/vapur HATLARI (lines.json) — otobüs paketinde bulunmazlar.
  final List<TransitLine> railLines;

  final List<(TransitLine, Stop)> transitResults;
  final AsyncValue<BusSearchResults> busAsync;

  /// Bulunulan şehir — sonuç başka şehirdense rozeti gösterilir.
  final TransitCity activeCity;

  /// Tür süzgeci (çip şeridi).
  final SearchFilter filter;
  final void Function(TransitLine line, Stop stop) onTransitStop;
  final void Function(TransitLineBrief brief, TransitCity city) onBusLine;

  /// Ray/vapur hattı seçildi — hat sayfası açılır.
  final void Function(TransitLine line) onRailLine;
  final void Function(Stop stop, TransitCity city) onBusStop;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final bus = busAsync.valueOrNull ?? const BusSearchResults();
    final busLoading = busAsync.isLoading;

    // SÜZGEÇ burada uygulanır (sorguda değil): kaynaklar farklı sağlayıcılardan
    // geliyor ve her birine ayrı süzgeç geçirmek dört yerde aynı kuralı
    // tekrarlamak olurdu.
    final metrobus = [
      for (final b in bus.lines)
        if (b.line.isMetrobus && filter.accepts(LineType.metrobus)) b,
    ];
    final busOnly = [
      for (final b in bus.lines)
        if (!b.line.isMetrobus && filter.accepts(LineType.bus)) b,
    ];
    final nothing =
        metrobus.isEmpty && busOnly.isEmpty && railLines.isEmpty && !busLoading;

    if (nothing) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // STOPİ "Dikkat!" — sonuç yok.
            const Mascot(MascotAssets.dikkat, height: 110),
            const SizedBox(height: 12),
            Text(
              filter == SearchFilter.tumu
                  ? 'Sonuç bulunamadı.'
                  : '${filter.label} sonucu yok — "Tümü"ne bakabilirsin.',
              textAlign: TextAlign.center,
              style: text.bodyMedium
                  ?.copyWith(color: VigilantColors.onSurfaceVariant),
            ),
          ],
        ),
      );
    }

    final children = <Widget>[];

    if (metrobus.isNotEmpty) {
      children.add(const _SectionLabel(
          icon: Icons.airport_shuttle_rounded, label: 'METROBÜS'));
      children.add(const SizedBox(height: 12));
      for (final b in metrobus) {
        children.add(_LineResultTile(
            brief: b.line,
            city: b.city,
            showCity: b.city.id != activeCity.id,
            onTap: () => onBusLine(b.line, b.city)));
        children.add(const SizedBox(height: 12));
      }
      children.add(const SizedBox(height: 20));
    }

    // Otobüs hatları — numarayla aramada en alakalı (ör. "500T").
    if (busOnly.isNotEmpty) {
      children.add(const _SectionLabel(
          icon: Icons.directions_bus_filled_rounded, label: 'OTOBÜS HATLARI'));
      children.add(const SizedBox(height: 12));
      for (final b in busOnly) {
        children.add(_LineResultTile(
            brief: b.line,
            city: b.city,
            showCity: b.city.id != activeCity.id,
            onTap: () => onBusLine(b.line, b.city)));
        children.add(const SizedBox(height: 12));
      }
      children.add(const SizedBox(height: 20));
    }

    // RAY & VAPUR hatları (Marmaray, metro, tramvay, vapur).
    if (railLines.isNotEmpty) {
      children.add(const _SectionLabel(
          icon: Icons.directions_transit_rounded, label: 'RAY & VAPUR'));
      children.add(const SizedBox(height: 12));
      for (final l in railLines) {
        children.add(_RailLineTile(line: l, onTap: () => onRailLine(l)));
        children.add(const SizedBox(height: 12));
      }
      children.add(const SizedBox(height: 20));
    }

    // DURAK sonuçları burada YOK — onlar Duraklar sekmesinde.
    // Hat ve durak tek listede karışınca "Şişli" yazan kullanıcı ne aradığını
    // bulamıyordu; her sekme tek bir şeye cevap veriyor.

    if (busLoading && children.isEmpty) {
      children.addAll(const [
        SkeletonTile(),
        SizedBox(height: 12),
        SkeletonTile(),
      ]);
    }

    // ARAMA SONUÇLARININ SONUNDA yerel reklam. Sonuçların ARASINA koymak
    // kullanıcının aradığı hattı kaçırmasına yol açardı; aradığını bulduktan
    // sonra karşısına çıkması hem daha az rahatsız hem daha çok tıklanıyor.
    if (children.isNotEmpty && !busLoading) {
      children.add(const NativeAdSlot(
        margin: EdgeInsets.only(top: 18),
        template: TemplateType.small,
      ));
    }

    return ListView(
      padding: EdgeInsets.fromLTRB(20, 0, 20, AppInsets.listBottom(context)),
      children: children,
    );
  }
}

/// Ray/vapur durak sonucu (durak adı + hat kodu • tür).
class _LineResultTile extends StatelessWidget {
  const _LineResultTile({
    required this.brief,
    required this.city,
    required this.showCity,
    required this.onTap,
  });

  final TransitLineBrief brief;
  final TransitCity city;

  /// Sonuç bulunulan şehirden DEĞİLSE rozet gösterilir; aksi halde her satıra
  /// gereksiz "İstanbul" yazmak listeyi gürültüye boğardı.
  final bool showCity;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    // Metrobüs kendi rengiyle ayrışsın (arama sonucunda "Otobüs hattı"
    // yazması yanlıştı).
    final color = lineColorOf(brief.color, brief.type);
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
                _CityBadge(name: city.name, isCurrent: !showCity),
                Text('${brief.type.label} hattı',
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
/// Sonucun hangi şehre ait olduğunu gösteren rozet.
///
/// HER sonuçta yazılır: arama bütün kurulu paketlerde yapıldığı için "İZMİT"
/// ile İstanbul'daki "İZMİT CADDESİ" aynı listede çıkabiliyor. Bulunulan
/// şehir marka renginde, diğerleri mavi — ikisi de aynı netlikte okunur,
/// biri soluk bırakılmaz.
class _CityBadge extends StatelessWidget {
  const _CityBadge({required this.name, required this.isCurrent});

  final String name;
  final bool isCurrent;

  @override
  Widget build(BuildContext context) {
    final color =
        isCurrent ? VigilantColors.primary : VigilantColors.accentBlue;
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.22),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: color.withValues(alpha: 0.45)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                    isCurrent
                        ? Icons.my_location_rounded
                        : Icons.location_city_rounded,
                    size: 10,
                    color: color),
                const SizedBox(width: 4),
                Text(name,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: color, fontWeight: FontWeight.w700)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.icon, required this.label, this.trailing});

  final IconData icon;
  final String label;

  /// Başlığın sağındaki eylem (ör. "Tümünü gör").
  final Widget? trailing;

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
        if (trailing != null) ...[const Spacer(), trailing!],
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

class _FilterChips extends StatelessWidget {
  const _FilterChips({required this.selected, required this.onSelected});

  final SearchFilter selected;
  final ValueChanged<SearchFilter> onSelected;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return SizedBox(
      height: 38,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        itemCount: SearchFilter.values.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final f = SearchFilter.values[i];
          final on = f == selected;
          return Material(
            color: on
                ? VigilantColors.primary.withValues(alpha: 0.16)
                : VigilantColors.surfaceContainer,
            borderRadius: BorderRadius.circular(999),
            child: InkWell(
              onTap: () => onSelected(f),
              borderRadius: BorderRadius.circular(999),
              child: Container(
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: on
                        ? VigilantColors.primary.withValues(alpha: 0.55)
                        : VigilantColors.surfaceVariant.withValues(alpha: 0.5),
                  ),
                ),
                child: Text(
                  f.label,
                  style: text.labelLarge?.copyWith(
                    color: on
                        ? VigilantColors.primary
                        : VigilantColors.onSurfaceVariant,
                    fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Ray/vapur hat sonucu (kod + güzergâh adı).
class _RailLineTile extends StatelessWidget {
  const _RailLineTile({required this.line, required this.onTap});

  final TransitLine line;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final color = lineColorOf(line.color, line.type);
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
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(line.code, style: text.titleSmall),
                const SizedBox(height: 2),
                Text('${line.type.label} · ${line.name}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.labelMedium
                        ?.copyWith(color: VigilantColors.onSurfaceVariant)),
              ],
            ),
          ),
          const Icon(Icons.arrow_forward,
              size: 18, color: VigilantColors.onSurfaceVariant),
        ],
      ),
    );
  }
}
