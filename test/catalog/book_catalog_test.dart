import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:podcast_app/books/book_library.dart';
import 'package:podcast_app/catalog/books/book_catalog.dart';
import 'package:podcast_app/catalog/books/librivox_source.dart';
import 'package:podcast_app/catalog/books/opds_source.dart';
import 'package:podcast_app/data/db/books_dao.dart';
import 'package:podcast_app/data/db/database.dart';

import '../books/book_test_files.dart';

http.Response json(Object body) => http.Response.bytes(utf8.encode(jsonEncode(body)), 200);
http.Response xml(String body) => http.Response.bytes(utf8.encode(body), 200);

const searchJson = {
  'response': {
    'numFound': 2,
    'docs': [
      {
        'identifier': 'twenty_thousand_leagues_librivox',
        'title': 'Twenty Thousand Leagues Under the Sea (version 2)',
        'creator': ['Jules Verne'],
        'language': ['English'],
        'downloads': 50000,
      },
      {'identifier': 'rasskazy_chekhov_librivox', 'title': 'Рассказы', 'creator': 'Антон Чехов', 'language': 'Russian'},
      {'title': 'без идентификатора'},
    ],
  },
};

const metadataJson = {
  'metadata': {
    'title': 'Twenty Thousand Leagues Under the Sea',
    'creator': 'Jules Verne',
    'language': 'eng',
    'description': '<p>Профессор Аронакс и капитан Немо.</p><br>Запись LibriVox &amp; волонтёров.',
  },
  'files': [
    {'name': 'leagues_02_verne_64kb.mp3', 'format': '64Kbps MP3', 'size': '2000', 'length': '61.5', 'title': 'Chapter 2', 'track': '2'},
    {'name': 'leagues_01_verne_64kb.mp3', 'format': '64Kbps MP3', 'size': '1000', 'length': '01:00', 'title': 'Chapter 1', 'track': '1'},
    {'name': 'leagues_01_verne_128kb.mp3', 'format': 'VBR MP3', 'size': '9000', 'length': '60'},
    {'name': 'leagues_1006_thumb.jpg', 'format': 'JPEG Thumb', 'size': '100'},
    {'name': 'leagues_1006.jpg', 'format': 'JPEG', 'size': '50000'},
  ],
};

const acquisitionFeed = '''<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom" xmlns:dc="http://purl.org/dc/terms/">
  <title>Классика</title>
  <link rel="next" href="?page=2" type="application/atom+xml;profile=opds-catalog"/>
  <entry>
    <title>Мёртвые души</title>
    <id>urn:book:1</id>
    <author><name>Николай Гоголь</name></author>
    <dc:language>ru</dc:language>
    <summary>Поэма.</summary>
    <link rel="http://opds-spec.org/acquisition" type="text/plain" href="/files/1.txt" length="20"/>
    <link rel="http://opds-spec.org/acquisition/open-access" type="application/epub+zip" href="/files/1.epub" length="3000"/>
    <link rel="http://opds-spec.org/image" type="image/jpeg" href="/covers/1.jpg"/>
    <link rel="http://opds-spec.org/image/thumbnail" type="image/jpeg" href="/covers/1-small.jpg"/>
  </entry>
</feed>''';

const rootFeed = '''<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>Библиотека</title>
  <link rel="search" type="application/atom+xml" href="/search?q={searchTerms}"/>
  <entry>
    <title>Популярное</title>
    <id>popular</id>
    <link rel="subsection" type="application/atom+xml;profile=opds-catalog" href="/popular"/>
  </entry>
  <entry>
    <title>Жанры</title>
    <id>genres</id>
    <link rel="subsection" type="application/atom+xml;profile=opds-catalog;kind=navigation" href="/genres"/>
  </entry>
</feed>''';

const genresFeed = '''<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>Жанры</title>
  <entry><title>Научная фантастика</title><id>g1</id>
    <link rel="subsection" type="application/atom+xml;profile=opds-catalog" href="/genre/sf"/></entry>
  <entry><title>Классическая проза</title><id>g2</id>
    <link rel="subsection" type="application/atom+xml;profile=opds-catalog" href="/genre/classic"/></entry>
</feed>''';

