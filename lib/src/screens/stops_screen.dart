import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart' show TemplateType;

import '../data/models.dart';
import '../data/recent_search.dart';
import '../data/transit_city.dart';
import '../data/transit_db.dart';
import '../services/bus_data_service.dart';
import '../state/city_provider.dart';
import '../state/journey_provider.dart';
import '../theme/app_theme.dart';
import '../util/haptics.dart';
import '../util/insets.dart';
import '../widgets/bottom_nav_shell.dart';
import '../widgets/native_ad_slot.dart';
import '../widgets/skeleton.dart';
import 'line_detail_screen.dart';
import 'nearby_map_screen.dart';
import 'stop_lines_screen.dart';

/// DURAKLAR sekmesi — üstte harita, altta yükseklik ayarlanabilir liste.
///
/// Hatlar sekmesi hat arıyor, burası durak: ikisi tek listede karışınca
/// "Şişli" yazan kullanıcı ne aradığını bulamıyordu.
///
/// Varsayılan görünüm HARİTA: durak arayan kişinin çoğu zaman aradığı yanı
/// başındaki duraktır ve onu listede değil haritada tanır. Arama çubuğuna
/// dokununca tam ekran arama açılır.
class StopsScreen extends ConsumerStatefulWidget {
  const StopsScreen({super.key});

  @override
  ConsumerState<StopsScreen> createState() => _StopsScreenState();
}

class _StopsScreenState extends ConsumerState<StopsScreen> {
  bool _searching = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // Harita + sürüklenebilir yakındaki duraklar paneli. Kendi üst
          // çubuğunu çizmez (embedded); onun yerine arama çubuğu duruyor.
          const Positioned.fill(child: NearbyMapScreen(embedded: true)),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: _SearchBar(
                  onTap: () {
                    Haptics.light();
                    setState(() => _searching = true);
                  },
                ),
              ),
            ),
          ),
          // Arama TAM EKRAN kaplar: harita arkada kalır, kullanıcı geri
          // dönünce baktığı yeri kaybetmez.
          if (_searching)
            Positioned.fill(
              child: _StopSearchView(
                onClose: () => setState(() => _searching = false),
              ),
            ),
        ],
      ),
    );
  }
}

