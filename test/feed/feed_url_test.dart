import 'package:flutter_test/flutter_test.dart';
import 'package:podcast_app/feed/feed_url.dart';

String? direct(String input) => switch (parseFeedInput(input)) {
      DirectFeedUrl(:final url) => url.toString(),
      _ => null,
    };

void main() {
  test('обычная ссылка', () {
    expect(direct('https://example.com/feed.xml'), 'https://example.com/feed.xml');
    expect(direct('  http://example.com/rss  '), 'http://example.com/rss');
  });

  test('без схемы добавляется https', () {
    expect(direct('example.com/feed'), 'https://example.com/feed');
  });

  test('схемы подкаст-приложений', () {
    expect(direct('feed://example.com/rss'), 'https://example.com/rss');
    expect(direct('itpc://example.com/rss'), 'https://example.com/rss');
    expect(direct('pcast://example.com/rss'), 'https://example.com/rss');
    expect(direct('podcast://example.com/rss'), 'https://example.com/rss');
    expect(direct('feed:https://example.com/rss'), 'https://example.com/rss');
  });

  test('логин и пароль в ссылке сохраняются', () {
    expect(direct('https://user:pass@example.com/rss'), 'https://user:pass@example.com/rss');
  });

  test('ссылки Apple Podcasts', () {
    final a = parseFeedInput('https://podcasts.apple.com/ru/podcast/name/id1234567890?i=1000');
    expect(a, isA<ApplePodcastsLink>().having((l) => l.id, 'id', '1234567890'));
    final b = parseFeedInput('https://itunes.apple.com/us/podcast/id987');
    expect(b, isA<ApplePodcastsLink>().having((l) => l.id, 'id', '987'));
  });

  test('не ссылки', () {
    expect(parseFeedInput(''), isNull);
    expect(parseFeedInput('просто текст'), isNull);
    expect(parseFeedInput('localhost'), isNull);
    expect(parseFeedInput('ftp://example.com/rss'), isNull);
    expect(parseFeedInput('mailto:a@example.com'), isNull);
  });
}
