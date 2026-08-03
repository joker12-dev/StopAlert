import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/transit_city.dart';
import '../services/bus_data_service.dart';
import '../state/city_provider.dart';
import '../state/journey_provider.dart';
import '../theme/app_theme.dart';
import '../util/haptics.dart';
import '../widgets/mascot.dart';

/// İlk açılış VERİ PAKETLERİ ekranı.
///
/// HİÇBİR ŞEY KENDİLİĞİNDEN İNMEZ. Kullanıcı hangi şehri istiyorsa onun
/// "İndir" düğmesine basar; konumun bir önemi yoktur. Böylece kimse
/// istemediği bir indirmeyle — ve onu bekleten bir ekranla — karşılaşmaz;
/// İstanbul'da yaşayıp Kocaeli'ye gidip gelen biri ikisini birden indirir.
///
/// Ray/vapur hatları şehir paketinin içinde gelir; İstanbul'unki ayrıca
/// APK'da gömülü olduğundan hiç paket inmese de temel akış çalışır.
class DataBootstrapScreen extends ConsumerStatefulWidget {
  const DataBootstrapScreen({super.key, required this.onCompleted});

  final VoidCallback onCompleted;

  @override
  ConsumerState<DataBootstrapScreen> createState() =>
      _DataBootstrapScreenState();
}

class _DataBootstrapScreenState extends ConsumerState<DataBootstrapScreen> {
  /// Şehir kimliği -> cihazdaki paket durumu.
  final Map<String, bool> _installed = {};

  /// Şehir kimliği -> sunucudaki boyut (yalnızca göstermek için).
  final Map<String, int> _remoteBytes = {};

