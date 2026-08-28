import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme/app_theme.dart';
import '../util/insets.dart';
import '../widgets/mascot.dart';

/// Rehberin bir bölümü — bilgi ("i") butonları doğrudan ilgili bölümü açar.
enum GuideSection { alarm, stop, bus, extras }

/// Rehberdeki YouTube videoları.
///
/// ⚠️ VİDEOLARINI ÇEKİNCE BURAYA ID'LERİNİ YAZ (yalnızca ID, tam URL değil).
/// Örn. `https://youtu.be/dQw4w9WgXcQ` → `'dQw4w9WgXcQ'`.
/// ID null iken kartlar "yakında" görünür; dolunca dokununca video açılır.
abstract final class GuideVideos {
  static const intro = 'RE33qVWkCHQ'; // Uygulama tanıtımı (Shorts)
  static const String? alarm = null; // Nasıl alarm kurulur
  static const String? stop = null; // Nasıl durak seçilir
  static const String? bus = null; // Yaklaşan otobüs / canlı takip
}

/// "Nasıl Kullanılır" — uygulama amacı + adım adım kullanım + (ileride) videolar.
///
/// Görsel ağırlıklı: her adım, uygulamanın gerçek arayüzünü taklit eden küçük
/// maketlerle anlatılır. [section] verilirse o bölüme kaydırır (bilgi butonları).
class GuideScreen extends StatefulWidget {
  const GuideScreen({super.key, this.section});

  final GuideSection? section;

  @override
  State<GuideScreen> createState() => _GuideScreenState();
}

class _GuideScreenState extends State<GuideScreen> {
  final _keys = {
    for (final s in GuideSection.values) s: GlobalKey(),
  };

