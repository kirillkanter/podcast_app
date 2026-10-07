import 'package:flutter/material.dart';

import '../data/db/database.dart';
import '../sync/sync_service.dart';
import 'app_scope.dart';
import 'downloads_screen.dart';
import 'episode_actions.dart';
import 'format.dart';
import 'library_screen.dart';
import 'mini_player.dart';
import 'now_playing.dart';
import 'podcast_cover.dart';
import 'podcast_screen.dart';
import 'queue_screen.dart';
import 'search_screen.dart';
import 'settings_screen.dart';
import 'icons.dart';
import 'theme.dart';

/// Разделы приложения: нижние вкладки на телефоне, боковое меню на компьютере.
enum ShellTab {
  library('Библиотека', BcIcons.library),
  search('Поиск', BcIcons.search),
  downloads('Загрузки', BcIcons.download),
  // На телефоне очередь — блок в библиотеке и отдельный экран оттуда.
  queue('Очередь', BcIcons.queue, phone: false),
  settings('Настройки', BcIcons.settings);

  const ShellTab(this.label, this.icon, {this.phone = true});
  final String label;
  final BcIcons icon;

  /// Есть ли вкладка внизу на телефоне.
  final bool phone;
}

/// Ширина окна, с которой показывается компьютерная раскладка.
const wideLayoutWidth = 900.0;

/// Каркас приложения: разделы со своими стопками экранов и мини-плеер.
class AppShell extends StatefulWidget {
  const AppShell({super.key, this.refreshOnStart = true});

  final bool refreshOnStart;

  /// Открыть экран подкаста в разделе «Библиотека» (например, из бокового меню).
  /// Работает и из экранов поверх каркаса (большой плеер).
  static void openPodcast(BuildContext context, int podcastId) =>
      (context.findAncestorStateOfType<_AppShellState>() ?? _AppShellState._current)?._openPodcast(podcastId);