  String? _busyCity;
  double _frac = 0;
  BusDataPhase _phase = BusDataPhase.checking;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    for (final c in TransitCities.all) {
      final has = await BusDataService.instance.hasLocal(c);
      if (!mounted) return;
      setState(() => _installed[c.id] = has);
    }
    // Boyut bilgisi için yalnızca manifest okunur — paket İNDİRİLMEZ.
    for (final c in TransitCities.all) {
      final r = await BusDataService.instance.remoteInfo(c);
      if (!mounted) return;
      if (r != null) setState(() => _remoteBytes[c.id] = r.bytes);
    }
  }

  Future<void> _download(TransitCity city) async {
    Haptics.light();
    setState(() {
      _busyCity = city.id;
      _frac = 0;
      _phase = BusDataPhase.checking;
    });
    await BusDataService.instance.ensureReady(
      city: city,
      onProgress: (phase, frac) {
        if (!mounted) return;
        setState(() {
          _phase = phase;
          _frac = frac;
        });
      },
    );
    if (!mounted) return;
    setState(() => _busyCity = null);
    // İndirilen şehir aktif olur: kullanıcı onu bilinçli seçmiş sayılır.
    await ref.read(cityProvider.notifier).select(city);
    ref.invalidate(installedCitiesProvider);
    await _refresh();
  }

  bool get _anyInstalled => _installed.values.any((v) => v);

  String _statusText(TransitCity city) {
    if (_busyCity != city.id) return '';
    return switch (_phase) {
      BusDataPhase.checking => 'Sürüm kontrol ediliyor…',
      BusDataPhase.downloading =>
        'İniyor · %${(_frac * 100).clamp(0, 100).toStringAsFixed(0)}',
      BusDataPhase.verifying => 'Doğrulanıyor…',
      BusDataPhase.ready => 'Hazır',
      BusDataPhase.offline => 'İnternet yok — sonra tekrar dene',
      BusDataPhase.skipped => '',
    };
  }

  String _size(int? bytes) => (bytes == null || bytes <= 0)
      ? ''
      : '${(bytes / 1024 / 1024).toStringAsFixed(1).replaceAll('.', ',')} MB';

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
                children: [
                  const Center(
                    child:
                        AnimatedMascot(MascotAssets.poseTelefon, height: 120),
                  ),
                  const SizedBox(height: 18),
                  Text('Veri Paketleri',
                      textAlign: TextAlign.center, style: text.headlineSmall),
                  const SizedBox(height: 8),
                  Text(
                    'Kullanacağın şehri indir. Durak ve hat verileri cihazında '
                    'saklanır; alarm tünelde, internetsiz de çalışır.',
                    textAlign: TextAlign.center,
                    style: text.bodyMedium
                        ?.copyWith(color: VigilantColors.onSurfaceVariant),
                  ),
                  const SizedBox(height: 24),
                  for (final city in TransitCities.all) ...[
                    _CityPackage(
                      city: city,
                      installed: _installed[city.id] ?? false,
                      sizeLabel: _size(_remoteBytes[city.id]),
                      busy: _busyCity == city.id,
                      progress: _frac,
                      status: _statusText(city),
                      onDownload: () => _download(city),
                    ),
                    const SizedBox(height: 12),
                  ],
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const Icon(Icons.map_rounded,
                          size: 16, color: VigilantColors.onSurfaceVariant),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Harita internetle canlı yüklenir (paket gerekmez). '
                          'Şehirleri sonradan Ayarlar’dan da indirebilirsin.',
                          style: text.labelMedium?.copyWith(
                              color: VigilantColors.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  // Lisans şartı: kaynak atfı (İBB Açık Veri / Kocaeli CC BY).
                  Text(
                    '${TransitCities.istanbul.attribution} · '
                    '${TransitCities.kocaeli.attribution}. '
                    'Harita © OpenStreetMap katkıcıları.',
                    textAlign: TextAlign.center,
                    style: text.labelSmall
                        ?.copyWith(color: VigilantColors.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
              child: SizedBox(
                height: 54,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: VigilantColors.primary,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor:
                        VigilantColors.surfaceContainerHigh,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                  ),
                  // İndirme sürerken beklenir; hiç paket yokken de devam
                  // edilebilir (ray/vapur gömülü kopyayla çalışır).
                  onPressed: _busyCity != null ? null : widget.onCompleted,
                  child: Text(
                    _busyCity != null
                        ? 'İndiriliyor…'
                        : (_anyInstalled ? 'Devam Et' : 'Şimdilik Atla'),
                    style: text.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: _busyCity != null
                            ? VigilantColors.onSurfaceVariant
                            : Colors.white),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Tek şehir paketi kartı — indirme YALNIZCA düğmeyle başlar.
class _CityPackage extends StatelessWidget {
  const _CityPackage({
    required this.city,
    required this.installed,
    required this.sizeLabel,
    required this.busy,
    required this.progress,
    required this.status,
    required this.onDownload,
  });

  final TransitCity city;
  final bool installed;
  final String sizeLabel;
  final bool busy;
  final double progress;
  final String status;
  final VoidCallback onDownload;

  /// Şehirde hangi taşıma türleri var — kullanıcı ne indirdiğini bilsin.
  String get _contents => city.id == 'kocaeli'
      ? 'Otobüs, Akçaray tramvay, vapur, teleferik'
      : 'Otobüs, metrobüs, Marmaray, metro, tramvay, vapur';

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: VigilantColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: installed
              ? VigilantColors.secondary.withValues(alpha: 0.45)
              : VigilantColors.surfaceVariant.withValues(alpha: 0.4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.location_city_rounded,
                  size: 20,
                  color: installed
                      ? VigilantColors.secondary
                      : VigilantColors.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(city.name,
                    style: text.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w800)),
              ),
              if (installed)
                const Icon(Icons.download_done_rounded,
                    size: 20, color: VigilantColors.secondary),
            ],
          ),
          const SizedBox(height: 4),
          Text(_contents,
              style: text.labelMedium
                  ?.copyWith(color: VigilantColors.onSurfaceVariant)),
          if (sizeLabel.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(installed ? 'İndirildi · $sizeLabel' : sizeLabel,
                style: text.labelSmall
                    ?.copyWith(color: VigilantColors.onSurfaceVariant)),
          ],
          const SizedBox(height: 12),
          if (busy) ...[
            LinearProgressIndicator(
              value: progress > 0 && progress < 1 ? progress : null,
              minHeight: 6,
              backgroundColor: VigilantColors.surfaceVariant,
              color: VigilantColors.primary,
              borderRadius: BorderRadius.circular(999),
            ),
            const SizedBox(height: 6),
            Text(status,
                style: text.labelSmall
                    ?.copyWith(color: VigilantColors.onSurfaceVariant)),
          ] else
            SizedBox(
              width: double.infinity,
              child: installed
                  ? OutlinedButton.icon(
                      onPressed: null,
                      icon: const Icon(Icons.check_rounded, size: 18),
                      label: const Text('Cihazında hazır'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: VigilantColors.secondary,
                        disabledForegroundColor: VigilantColors.secondary,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                    )
                  : FilledButton.icon(
                      onPressed: onDownload,
                      icon: const Icon(Icons.download_rounded, size: 18),
                      label: const Text('İndir'),
                      style: FilledButton.styleFrom(
                        backgroundColor: VigilantColors.primary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
            ),
        ],
      ),
    );
  }
}