/// Haritanın üstünde yüzen arama çubuğu (dokununca aramayı açar).
class _SearchBar extends StatelessWidget {
  const _SearchBar({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    // OPAK: cam efektinde harita döşemeleri yazının arkasından görünüyor ve
    // "Durak ara" okunmuyordu. Hareket eden bir haritanın üstünde
    // okunabilirlik saydamlıktan önce gelir.
    return Material(
      color: VigilantColors.surfaceContainer,
      borderRadius: BorderRadius.circular(20),
      elevation: 6,
      shadowColor: const Color(0x66000000),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              const Icon(Icons.search,
                  color: VigilantColors.primary, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Text('Durak ara…',
                    style: text.bodyMedium
                        ?.copyWith(color: VigilantColors.onSurfaceVariant)),
              ),
              const Icon(Icons.tune_rounded,
                  size: 18, color: VigilantColors.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

/// Tam ekran durak arama.
///
/// TÜM KURULU ŞEHİRLERDE arar ve her sonucun ilini rozetle yazar: Kocaeli'deki
/// biri İstanbul'daki bir durağa bakmak için ayar değiştirmek zorunda
/// kalmasın, ama hangi ildeki durağa baktığını da karıştırmasın.
class _StopSearchView extends ConsumerStatefulWidget {
  const _StopSearchView({required this.onClose});

  final VoidCallback onClose;

  @override
  ConsumerState<_StopSearchView> createState() => _StopSearchViewState();
}

class _StopSearchViewState extends ConsumerState<_StopSearchView> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  String _query = '';

  /// Durak kimliği -> baskın hat türü ("bus", "marmaray", "metro"…).
  ///
  /// Durak kaydının kendi türü yok; anlamını ondan geçen hatlar veriyor.
  Map<String, String> _types = const {};
  String _typesFor = '';

  /// Sorgu bir HAT KODUNA benziyor mu (Duraklar'da "147" arandı mı)?
  bool _looksLikeLine = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Sonuç listesi için yardımcı bilgiler: durak türleri ve sorgunun bir
  /// HAT KODU olup olmadığı.
  Future<void> _refreshHints(String q) async {
    if (q.length < 2) {
      if (mounted) setState(() => _looksLikeLine = false);
      return;
    }
    try {
      final lines = await TransitDb.instance.searchLines(q, limit: 3);
      if (!mounted || _query.trim() != q) return;
      setState(() => _looksLikeLine = lines.isNotEmpty);
    } catch (_) {
      // Paket yoksa ipucu gösterilmez; arama yine çalışır.
    }
  }

  /// Görünen durakların türlerini tek sorguda çek (sayfa başına bir kez).
  Future<void> _ensureTypes(List<Stop> stops, String key) async {
    if (_typesFor == key) return;
    _typesFor = key;
    final busIds = [for (final s in stops) if (isBusId(s.id)) s.id];
    if (busIds.isEmpty) return;
    try {
      final map = await TransitDb.instance.stopTypes(busIds);
      if (!mounted || _typesFor != key) return;
      setState(() => _types = map);
    } catch (_) {
      // Tür bilinmezse rozet gösterilmez.
    }
  }

  /// Durak künyesini aç: yaklaşan otobüsler + duraktan geçen hatlar.
  Future<void> _open(Stop stop, TransitCity city) async {
    Haptics.light();
    final active = ref.read(activeCityProvider);
    final other = city.id == active.id ? null : city;
    // AÇILAN DURAK GEÇMİŞE YAZILIR. Duraklar sekmesinde arama yapıp bir
    // durağa girmek son aramalara hiç düşmüyordu; ertesi gün aynı durağı
    // baştan aratmak gerekiyordu.
    ref.read(stopRecentSearchesProvider.notifier).add(RecentSearch(
          stopName: stop.name,
          stopId: stop.id,
          lineId: '',
          lineCode: '',
          lineTypeName: 'bus',
          cityId: city.id,
          stopDirection: stop.direction,
        ));
    var lines = const <TransitLineBrief>[];
    if (isBusId(stop.id)) {
      lines = await TransitDb.instance.linesForStop(stop.id, cityId: other?.id);
    } else {
      // Ray/vapur: durağı içeren hatları gömülü listeden topla.
      final rail = ref.read(linesProvider).valueOrNull ?? const <TransitLine>[];
      lines = [
        for (final l in rail)
          if (l.stops.any((s) => s.id == stop.id))
            TransitLineBrief(
                id: l.id, code: l.code, name: l.name, type: l.type),
      ];
    }
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => StopLinesScreen(stop: stop, lines: lines, city: other),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final active = ref.watch(activeCityProvider);
    final q = _query.trim();

    // Otobüs durakları TÜM kurulu şehirlerde aranır (şehir etiketli gelir).
    final busAsync = ref.watch(busSearchProvider(q));
    final bus = busAsync.valueOrNull ?? const BusSearchResults();

    // Ray/vapur durakları ayrı kaynakta — aktif şehrin listesi.
    final norm = transitNorm(q);
    final rail = <(Stop, TransitCity)>[];
    final railTypes = <String, String>{};
    if (q.length >= 2) {
      final seen = <String>{};
      for (final l in ref.read(linesProvider).valueOrNull ??
          const <TransitLine>[]) {
        for (final s in l.stops) {
          if (!transitNorm(s.name).contains(norm)) continue;
          if (!seen.add('${s.name}|${s.direction}')) continue;
          rail.add((s, active));
          railTypes[s.id] = l.type.name;
        }
      }
    }

    final results = <(Stop, TransitCity)>[
      for (final s in bus.stops) (s.stop, s.city),
      ...rail,
    ];

    // Otobüs paketinden gelen durakların türünü tek sorguda çek.
    if (results.isNotEmpty) {
      final key = '$q|${results.length}';
      WidgetsBinding.instance.addPostFrameCallback(
          (_) => _ensureTypes([for (final r in results) r.$1], key));
    }

    return ColoredBox(
      color: VigilantColors.background,
      child: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 16, 8),
              child: Row(
                children: [
                  IconButton(
                    onPressed: widget.onClose,
                    icon: const Icon(Icons.arrow_back,
                        color: VigilantColors.onSurfaceVariant),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      focusNode: _focus,
                      onChanged: (v) {
                        setState(() => _query = v);
                        _refreshHints(v.trim());
                      },
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        isDense: true,
                        filled: true,
                        fillColor: VigilantColors.surfaceContainer,
                        hintText: 'Durak adı ara…',
                        prefixIcon: const Icon(Icons.search,
                            color: VigilantColors.primary),
                        suffixIcon: q.isEmpty
                            ? null
                            : IconButton(
                                icon:
                                    const Icon(Icons.close_rounded, size: 18),
                                onPressed: () {
                                  _controller.clear();
                                  setState(() => _query = '');
                                },
                              ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(18),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _body(text, q, results, busAsync.isLoading, active,
          {..._types, ...railTypes}),
            ),
          ],
        ),
      ),
    );
  }

  /// Arama boşken gösterilen SON ARAMALAR listesi.
  Widget _recents(TextTheme text) {
    final items =
        ref.watch(stopRecentSearchesProvider).valueOrNull ??
            const <RecentSearch>[];
    if (items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'Durak adının en az iki harfini yaz.\n'
            'Kurulu bütün illerde aranır.',
            textAlign: TextAlign.center,
            style: text.bodyMedium
                ?.copyWith(color: VigilantColors.onSurfaceVariant),
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      children: [
        Row(
          children: [
            Expanded(
              child: Text('SON ARAMALAR',
                  style: text.labelSmall?.copyWith(
                      color: VigilantColors.onSurfaceVariant,
                      letterSpacing: 1.2)),
            ),
            InkResponse(
              onTap: () {
                Haptics.light();
                ref.read(stopRecentSearchesProvider.notifier).clear();
              },
              radius: 20,
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Text('Temizle',
                    style: text.labelSmall
                        ?.copyWith(color: VigilantColors.primary)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        for (final e in items) ...[
          _RecentTile(entry: e, onTap: () => _openRecent(e)),
          const SizedBox(height: 8),
        ],
      ],
    );
  }

  /// Son arama kaydını aç: durak varsa durak künyesi, yoksa hat sayfası.
  Future<void> _openRecent(RecentSearch e) async {
    Haptics.light();
    final active = ref.read(activeCityProvider);
    final city = e.cityId.isEmpty ? active : TransitCities.byId(e.cityId);
    final other = city.id == active.id ? null : city;

    if (e.stopId.isNotEmpty) {
      // KURULU PAKETLERİ AÇ ve HEPSİNDE ARA.
      //
      // Kayıt başka şehirden olabiliyor ve o paket yalnızca arama yapılınca
      // açılıyordu; uygulamayı kapatıp açtıktan sonra doğrudan son aramaya
      // dokunmak durağı bulamıyordu.
      await BusDataService.instance.openAllForLookup();
      final stop = await TransitDb.instance.stopByIdAnyCity(e.stopId);
      if (!mounted) return;
      if (stop != null) {
        await _open(stop, city);
        return;
      }
      // DURAK ÇÖZÜLEMEDİ. Bu kayıtta hat kodu yok (durak araması), o yüzden
      // hat sayfasına düşmek BOŞ bir sayfa açıyordu. Sebebini söyleyip
      // kaydı listede bırakmak daha dürüst.
      if (e.lineCode.trim().isEmpty) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            content: Text('${e.stopName} bulunamadı — '
                '${city.name} veri paketi yüklü mü?'),
          ));
        return;
      }
    }
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => LineDetailScreen(
        code: e.lineCode,
        city: other,
        type: e.lineType,
      ),
    ));
  }

  Widget _body(
    TextTheme text,
    String q,
    List<(Stop, TransitCity)> results,
    bool loading,
    TransitCity active,
    Map<String, String> types,
  ) {
    // ARAMA BOŞKEN SON ARAMALAR. Boş bir yönerge yazısı ekranın tamamını
    // harcıyordu; kullanıcının aradığı durak çoğu zaman zaten listede.
    if (q.length < 2) return _recents(text);
    if (results.isEmpty) {
      return loading
          ? ListView(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              children: const [
                SkeletonTile(),
                SizedBox(height: 12),
                SkeletonTile(),
              ],
            )
          : Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text('Durak bulunamadı.',
                    style: text.bodyMedium
                        ?.copyWith(color: VigilantColors.onSurfaceVariant)),
              ),
            );
    }
    // HAT KODU İPUCU: kullanıcı Duraklar'da "147" aradıysa aradığı şey
    // burada değil, Hatlar'da. Boş sonuç göstermek yerine yolu gösteriyoruz.
    final hint = _looksLikeLine ? 1 : 0;
    return ListView.separated(
      padding: EdgeInsets.fromLTRB(20, 0, 20, AppInsets.listBottom(context)),
      // +1: sonuçların SONUNDA yerel reklam. Araya koymak kullanıcının
      // aradığı durağı kaçırmasına yol açardı.
      itemCount: results.length + hint + 1,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        if (i == results.length + hint) {
          return const NativeAdSlot(
            margin: EdgeInsets.only(top: 8),
            template: TemplateType.small,
          );
        }
        if (hint == 1 && i == 0) {
          return _LineHintCard(
            query: q,
            onTap: () {
              Haptics.light();
              // Sorguyu Hatlar sekmesine taşı ve oraya geç.
              ref.read(pendingLineQueryProvider.notifier).state = q;
              ref.read(bottomNavIndexProvider.notifier).state = NavTab.lines;
              widget.onClose();
            },
          );
        }
        final (stop, city) = results[i - hint];
        return _StopResultTile(
          stop: stop,
          city: city,
          isActiveCity: city.id == active.id,
          typeName: types[stop.id],
          onTap: () => _open(stop, city),
        );
      },
    );
  }
}

