import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/transit_city.dart';
import '../services/bus_data_service.dart';
import '../state/city_provider.dart';
import '../theme/app_theme.dart';
import '../util/haptics.dart';
import '../util/insets.dart';

/// Ayarlar → Veri Paketleri.
///
/// Şehir paketlerini sonradan indirmek, güncellemek ve yer açmak için silmek
/// buradan yapılır. İlk açılıştaki dolum ekranı yalnızca aktif şehri indirir;
/// kullanıcı başka şehre gidecekse paketi ÖNCEDEN (wifi'dayken) indirebilsin
/// diye bu ekran var — StopAlert tünelde/çevrimdışı çalışmak zorunda.
class DataPackagesScreen extends ConsumerStatefulWidget {
  const DataPackagesScreen({super.key});

  @override
  ConsumerState<DataPackagesScreen> createState() => _DataPackagesScreenState();
}

class _DataPackagesScreenState extends ConsumerState<DataPackagesScreen> {
  /// Şehir kimliği -> yerel paket durumu.
  final Map<String, ({bool installed, int bytes, String? version})> _local = {};

  /// Şehir kimliği -> sunucudaki sürüm/boyut (null = bakılmadı/ulaşılamadı).
  final Map<String, ({String? version, int bytes})?> _remote = {};

  /// O an indirilen şehir ve ilerlemesi.
  String? _busyCity;
  double _progress = 0;
  String _phase = '';

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    for (final c in TransitCities.all) {
      final info = await BusDataService.instance.packageInfo(c);
      if (!mounted) return;
      setState(() => _local[c.id] = info);
    }
    for (final c in TransitCities.all) {
      final r = await BusDataService.instance.remoteInfo(c);
      if (!mounted) return;
      setState(() => _remote[c.id] = r);
    }
  }

  Future<void> _download(TransitCity city) async {
    Haptics.light();
    setState(() {
      _busyCity = city.id;
      _progress = 0;
      _phase = 'Kontrol ediliyor…';
    });
    await BusDataService.instance.ensureReady(
      city: city,
      onProgress: (phase, fraction) {
        if (!mounted) return;
        setState(() {
          _progress = fraction;
          _phase = switch (phase) {
            BusDataPhase.checking => 'Sürüm kontrol ediliyor…',
            BusDataPhase.downloading => 'İndiriliyor…',
            BusDataPhase.verifying => 'Doğrulanıyor…',
            BusDataPhase.ready => 'Hazır',
            BusDataPhase.offline => 'İndirilemedi',
            BusDataPhase.skipped => '',
          };
        });
      },
    );
    if (!mounted) return;
    setState(() => _busyCity = null);
    await _refresh();
    // İndirilen paket aktif şehrinki değilse veritabanı ona geçmiş olur;
    // aktif şehri yeniden açarak eski hâle döndür.
    final active = ref.read(activeCityProvider);
    if (active.id != city.id) {
      await BusDataService.instance.ensureReady(city: active);
    }
  }

  Future<void> _remove(TransitCity city) async {
    final active = ref.read(activeCityProvider);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: VigilantColors.surfaceContainer,
        title: Text('${city.name} paketi silinsin mi?'),
        content: Text(
          active.id == city.id
              ? '${city.name} şu an aktif şehrin. Paketi silersen otobüs '
                  'hatları ve durakları görünmez; tekrar indirene kadar '
                  'yalnızca gömülü ray/vapur hatları kalır.'
              : 'Yer açılır. İhtiyacın olursa tekrar indirebilirsin.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Vazgeç'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: VigilantColors.primary),
            child: const Text('Sil'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await BusDataService.instance.removePackage(city);
    await _refresh();
  }

  String _size(int bytes) => bytes <= 0
      ? ''
      : '${(bytes / 1024 / 1024).toStringAsFixed(1).replaceAll('.', ',')} MB';

  String _versionLabel(String? v) {
    if (v == null || v.length < 8) return v ?? '';
    return '${v.substring(6, 8)}.${v.substring(4, 6)}.${v.substring(0, 4)}';
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final active = ref.watch(activeCityProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Veri Paketleri')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 8, 16, AppInsets.pageBottom(context)),
        children: [
          Text(
            'Şehir verileri cihazda saklanır; alarm tünelde ve internetsiz '
            'çalışsın diye canlı sorgulanmaz. Başka bir şehre gidecekseniz '
            'paketi önceden indirin.',
            style: text.bodyMedium
                ?.copyWith(color: VigilantColors.onSurfaceVariant),
          ),
          const SizedBox(height: 18),
          for (final city in TransitCities.all) ...[
            _CityCard(
              city: city,
              isActive: active.id == city.id,
              local: _local[city.id],
              remote: _remote[city.id],
              busy: _busyCity == city.id,
              progress: _progress,
              phase: _phase,
              sizeLabel: _size,
              versionLabel: _versionLabel,
              onDownload: () => _download(city),
              onRemove: () => _remove(city),
              onActivate: () async {
                Haptics.light();
                await ref.read(cityProvider.notifier).select(city);
                await BusDataService.instance.ensureReady(city: city);
                if (mounted) setState(() {});
              },
            ),
            const SizedBox(height: 12),
          ],
        ],
      ),
    );
  }
}

