import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../data/transit_city.dart';
import '../data/transit_db.dart';
import '../services/bus_data_service.dart';
import '../state/city_provider.dart';
import '../state/journey_provider.dart';
import '../theme/app_theme.dart';
import '../util/haptics.dart';
import '../util/insets.dart';
import '../widgets/skeleton.dart';
import 'line_detail_screen.dart';

/// Hat kodlarını İNSAN sırasına dizer: 10 < 10A < 11 < 100 < 500T.
///
/// Düz metin sıralaması "100"ü "11"in önüne koyuyor ve otobüs listesini
/// okunmaz yapıyordu. Kod sayı ve harf öbeklerine bölünüp sayılar sayı,
/// harfler metin olarak karşılaştırılır.
int compareLineCodes(String a, String b) {
  final ra = _chunks(a);
  final rb = _chunks(b);
  for (var i = 0; i < ra.length && i < rb.length; i++) {
    final x = ra[i];
    final y = rb[i];
    final nx = int.tryParse(x);
    final ny = int.tryParse(y);
    final int c;
    if (nx != null && ny != null) {
      c = nx.compareTo(ny);
    } else if (nx != null) {
      c = -1; // sayı önce: "10" < "E-58"
    } else if (ny != null) {
      c = 1;
    } else {
      c = x.compareTo(y);
    }
    if (c != 0) return c;
  }
  return ra.length.compareTo(rb.length);
}

/// "500T" → ["500", "T"],  "E-58" → ["E", "58"]  (ayraçlar atılır)
List<String> _chunks(String s) {
  final out = <String>[];
  final buf = StringBuffer();
  bool? digit;
  for (final ch in s.toUpperCase().split('')) {
    if (RegExp(r'[\s\-_.]').hasMatch(ch)) continue;
    final d = RegExp(r'[0-9]').hasMatch(ch);
    if (digit != null && d != digit) {
      out.add(buf.toString());
      buf.clear();
    }
    digit = d;
    buf.write(ch);
  }
  if (buf.isNotEmpty) out.add(buf.toString());
  return out;
}

/// Bir TÜRÜN bütün hatları — "Otobüs", "Metro", "Vapur" sayfaları.
///
/// Ana sayfadaki tür çipleri buraya gelir. Liste hat numarası sırasında;
/// her satırda kod + güzergâh adı var. Bir hatta dokunmak hat sayfasını
/// açar: orada yön değiştirilir, durak seçilir, alarm kurulur.
///
/// ŞEHİR BAZLI ve şehir SAĞ ÜSTTEN değişir — kullanıcı Ayarlar'a gitmeden
/// öteki şehrin hatlarına bakabilsin. Buradaki değişim AKTİF ŞEHRİ DE
/// değiştirir (bilinçli bir seçim sayılır).
class LinesByTypeScreen extends ConsumerStatefulWidget {
  const LinesByTypeScreen({super.key, required this.type});

  final LineType type;

  @override
  ConsumerState<LinesByTypeScreen> createState() => _LinesByTypeScreenState();
}

class _LinesByTypeScreenState extends ConsumerState<LinesByTypeScreen> {
  List<TransitLineBrief> _lines = const [];
  bool _loading = true;
  String _filter = '';
  String? _loadedForCity;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final city = ref.read(activeCityProvider);
    setState(() {
      _loading = true;
      _loadedForCity = city.id;
    });

    // İKİ KAYNAK: otobüs/metrobüs (ve Kocaeli'de tramvay/vapur) indirilen
    // SQLite paketinde; İstanbul'un ray/vapur hatları ayrı JSON'da.
    // Kod bazında tekilleştirilir.
    final byCode = <String, TransitLineBrief>{};
    try {
      for (final b in await TransitDb.instance.linesByType(widget.type.name)) {
        byCode.putIfAbsent(b.code, () => b);
      }
    } catch (_) {
      // Paket yok: yalnızca gömülü hatlar listelenir.
    }
    final rail = ref.read(linesProvider).valueOrNull ?? const <TransitLine>[];
    for (final l in rail) {
      if (l.type != widget.type) continue;
      byCode.putIfAbsent(
        l.code,
        () => TransitLineBrief(
            id: l.id, code: l.code, name: l.name, type: l.type),
      );
    }