/// Как отдаёт поиск Project Gutenberg: книги — ссылки на свою ленту.
const gutenbergSearch = '''<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>Search</title>
  <link rel="search" type="application/opensearchdescription+xml" href="/catalog/osd-books.xml"/>
  <entry>
    <title>The Time Machine</title>
    <id>https://www.gutenberg.org/ebooks/35.opds</id>
    <content type="text">H. G. Wells</content>
    <link type="application/atom+xml;profile=opds-catalog" rel="subsection" href="/ebooks/35.opds"/>
    <link type="image/png" rel="http://opds-spec.org/image/thumbnail" href="/cache/epub/35/pg35.cover.small.jpg"/>
  </entry>
  <entry>
    <title>Sort Alphabetically</title>
    <id>sort</id>
    <link type="application/atom+xml;profile=opds-catalog" rel="subsection" href="/ebooks/search.opds/?sort_order=title"/>
  </entry>
</feed>''';

/// Корень Project Gutenberg: у разделов есть значки и подписи.
const gutenbergRoot = '''<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>Project Gutenberg</title>
  <entry>
    <title>Popular</title>
    <id>popular</id>
    <content type="text">Our most popular books.</content>
    <link type="application/atom+xml;profile=opds-catalog" rel="subsection" href="/ebooks/search.opds/?sort_order=downloads"/>
    <link type="image/png" rel="http://opds-spec.org/image/thumbnail" href="/gutenberg/popular.png"/>
  </entry>
  <entry>
    <title>Latest</title>
    <id>latest</id>
    <content type="text">Recently added.</content>
    <link type="application/atom+xml;profile=opds-catalog" rel="subsection" href="/ebooks/latest.opds"/>
    <link type="image/png" rel="http://opds-spec.org/image/thumbnail" href="/gutenberg/new.png"/>
  </entry>
  <entry>
    <title>Random</title>
    <id>random</id>
    <link type="application/atom+xml;profile=opds-catalog;kind=navigation" rel="subsection" href="/ebooks/random.opds"/>
    <link type="image/png" rel="http://opds-spec.org/image/thumbnail" href="/gutenberg/random.png"/>
  </entry>
  <entry>
    <title>New Arabian Nights</title>
    <id>book</id>
    <content type="text">Robert Louis Stevenson</content>
    <link type="application/atom+xml;profile=opds-catalog" rel="subsection" href="/ebooks/839.opds"/>
    <link type="image/jpeg" rel="http://opds-spec.org/image/thumbnail" href="/cache/839.jpg"/>
  </entry>
</feed>''';

const openSearch = '''<?xml version="1.0" encoding="UTF-8"?>
<OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
  <Url type="text/html" template="https://www.gutenberg.org/ebooks/search/?query={searchTerms}"/>
  <Url type="application/atom+xml" template="/ebooks/search.opds/?query={searchTerms}&amp;start_index={startIndex?}"/>
</OpenSearchDescription>''';