class _StopResultTile extends StatelessWidget {
  const _StopResultTile({
    required this.stop,
    required this.city,
    required this.isActiveCity,
    required this.onTap,
    this.typeName,
  });

  final Stop stop;
  final TransitCity city;
  final bool isActiveCity;
  final VoidCallback onTap;

  /// Durağın baskın hat türü ("marmaray", "metro"…). Bilinmiyorsa null.
  final String? typeName;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Material(
      color: VigilantColors.surfaceContainer,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          child: Row(
            children: [
              Builder(builder: (context) {
                final t = typeName == null
                    ? null
                    : LineType.values
                        .where((x) => x.name == typeName)
                        .firstOrNull;
                final color =
                    t == null ? VigilantColors.primary : lineTypeColor(t);
                return Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: VigilantColors.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                      t == null
                          ? Icons.location_on_outlined
                          : lineTypeIcon(t),
                      size: 20,
                      color: color),
                );
              }),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(stop.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleSmall),
                    const SizedBox(height: 2),
                    Text(
                      [
                        // TÜR ÖNCE: kullanıcı "Marmaray mı otobüs mü"
                        // sorusunu ilk soruyor.
                        if (typeName != null)
                          LineType.values
                                  .where((x) => x.name == typeName)
                                  .firstOrNull
                                  ?.label ??
                              '',
                        if (stop.contextLabel.isNotEmpty) stop.contextLabel,
                      ].where((x) => x.isNotEmpty).join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.labelSmall
                          ?.copyWith(color: VigilantColors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // İL ROZETİ — bulunduğun il farklı renkte, ötekiler soluk değil
              // (soluk gösterim "ikinci sınıf sonuç" izlenimi veriyordu).
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                  color: (isActiveCity
                          ? VigilantColors.primary
                          : VigilantColors.accentBlue)
                      .withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  city.name,
                  style: text.labelSmall?.copyWith(
                    color: isActiveCity
                        ? VigilantColors.primary
                        : VigilantColors.accentBlue,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Aradığın bir HAT olabilir" ipucu — Duraklar'da hat kodu arandığında.
class _LineHintCard extends StatelessWidget {
  const _LineHintCard({required this.query, required this.onTap});

  final String query;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Material(
      color: VigilantColors.primary.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
                color: VigilantColors.primary.withValues(alpha: 0.35)),
          ),
          child: Row(
            children: [
              const Icon(Icons.alt_route_rounded,
                  size: 20, color: VigilantColors.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('"$query" bir hat olabilir',
                        style: text.titleSmall
                            ?.copyWith(color: VigilantColors.primary)),
                    const SizedBox(height: 2),
                    Text('Hatlar sekmesinde ara',
                        style: text.labelSmall?.copyWith(
                            color: VigilantColors.onSurfaceVariant)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded,
                  size: 20, color: VigilantColors.primary),
            ],
          ),
        ),
      ),
    );
  }
}

/// Son arama satırı — hat rozeti + durak/hat adı.
class _RecentTile extends StatelessWidget {
  const _RecentTile({required this.entry, required this.onTap});

  final RecentSearch entry;
  final VoidCallback onTap;

  /// Alt satır: önce durak yönü, yoksa hat kodu.
  String? _recentSubtitle(RecentSearch e) {
    final dir = e.stopDirection.trim();
    if (dir.isNotEmpty) return '$dir yönü';
    final code = e.lineCode.trim();
    return code.isEmpty ? null : '$code hattı';
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final hasStop = entry.stopName.trim().isNotEmpty;
    return Material(
      color: VigilantColors.surfaceContainer,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Icon(Icons.history_rounded,
                  size: 18, color: VigilantColors.onSurfaceVariant),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(hasStop ? entry.stopName : entry.lineCode,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    // ALT SATIR: durağın YÖNÜ. Aynı adlı durak yolun iki
                    // yakasında ayrı ayrı var; yön yazmadan hangisine
                    // bakıldığı belli olmuyordu.
                    if (_recentSubtitle(entry) case final sub?)
                      Text(sub,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.labelSmall?.copyWith(
                              color: VigilantColors.onSurfaceVariant)),
                  ],
                ),
              ),
              Icon(lineTypeIcon(entry.lineType),
                  size: 18, color: lineTypeColor(entry.lineType)),
            ],
          ),
        ),
      ),
    );
  }
}