    final all = byCode.values.toList()
      ..sort((a, b) => compareLineCodes(a.code, b.code));
    if (!mounted) return;
    setState(() {
      _lines = all;
      _loading = false;
    });
  }

  Future<void> _switchCity(TransitCity city) async {
    if (city.id == ref.read(activeCityProvider).id) return;
    Haptics.selection();
    // Sağ üstten şehir değiştirmek BİLİNÇLİ bir seçimdir: kalıcı sabitlenir
    // (bkz. CityNotifier.select), konumdan otomatik belirleme susar.
    await ref.read(cityProvider.notifier).select(city);
    await BusDataService.instance.ensureReady(city: city);
    if (!mounted) return;
    ref.invalidate(linesProvider);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final city = ref.watch(activeCityProvider);
    // Şehir dışarıdan değişmiş olabilir (ör. veri paketi ekranı).
    if (_loadedForCity != null && _loadedForCity != city.id && !_loading) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }

    final q = transitNorm(_filter.trim());
    final shown = q.isEmpty
        ? _lines
        : [
            for (final l in _lines)
              if (compactLineCode(l.code).contains(_compactQ(q)) ||
                  transitNorm(l.name).contains(q))
                l,
          ];

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.type.label),
            Text(
              _loading ? 'yükleniyor…' : '${_lines.length} hat · ${city.name}',
              style: text.labelSmall
                  ?.copyWith(color: VigilantColors.onSurfaceVariant),
            ),
          ],
        ),
        actions: [
          // ŞEHİR seçici — kullanıcı Ayarlar'a gitmeden öteki ilin hatlarına
          // bakabilsin.
          PopupMenuButton<TransitCity>(
            tooltip: 'Şehir',
            onSelected: _switchCity,
            itemBuilder: (context) => [
              for (final c in TransitCities.all)
                PopupMenuItem(
                  value: c,
                  child: Row(
                    children: [
                      Icon(
                        c.id == city.id
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        size: 18,
                        color: c.id == city.id
                            ? VigilantColors.primary
                            : VigilantColors.onSurfaceVariant,
                      ),
                      const SizedBox(width: 10),
                      Text(c.name),
                    ],
                  ),
                ),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  const Icon(Icons.location_city_rounded, size: 18),
                  const SizedBox(width: 6),
                  Text(city.name, style: text.labelLarge),
                  const Icon(Icons.arrow_drop_down, size: 20),
                ],
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              onChanged: (v) => setState(() => _filter = v),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: VigilantColors.surfaceContainer,
                hintText: '${widget.type.label} ara (kod veya güzergâh)',
                prefixIcon: const Icon(Icons.search,
                    color: VigilantColors.onSurfaceVariant),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          Expanded(child: _body(text, shown)),
        ],
      ),
    );
  }

  String _compactQ(String norm) => norm.replaceAll(RegExp(r'[\s\-_.]'), '');

  Widget _body(TextTheme text, List<TransitLineBrief> shown) {
    if (_loading) {
      return ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: const [
          SkeletonTile(),
          SizedBox(height: 10),
          SkeletonTile(),
          SizedBox(height: 10),
          SkeletonTile(),
        ],
      );
    }
    if (shown.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            _lines.isEmpty
                ? '${ref.read(activeCityProvider).name} için '
                    '${widget.type.label.toLowerCase()} verisi yok. '
                    'Veri paketini Ayarlar\'dan indirebilirsin.'
                : 'Eşleşen hat yok.',
            textAlign: TextAlign.center,
            style: text.bodyMedium
                ?.copyWith(color: VigilantColors.onSurfaceVariant),
          ),
        ),
      );
    }
    return ListView.separated(
      padding: EdgeInsets.fromLTRB(16, 0, 16, AppInsets.listBottom(context)),
      itemCount: shown.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, i) => _LineTile(
        brief: shown[i],
        onTap: () {
          Haptics.light();
          Navigator.of(context).push(MaterialPageRoute(
            builder: (_) =>
                LineDetailScreen(code: shown[i].code, type: shown[i].type),
          ));
        },
      ),
    );
  }
}

class _LineTile extends StatelessWidget {
  const _LineTile({required this.brief, required this.onTap});

  final TransitLineBrief brief;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final color = lineColorOf(brief.color, brief.type);
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
              Container(
                constraints: const BoxConstraints(minWidth: 58),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  brief.code,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.titleSmall
                      ?.copyWith(color: color, fontWeight: FontWeight.w800),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  brief.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodyMedium,
                ),
              ),
              const SizedBox(width: 6),
              const Icon(Icons.chevron_right_rounded,
                  size: 20, color: VigilantColors.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}
