// Правит платформенные файлы после `flutter create`.
//
// Папки android/ и windows/ не хранятся в репозитории: их генерирует
// `flutter create` при сборке. Этот скрипт добавляет то, чего нет в шаблоне:
// - разрешение на интернет (в шаблоне оно есть только для отладочной сборки);
// - загрузку по http:// (Android 9+ по умолчанию разрешает только https,
//   а многие старые фиды и аудиофайлы до сих пор отдаются по http);
// - название приложения Basic Caster (Android и окно Windows);
// - фоновое воспроизведение через audio_service: разрешения, сервис,
//   приёмник медиа-кнопок и MainActivity на основе AudioServiceActivity
//   (tool/android/MainActivity.kt).
//
// Скрипт можно запускать повторно: уже внесённые правки не дублируются.
// Запуск: dart run tool/patch_platforms.dart
import 'dart:io';

const _permissions = [
  'android.permission.INTERNET',
  'android.permission.WAKE_LOCK',
  'android.permission.FOREGROUND_SERVICE',
  'android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK',
  'android.permission.POST_NOTIFICATIONS',
];

const _audioServiceComponents = '''
        <service android:name="com.ryanheise.audioservice.AudioService"
            android:foregroundServiceType="mediaPlayback"
            android:exported="true"
            tools:ignore="Instantiatable">
            <intent-filter>
                <action android:name="android.media.browse.MediaBrowserService" />
            </intent-filter>
        </service>

        <receiver android:name="com.ryanheise.audioservice.MediaButtonReceiver"
            android:exported="true"
            tools:ignore="Instantiatable">
            <intent-filter>
                <action android:name="android.intent.action.MEDIA_BUTTON" />
            </intent-filter>
        </receiver>
''';

void main() {
  _patchAndroid();
  _patchWindows();
}

const _windowsMarker = '# podcast_app: совместимость плагинов с новым MSVC';
const _windowsPatch = '''

$_windowsMarker
# Плагины на C++/WinRT (just_audio_windows, audio_service_win) собираются
# в C++17, где C++/WinRT подключает <experimental/coroutine>. MSVC 14.51+
# превращает это в ошибку STL1011; макрос возвращает прежнее поведение.
# Перевод плагинов на C++20 не подходит: их код не собирается в C++20.
foreach(plugin \${FLUTTER_PLUGIN_LIST})
  if(TARGET \${plugin}_plugin)
    target_compile_definitions(\${plugin}_plugin PRIVATE _SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS)
  endif()
endforeach()
''';

void _patchWindows() {
  final cmake = File('windows/CMakeLists.txt');
  if (!cmake.existsSync()) {
    stdout.writeln('Нет windows/ — пропускаю Windows.');
    return;
  }
  var text = cmake.readAsStringSync();
  // Имя exe-файла.
  text = text.replaceFirst(RegExp(r'set\(BINARY_NAME "[^"]*"\)'), 'set(BINARY_NAME "BasicCaster")');
  if (!text.contains(_windowsMarker)) text += _windowsPatch;
  cmake.writeAsStringSync(text);

  // Заголовок окна.
  final main = File('windows/runner/main.cpp');
  if (main.existsSync()) {
    main.writeAsStringSync(
      main.readAsStringSync().replaceFirst(RegExp(r'window\.Create\(L"[^"]*"'), 'window.Create(L"Basic Caster"'),
    );
  }

  // Минимальный размер окна: иначе его можно сжать до одного заголовка.
  final window = File('windows/runner/win32_window.cpp');
  if (window.existsSync()) {
    var code = window.readAsStringSync();
    if (!code.contains('WM_GETMINMAXINFO')) {
      final at = code.indexOf(RegExp(r'switch \(message\) \{'));
      if (at < 0) throw StateError('win32_window.cpp: не найден обработчик сообщений окна');
      final end = code.indexOf('{', at) + 1;
      code = code.replaceRange(end, end, _minSizePatch);
      window.writeAsStringSync(code);
    }
  }

  // Название в свойствах файла и диспетчере задач.
  final rc = File('windows/runner/Runner.rc');
  if (rc.existsSync()) {
    var res = rc.readAsStringSync();
    for (final key in ['FileDescription', 'ProductName', 'InternalName']) {
      res = res.replaceFirst(RegExp('VALUE "$key", "[^"]*"'), 'VALUE "$key", "Basic Caster"');
    }
    res = res.replaceFirst(RegExp(r'VALUE "OriginalFilename", "[^"]*"'), 'VALUE "OriginalFilename", "BasicCaster.exe"');
    res = res.replaceFirst(RegExp(r'VALUE "CompanyName", "[^"]*"'), 'VALUE "CompanyName", "bcaster.ru"');
    res = res.replaceFirst(RegExp(r'VALUE "LegalCopyright", "[^"]*"'), 'VALUE "LegalCopyright", "Basic Caster"');
    rc.writeAsStringSync(res);
  }

  // Иконка приложения (exe, окно, панель задач).
  File('tool/windows/app_icon.ico').copySync('windows/runner/resources/app_icon.ico');
  stdout.writeln('Windows: название, иконка и сборка обновлены.');
}

