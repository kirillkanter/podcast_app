import 'package:flutter/material.dart';

import '../data/db/database.dart';
import 'app_scope.dart';
import 'format.dart';
import 'library_screen.dart';
import 'theme.dart';

/// Все эпизоды ленты по фильтру, сгруппированные по дням выхода.
class FeedScreen extends StatefulWidget {
  const FeedScreen({super.key, this.initialFilter = FeedFilter.fresh});

  final FeedFilter initialFilter;

  @override
  State<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends State<FeedScreen> {
  late FeedFilter _filter = widget.initialFilter;

  /// Столько эпизодов хватает на долгую прокрутку и не нагружает базу.
  static const _limit = 300;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppBar(),
      body: StreamBuilder<List<FeedEpisode>>(
        stream: AppScope.of(context).db.watchFeed(_filter, limit: _limit),
        builder: (context, snapshot) {
          final items = snapshot.data;
          return CustomScrollView(slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
                child: Text('Эпизоды', style: screenTitleStyle(context)),
              ),
            ),
            SliverToBoxAdapter(
              child: FeedFilterChips(value: _filter, onChanged: (f) => setState(() => _filter = f)),
            ),
            if (items == null)
              const SliverToBoxAdapter(child: SizedBox(height: 120))
            else if (items.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text('Здесь пока пусто.', style: TextStyle(color: c.muted)),
                ),
              )
            else
              SliverList.list(children: _grouped(items, c)),
            SliverToBoxAdapter(child: SizedBox(height: MediaQuery.paddingOf(context).bottom + 16)),
          ]);
        },
      ),
    );
  }

  /// Заголовок дня перед первым эпизодом этого дня. Начатые идут в порядке
  /// прослушивания, поэтому для них группы нет.
  List<Widget> _grouped(List<FeedEpisode> items, BcColors c) {
    if (_filter == FeedFilter.started) {
      return [for (final item in items) FeedEpisodeRow(item: item)];
    }
    final out = <Widget>[];
    String? current;
    for (final item in items) {
      final day = formatEpisodeDate(item.episode.pubDate);
      if (day != current) {
        current = day;
        out.add(Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 2),
          child: Text(day.isEmpty ? 'Без даты' : day,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.muted)),
        ));
      }
      out.add(FeedEpisodeRow(item: item, showDate: false));
    }
    return out;
  }
}