void main() {
  group('LibriVox', () {
    test('запрос к Internet Archive: жанр, язык, текст', () {
      final genre = bookGenres.firstWhere((g) => g.id == 'scifi');
      final q = LibriVoxSource.query(genre: genre, text: 'war: (worlds)', language: CatalogLanguage.ru);
      expect(q, startsWith('collection:librivoxaudio'));
      expect(q, contains('subject:("science fiction" OR "fantasy"'));
      expect(q, contains('language:(Russian OR rus)'));
      expect(q, contains('(title:(war AND worlds) OR creator:(war AND worlds))'));

      final uri = LibriVoxSource.searchUri(q);
      expect(uri.host, 'archive.org');
      expect(uri.queryParametersAll['fl[]'], containsAll(['identifier', 'title', 'creator']));
      expect(uri.queryParameters['sort[]'], 'downloads desc');
      expect(uri.queryParameters['output'], 'json');
    });

    test('разбор поиска', () {
      final books = LibriVoxSource.parseSearch(jsonEncode(searchJson));
      expect(books, hasLength(2));
      final b = books.first;
      expect(b.id, 'lv:twenty_thousand_leagues_librivox');
      expect(b.title, 'Twenty Thousand Leagues Under the Sea');
      expect(b.author, 'Jules Verne');
      expect(b.audio, isTrue);
      expect(b.language, 'en');
      expect(b.sourceName, 'LibriVox');
      expect(b.cover, 'https://archive.org/services/img/twenty_thousand_leagues_librivox');
      expect(books.last.language, 'ru');
    });

    test('главы, длительность, размер и обложка из метаданных', () {
      final book = LibriVoxSource.parseSearch(jsonEncode(searchJson)).first;
      final d = LibriVoxSource.parseMetadata(book, jsonEncode(metadataJson));
      expect(d.files.map((f) => f.title), ['Chapter 1', 'Chapter 2'], reason: 'по номеру дорожки, только 64 кбит/с');
      expect(d.files.first.url, 'https://archive.org/download/twenty_thousand_leagues_librivox/leagues_01_verne_64kb.mp3');
      expect(d.size, 3000);
      expect(d.duration, const Duration(seconds: 121, milliseconds: 500));
      expect(d.coverFile, 'https://archive.org/download/twenty_thousand_leagues_librivox/leagues_1006.jpg');
      expect(d.book.description, 'Профессор Аронакс и капитан Немо.\n\nЗапись LibriVox & волонтёров.');
    });

    test('длительность: секунды и часы:минуты:секунды', () {
      expect(LibriVoxSource.parseLength('1:02:03'), const Duration(hours: 1, minutes: 2, seconds: 3));
      expect(LibriVoxSource.parseLength('90'), const Duration(seconds: 90));
      expect(LibriVoxSource.parseLength('x'), isNull);
    });
  });

  group('OPDS', () {
    test('книга с файлами: лучший формат первым, обложки, следующая страница', () {
      final feed = parseOpdsFeed(acquisitionFeed, Uri.parse('https://lib.example/classic'),
          catalogId: 'c1', catalogName: 'Библиотека');
      expect(feed.next, 'https://lib.example/classic?page=2');
      final b = feed.books.single;
      expect(b.title, 'Мёртвые души');
      expect(b.author, 'Николай Гоголь');
      expect(b.language, 'ru');
      expect(b.audio, isFalse);
      expect(b.files.map((f) => f.format), ['epub', 'txt']);
      expect(b.files.first.url, 'https://lib.example/files/1.epub');
      expect(b.files.first.size, 3000);
      expect(b.cover, 'https://lib.example/covers/1.jpg');
      expect(b.thumbnail, 'https://lib.example/covers/1-small.jpg');
      expect(b.sourceName, 'Библиотека');
    });

    test('разделы и шаблон поиска', () {
      final feed = parseOpdsFeed(rootFeed, Uri.parse('https://lib.example/opds'), catalogId: 'c1', catalogName: 'L');
      expect(feed.books, isEmpty);
      expect(feed.sections.map((s) => s.title), ['Популярное', 'Жанры']);
      expect(feed.search, 'https://lib.example/search?q={searchTerms}');
      expect(fillSearchTemplate(feed.search!, 'война и мир'), 'https://lib.example/search?q=%D0%B2%D0%BE%D0%B9%D0%BD%D0%B0+%D0%B8+%D0%BC%D0%B8%D1%80');
    });

    test('Project Gutenberg: книги-ссылки и OpenSearch', () {
      final feed = parseOpdsFeed(gutenbergSearch, Uri.parse('https://www.gutenberg.org/ebooks/search.opds/?query=x'),
          catalogId: 'pg', catalogName: 'Project Gutenberg');
      expect(feed.books.single.title, 'The Time Machine');
      expect(feed.books.single.author, 'H. G. Wells');
      expect(feed.books.single.detailsUrl, 'https://www.gutenberg.org/ebooks/35.opds');
      expect(feed.sections.single.title, 'Sort Alphabetically');
      expect(feed.searchDescription, 'https://www.gutenberg.org/catalog/osd-books.xml');
      final t = parseOpenSearch(openSearch, Uri.parse('https://www.gutenberg.org/catalog/osd-books.xml'));
      expect(t, 'https://www.gutenberg.org/ebooks/search.opds/?query={searchTerms}&start_index={startIndex?}');
      expect(fillSearchTemplate(t!, 'time'), 'https://www.gutenberg.org/ebooks/search.opds/?query=time&start_index=');
    });

    test('Project Gutenberg: разделы со значками — не книги', () {
      final feed = parseOpdsFeed(gutenbergRoot, Uri.parse('https://www.gutenberg.org/ebooks.opds/'),
          catalogId: 'pg', catalogName: 'Project Gutenberg');
      expect(feed.sections.map((s) => s.title), ['Popular', 'Latest', 'Random']);
      expect(feed.books.single.title, 'New Arabian Nights');
    });

    test('не лента — понятная ошибка', () {
      expect(
        () => parseOpdsFeed('<html><body>hi</body></html>', Uri.parse('https://x.example'), catalogId: 'a', catalogName: 'a'),
        throwsA(isA<BookCatalogException>()),
      );
    });

    test('жанр: раздел внутри «Жанров», закрытый каталог — с паролем', () async {
      final auth = <String?>[];
      final client = MockClient((r) async {
        auth.add(r.headers['Authorization']);
        return switch (r.url.path) {
          '/opds' => xml(rootFeed),
          '/genres' => xml(genresFeed),
          '/genre/sf' => xml(acquisitionFeed),
          _ => http.Response('', 404),
        };
      });
      final source = OpdsSource(
        const OpdsCatalog(id: 'c', name: 'L', url: 'https://lib.example/opds', login: 'me', password: 'pw'),
        client: client,
      );
      final books = await source.genre(bookGenres.firstWhere((g) => g.id == 'scifi'));
      expect(books.single.title, 'Мёртвые души');
      expect(auth, everyElement('Basic ${base64Encode(utf8.encode('me:pw'))}'));
      expect(source.headersFor('https://cdn.other.example/file.epub'), isEmpty, reason: 'пароль — только своему сайту');
    });
  });

  group('BookCatalog', () {
    late AppDatabase db;
    late Directory dir;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      dir = await Directory.systemTemp.createTemp('book_catalog_test');
    });

    tearDown(() async {
      await db.close();
      await dir.delete(recursive: true);
    });

    test('видимость: LibriVox по умолчанию включён; без него и без OPDS — скрыто', () async {
      final catalog = BookCatalog(db: db, client: MockClient((_) async => xml(rootFeed)), passwords: MemoryCatalogPasswords());
      expect((await catalog.config()).enabled, isTrue);
      await catalog.setLibriVox(false);
      expect((await catalog.config()).enabled, isFalse);

      final added = await catalog.addOpds(url: 'lib.example/opds', login: 'me', password: 'secret');
      expect(added.url, 'https://lib.example/opds');
      expect(added.name, 'Библиотека', reason: 'название из ленты');
      final config = await catalog.config();
      expect(config.enabled, isTrue);
      expect(config.opds.single.login, 'me');
      expect(await db.setting(BookCatalogSettings.config), isNot(contains('secret')), reason: 'пароль не в базе');

      await expectLater(catalog.addOpds(url: 'https://lib.example/opds'), throwsA(isA<BookCatalogException>()));
      await catalog.removeOpds(added.id);
      expect((await catalog.config()).enabled, isFalse);
    });

    test('жанр из двух источников и фильтры', () async {
      final client = MockClient((r) async {
        if (r.url.host == 'archive.org') return json(searchJson);
        return switch (r.url.path) {
          '/opds' => xml(rootFeed),
          '/genres' => xml(genresFeed),
          '/genre/classic' => xml(acquisitionFeed),
          _ => http.Response('', 404),
        };
      });
      final catalog = BookCatalog(db: db, client: client, passwords: MemoryCatalogPasswords());
      await catalog.addOpds(url: 'https://lib.example/opds');
      final classic = bookGenres.firstWhere((g) => g.id == 'classic');

      final all = await catalog.genre(classic, const CatalogFilter());
      expect(all.map((b) => b.title), ['Twenty Thousand Leagues Under the Sea', 'Мёртвые души', 'Рассказы']);

      final audio = await catalog.genre(classic, const CatalogFilter(kind: CatalogKind.audio));
      expect(audio.every((b) => b.audio), isTrue);

      final ru = await catalog.genre(classic, const CatalogFilter(language: CatalogLanguage.ru, kind: CatalogKind.text));
      expect(ru.map((b) => b.title), ['Мёртвые души']);
    });

    test('ошибка одного источника не прячет другой', () async {
      final client = MockClient((r) async {
        if (r.url.host == 'archive.org') return http.Response('', 500);
        return switch (r.url.path) {
          '/opds' => xml(rootFeed),
          '/popular' => xml(acquisitionFeed),
          _ => http.Response('', 404),
        };
      });
      final catalog = BookCatalog(db: db, client: client, passwords: MemoryCatalogPasswords());
      final added = await catalog.addOpds(url: 'https://lib.example/opds');
      expect((await catalog.popularOpds(added.id, const CatalogFilter())).single.title, 'Мёртвые души');
      await expectLater(catalog.popularLibriVox(const CatalogFilter()), throwsA(isA<BookCatalogException>()));
    });

    test('скачивание текстовой книги в библиотеку', () async {
      final text = utf8.encode('Мёртвые души\n\nТом первый. Глава первая.');
      final client = MockClient((r) async {
        if (r.url.path == '/opds') return xml(rootFeed);
        if (r.url.path == '/files/1.txt') return http.Response.bytes(text, 200);
        return http.Response('', 404);
      });
      final library = BookLibrary(db: db, dataDirectory: () async => dir, lookupCovers: false);
      final catalog = BookCatalog(
        db: db,
        library: library,
        client: client,
        passwords: MemoryCatalogPasswords(),
        tempDirectory: () async => dir,
      );
      final added = await catalog.addOpds(url: 'https://lib.example/opds');
      final book = parseOpdsFeed(acquisitionFeed, Uri.parse('https://lib.example/'), catalogId: added.id, catalogName: 'L')
          .books
          .single;
      // Только TXT: EPUB в тесте не собираем.
      final details = CatalogDetails(book: book, files: [book.files.last]);
      final id = await catalog.download(details);
      expect(id, isNotNull);
      final saved = await db.bookById(id!);
      expect(saved!.format, 'txt');
      expect(await catalog.watchDownloaded().first, {book.id: id});
      expect(catalog.downloads.value, isEmpty);
    });

    test('скачивание аудиокниги: главы по порядку, обложка, название из каталога', () async {
      final client = MockClient((r) async {
        final name = r.url.pathSegments.last;
        if (name.endsWith('.mp3')) {
          return http.Response.bytes(mp3(frames: [id3Text('TPE1', 'Jules Verne')], audioBytes: 4000 + name.length), 200);
        }
        if (name.endsWith('.jpg')) return http.Response.bytes(List.filled(100, 1), 200);
        return http.Response('', 404);
      });
      final library = BookLibrary(db: db, dataDirectory: () async => dir, lookupCovers: false);
      final catalog = BookCatalog(db: db, library: library, client: client, passwords: MemoryCatalogPasswords());
      final book = LibriVoxSource.parseSearch(jsonEncode(searchJson)).first;
      final details = LibriVoxSource.parseMetadata(book, jsonEncode(metadataJson));
      final id = await catalog.download(details);
      final saved = await db.bookById(id!);
      expect(saved!.title, 'Twenty Thousand Leagues Under the Sea');
      expect(saved.author, 'Jules Verne');
      final folder = Directory(saved.path!);
      final names = folder.listSync().map((e) => e.uri.pathSegments.last).toList()..sort();
      expect(names, ['01 leagues_01_verne_64kb.mp3', '02 leagues_02_verne_64kb.mp3', 'cover.jpg']);
    });

    test('отмена скачивания убирает файлы', () async {
      late BookCatalog catalog;
      final client = MockClient.streaming((r, _) async {
        catalog.cancel('lv:twenty_thousand_leagues_librivox');
        return http.StreamedResponse(Stream.fromIterable([List.filled(1000, 0), List.filled(1000, 0)]), 200);
      });
      final library = BookLibrary(db: db, dataDirectory: () async => dir, lookupCovers: false);
      catalog = BookCatalog(db: db, library: library, client: client, passwords: MemoryCatalogPasswords());
      final book = LibriVoxSource.parseSearch(jsonEncode(searchJson)).first;
      final details = LibriVoxSource.parseMetadata(book, jsonEncode(metadataJson));
      expect(await catalog.download(details), isNull);
      final audiobooks = Directory('${dir.path}/audiobooks');
      expect(audiobooks.existsSync() ? audiobooks.listSync() : const [], isEmpty);
      expect(catalog.downloads.value, isEmpty);
    });
  });

  test('настройки каталога: разбор и запись', () {
    const config = CatalogConfig(librivox: false, opds: [OpdsCatalog(id: 'a', name: 'A', url: 'https://a.example', password: 'x')]);
    final back = CatalogConfig.decode(config.encode());
    expect(back.librivox, isFalse);
    expect(back.opds.single.url, 'https://a.example');
    expect(back.opds.single.password, isNull);
    expect(CatalogConfig.decode('мусор').enabled, isTrue);
    expect(CatalogLanguage.ru.matches(null, title: 'Война и мир'), isTrue);
    expect(CatalogLanguage.ru.matches(null, title: 'War and Peace'), isFalse);
    expect(bookGenres.firstWhere((g) => g.id == 'children').matchesTitle('Детективы'), isFalse);
    expect(bookGenres.firstWhere((g) => g.id == 'detective').matchesTitle('Детективы'), isTrue);
  });
}
