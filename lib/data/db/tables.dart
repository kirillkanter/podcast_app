/// Схема локальной БД.
///
/// Метаданные (подкасты, эпизоды) — кэш фидов, их всегда можно перечитать.
/// Пользовательское состояние (подписки, позиции, очередь, настройки)
/// синхронизируется между устройствами: у таких таблиц есть `updatedAt`
/// и флаг `dirty` — «изменено локально, ещё не отправлено на сервер».
/// Удаление в синхронизируемых таблицах — мягкое (флаг), иначе его
/// нельзя передать на другие устройства.
library;

import 'package:drift/drift.dart';

import '../../feed/models.dart';

// ---------------------------------------------------------------------------
// Кэш фидов
// ---------------------------------------------------------------------------

@DataClassName('Podcast')
class Podcasts extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// Текущий адрес фида. Меняется при переезде (`itunes:new-feed-url`, 301).
  TextColumn get feedUrl => text().unique()();
  TextColumn get title => text()();
  TextColumn get description => text().nullable()();
  TextColumn get link => text().nullable()();
  TextColumn get imageUrl => text().nullable()();
  TextColumn get author => text().nullable()();
  TextColumn get language => text().nullable()();

  /// Категории через перевод строки.
  TextColumn get categories => text().withDefault(const Constant(''))();
  BoolColumn get explicit => boolean().nullable()();
  TextColumn get podcastType =>
      textEnum<PodcastType>().withDefault(Constant(PodcastType.episodic.name))();
  TextColumn get podcastGuid => text().nullable()();

  // Служебные поля обновления фида.
  TextColumn get etag => text().nullable()();
  TextColumn get lastModified => text().nullable()();
  DateTimeColumn get lastCheckedAt => dateTime().nullable()();
  DateTimeColumn get lastSuccessAt => dateTime().nullable()();
  TextColumn get lastError => text().nullable()();

  DateTimeColumn get createdAt => dateTime().clientDefault(DateTime.now)();
}