  @override
  void initState() {
    super.initState();
    final s = widget.section;
    if (s != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _keys[s]?.currentContext;
        if (ctx != null) {
          Scrollable.ensureVisible(ctx,
              duration: const Duration(milliseconds: 450),
              curve: Curves.easeOutCubic,
              alignment: 0.05);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.arrow_back),
        ),
        title: const Text('Nasıl Kullanılır'),
      ),
      body: ListView(
        padding:
            EdgeInsets.fromLTRB(20, 8, 20, AppInsets.pageBottom(context) + 20),
        children: [
          // ---- Uygulama amacı ----
          _IntroCard(text: text),
          const SizedBox(height: 16),
          const _VideoCard(
            title: 'Uygulama tanıtımı',
            youtubeId: GuideVideos.intro,
          ),
          const SizedBox(height: 24),

          // ---- Alarm nasıl kurulur ----
          _Section(
            sectionKey: _keys[GuideSection.alarm]!,
            color: VigilantColors.primary,
            icon: Icons.notifications_active_rounded,
            title: 'Alarm nasıl kurulur?',
            children: [
              const _Step(
                n: 1,
                title: 'Durağını ya da hattını ara',
                body: 'Ana sayfadaki arama kutusuna ineceğin durağın veya '
                    'binmek istediğin hattın adını yaz.',
              ),
              const _MockSearchBox(),
              const _Step(
                n: 2,
                title: 'Durağı seç',
                body: 'Listeden ineceğin durağa dokun. Yakındaki duraklar '
                    'konumuna göre en yakından sıralanır.',
              ),
              const _MockStopRow(),
              const _Step(
                n: 3,
                title: 'Hattı ve yönü seç',
                body: 'Otobüs durağında o duraktan geçen hatlar çıkar; '
                    'gideceğin hattı ve yönü seç.',
              ),
              const _MockLineChips(),
              const _Step(
                n: 4,
                title: 'Alarmı kur',
                body: 'Kırmızı "Alarm Kur" butonuna bas. Takip başlar; '
                    'uygulamayı kapatabilirsin.',
              ),
              const _MockAlarmButton(),
              const _Step(
                n: 5,
                title: 'Durağına yaklaşınca uyandırır',
                body: 'StopAlert konumunu izler ve durağına yaklaşınca '
                    'çalar saat gibi seni uyarır — arka planda bile.',
                last: true,
              ),
              const SizedBox(height: 4),
              const _VideoCard(
                title: 'Adım adım: alarm kurma',
                youtubeId: GuideVideos.alarm,
              ),
            ],
          ),
          const SizedBox(height: 20),

          // ---- Durak nasıl seçilir ----
          _Section(
            sectionKey: _keys[GuideSection.stop]!,
            color: VigilantColors.accentBlue,
            icon: Icons.location_on_rounded,
            title: 'Durak nasıl seçilir?',
            children: [
              const _Bullet(
                  'Aramadan: durak adını yaz, listeden seç.'),
              const _Bullet(
                  'Yakındakilerden: ana sayfadaki "Yakındaki Duraklar" '
                  'kartından en yakın durağa dokun.'),
              const _Bullet(
                  'Haritadan: durak kartındaki harita düğmesiyle çevreni '
                  'görüp bir durağa dokun.'),
              const SizedBox(height: 8),
              const _VideoCard(
                title: 'Durak seçme yolları',
                youtubeId: GuideVideos.stop,
              ),
            ],
          ),
          const SizedBox(height: 20),

          // ---- Yaklaşan otobüs / canlı takip ----
          _Section(
            sectionKey: _keys[GuideSection.bus]!,
            color: VigilantColors.secondary,
            icon: Icons.directions_bus_filled_rounded,
            title: 'Yaklaşan otobüs & canlı takip',
            children: [
              const _Bullet(
                  'Ana sayfada en yakın durağa yaklaşan otobüsü dakikası ve '
                  'gittiği yönüyle görürsün (canlı konumu olan hatlarda).'),
              const _Bullet(
                  'Alarm kurulunca canlı takip ekranı kalan durağı ve '
                  'mesafeyi gösterir.'),
              const _Bullet(
                  'Sinyal kesilse bile hesaba dayalı tahminle takip sürer.'),
              const SizedBox(height: 8),
              const _VideoCard(
                title: 'Canlı takip nasıl çalışır',
                youtubeId: GuideVideos.bus,
              ),
            ],
          ),
          const SizedBox(height: 20),

          // ---- Ekstralar ----
          _Section(
            sectionKey: _keys[GuideSection.extras]!,
            color: VigilantColors.tertiaryContainer,
            icon: Icons.auto_awesome_rounded,
            title: 'Favoriler, widget ve dil',
            children: const [
              _Bullet('Sık kullandığın rotaları favorilere ekle, tek '
                  'dokunuşla alarm kur.'),
              _Bullet('Ana ekran widget\'ıyla alarmı uygulamayı açmadan '
                  'başlat ve kalan durağı gör.'),
              _Bullet('Ayarlar > Dil ile uygulamayı Türkçe, İngilizce, '
                  'Fransızca, İspanyolca veya Arapça yap.'),
            ],
          ),
          const SizedBox(height: 20),
          Text(
            'Daha fazla anlatım videosu yakında YouTube kanalımızda.',
            textAlign: TextAlign.center,
            style: text.labelMedium
                ?.copyWith(color: VigilantColors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// Uygulamanın ne işe yaradığını anlatan giriş kartı.
class _IntroCard extends StatelessWidget {
  const _IntroCard({required this.text});
  final TextTheme text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: VigilantColors.surfaceContainer,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
            color: VigilantColors.primary.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Mascot(MascotAssets.hero, height: 72),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('StopAlert nedir?',
                    style:
                        text.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: 6),
                Text(
                  'Toplu taşımada ineceğin durağı kaçırma. Durağını seç, '
                  'alarmı kur; StopAlert konumunu izler ve durağına yaklaşınca '
                  'seni uyandırır — arka planda, uygulama kapalıyken bile.',
                  style: text.bodyMedium?.copyWith(
                      color: VigilantColors.onSurfaceVariant, height: 1.4),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Renkli başlıklı bölüm kutusu.
class _Section extends StatelessWidget {
  const _Section({
    required this.sectionKey,
    required this.color,
    required this.icon,
    required this.title,
    required this.children,
  });

  final Key sectionKey;
  final Color color;
  final IconData icon;
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      key: sectionKey,
      decoration: BoxDecoration(
        color: VigilantColors.surfaceContainer,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Başlık şeridi.
          Container(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(20)),
            ),
            child: Row(
              children: [
                Icon(icon, size: 20, color: color),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(title,
                      style: text.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w800)),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            ),
          ),
        ],
      ),
    );
  }
}

/// Numaralı adım (dikey bağlantı çizgisiyle).
class _Step extends StatelessWidget {
  const _Step({
    required this.n,
    required this.title,
    required this.body,
    this.last = false,
  });

  final int n;
  final String title;
  final String body;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              Container(
                width: 26,
                height: 26,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                  color: VigilantColors.primary,
                  shape: BoxShape.circle,
                ),
                child: Text('$n',
                    style: text.labelMedium?.copyWith(
                        color: Colors.white, fontWeight: FontWeight.w800)),
              ),
              if (!last)
                Expanded(
                  child: Container(
                    width: 2,
                    color: VigilantColors.primary.withValues(alpha: 0.25),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: last ? 0 : 14, top: 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: text.labelLarge
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 3),
                  Text(body,
                      style: text.bodyMedium?.copyWith(
                          color: VigilantColors.onSurfaceVariant,
                          height: 1.35)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Madde işaretli satır.
class _Bullet extends StatelessWidget {
  const _Bullet(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 6, right: 10),
            child: Icon(Icons.check_circle_rounded,
                size: 16, color: VigilantColors.secondary),
          ),
          Expanded(
            child: Text(text,
                style: t.bodyMedium?.copyWith(
                    color: VigilantColors.onSurfaceVariant, height: 1.35)),
          ),
        ],
      ),
    );
  }
}

