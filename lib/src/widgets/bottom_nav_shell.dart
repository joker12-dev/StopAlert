import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../screens/favorites_screen.dart';
import '../screens/home_screen.dart';
import '../screens/profile_screen.dart';
import '../screens/search_screen.dart';
import '../theme/app_theme.dart';

/// Aktif alt sekme indeksi (0: Ana Sayfa, 1: Hatlar, 2: Favoriler, 3: Profil).
///
/// Ana sayfadaki "Tümünü Gör", tür butonları vb. bir sekmeye geçmek için
/// yeni sayfa PUSH etmek yerine bu değeri değiştirir — böylece alt menü
/// kaybolmaz ve kullanıcı sekmeler arasında serbestçe gezebilir.
final bottomNavIndexProvider = StateProvider<int>((ref) => 0);

/// Alt navigasyon kabuğu: Ana Sayfa / Hatlar / Favoriler / Profil.
/// Tasarımdaki gibi buzlu cam zemin, üstten 32px yuvarlatma ve
/// aktif sekmede kırmızı hap arka planı kullanır.
class BottomNavShell extends ConsumerStatefulWidget {
  const BottomNavShell({super.key});

  @override
  ConsumerState<BottomNavShell> createState() => _BottomNavShellState();
}

class _BottomNavShellState extends ConsumerState<BottomNavShell> {
  static const _tabs = [
    (icon: Icons.home_rounded, label: 'Ana Sayfa'),
    // "Rotalar" yol tarifi çağrıştırıyordu; sekme aslında HAT arama.
    (icon: Icons.alt_route_rounded, label: 'Hatlar'),
    (icon: Icons.bookmark_rounded, label: 'Favoriler'),
    (icon: Icons.person_rounded, label: 'Profil'),
  ];

  // Ziyaret edilen sekmeler; yalnızca açıldıktan sonra inşa edilir (tembel
  // yükleme) — böylece Favoriler/Profil, kullanıcı dokunmadan Firestore'a
  // gereksiz sorgu açmaz. Ziyaret sonrası IndexedStack durumu korunur.
  final Set<int> _visited = {0};

  Widget _screenFor(int i) => switch (i) {
        0 => const HomeScreen(),
        1 => const SearchScreen(),
        2 => const FavoritesScreen(),
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
      body: IndexedStack(
        index: index,
        children: [
          for (var i = 0; i < _tabs.length; i++)
            _visited.contains(i) ? _screenFor(i) : const SizedBox.shrink(),
        ],
      ),
      bottomNavigationBar: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
        child: BackdropFilter(
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
                        icon: _tabs[i].icon,
                        label: _tabs[i].label,
                        active: i == index,
                        onTap: () => setState(() => _select(i)),
                      ),
                    ),
                ],
              ),
            );
          }),
        ),
      ),
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
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
        decoration: BoxDecoration(
          color: active
              ? VigilantColors.primary.withValues(alpha: 0.14)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: active
                ? VigilantColors.primary.withValues(alpha: 0.35)
                : Colors.transparent,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: color,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
