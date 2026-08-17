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
  /// Hat + AİT OLDUĞU İL. Şehir seçimi kaldırıldı; liste kurulu bütün
  /// illerin hatlarını taşıyor ve il rozette yazıyor.
  List<(TransitLineBrief, TransitCity)> _lines = const [];
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

    // KURULU BÜTÜN İLLER. Şehir seçimi kaldırıldı: kullanıcı bir ilde yaşayıp
    // öbürüne gidiyor ve hangi ilde olduğunu uygulamaya söylemek zorunda
    // kalması gereksiz bir ödevdi. Hattın hangi ile ait olduğu satırdaki
    // rozette yazıyor.
    await BusDataService.instance.openAllForLookup();
    final byKey = <String, (TransitLineBrief, TransitCity)>{};
    for (final c in TransitCities.all) {
      try {
        final rows =
            await TransitDb.instance.linesByType(widget.type.name, cityId: c.id);
        for (final b in rows) {
          // TEKİLLEŞTİRME HAT KİMLİĞİNE GÖRE, şehir+koda göre DEĞİL.
          //
          // Şehir anahtarı kullanılınca aynı satır iki ilin altında ayrı ayrı
          // görünebiliyordu: Marmaray sayfasında 3 İstanbul + 3 Kocaeli çıktı,
          // oysa Kocaeli paketinde Marmaray yok. Kimlik paketin içinden geldiği
          // için aynı hat hangi yoldan okunursa okunsun tek satır kalır.
          byKey.putIfAbsent(b.id, () => (b, c));
        }
      } catch (_) {
        // O ilin paketi kurulu değil; ötekiler yine listelenir.
      }
    }
    final rail = ref.read(linesProvider).valueOrNull ?? const <TransitLine>[];
    for (final l in rail) {
      if (l.type != widget.type) continue;
      byKey.putIfAbsent(
        l.id,
        () => (
          TransitLineBrief(id: l.id, code: l.code, name: l.name, type: l.type),
          city,
        ),
      );
    }

    final all = byKey.values.toList()
      ..sort((a, b) => compareLineCodes(a.$1.code, b.$1.code));
    if (!mounted) return;
    setState(() {
      _lines = all;
      _loading = false;
    });
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
              if (compactLineCode(l.$1.code).contains(_compactQ(q)) ||
                  transitNorm(l.$1.name).contains(q))
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
              _loading ? 'yükleniyor…' : '${_lines.length} hat',
              style: text.labelSmall
                  ?.copyWith(color: VigilantColors.onSurfaceVariant),
            ),
          ],
        ),
        actions: const [
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

  Widget _body(
      TextTheme text, List<(TransitLineBrief, TransitCity)> shown) {
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
        brief: shown[i].$1,
        city: shown[i].$2,
        // İL ROZETİ yalnızca birden çok il kuruluysa: tek ilde herkes zaten
        // hangi ilde olduğunu biliyor, her satıra yazmak gürültü olurdu.
        showCity: _lines.map((e) => e.$2.id).toSet().length > 1,
        onTap: () {
          Haptics.light();
          Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => LineDetailScreen(
              code: shown[i].$1.code,
              type: shown[i].$1.type,
              city: shown[i].$2.id == ref.read(activeCityProvider).id
                  ? null
                  : shown[i].$2,
            ),
          ));
        },
      ),
    );
  }
}

class _LineTile extends StatelessWidget {
  const _LineTile({
    required this.brief,
    required this.city,
    required this.showCity,
    required this.onTap,
  });

  final TransitLineBrief brief;
  final TransitCity city;

  /// Birden çok il kuruluysa satırda il rozeti gösterilir.
  final bool showCity;
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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      brief.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodyMedium,
                    ),
                    if (showCity)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.location_city_rounded,
                                size: 11,
                                color: VigilantColors.onSurfaceVariant),
                            const SizedBox(width: 4),
                            Text(city.name,
                                style: text.labelSmall?.copyWith(
                                    color: VigilantColors.onSurfaceVariant)),
                          ],
                        ),
                      ),
                  ],
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
