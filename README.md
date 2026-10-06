# podcast_app

Подкаст-плеер для Android и Windows на Flutter.

Готово: добавление подкаста по ссылке на RSS или Apple Podcasts, подписки,
список эпизодов, обновление фидов (ETag, редиректы, переезды фидов).

## Сборка

Каждый push собирается в GitHub Actions: тесты, APK для Android, программа для
Windows. Готовые файлы — во вкладке Actions, раздел Artifacts.

## Локальный запуск (Windows, PowerShell)

Нужны Flutter (stable, Dart 3.10+), Android Studio с Android SDK и Visual Studio
с компонентом «Desktop development with C++» (для сборки под Windows).
Проверка окружения: `flutter doctor`.

```powershell
cd podcast_app

# Дописывает платформенные папки android/ и windows/.
# Существующие файлы (pubspec.yaml, lib/, test/) не перезаписываются.
flutter create --platforms=android,windows --project-name podcast_app .

flutter pub get

# Генерирует lib/data/db/database.g.dart. Повторять после каждого изменения tables.dart.
dart run build_runner build --delete-conflicting-outputs

flutter test
flutter run -d windows
```

Если `flutter test` падает на тестах БД с ошибкой загрузки SQLite, проверьте,
что Flutter обновлён (`flutter upgrade`): пакет `sqlite3` 3.x собирает SQLite
через native assets и не требует `sqlite3.dll`.

## Структура

```
lib/
  feed/
    models.dart            результат разбора фида
    rss_parser.dart        RSS 2.0 + itunes, podcast (2.0), content, media, googleplay, dc
    feed_decoder.dart      байты → строка: BOM, encoding из декларации, charset, windows-1251
    date_parser.dart       pubDate: RFC 822 со всеми вариациями, русские месяцы, ISO-8601
    duration_parser.dart   itunes:duration: секунды, ЧЧ:ММ:СС, ISO-8601
    episode_identity.dart  стабильный ключ эпизода
  data/db/
    tables.dart            схема drift
    database.dart          AppDatabase: сохранение фида, позиции, подписки
test/
  fixtures/                full.xml (все расширения), messy.xml (кривой фид), cp1251.xml
```

## Ключевые решения

**Ключ эпизода** — `g:<guid>`, без guid — `u:<URL файла>`. От него зависит,
не потеряется ли позиция при обновлении фида и не появится ли дубль.
При повторе guid с другим файлом эпизод получает ключ по URL; полный повтор
(тот же guid и тот же файл) отбрасывается.

**Синхронизируемые таблицы** (`subscriptions`, `episode_states`,
`podcast_settings`, `queue_entries`) имеют `updatedAt` и `dirty`. Любое
локальное изменение ставит `dirty = true`; синхронизация (этап 6) отправит
такие строки и сбросит флаг. Удаление мягкое: `subscribed = false`,
`removed = true`.

**Эпизоды, пропавшие из фида, не удаляются**: многие фиды отдают только
последние N выпусков, а у старых может быть позиция или загрузка.

**Даты** хранятся как ISO-8601 текст (`build.yaml`), даты публикации — в UTC.

## Известные ограничения

- Atom и RSS 1.0 (RDF) не поддерживаются — парсер сообщает об этом явно.
- Из однобайтовых кодировок поддержаны windows-1251, windows-1252, ISO-8859-1.
  KOI8-R и другие декодируются как UTF-8 с предупреждением.
- Если guid повторяется, второй эпизод получает ключ по URL. Когда первый
  эпизод исчезнет из фида, второй при следующем обновлении получит ключ
  по guid и появится как новый. Случай редкий, решается на этапе обновления
  фидов сопоставлением по URL.

## Дальше

2. ~~Добавление RSS по ссылке, подписки, экран эпизодов.~~ Импорт/экспорт OPML.
3. Плеер: фон на Android, SMTC на Windows, скорость, сохранение позиции.
4. Загрузки.
5. Поиск через Podcast Index.
6. Синхронизация по gPodder API.
