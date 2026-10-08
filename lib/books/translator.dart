/// Перевод и словарь для читалки.
///
/// Перевод — MyMemory (бесплатно, без ключа, до ~5000 символов в день),
/// значения слов на языке оригинала — Викисловарь: для английского
/// и большинства языков — английский Викисловарь (REST API), для русского —
/// русский Викисловарь (раздел «Значение»).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:http/http.dart' as http;

import '../ui/format.dart' show htmlToText;

class TranslatorException implements Exception {
  const TranslatorException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Значение слова из словаря.
class WordSense {
  const WordSense({required this.definition, this.partOfSpeech, this.example});

  final String definition;
  final String? partOfSpeech;
  final String? example;
}

/// Язык текста по буквам: кириллица → ru, иначе en.
String guessLanguage(String text) {
  final letters = text.runes.where((r) => (r >= 0x41 && r <= 0x5A) || (r >= 0x61 && r <= 0x7A) || (r >= 0x400 && r <= 0x4FF));
  if (letters.isEmpty) return 'en';
  final cyr = letters.where((r) => r >= 0x400).length;
  return cyr * 2 >= letters.length ? 'ru' : 'en';
}

/// «en-US» → «en».
String baseLanguage(String? code) => (code ?? '').split(RegExp('[-_]')).first.toLowerCase();

class Translator {
  Translator({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  static const _agent = 'BasicCaster/0.9 (+https://bcaster.ru)';
  static const _timeout = Duration(seconds: 12);

  Future<Object?> _getJson(Uri uri) async {
    final http.Response r;
    try {
      r = await _client.get(uri, headers: {'user-agent': _agent, 'accept': 'application/json'}).timeout(_timeout);
    } on TimeoutException {
      throw const TranslatorException('Сервис не ответил вовремя.');
    } on SocketException {
      throw const TranslatorException('Нет соединения с интернетом.');
    } on http.ClientException catch (e) {
      throw TranslatorException('Ошибка соединения: ${e.message}');
    }
    if (r.statusCode == 404) return null;
    if (r.statusCode != 200) throw TranslatorException('Сервис вернул ошибку (код ${r.statusCode}).');
    try {
      return jsonDecode(utf8.decode(r.bodyBytes));
    } on FormatException {
      throw const TranslatorException('Сервис вернул некорректный ответ.');
    }
  }

  /// Перевести [text] с языка [from] на [to].
  Future<String> translate(String text, {required String from, required String to}) async {
    // MyMemory принимает до 500 байт за запрос.
    var q = text.trim();
    while (utf8.encode(q).length > 480) {
      q = q.substring(0, (q.length * 0.9).floor());
    }
    final data = await _getJson(Uri.https('api.mymemory.translated.net', '/get', {'q': q, 'langpair': '$from|$to'}));
    if (data is! Map) throw const TranslatorException('Перевод не получен.');
    final status = data['responseStatus'];
    final response = data['responseData'];
    final translated = response is Map ? response['translatedText'] : null;
    if ('$status' != '200' || translated is! String || translated.isEmpty) {
      final details = data['responseDetails'] is String ? data['responseDetails'] as String : '';
      if (details.toUpperCase().contains('USED ALL AVAILABLE FREE TRANSLATIONS')) {
        throw const TranslatorException('Дневной лимит бесплатного перевода исчерпан. Попробуйте завтра.');
      }
      throw TranslatorException(details.isEmpty ? 'Перевод не получен.' : details);
    }
    return htmlToText(translated);
  }

  /// Значения слова [word] на языке [lang] (пустой список — не нашлось).
  Future<List<WordSense>> define(String word, {required String lang}) async {
    final w = word.trim().replaceAll(RegExp(r'''^[^\p{L}]+|[^\p{L}'-]+$''', unicode: true), '');
    if (w.isEmpty) return const [];
    for (final candidate in {w, w.toLowerCase()}) {
      final senses = lang == 'ru' ? await _defineRu(candidate) : await _defineEn(candidate, lang);
      if (senses.isNotEmpty) return senses;
    }
    return const [];
  }

  Future<List<WordSense>> _defineEn(String word, String lang) async {
    final data = await _getJson(
      Uri.https('en.wiktionary.org', '/api/rest_v1/page/definition/${Uri.encodeComponent(word)}'),
    );
    if (data is! Map) return const [];
    final entries = data[lang] ?? data['en'];
    if (entries is! List) return const [];
    final out = <WordSense>[];
    for (final e in entries.whereType<Map>()) {
      final pos = e['partOfSpeech'] is String ? e['partOfSpeech'] as String : null;
      final defs = e['definitions'];
      if (defs is! List) continue;
      for (final d in defs.whereType<Map>()) {
        final text = d['definition'] is String ? htmlToText(d['definition'] as String) : '';
        if (text.isEmpty) continue;
        final examples = d['examples'];
        final example = examples is List && examples.isNotEmpty && examples.first is String
            ? htmlToText(examples.first as String)
            : null;
        out.add(WordSense(definition: text, partOfSpeech: pos, example: example));
        if (out.length >= 8) return out;
      }
    }
    return out;
  }

  Future<List<WordSense>> _defineRu(String word) async {
    final data = await _getJson(Uri.https('ru.wiktionary.org', '/w/api.php', {
      'action': 'parse',
      'page': word,
      'prop': 'wikitext',
      'format': 'json',
      'formatversion': '2',
      'redirects': '1',
    }));
    if (data is! Map) return const [];
    final parse = data['parse'];
    final wikitext = parse is Map ? parse['wikitext'] : null;
    if (wikitext is! String) return const [];
    return parseRuWiktionary(wikitext);
  }

  void close() => _client.close();
}

/// Значения из вики-разметки русского Викисловаря: строки «# …» в разделах
/// «Значение» (только русская статья, если на странице несколько языков).
List<WordSense> parseRuWiktionary(String wikitext) {
  // Только русская часть страницы: от «= {{-ru-}} =» до следующего языка.
  var text = wikitext;
  final ru = RegExp(r'^=\s*\{\{-ru-\}\}\s*=\s*$', multiLine: true).firstMatch(text);
  if (ru != null) {
    text = text.substring(ru.end);
    final next = RegExp(r'^=\s*\{\{-[a-z-]+-\}\}\s*=\s*$', multiLine: true).firstMatch(text);
    if (next != null) text = text.substring(0, next.start);
  }
  final out = <WordSense>[];
  final lines = text.split('\n');
  var inMeaning = false;
  for (final line in lines) {
    final heading = RegExp(r'^(=+)\s*(.+?)\s*=+\s*$').firstMatch(line);
    if (heading != null) {
      inMeaning = heading.group(2)!.toLowerCase().contains('значение');
      continue;
    }
    if (!inMeaning || !line.startsWith('#') || line.startsWith('#:') || line.startsWith('#*')) continue;
    final parts = line.substring(1).split(RegExp(r'\{\{пример\|'));
    final def = cleanWikitext(parts.first);
    if (def.isEmpty || def == '?' || def == '…') continue;
    String? example;
    if (parts.length > 1) {
      final ex = cleanWikitext(parts[1].split('|').first);
      if (ex.isNotEmpty) example = ex;
    }
    out.add(WordSense(definition: def, example: example));
    if (out.length >= 8) break;
  }
  return out;
}

/// Вики-разметка → текст: шаблоны убираются (кроме помет), ссылки
/// заменяются текстом.
String cleanWikitext(String s) {
  var t = s;
  // Пометы: {{помета|разг.}}, {{разг.|ru}} → «разг.».
  t = t.replaceAllMapped(RegExp(r'\{\{помета\|([^}|]+)[^}]*\}\}'), (m) => '${m.group(1)} ');
  t = t.replaceAllMapped(RegExp(r'\{\{(устар|разг|книжн|перен|прост|спец|ирон|неодобр|шутл|высок|поэт)\.?(\|[^}]*)?\}\}'),
      (m) => '${m.group(1)}. ');
  // Остальные шаблоны — убрать (несколько проходов для вложенных).
  for (var i = 0; i < 4; i++) {
    t = t.replaceAll(RegExp(r'\{\{[^{}]*\}\}'), '');
  }
  t = t.replaceAllMapped(RegExp(r'\[\[(?:[^\]|]*\|)?([^\]]+)\]\]'), (m) => m.group(1)!);
  t = t.replaceAll(RegExp(r"'{2,}"), '');
  t = t.replaceAll(RegExp(r'<ref[^>]*>.*?</ref>|<ref[^>]*/>', dotAll: true), '');
  t = htmlToText(t);
  return t.replaceAll(RegExp(r'\s+'), ' ').replaceAllMapped(RegExp(r'\s+([,.;:])'), (m) => m.group(1)!).trim();
}