/// YouTube video kartı — ID doluysa dokununca videoyu açar, boşsa "yakında".
class _VideoCard extends StatelessWidget {
  const _VideoCard({required this.title, required this.youtubeId});

  final String title;
  final String? youtubeId;

  Future<void> _open() async {
    final id = youtubeId;
    if (id == null || id.isEmpty) return;
    final uri = Uri.parse('https://www.youtube.com/watch?v=$id');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final has = youtubeId != null && youtubeId!.isNotEmpty;
    return GestureDetector(
      onTap: has ? _open : null,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF141414),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: has
                    ? VigilantColors.primary
                    : VigilantColors.surfaceContainerHigh,
                shape: BoxShape.circle,
              ),
              child: Icon(
                has ? Icons.play_arrow_rounded : Icons.movie_outlined,
                color: has ? Colors.white : VigilantColors.onSurfaceVariant,
                size: 26,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title,
                      style: text.labelLarge
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(
                    has ? 'İzlemek için dokun' : 'Video yakında eklenecek',
                    style: text.labelSmall
                        ?.copyWith(color: VigilantColors.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            if (has)
              const Icon(Icons.open_in_new_rounded,
                  size: 18, color: VigilantColors.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

// ---- Uygulama arayüzünü taklit eden küçük maketler ----

class _MockWrap extends StatelessWidget {
  const _MockWrap({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 14, top: 2),
        child: child,
      );
}

class _MockSearchBox extends StatelessWidget {
  const _MockSearchBox();

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return _MockWrap(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: VigilantColors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            const Icon(Icons.search, color: VigilantColors.onSurfaceVariant),
            const SizedBox(width: 12),
            Text('İneceğin durağı veya hattı yaz…',
                style: text.bodyMedium
                    ?.copyWith(color: VigilantColors.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

class _MockStopRow extends StatelessWidget {
  const _MockStopRow();

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return _MockWrap(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: VigilantColors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: const Color(0xFF2C2C2C),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text('DURAK',
                  style: text.labelSmall?.copyWith(
                      color: Colors.white, fontWeight: FontWeight.w800)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text('Kadıköy',
                  style: text.labelLarge?.copyWith(
                      fontWeight: FontWeight.w700)),
            ),
            const Icon(Icons.sensors, size: 15, color: VigilantColors.primary),
            const SizedBox(width: 4),
            Text('120 m',
                style: text.labelLarge?.copyWith(
                    color: VigilantColors.primary,
                    fontWeight: FontWeight.w800)),
          ],
        ),
      ),
    );
  }
}

class _MockLineChips extends StatelessWidget {
  const _MockLineChips();

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    Widget chip(String code) => Container(
          margin: const EdgeInsets.only(right: 8),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: VigilantColors.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: VigilantColors.surfaceVariant.withValues(alpha: 0.5)),
          ),
          child: Text(code,
              style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
        );
    return _MockWrap(
      child: Row(children: [chip('34A'), chip('16D'), chip('E-5')]),
    );
  }
}

class _MockAlarmButton extends StatelessWidget {
  const _MockAlarmButton();

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return _MockWrap(
      child: Container(
        width: double.infinity,
        height: 52,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: VigilantColors.primary,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.notifications_active_rounded,
                color: Colors.white, size: 20),
            const SizedBox(width: 8),
            Text('Alarm Kur',
                style: text.bodyLarge?.copyWith(
                    color: Colors.white, fontWeight: FontWeight.w700)),
          ],
        ),
      ),
    );
  }
}