class _CityCard extends StatelessWidget {
  const _CityCard({
    required this.city,
    required this.isActive,
    required this.local,
    required this.remote,
    required this.busy,
    required this.progress,
    required this.phase,
    required this.sizeLabel,
    required this.versionLabel,
    required this.onDownload,
    required this.onRemove,
    required this.onActivate,
  });

  final TransitCity city;
  final bool isActive;
  final ({bool installed, int bytes, String? version})? local;
  final ({String? version, int bytes})? remote;
  final bool busy;
  final double progress;
  final String phase;
  final String Function(int) sizeLabel;
  final String Function(String?) versionLabel;
  final VoidCallback onDownload;
  final VoidCallback onRemove;
  final VoidCallback onActivate;

  /// Sunucuda yeni sürüm var mı?
  bool get _updateAvailable {
    final l = local, r = remote;
    return l != null &&
        l.installed &&
        r?.version != null &&
        r!.version != l.version;
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final installed = local?.installed ?? false;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: VigilantColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isActive
              ? VigilantColors.primary.withValues(alpha: 0.5)
              : VigilantColors.surfaceVariant.withValues(alpha: 0.4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Text(city.name,
                        style: text.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w800)),
                    if (isActive) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: VigilantColors.primary.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text('Aktif',
                            style: text.labelSmall?.copyWith(
                                color: VigilantColors.primary,
                                fontWeight: FontWeight.w700)),
                      ),
                    ],
                  ],
                ),
              ),
              if (installed)
                Icon(Icons.download_done_rounded,
                    size: 20,
                    color: VigilantColors.secondary.withValues(alpha: 0.9)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            installed
                ? '${sizeLabel(local!.bytes)}'
                    '${local!.version != null ? ' · ${versionLabel(local!.version)}' : ''}'
                : (remote != null && remote!.bytes > 0
                    ? 'İndirilmedi · ${sizeLabel(remote!.bytes)}'
                    : 'İndirilmedi'),
            style: text.labelMedium
                ?.copyWith(color: VigilantColors.onSurfaceVariant),
          ),
          const SizedBox(height: 2),
          // Lisans gereği veri kaynağı görünmek zorunda (Kocaeli CC BY).
          Text(city.attribution,
              style: text.labelSmall?.copyWith(
                  color: VigilantColors.onSurfaceVariant
                      .withValues(alpha: 0.75))),
          if (!city.hasLiveBus) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(Icons.info_outline_rounded,
                    size: 13, color: VigilantColors.onSurfaceVariant),
                const SizedBox(width: 5),
                Expanded(
                  child: Text('Canlı otobüs konumu bu şehirde yok',
                      style: text.labelSmall
                          ?.copyWith(color: VigilantColors.onSurfaceVariant)),
                ),
              ],
            ),
          ],
          if (busy) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: progress > 0 && progress < 1 ? progress : null,
              minHeight: 6,
              backgroundColor: VigilantColors.surfaceVariant,
              color: VigilantColors.primary,
              borderRadius: BorderRadius.circular(999),
            ),
            const SizedBox(height: 6),
            Text(phase,
                style: text.labelSmall
                    ?.copyWith(color: VigilantColors.onSurfaceVariant)),
          ] else ...[
            const SizedBox(height: 12),
            Row(
              children: [
                if (!installed || _updateAvailable)
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: onDownload,
                      icon: Icon(
                          _updateAvailable
                              ? Icons.refresh_rounded
                              : Icons.download_rounded,
                          size: 18),
                      label: Text(_updateAvailable ? 'Güncelle' : 'İndir'),
                      style: FilledButton.styleFrom(
                        backgroundColor: VigilantColors.primary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                // "BU ŞEHRE GEÇ" YOK: şehir seçimi kaldırıldı, indirilen
                // her paket her yerde geçerli. Aktif şehir kavramı yalnızca
                // hangi paketin birincil açılacağını belirliyor ve konumdan
                // kendiliğinden çözülüyor.
                if (installed) ...[
                  const SizedBox(width: 10),
                  IconButton(
                    onPressed: onRemove,
                    icon: const Icon(Icons.delete_outline_rounded),
                    color: VigilantColors.onSurfaceVariant,
                    tooltip: 'Paketi sil',
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}