@DataClassName('Episode')
@TableIndex(name: 'episodes_by_podcast_date', columns: {#podcastId, #pubDate})
class Episodes extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get podcastId => integer().references(Podcasts, #id, onDelete: KeyAction.cascade)();

  /// Стабильный ключ из `episode_identity.dart`. Уникален в пределах подкаста.
  TextColumn get episodeKey => text()();
  TextColumn get guid => text().nullable()();
  TextColumn get title => text()();
  TextColumn get description => text().nullable()();
  TextColumn get summary => text().nullable()();
  TextColumn get link => text().nullable()();
  DateTimeColumn get pubDate => dateTime().nullable()();

  TextColumn get enclosureUrl => text()();
  TextColumn get enclosureType => text().nullable()();
  IntColumn get enclosureLength => integer().nullable()();

  IntColumn get durationMs => integer().nullable()();
  TextColumn get imageUrl => text().nullable()();
  IntColumn get season => integer().nullable()();
  IntColumn get episodeNumber => integer().nullable()();
  TextColumn get episodeType =>
      textEnum<EpisodeType>().withDefault(Constant(EpisodeType.full.name))();
  BoolColumn get explicit => boolean().nullable()();
  TextColumn get chaptersUrl => text().nullable()();
  TextColumn get chaptersType => text().nullable()();

  /// Когда эпизод впервые появился в локальной БД — для «новых эпизодов».
  DateTimeColumn get firstSeenAt => dateTime().clientDefault(DateTime.now)();

  @override
  List<Set<Column>> get uniqueKeys => [
        {podcastId, episodeKey},
      ];
}

@DataClassName('EpisodeTranscript')
class EpisodeTranscripts extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get episodeId => integer().references(Episodes, #id, onDelete: KeyAction.cascade)();
  TextColumn get url => text()();
  TextColumn get mimeType => text().nullable()();
  TextColumn get language => text().nullable()();
  TextColumn get rel => text().nullable()();

  @override
  List<Set<Column>> get uniqueKeys => [
        {episodeId, url},
      ];
}

// ---------------------------------------------------------------------------
// Синхронизируемое состояние
// ---------------------------------------------------------------------------

@DataClassName('Subscription')
class Subscriptions extends Table {
  IntColumn get podcastId => integer().references(Podcasts, #id, onDelete: KeyAction.cascade)();

  /// `false` — отписка (мягкое удаление).
  BoolColumn get subscribed => boolean().withDefault(const Constant(true))();
  DateTimeColumn get updatedAt => dateTime().clientDefault(DateTime.now)();
  BoolColumn get dirty => boolean().withDefault(const Constant(true))();

  @override
  Set<Column> get primaryKey => {podcastId};
}

@DataClassName('EpisodeState')
class EpisodeStates extends Table {
  IntColumn get episodeId => integer().references(Episodes, #id, onDelete: KeyAction.cascade)();
  IntColumn get positionMs => integer().withDefault(const Constant(0))();
  BoolColumn get played => boolean().withDefault(const Constant(false))();
  DateTimeColumn get playedAt => dateTime().nullable()();
  DateTimeColumn get updatedAt => dateTime().clientDefault(DateTime.now)();
  BoolColumn get dirty => boolean().withDefault(const Constant(true))();

  @override
  Set<Column> get primaryKey => {episodeId};
}

@DataClassName('PodcastSetting')
class PodcastSettings extends Table {
  IntColumn get podcastId => integer().references(Podcasts, #id, onDelete: KeyAction.cascade)();

  /// `null` — использовать глобальную настройку.
  RealColumn get playbackSpeed => real().nullable()();
  IntColumn get skipIntroSec => integer().withDefault(const Constant(0))();
  IntColumn get skipOutroSec => integer().withDefault(const Constant(0))();

  /// Сколько последних эпизодов держать загруженными; `null` — глобально, 0 — выкл.
  IntColumn get autoDownloadCount => integer().nullable()();
  BoolColumn get notifyNewEpisodes => boolean().withDefault(const Constant(true))();
  DateTimeColumn get updatedAt => dateTime().clientDefault(DateTime.now)();
  BoolColumn get dirty => boolean().withDefault(const Constant(true))();

  @override
  Set<Column> get primaryKey => {podcastId};
}

@DataClassName('QueueEntry')
class QueueEntries extends Table {
  IntColumn get episodeId => integer().references(Episodes, #id, onDelete: KeyAction.cascade)();

  /// Дробный порядок: вставка между двумя элементами не требует
  /// перенумерации всей очереди.
  RealColumn get sortOrder => real()();
  BoolColumn get removed => boolean().withDefault(const Constant(false))();
  DateTimeColumn get updatedAt => dateTime().clientDefault(DateTime.now)();
  BoolColumn get dirty => boolean().withDefault(const Constant(true))();

  @override
  Set<Column> get primaryKey => {episodeId};
}

/// Архив: эпизод скрыт из списков. `archived = false` — возвращён из архива
/// (строка остаётся, чтобы передать это на другие устройства).
@DataClassName('EpisodeArchive')
class EpisodeArchives extends Table {
  IntColumn get episodeId => integer().references(Episodes, #id, onDelete: KeyAction.cascade)();
  BoolColumn get archived => boolean().withDefault(const Constant(true))();
  DateTimeColumn get updatedAt => dateTime().clientDefault(DateTime.now)();
  BoolColumn get dirty => boolean().withDefault(const Constant(true))();

  @override
  Set<Column> get primaryKey => {episodeId};
}

// ---------------------------------------------------------------------------
// Только локально
// ---------------------------------------------------------------------------

/// Состояние загрузки эпизода.
/// - queued — ждёт очереди (или Wi-Fi для автозагрузки);
/// - running — качается;
/// - completed — файл на устройстве;
/// - failed — ошибка, см. `error`;
/// - removed — пользователь удалил файл: автозагрузка не скачает его снова.
enum DownloadStatus { queued, running, completed, failed, removed }

@DataClassName('Download')
class Downloads extends Table {
  IntColumn get episodeId => integer().references(Episodes, #id, onDelete: KeyAction.cascade)();
  TextColumn get status => textEnum<DownloadStatus>()();

  /// Загрузка поставлена автоматически, а не пользователем.
  BoolColumn get auto => boolean().withDefault(const Constant(false))();
  TextColumn get filePath => text().nullable()();
  IntColumn get totalBytes => integer().nullable()();
  IntColumn get receivedBytes => integer().withDefault(const Constant(0))();
  TextColumn get error => text().nullable()();
  DateTimeColumn get updatedAt => dateTime().clientDefault(DateTime.now)();

  @override
  Set<Column> get primaryKey => {episodeId};
}

/// Настройки приложения: ключ → значение (строкой).
@DataClassName('AppSetting')
class AppSettings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

// ---------------------------------------------------------------------------
// Книги: аудиокниги и текстовые. Отдельно от подкастов — свои таблицы,
// своя синхронизация (books.php на сервере).
// ---------------------------------------------------------------------------

enum BookKind { audio, text }

/// Полка: слушаю/читаю, отложено, готово.
enum BookShelf { reading, later, done }

@DataClassName('Book')
class Books extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// Ключ для синхронизации, одинаковый на всех устройствах:
  /// «a:…» — отпечаток аудиокниги (имена и размеры файлов),
  /// «t:…» — sha1 файла текстовой книги.
  TextColumn get key => text().unique()();
  TextColumn get kind => textEnum<BookKind>()();
  TextColumn get title => text()();
  TextColumn get author => text().nullable()();
  TextColumn get narrator => text().nullable()();
  TextColumn get description => text().nullable()();
  TextColumn get language => text().nullable()();

  /// mp3, m4b, epub, fb2, fbz, txt.
  TextColumn get format => text()();

  /// Аудиокнига — папка или файл; текстовая — файл в папке приложения
  /// (`null` — книга есть только на сервере, ещё не скачана).
  TextColumn get path => text().nullable()();

  /// Папка-источник, из которой найдена аудиокнига; `null` — добавлена файлом.
  TextColumn get sourceRoot => text().nullable()();
  TextColumn get coverPath => text().nullable()();
  IntColumn get sizeBytes => integer().withDefault(const Constant(0))();

  /// Длительность аудиокниги.
  IntColumn get durationMs => integer().nullable()();
  TextColumn get shelf => textEnum<BookShelf>().withDefault(Constant(BookShelf.reading.name))();

  /// Скорость этой книги; `null` — общая.
  RealColumn get speed => real().nullable()();

  /// Файлы аудиокниги не нашлись при последней проверке папки.
  BoolColumn get missing => boolean().withDefault(const Constant(false))();

  /// Текстовая книга загружена на сервер.
  BoolColumn get uploaded => boolean().withDefault(const Constant(false))();

  /// Удалена здесь, удаление ещё не дошло до сервера.
  BoolColumn get deletePending => boolean().withDefault(const Constant(false))();
  DateTimeColumn get addedAt => dateTime().clientDefault(DateTime.now)();
  DateTimeColumn get openedAt => dateTime().nullable()();
}

/// Файлы аудиокниги по порядку.
@DataClassName('BookTrack')
class BookTracks extends Table {
  IntColumn get bookId => integer().references(Books, #id, onDelete: KeyAction.cascade)();
  IntColumn get idx => integer()();
  TextColumn get path => text()();
  IntColumn get durationMs => integer().withDefault(const Constant(0))();
  TextColumn get title => text().nullable()();

  @override
  Set<Column> get primaryKey => {bookId, idx};
}

/// Главы аудиокниги: начало — файл и место в нём.
@DataClassName('BookChapter')
class BookChapters extends Table {
  IntColumn get bookId => integer().references(Books, #id, onDelete: KeyAction.cascade)();
  IntColumn get idx => integer()();
  TextColumn get title => text()();
  IntColumn get trackIdx => integer()();
  IntColumn get startMs => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {bookId, idx};
}

/// Место в книге. [locator] — точное место (`t<файл>:<мс>` в аудио,
/// `c<глава>:b<абзац>:o<символ>` в тексте), [percent] — доля книги.
@DataClassName('BookProgress')
class BookProgresses extends Table {
  IntColumn get bookId => integer().references(Books, #id, onDelete: KeyAction.cascade)();
  TextColumn get locator => text()();

  /// Аудио: место от начала книги.
  IntColumn get positionMs => integer().withDefault(const Constant(0))();
  RealColumn get percent => real().withDefault(const Constant(0))();
  DateTimeColumn get updatedAt => dateTime().clientDefault(DateTime.now)();
  BoolColumn get dirty => boolean().withDefault(const Constant(true))();

  /// Устройство, с которого пришло место (если с другого).
  TextColumn get device => text().nullable()();

  @override
  Set<Column> get primaryKey => {bookId};
}

@DataClassName('BookBookmark')
class BookBookmarks extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get bookId => integer().references(Books, #id, onDelete: KeyAction.cascade)();
  TextColumn get locator => text()();
  IntColumn get positionMs => integer().nullable()();

  /// Глава и время, или начало абзаца — чтобы узнать закладку в списке.
  TextColumn get label => text()();
  DateTimeColumn get createdAt => dateTime().clientDefault(DateTime.now)();
}

/// Папки с аудиокнигами: каждая подпапка — отдельная книга.
@DataClassName('BookSource')
class BookSources extends Table {
  TextColumn get path => text()();
  DateTimeColumn get addedAt => dateTime().clientDefault(DateTime.now)();

  @override
  Set<Column> get primaryKey => {path};
}