  /// Открыть очередь: на компьютере — раздел меню, на телефоне — экран
  /// поверх текущего раздела.
  static void openQueue(BuildContext context) {
    final shell = context.findAncestorStateOfType<_AppShellState>() ?? _AppShellState._current;
    if (shell != null && MediaQuery.sizeOf(context).width >= wideLayoutWidth) {
      shell._select(ShellTab.queue);
    } else if (shell != null && context.findAncestorStateOfType<_AppShellState>() == null) {
      // Вызов поверх каркаса — открываем в текущем разделе.
      shell._navigators[shell._tab]!.currentState
          ?.push(MaterialPageRoute<void>(builder: (_) => const QueueScreen()));
    } else {
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const QueueScreen()));
    }
  }

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  static _AppShellState? _current;

  @override
  void initState() {
    super.initState();
    _current = this;
  }

  @override
  void dispose() {
    if (_current == this) _current = null;
    super.dispose();
  }

  final _navigators = {for (final t in ShellTab.values) t: GlobalKey<NavigatorState>()};
  final _visited = <ShellTab>{ShellTab.library};
  ShellTab _tab = ShellTab.library;

  void _select(ShellTab tab) {
    if (tab == _tab) {
      // Повторное нажатие — к началу раздела.
      _navigators[tab]!.currentState?.popUntil((r) => r.isFirst);
      return;
    }
    setState(() {
      _tab = tab;
      _visited.add(tab);
    });
  }

  void _openPodcast(int podcastId) {
    _select(ShellTab.library);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final nav = _navigators[ShellTab.library]!.currentState;
      nav?.popUntil((r) => r.isFirst);
      nav?.push(MaterialPageRoute<void>(builder: (_) => PodcastScreen(podcastId: podcastId)));
    });
  }

  Widget _root(ShellTab tab) {
    final scope = AppScope.of(context);
    return switch (tab) {
      ShellTab.library => LibraryScreen(refreshOnStart: widget.refreshOnStart),
      ShellTab.search => scope.catalog == null
          ? const _Unavailable('Каталог подкастов недоступен')
          : const SearchScreen(),
      ShellTab.downloads => scope.downloads == null
          ? const _Unavailable('Загрузки недоступны')
          : const DownloadsScreen(),
      ShellTab.queue => const QueueScreen(showBack: false),
      ShellTab.settings => const SettingsScreen(),
    };
  }

  Widget _pages(double bottomInset) {
    return IndexedStack(
      index: _tab.index,
      children: [
        for (final tab in ShellTab.values)
          if (!_visited.contains(tab))
            const SizedBox.shrink()
          else
            MediaQuery(
              data: MediaQuery.of(context).copyWith(
                padding: MediaQuery.paddingOf(context).copyWith(bottom: bottomInset),
              ),
              child: HeroControllerScope.none(
                child: Navigator(
                  key: _navigators[tab],
                  onGenerateRoute: (_) => MaterialPageRoute<void>(builder: (_) => _root(tab)),
                ),
              ),
            ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= wideLayoutWidth;
    // Окно сузили, а открыт раздел только для компьютера — в библиотеку.
    if (!wide && !_tab.phone) {
      _tab = ShellTab.library;
    }
    return NavigatorPopHandler(
      onPopWithResult: (_) {
        // Жест «назад» сначала закрывает то, что открыто поверх разделов:
        // карточку эпизода, диалог, большой плеер. Иначе жест уходил
        // в раздел под ними, а окно оставалось висеть.
        final root = Navigator.of(context, rootNavigator: true);
        if (root.canPop()) {
          root.maybePop();
          return;
        }
        _navigators[_tab]!.currentState?.maybePop();
      },
      child: SwipeSettingsProvider(
        child: NowPlayingBuilder(builder: (context, now, audio) {
          final playerVisible = audio != null && now.item != null && now.active;
          return wide ? _wide(playerVisible) : _phone(playerVisible);
        }),
      ),
    );
  }

  Widget _phone(bool playerVisible) {
    final c = BcColors.of(context);
    return Scaffold(
      backgroundColor: c.bg,
      body: Stack(children: [
        Positioned.fill(child: _pages(playerVisible ? MiniPlayer.height + 16 : 8)),
        if (playerVisible)
          const Positioned(left: 10, right: 10, bottom: 8, child: MiniPlayer()),
      ]),
      bottomNavigationBar: _PhoneNav(selected: _tab, onSelect: _select),
    );
  }

  Widget _wide(bool playerVisible) {
    final c = BcColors.of(context);
    return Scaffold(
      backgroundColor: c.bg,
      body: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _Sidebar(selected: _tab, onSelect: _select, onOpenPodcast: _openPodcast),
        VerticalDivider(width: 1, color: c.divider),
        Expanded(
          child: Stack(children: [
            Positioned.fill(child: _pages(playerVisible ? DesktopPlayerBar.height + 28 : 16)),
            if (playerVisible)
              const Positioned(left: 12, right: 12, bottom: 12, child: DesktopPlayerBar()),
          ]),
        ),
      ]),
    );
  }
}

class _PhoneNav extends StatelessWidget {
  const _PhoneNav({required this.selected, required this.onSelect});

