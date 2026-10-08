import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:podcast_app/books/book_models.dart';
import 'package:podcast_app/books/translator.dart';
import 'package:podcast_app/data/db/books_dao.dart';
import 'package:podcast_app/data/db/database.dart';

ScannedAudioBook _audio(String key, {String root = '/a'}) => ScannedAudioBook(
      key: key,
      title: 'Книга $key',
      path: '$root/$key',
      format: 'mp3',
      tracks: const [ScannedTrack(path: '/x/1.mp3', durationMs: 1000, sizeBytes: 10)],
      chapters: const [ScannedChapter(title: 'Глава', trackIdx: 0, startMs: 0)],
    );

void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('аудиокнига: повторная проверка папки обновляет книгу, место сохраняется', () async {
    final id = await db.saveAudioBook(_audio('a:1'), sourceRoot: '/a');
    await db.saveBookProgress(id, locator: 't0:500', positionMs: 500, percent: 0.5);
    final again = await db.saveAudioBook(_audio('a:1'), sourceRoot: '/a');
    expect(again, id);
    expect((await db.bookProgress(id))?.locator, 't0:500');
    expect(await db.tracksOfBook(id), hasLength(1));

    await db.saveAudioBook(_audio('a:2'), sourceRoot: '/a');
    await db.markMissingBooks('/a', {'a:2'});
    expect((await db.bookById(id))!.missing, isTrue);
    expect((await db.bookByKey('a:2'))!.missing, isFalse);
  });

  test('место с другого устройства: более новое применяется, старое — нет', () async {
    final id = await db.saveAudioBook(_audio('a:1'));
    final now = DateTime.now();
    await db.saveBookProgress(id, locator: 't0:100', percent: 0.1, at: now);
    expect(
      await db.applyRemoteBookProgress(id,
          locator: 't0:50', positionMs: 50, percent: 0.05, changed: now.subtract(const Duration(minutes: 1))),
      isFalse,
    );
    expect(
      await db.applyRemoteBookProgress(id,
          locator: 't0:900', positionMs: 900, percent: 0.9, changed: now.add(const Duration(minutes: 1)), device: 'A'),
      isTrue,
    );
    final p = await db.bookProgress(id);
    expect(p?.locator, 't0:900');
    expect(p?.dirty, isFalse, reason: 'пришедшее с сервера обратно не отправляется');
    expect(p?.device, 'A');
    // Человек выбрал «продолжить оттуда» — применяется и старое.
    await db.applyRemoteBookProgress(id,
        locator: 't0:10', positionMs: 10, percent: 0.01, changed: now.subtract(const Duration(days: 1)), force: true);
    expect((await db.bookProgress(id))?.locator, 't0:10');
  });

  test('отложенная книга возвращается «в процесс», когда её начинают', () async {
    final id = await db.saveAudioBook(_audio('a:1'));
    await db.setBookShelf(id, BookShelf.later);
    await db.saveBookProgress(id, locator: 't0:1', percent: 0.01);
    expect((await db.bookById(id))!.shelf, BookShelf.reading);
  });

  test('текстовые книги: на загрузку и на скачивание; удаление ждёт сервера', () async {
    final local = await db.saveTextBook(
      const TextBookInfo(key: 't:1', title: 'Здесь', format: 'fb2', sizeBytes: 5),
      path: '/books/1.fb2',
    );
    final remote = await db.saveTextBook(const TextBookInfo(key: 't:2', title: 'Там', format: 'epub', sizeBytes: 5), uploaded: true);
    expect((await db.textBooksToUpload()).map((b) => b.id), [local]);
    expect((await db.textBooksToDownload()).map((b) => b.id), [remote]);
    await db.markBookDeletePending(local);
    expect((await db.watchBooks().first).map((i) => i.book.id), [remote], reason: 'удалённая скрыта сразу');
    expect((await db.pendingBookDeletes()).map((b) => b.id), [local]);
  });

  test('отправленное место снимает отметку, только если с тех пор не менялось', () async {
    final id = await db.saveAudioBook(_audio('a:1'));
    final t = DateTime.now();
    await db.saveBookProgress(id, locator: 't0:1', percent: 0.1, at: t);
    final dirty = await db.dirtyBookProgress();
    expect(dirty.single.key, 'a:1');
    await db.saveBookProgress(id, locator: 't0:2', percent: 0.2, at: t.add(const Duration(seconds: 1)));
    await db.markBookProgressSynced(id, dirty.single.updatedAt);
    expect((await db.bookProgress(id))!.dirty, isTrue);
  });

  group('перевод и словарь', () {
    test('MyMemory: перевод и исчерпанный лимит', () async {
      final ok = Translator(client: MockClient((r) async {
        expect(r.url.queryParameters['langpair'], 'en|ru');
        return http.Response.bytes(
            utf8.encode(jsonEncode({'responseStatus': 200, 'responseData': {'translatedText': 'Привет, мир'}})), 200);
      }));
      expect(await ok.translate('Hello, world', from: 'en', to: 'ru'), 'Привет, мир');

      final limit = Translator(client: MockClient((r) async => http.Response(
          jsonEncode({'responseStatus': 429, 'responseDetails': 'MYMEMORY WARNING: YOU USED ALL AVAILABLE FREE TRANSLATIONS FOR TODAY'}),
          200)));
      expect(limit.translate('x', from: 'en', to: 'ru'),
          throwsA(isA<TranslatorException>().having((e) => e.message, 'message', contains('лимит'))));
    });

    test('английский Викисловарь: значения слова', () async {
      final t = Translator(client: MockClient((r) async {
        // Сначала слово как есть, потом в нижнем регистре.
        if (r.url.path != '/api/rest_v1/page/definition/run') return http.Response('', 404);
        return http.Response(
          jsonEncode({
            'en': [
              {
                'partOfSpeech': 'Verb',
                'definitions': [
                  {'definition': 'To move <b>swiftly</b>.', 'examples': ['<i>He runs</i>']},
                  {'definition': ''},
                ],
              },
            ],
          }),
          200,
        );
      }));
      final senses = await t.define('Run,', lang: 'en');
      expect(senses.single.definition, 'To move swiftly.');
      expect(senses.single.partOfSpeech, 'Verb');
      expect(senses.single.example, 'He runs');
    });

    test('русский Викисловарь: раздел «Значение» без разметки', () {
      const wiki = '''
= {{-ru-}} =
=== Морфологические и синтаксические свойства ===
{{сущ ru f ina 1a}}
==== Значение ====
# {{помета|устар.}} [[жилище|жилое]] помещение {{пример|Дом стоял у реки.|Автор}}
# [[семья]], [[люди]], живущие вместе
#: не значение
==== Синонимы ====
# [[здание]]
= {{-en-}} =
==== Значение ====
# English
''';
      final senses = parseRuWiktionary(wiki);
      expect(senses.map((s) => s.definition), ['устар. жилое помещение', 'семья, люди, живущие вместе']);
      expect(senses.first.example, 'Дом стоял у реки.');
    });

    test('язык текста по буквам', () {
      expect(guessLanguage('Привет, как дела?'), 'ru');
      expect(guessLanguage('It was a dark night'), 'en');
      expect(baseLanguage('en-US'), 'en');
    });
  });
}
