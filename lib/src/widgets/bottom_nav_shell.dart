import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../state/tour_keys.dart';
import '../screens/favorites_screen.dart';
import '../screens/home_screen.dart';
import '../screens/profile_screen.dart';
import '../screens/search_screen.dart';
import '../screens/stops_screen.dart';
import '../theme/app_theme.dart';
import 'anim.dart';

/// Sekme indeksleri — ÇAĞIRAN TARAF BU ADLARI KULLANIR.
///
/// Sayı yazmak kırılgandı: araya yeni bir sekme eklendiğinde ana sayfadaki
/// "Tümü" bağlantıları sessizce yanlış sayfaya gidiyordu.
abstract final class NavTab {
  static const home = 0;
  static const lines = 1;
  static const stops = 2;
  static const favorites = 3;
  static const profile = 4;
}

/// Aktif alt sekme indeksi (bkz. [NavTab]).
///
/// Ana sayfadaki "Tümünü Gör", tür butonları vb. bir sekmeye geçmek için
/// yeni sayfa PUSH etmek yerine bu değeri değiştirir — böylece alt menü
/// kaybolmaz ve kullanıcı sekmeler arasında serbestçe gezebilir.
final bottomNavIndexProvider = StateProvider<int>((ref) => NavTab.home);

/// Alt navigasyon kabuğu: Ana Sayfa / Hatlar / Duraklar / Favoriler / Profil.
/// Tasarımdaki gibi buzlu cam zemin, üstten 32px yuvarlatma ve
/// aktif sekmede kırmızı hap arka planı kullanır.
class BottomNavShell extends ConsumerStatefulWidget {
  const BottomNavShell({super.key});

  @override
  ConsumerState<BottomNavShell> createState() => _BottomNavShellState();
}

class _BottomNavShellState extends ConsumerState<BottomNavShell> {
  // Her sekme: DOLU (aktif) ve İNCE (pasif) ikon — mockup'taki gibi aktif
  // sekme kırmızı+dolu, ötekiler gri+ince. Başlıklar korunur.
  // İkonlar sabit; başlıklar dile göre [_labels] ile üretilir.
  static const _tabs = [
    (on: Icons.home_rounded, off: Icons.home_outlined),
    // "Rotalar" yol tarifi çağrıştırıyordu; sekme aslında HAT arama.
    (on: Icons.alt_route_rounded, off: Icons.alt_route_outlined),
    // Durak arama AYRI sekme: hat ve durak tek listede karışınca kullanıcı
    // ne aradığını bulamıyordu.
    (on: Icons.location_on_rounded, off: Icons.location_on_outlined),
    (on: Icons.star_rounded, off: Icons.star_border_rounded),
    (on: Icons.person_rounded, off: Icons.person_outline_rounded),
  ];

  /// Sekme başlıkları — seçili dile göre.
  static List<String> _labels(AppLocalizations l) =>
      [l.navHome, l.navLines, l.navStops, l.navFavorites, l.navProfile];

  // Ziyaret edilen sekmeler; yalnızca açıldıktan sonra inşa edilir (tembel
  // yükleme) — böylece Favoriler/Profil, kullanıcı dokunmadan Firestore'a
  // gereksiz sorgu açmaz. Ziyaret sonrası IndexedStack durumu korunur.
  final Set<int> _visited = {0};

  Widget _screenFor(int i) => switch (i) {
        NavTab.home => const HomeScreen(),
        NavTab.lines => const SearchScreen(),
        NavTab.stops => const StopsScreen(),
        NavTab.favorites => const FavoritesScreen(),
        _ => const ProfileScreen(),
      };

  void _select(int i) {
    ref.read(bottomNavIndexProvider.notifier).state = i;
    _visited.add(i);
  }

  @override
  Widget build(BuildContext context) {
    final index = ref.watch(bottomNavIndexProvider);
    // Provider dışarıdan değişince (ör. "Tümünü Gör") sekmeyi ziyaret et.
    _visited.add(index);
    return Scaffold(
      extendBody: true,
      body: TabSwitchTransition(
        index: index,
        child: IndexedStack(
          index: index,
          children: [
            for (var i = 0; i < _tabs.length; i++)
              _visited.contains(i) ? _screenFor(i) : const SizedBox.shrink(),
          ],
        ),
      ),
      // BANNER YOK. Menüye yapışık banner denendi ve kaldırıldı: alt menü
      // uygulamanın en çok dokunulan yeri, hemen üstüne reklam koymak yanlış
      // dokunuşa davetiye çıkarıyor. Reklam artık yalnızca sayfa içlerinde,
      // içeriğin sonunda ve çerçeveli (bkz. `NativeAdSlot`).
      bottomNavigationBar: KeyedSubtree(
        key: TourKeys.nav,
        child: ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
          child: _navBar(context),
        ),
      ),
    );
  }

  Widget _navBar(BuildContext context) {
    final index = ref.watch(bottomNavIndexProvider);
    final labels = _labels(AppLocalizations.of(context));
    return BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          // Yükseklik = içerik + sistem navigasyon çubuğu payı. Sabit 80 px
          // verilirse 3 tuşlu/jest çubuğu olan cihazlarda sekmelerin altı
          // çubuğun ARKASINDA kalıyordu (SafeArea içeriği iter ama kutu
          // büyümez). Bu yüzden inset kadar büyütüp altına boşluk veriyoruz.
          child: Builder(builder: (context) {
            final inset = MediaQuery.viewPaddingOf(context).bottom;
            return Container(
              height: 80 + inset,
              padding: EdgeInsets.only(bottom: inset),
              decoration: BoxDecoration(
                color: VigilantColors.surfaceContainer.withValues(alpha: 0.8),
                border: Border(
                  top: BorderSide(color: Colors.white.withValues(alpha: 0.05)),
                ),
              ),
              child: Row(
                children: [
                  for (var i = 0; i < _tabs.length; i++)
                    Expanded(
                      child: _NavTab(
                        icon: i == index ? _tabs[i].on : _tabs[i].off,
                        label: labels[i],
                        active: i == index,
                        onTap: () => setState(() => _select(i)),
                      ),
                    ),
                ],
              ),
            );
          }),
    );
  }
}

class _NavTab extends StatelessWidget {
  const _NavTab({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color =
        active ? VigilantColors.primary : VigilantColors.onSurfaceVariant;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      // PILL KUTUSU YOK (mockup): aktif sekme yalnızca kırmızı ikon + kırmızı
      // kalın etiketle belli olur, ötekiler gri.
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 25),
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: color,
                    fontWeight: active ? FontWeight.w800 : FontWeight.w500,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