  final ShellTab selected;
  final ValueChanged<ShellTab> onSelect;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    return ColoredBox(
      color: c.bg,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
          child: Row(children: [
            for (final tab in ShellTab.values.where((t) => t.phone))
              Expanded(
                child: Semantics(
                  selected: tab == selected,
                  button: true,
                  child: InkResponse(
                    key: Key('tab-${tab.name}'),
                    onTap: () => onSelect(tab),
                    radius: 36,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        BcIcon(tab.icon, size: 24, color: tab == selected ? c.ink : c.muted),
                        const SizedBox(height: 4),
                        Text(
                          tab.label,
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: tab == selected ? FontWeight.w600 : FontWeight.w400,
                            color: tab == selected ? c.ink : c.muted,
                          ),
                        ),
                      ]),
                    ),
                  ),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.selected, required this.onSelect, required this.onOpenPodcast});

  final ShellTab selected;
  final ValueChanged<ShellTab> onSelect;
  final ValueChanged<int> onOpenPodcast;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final db = AppScope.of(context).db;
    return SizedBox(
      width: 248,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 20, 14, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 18),
            child: Row(children: [
              Image.asset('assets/images/logo.png', width: 32, height: 32,
                  errorBuilder: (_, _, _) => const SizedBox.square(dimension: 32)),
              const SizedBox(width: 10),
              const Text('Basic Caster',
                  style: TextStyle(fontFamily: displayFont, fontWeight: FontWeight.w600, fontSize: 17)),
            ]),
          ),
          for (final tab in ShellTab.values)
            _SideItem(
              key: Key('tab-${tab.name}'),
              icon: tab.icon,
              label: tab.label,
              selected: tab == selected,
              onTap: () => onSelect(tab),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 22, 12, 8),
            child: Text('Подписки', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.muted)),
          ),
          Expanded(
            child: StreamBuilder<List<Podcast>>(
              stream: db.watchSubscribedPodcasts(),
              builder: (context, podcasts) => StreamBuilder<Map<int, int>>(
                stream: db.watchNewEpisodeCounts(),
                builder: (context, counts) {
                  final list = podcasts.data ?? const <Podcast>[];
                  return ListView.builder(
                    padding: EdgeInsets.zero,
                    itemCount: list.length,
                    itemBuilder: (context, i) {
                      final p = list[i];
                      final n = counts.data?[p.id] ?? 0;
                      return InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () => onOpenPodcast(p.id),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                          child: Row(children: [
                            PodcastCover(url: p.imageUrl, size: 26),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(p.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 14)),
                            ),
                            if (n > 0) CountBadge(count: n, small: true),
                          ]),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ),
          const _SyncStatus(),
        ]),
      ),
    );
  }
}

class _SideItem extends StatelessWidget {
  const _SideItem({super.key, required this.icon, required this.label, required this.selected, required this.onTap});

  final BcIcons icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: selected ? c.raised : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: SizedBox(
            height: 44,
            child: Row(children: [
              const SizedBox(width: 12),
              BcIcon(icon, size: 20, color: selected ? c.ink : c.muted),
              const SizedBox(width: 12),
              Text(label,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: selected ? c.text : c.muted,
                  )),
            ]),
          ),
        ),
      ),
    );
  }
}

class _SyncStatus extends StatelessWidget {
  const _SyncStatus();

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final scope = AppScope.of(context);
    if (scope.sync == null) return const SizedBox.shrink();
    return StreamBuilder<String?>(
      stream: scope.db.watchSetting(SyncSettings.username),
      builder: (context, user) => StreamBuilder<String?>(
        stream: scope.db.watchSetting(SyncSettings.lastSync),
        builder: (context, last) {
          final at = DateTime.tryParse(last.data ?? '');
          final text = user.data == null || user.data!.isEmpty
              ? 'Синхронизация выключена'
              : at == null
                  ? 'Синхронизация включена'
                  : 'Синхронизировано · ${formatAgo(at)}';
          return Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              BcIcon(BcIcons.sync, size: 16, color: c.muted),
              const SizedBox(width: 8),
              Expanded(child: Text(text, style: TextStyle(fontSize: 12, color: c.muted))),
            ]),
          );
        },
      ),
    );
  }
}

/// Счётчик новых эпизодов на обложке или в списке.
class CountBadge extends StatelessWidget {
  const CountBadge({super.key, required this.count, this.small = false});

  final int count;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final h = small ? 20.0 : 22.0;
    return Container(
      constraints: BoxConstraints(minWidth: h),
      height: h,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      alignment: Alignment.center,
      decoration: BoxDecoration(color: c.fill, borderRadius: BorderRadius.circular(h / 2)),
      child: Text(count > 99 ? '99+' : '$count',
          style: TextStyle(fontSize: small ? 11 : 12, fontWeight: FontWeight.w600, color: c.onFill)),
    );
  }
}

class _Unavailable extends StatelessWidget {
  const _Unavailable(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Scaffold(body: Center(child: Text(text)));
}
