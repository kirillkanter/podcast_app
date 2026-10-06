import 'package:flutter/material.dart';

import 'data/db/database.dart';
import 'data/podcast_repository.dart';
import 'feed/feed_fetcher.dart';
import 'ui/app_scope.dart';
import 'ui/home_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final db = AppDatabase.defaults();
  final repository = PodcastRepository(db, FeedFetcher());
  runApp(PodcastApp(db: db, repository: repository));
}

class PodcastApp extends StatelessWidget {
  const PodcastApp({
    super.key,
    required this.db,
    required this.repository,
    this.refreshOnStart = true,
  });

  final AppDatabase db;
  final PodcastRepository repository;
  final bool refreshOnStart;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      db: db,
      repository: repository,
      child: MaterialApp(
        title: 'Подкасты',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: Colors.deepPurple, useMaterial3: true),
        darkTheme: ThemeData(
          colorSchemeSeed: Colors.deepPurple,
          brightness: Brightness.dark,
          useMaterial3: true,
        ),
        home: HomeScreen(refreshOnStart: refreshOnStart),
      ),
    );
  }
}
