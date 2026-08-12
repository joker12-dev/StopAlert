import 'package:flutter/material.dart';

import '../services/iett_service.dart';
import '../theme/app_theme.dart';
import '../util/haptics.dart';
import '../util/insets.dart';
import '../widgets/offline_notice.dart';

/// Tek bir hattın duyuruları — sefer iptalleri ve güzergâh değişiklikleri.
///
/// NEDEN AYRI SAYFA: duyurular ekranında 200'den fazla kayıt var ve kullanıcı
/// baktığı hattınkini orada aramak zorunda kalıyordu. Oysa hat sayfasındayken
/// sorduğu şey belli: "bu hatta bir sorun var mı".
///
/// KAYNAK İETT'nin duyuru servisi; hat bazlı bir uç yok, tüm liste çekilip
/// HATKODU ile süzülüyor (bkz. [IettService.forLine]). Bu yüzden yalnızca
/// İETT hatlarında (İstanbul, lastikli) sonuç döner.
class LineAnnouncementsScreen extends StatefulWidget {
  const LineAnnouncementsScreen({
    super.key,
    required this.lineCode,
    required this.lineName,
  });

  final String lineCode;
  final String lineName;

  @override
  State<LineAnnouncementsScreen> createState() =>
      _LineAnnouncementsScreenState();
}

class _LineAnnouncementsScreenState extends State<LineAnnouncementsScreen> {
  List<IettAnnouncement>? _items;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool force = false}) async {
    setState(() => _loading = true);
    if (force) await IettService.instance.announcements(force: true);
    final rows = await IettService.instance.forLine(widget.lineCode);
    if (!mounted) return;
    setState(() {
      _items = rows;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final items = _items;
    // Sefere ait olanlar ÖNCE: iptal edilen bir sefer, güzergâh notundan
    // daha aciltir.
    final sorted = items == null
        ? const <IettAnnouncement>[]
        : ([...items]..sort((a, b) {
            if (a.isTrip == b.isTrip) return 0;
            return a.isTrip ? -1 : 1;
          }));

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${widget.lineCode} duyuruları'),
            Text(
              widget.lineName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.labelSmall
                  ?.copyWith(color: VigilantColors.onSurfaceVariant),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Yenile',
            onPressed: _loading
                ? null
                : () {
                    Haptics.light();
                    _load(force: true);
                  },
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _loading && items == null
          ? const Center(
              child: CircularProgressIndicator(color: VigilantColors.primary))
          : items == null
              ? OfflineNotice(
                  title: 'Duyurular alınamadı',
                  onRetry: () => _load(force: true),
                )
              : sorted.isEmpty
                  ? _empty(text)
                  : ListView.separated(
                      padding: EdgeInsets.fromLTRB(
                          20, 12, 20, AppInsets.pageBottom(context)),
                      itemCount: sorted.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (context, i) => _Card(item: sorted[i]),
                    ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Text(
            IettService.attribution,
            textAlign: TextAlign.center,
            style: text.labelSmall
                ?.copyWith(color: VigilantColors.onSurfaceVariant),
          ),
        ),
      ),
    );
  }

  Widget _empty(TextTheme text) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.check_circle_outline_rounded,
                  size: 42, color: VigilantColors.tertiaryContainer),
              const SizedBox(height: 12),
              Text('Bu hatta duyuru yok',
                  style: text.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text(
                'Sefer iptali ya da güzergâh değişikliği bildirilmemiş.',
                textAlign: TextAlign.center,
                style: text.bodySmall
                    ?.copyWith(color: VigilantColors.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );
}

/// Tek duyuru kartı.
class _Card extends StatelessWidget {
  const _Card({required this.item});

  final IettAnnouncement item;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final color = item.isTrip
        ? VigilantColors.primary
        : VigilantColors.tertiaryContainer;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: VigilantColors.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  item.isTrip ? 'SEFER' : 'DURUM',
                  style: text.labelSmall?.copyWith(
                      fontSize: 9,
                      letterSpacing: 0.8,
                      fontWeight: FontWeight.w800,
                      color: color),
                ),
              ),
              const Spacer(),
              if (item.time.isNotEmpty)
                Text(item.time,
                    style: text.labelSmall
                        ?.copyWith(color: VigilantColors.onSurfaceVariant)),
            ],
          ),
          const SizedBox(height: 8),
          Text(item.message, style: text.bodyMedium?.copyWith(height: 1.35)),
        ],
      ),
    );
  }
}