void _patchAndroid() {
  final manifest = File('android/app/src/main/AndroidManifest.xml');
  if (!manifest.existsSync()) {
    stdout.writeln('Нет android/ — пропускаю Android.');
    return;
  }

  var xml = manifest.readAsStringSync();

  if (!xml.contains('xmlns:tools=')) {
    xml = xml.replaceFirst('<manifest ', '<manifest xmlns:tools="http://schemas.android.com/tools" ');
  }

  for (final permission in _permissions) {
    if (!xml.contains('"$permission"')) {
      xml = xml.replaceFirst(
        '<application',
        '<uses-permission android:name="$permission"/>\n    <application',
      );
    }
  }

  if (!xml.contains('usesCleartextTraffic')) {
    xml = xml.replaceFirst('<application', '<application\n        android:usesCleartextTraffic="true"');
  }

  xml = xml.replaceFirst(RegExp(r'android:label="[^"]*"'), 'android:label="Basic Caster"');

  // MainActivity заменяется своей (наследник AudioServiceActivity), см. ниже.

  if (!xml.contains('com.ryanheise.audioservice.AudioService"')) {
    xml = xml.replaceFirst('</application>', '$_audioServiceComponents    </application>');
  }

  manifest.writeAsStringSync(xml);
  stdout.writeln('AndroidManifest.xml обновлён.');

  // Своя MainActivity: наследник AudioServiceActivity (требование audio_service)
  // с каналом для разрешения на уведомления.
  final generated = Directory('android/app/src/main')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('MainActivity.kt') || f.path.endsWith('MainActivity.java'))
      .toList();
  if (generated.length != 1) {
    stderr.writeln('Ожидалась одна MainActivity, найдено: ${generated.length}');
    exitCode = 1;
    return;
  }
  final target = File(generated.single.path.replaceFirst(RegExp(r'\.java$'), '.kt'));
  if (generated.single.path != target.path) generated.single.deleteSync();
  File('tool/android/MainActivity.kt').copySync(target.path);
  stdout.writeln('MainActivity заменена: ${target.path}');

  _patchGradle();

  // Иконки audio_service не должны удаляться при сжатии ресурсов.
  Directory('android/app/src/main/res/raw').createSync(recursive: true);
  File('tool/android/keep.xml').copySync('android/app/src/main/res/raw/keep.xml');

  // Иконки Basic Caster: значок приложения (обычный и адаптивный) и значок
  // уведомления. Файлы из tool/android/res поверх сгенерированных flutter create.
  _copyTree(Directory('tool/android/res'), 'android/app/src/main/res');
  stdout.writeln('Иконки Android скопированы.');
}

/// Идентификатор приложения и постоянный ключ подписи release-сборки.
/// Ключ берётся из переменных окружения (в CI — из секретов репозитория);
/// без них сборка подписывается отладочным ключом, как раньше.
void _patchGradle() {
  final gradle = File('android/app/build.gradle.kts');
  if (!gradle.existsSync()) {
    stderr.writeln('Не найден android/app/build.gradle.kts');
    exitCode = 1;
    return;
  }
  var text = gradle.readAsStringSync();
  text = text.replaceFirst(RegExp(r'applicationId = "[^"]*"'), 'applicationId = "$androidApplicationId"');
  const debugSigning = 'signingConfig = signingConfigs.getByName("debug")';
  if (!text.contains('BCASTER_KEYSTORE')) {
    if (!text.contains(debugSigning) || !text.contains('    buildTypes {')) {
      stderr.writeln('build.gradle.kts: не найдено место для настройки подписи');
      exitCode = 1;
      return;
    }
    text = text.replaceFirst('    buildTypes {', _signingConfig);
    text = text.replaceFirst(
      debugSigning,
      'signingConfig = signingConfigs.getByName(if (System.getenv("BCASTER_KEYSTORE") != null) "release" else "debug")',
    );
  }
  gradle.writeAsStringSync(text);
  stdout.writeln('build.gradle.kts: applicationId $androidApplicationId, подпись настроена.');
}

const androidApplicationId = 'ru.bcaster.app';

const _signingConfig = '''    signingConfigs {
        create("release") {
            val keystore = System.getenv("BCASTER_KEYSTORE")
            if (keystore != null) {
                storeFile = file(keystore)
                storePassword = System.getenv("BCASTER_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("BCASTER_KEY_ALIAS")
                keyPassword = System.getenv("BCASTER_KEYSTORE_PASSWORD")
            }
        }
    }

    buildTypes {''';

void _copyTree(Directory from, String to) {
  for (final f in from.listSync(recursive: true).whereType<File>()) {
    final rel = f.path.substring(from.path.length + 1);
    final dest = File('$to/$rel');
    dest.parent.createSync(recursive: true);
    f.copySync(dest.path);
  }
}

/// Минимум 400×600 (в точках с учётом масштаба экрана).
const _minSizePatch = '''
    case WM_GETMINMAXINFO: {
      // Basic Caster: минимальный размер окна.
      auto info = reinterpret_cast<MINMAXINFO*>(lparam);
      const double scale =
          FlutterDesktopGetDpiForMonitor(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST)) / 96.0;
      info->ptMinTrackSize.x = static_cast<LONG>(400 * scale);
      info->ptMinTrackSize.y = static_cast<LONG>(600 * scale);
      return 0;
    }''';
