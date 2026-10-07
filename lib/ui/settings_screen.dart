import 'dart:io' show Platform;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../catalog/podcast_catalog.dart';
import '../data/db/database.dart';
import '../download/download_manager.dart';
import '../platform/desktop.dart';
import '../sync/sync_service.dart';
import 'app_scope.dart';
import 'diagnostics_dialog.dart';
import 'episode_actions.dart';
import 'format.dart';
import 'opml_actions.dart';
import 'sync_screen.dart';
import 'icons.dart';
import 'theme.dart';
import 'menu.dart';

/// Версия для экрана настроек; совпадает с pubspec.yaml.
const appVersion = '0.8.0';

/// Настройки. На широком экране — в две колонки.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final scope = AppScope.of(context);
    final audio = scope.audio;
    final downloads = scope.downloads;

    final playback = [
      const _SectionTitle('ВОСПРОИЗВЕДЕНИЕ'),
      _Card(children: [
        _ChoiceRow(
          label: 'Скорость по умолчанию',
          hint: 'Для подкастов, где скорость не выбрана отдельно',
          settingKey: PlayerSettings.speed,
          fallback: '1.0',
          options: {for (final v in _speeds) v: '${v.replaceAll('.', ',')}×'},
        ),
        _ChoiceRow(
          label: 'Перемотка назад',
          settingKey: PlayerSettings.rewind,
          fallback: '${audio?.skipSteps.value.$1 ?? 10}',
          options: {for (final v in const [5, 10, 15, 30, 60]) '$v': '$v с'},
          onSelect: audio == null ? null : (v) => audio.setSkipSteps(int.parse(v), audio.skipSteps.value.$2),
        ),
        _ChoiceRow(
          label: 'Перемотка вперёд',
          settingKey: PlayerSettings.forward,
          fallback: '${audio?.skipSteps.value.$2 ?? 30}',
          options: {for (final v in const [10, 15, 30, 45, 60, 90]) '$v': '$v с'},
          onSelect: audio == null ? null : (v) => audio.setSkipSteps(audio.skipSteps.value.$1, int.parse(v)),
        ),
      ]),
    ];

    final queue = [
      const _SectionTitle('ОЧЕРЕДЬ И АРХИВ'),
      _Card(children: [
        _SwitchRow(
          label: 'Играть следующий из очереди',
          hint: 'Когда эпизод закончится',
          settingKey: QueueSettings.continuePlayback,
        ),
        _SwitchRow(
          label: 'Прерванный эпизод — первым в очередь',
          hint: 'Если переключиться на другой эпизод, не дослушав',
          settingKey: QueueSettings.requeueInterrupted,
        ),
        _SwitchRow(
          label: 'Прослушанные — в архив',
          hint: 'Эпизод скрывается из списков, когда дослушан до конца',
          settingKey: QueueSettings.autoArchive,
        ),
      ]),
    ];

    final gestures = [
      const _SectionTitle('ЖЕСТЫ В СПИСКЕ ЭПИЗОДОВ'),
      _Card(children: [
        _SwipeRow(
          label: 'Свайп влево',
          settingKey: QueueSettings.swipeLeft,
          fallback: SwipeSettingsScope.defaultLeft,
        ),
        _SwipeRow(
          label: 'Свайп вправо',
          settingKey: QueueSettings.swipeRight,
          fallback: SwipeSettingsScope.defaultRight,
        ),
      ]),
    ];

    final downloadSection = [
      if (downloads != null) ...[
        const _SectionTitle('ЗАГРУЗКИ'),
        _Card(children: [
          _ChoiceRow(
            label: 'Автозагрузка новых эпизодов',
            hint: 'Сколько последних эпизодов каждого подкаста держать на устройстве',
            settingKey: DownloadSettings.autoCount,
            fallback: '0',
            options: const {
              '0': 'Выключена',
              '1': 'Последний',
              '3': '3 последних',
              '5': '5 последних',
              '10': '10 последних',
            },
            onChanged: (_) async {
              await downloads.autoDownloadAll();
              downloads.resume();
            },
          ),
          _SwitchRow(
            label: 'Только по Wi‑Fi',
            hint: 'Автозагрузка ждёт Wi‑Fi; вручную можно загрузить в любой сети',
            settingKey: DownloadSettings.wifiOnly,
            onChanged: (_) => downloads.resume(),
          ),
          _SwitchRow(
            label: 'Удалять прослушанные',
            hint: 'Файл удаляется, когда эпизод дослушан или отмечен прослушанным',
            settingKey: DownloadSettings.deletePlayed,
          ),
          _ChoiceRow(
            label: 'Лимит места',
            hint: 'Автозагрузка останавливается, когда загрузки занимают больше',
            settingKey: DownloadSettings.limitMb,
            fallback: '0',
            options: const {
              '0': 'Без лимита',
              '1024': '1 ГБ',
              '2048': '2 ГБ',
              '5120': '5 ГБ',
              '10240': '10 ГБ',
              '20480': '20 ГБ',
            },
            onChanged: (_) async => downloads.resume(),
          ),
          if (Platform.isWindows) const _FolderRow(),
        ]),
      ],
    ];

    final subscriptions = [
      const _SectionTitle('ПОДПИСКИ'),
      _Card(children: [
        _Row(
          label: 'Импорт из OPML',
          hint: 'Перенести подписки из другого плеера',
          onTap: () => importOpmlFromFile(context),
          trailing: BcIcon(BcIcons.chevronRight, size: 20, color: c.muted),
        ),
        _Row(
          label: 'Экспорт в OPML',
          hint: Platform.isWindows ? 'Сохранить список подписок в файл' : 'Сохранить или отправить список подписок',
          onTap: () => exportOpml(context),
          trailing: BcIcon(BcIcons.chevronRight, size: 20, color: c.muted),
        ),
      ]),
    ];

    final search = [
      if (scope.catalog != null) ...[
        const _SectionTitle('ПОИСК'),
        _Card(children: [_CountryRow(catalog: scope.catalog!)]),
      ],
    ];

    final look = [
      const _SectionTitle('ОФОРМЛЕНИЕ'),
      _Card(children: [
        _Row(
          label: 'Тема',
          trailing: StreamBuilder<String?>(
            stream: scope.db.watchSetting(themeSettingKey),
            builder: (context, s) => _ThemePicker(
              value: themeModeFrom(s.data),
              onChanged: (mode) => scope.db.setSetting(themeSettingKey, mode.name),
            ),
          ),
        ),
        if (Platform.isAndroid)
          const _SwitchRow(
            label: 'Поворачивать экран',
            hint: 'Альбомная ориентация, когда телефон повёрнут набок',
            settingKey: rotateSettingKey,
          ),
      ]),
    ];

    final app = [
      const _SectionTitle('ПРИЛОЖЕНИЕ'),
      _Card(children: [
        if (Platform.isWindows) ...[
          const _AutostartRow(),
          const _SwitchRow(
            label: 'Сворачивать в трей при закрытии',
            hint: 'Крестик прячет окно, воспроизведение продолжается. Выход — из меню значка в трее',
            settingKey: DesktopSettings.tray,
          ),
        ],
        _Row(
          label: 'Диагностика',
          hint: 'Состояние плеера и уведомлений',
          onTap: () => showDiagnosticsDialog(context),
          trailing: BcIcon(BcIcons.chevronRight, size: 20, color: c.muted),
        ),
        _Row(label: 'Версия', trailing: Text(appVersion, style: TextStyle(color: c.muted))),
      ]),
    ];

    final footer = Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Text('Basic Caster · bcaster.ru',
          textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: c.muted)),
    );

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        bottom: false,
        child: LayoutBuilder(builder: (context, constraints) {
          final twoColumns = constraints.maxWidth >= 860;
          final side = twoColumns ? 32.0 : 20.0;
          final bottom = MediaQuery.paddingOf(context).bottom + 16;
          final title = Text('Настройки', style: screenTitleStyle(context));
          if (!twoColumns) {
            return ListView(
              key: const Key('settings-list'),
              padding: EdgeInsets.fromLTRB(side, 16, side, bottom),
              children: [
                title,
                const SizedBox(height: 16),
                if (scope.sync != null) const _SyncCard(),
                ...playback,
                ...queue,
                ...gestures,
                ...subscriptions,
                ...downloadSection,
                ...search,
                ...look,
                ...app,
                footer,
              ],
            );
          }
          return SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(side, 24, side, bottom),
            child: Align(
              alignment: Alignment.topLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1100),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  title,
                  const SizedBox(height: 16),
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        if (scope.sync != null) const _SyncCard(),
                        ...playback,
                        ...queue,
                        ...gestures,
                        ...subscriptions,
                      ]),
                    ),
                    const SizedBox(width: 24),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        ...downloadSection,
                        ...search,
                        ...look,
                        ...app,
                      ]),
                    ),
                  ]),
                  footer,
                ]),
              ),
            ),
          );
        }),
      ),
    );
  }
}

const _speeds = ['0.8', '0.9', '1.0', '1.1', '1.2', '1.25', '1.3', '1.5', '1.75', '2.0'];

class _SyncCard extends StatelessWidget {
  const _SyncCard();

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final db = AppScope.of(context).db;
    return Material(
      color: c.raised,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SyncScreen())),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(color: c.fill, shape: BoxShape.circle),
              child: Center(child: BcIcon(BcIcons.sync, size: 22, color: c.onFill)),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: StreamBuilder<String?>(
                stream: db.watchSetting(SyncSettings.username),
                builder: (context, user) => StreamBuilder<String?>(
                  stream: db.watchSetting(SyncSettings.lastSync),
                  builder: (context, last) {
                    final name = user.data;
                    final at = DateTime.tryParse(last.data ?? '');
                    final status = name == null || name.isEmpty
                        ? 'Не настроена — подписки и прогресс только на этом устройстве'
                        : at == null
                            ? name
                            : '$name · ${formatAgo(at)}';
                    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('Синхронизация', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text(status, style: TextStyle(fontSize: 13, color: c.muted)),
                    ]);
                  },
                ),
              ),
            ),
            BcIcon(BcIcons.chevronRight, size: 20, color: c.muted),
          ]),
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 22, 4, 8),
        child: Text(text,
            style: TextStyle(
                fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 0.3, color: BcColors.of(context).muted)),
      );
}

class _Card extends StatelessWidget {
  const _Card({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    return Material(
      color: c.card,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) Divider(height: 1, color: c.divider),
          children[i],
        ],
      ]),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, this.hint, this.trailing, this.onTap});

  final String label;
  final String? hint;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(label, style: const TextStyle(fontSize: 15)),
                if (hint != null) Text(hint!, style: TextStyle(fontSize: 12, color: c.muted)),
              ]),
            ),
            ?trailing,
          ]),
        ),
      ),
    );
  }
}

/// Переключатель настройки «да/нет»; по умолчанию включено.
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({required this.label, required this.settingKey, this.hint, this.onChanged});

  final String label;
  final String? hint;
  final String settingKey;
  final void Function(bool)? onChanged;

  Future<void> _set(AppDatabase db, bool value) async {
    await db.setSetting(settingKey, '$value');
    onChanged?.call(value);
  }

  @override
  Widget build(BuildContext context) {
    final db = AppScope.of(context).db;
    return StreamBuilder<String?>(
      stream: db.watchSetting(settingKey),
      builder: (context, s) {
        final on = s.data != 'false';
        return _Row(
          label: label,
          hint: hint,
          onTap: () => _set(db, !on),
          trailing: Switch(value: on, onChanged: (v) => _set(db, v)),
        );
      },
    );
  }
}

/// Выбор одного значения из списка.
class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({
    required this.label,
    required this.settingKey,
    required this.options,
    required this.fallback,
    this.hint,
    this.onSelect,
    this.onChanged,
  });

  final String label;
  final String? hint;
  final String settingKey;
  final Map<String, String> options;
  final String fallback;

  /// Своё сохранение вместо записи в настройку.
  final Future<void> Function(String value)? onSelect;

  /// Вызывается после записи.
  final Future<void> Function(String value)? onChanged;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final db = AppScope.of(context).db;
    return StreamBuilder<String?>(
      stream: db.watchSetting(settingKey),
      builder: (context, s) {
        final raw = s.data ?? fallback;
        // «1» и «1.0» — одно и то же значение.
        final value = options.containsKey(raw)
            ? raw
            : options.keys.firstWhere(
                (k) => double.tryParse(k) != null && double.tryParse(k) == double.tryParse(raw),
                orElse: () => fallback,
              );
        return BcMenu<String>(
          tooltip: label,
          alignEnd: true,
          selected: value,
          onSelected: (v) async {
            if (onSelect != null) {
              await onSelect!(v);
            } else {
              await db.setSetting(settingKey, v);
            }
            await onChanged?.call(v);
          },
          options: [for (final e in options.entries) MenuOption(e.key, e.value)],
          child: _Row(
            label: label,
            hint: hint,
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(options[value] ?? value, style: TextStyle(color: c.muted)),
              const SizedBox(width: 4),
              BcIcon(BcIcons.chevronDown, size: 16, color: c.muted),
            ]),
          ),
        );
      },
    );
  }
}

/// Папка для загрузок (Windows).
class _FolderRow extends StatelessWidget {
  const _FolderRow();

  Future<void> _pick(BuildContext context, String? current) async {
    final db = AppScope.of(context).db;
    final messenger = ScaffoldMessenger.of(context);
    final dir = await getDirectoryPath(
      initialDirectory: current == null || current.isEmpty ? null : current,
      confirmButtonText: 'Выбрать',
    );
    if (dir == null || dir == current) return;
    await db.setSetting(DownloadSettings.directory, dir);
    messenger.showSnackBar(const SnackBar(
      content: Text('Новые загрузки будут сохраняться в выбранную папку. Уже загруженные файлы остаются на месте.'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final db = AppScope.of(context).db;
    return StreamBuilder<String?>(
      stream: db.watchSetting(DownloadSettings.directory),
      builder: (context, s) {
        final custom = s.data;
        final hasCustom = custom != null && custom.isNotEmpty;
        return _Row(
          label: 'Папка для загрузок',
          hint: hasCustom ? custom : 'Папка приложения',
          onTap: () => _pick(context, custom),
          trailing: hasCustom
              ? RoundIconButton(
                  icon: BcIcons.close,
                  tooltip: 'Вернуть папку приложения',
                  size: 36,
                  iconSize: 16,
                  color: c.muted,
                  onPressed: () => db.setSetting(DownloadSettings.directory, ''),
                )
              : BcIcon(BcIcons.chevronRight, size: 20, color: c.muted),
        );
      },
    );
  }
}

/// Запуск вместе с Windows: состояние хранится в реестре, не в настройках.
class _AutostartRow extends StatefulWidget {
  const _AutostartRow();

  @override
  State<_AutostartRow> createState() => _AutostartRowState();
}

class _AutostartRowState extends State<_AutostartRow> {
  bool? _on;

  @override
  void initState() {
    super.initState();
    Autostart.isEnabled().then((v) {
      if (mounted) setState(() => _on = v);
    });
  }

  Future<void> _set(bool value) async {
    setState(() => _on = value);
    final ok = await Autostart.setEnabled(value);
    if (!mounted) return;
    if (!ok) {
      setState(() => _on = !value);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Не удалось изменить автозапуск')));
    }
  }

  @override
  Widget build(BuildContext context) => _Row(
        label: 'Запускать вместе с Windows',
        hint: 'Приложение стартует свёрнутым в трей',
        onTap: _on == null ? null : () => _set(!_on!),
        trailing: Switch(value: _on ?? false, onChanged: _on == null ? null : _set),
      );
}

/// Выбор действия для свайпа.
class _SwipeRow extends StatelessWidget {
  const _SwipeRow({required this.label, required this.settingKey, required this.fallback});

  final String label;
  final String settingKey;
  final SwipeAction fallback;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final db = AppScope.of(context).db;
    return StreamBuilder<String?>(
      stream: db.watchSetting(settingKey),
      builder: (context, s) {
        final value = SwipeAction.parse(s.data, fallback);
        return BcMenu<SwipeAction>(
          tooltip: label,
          alignEnd: true,
          selected: value,
          onSelected: (a) => db.setSetting(settingKey, a.name),
          options: [for (final a in SwipeAction.values) MenuOption(a, a.label)],
          child: _Row(
            label: label,
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(value.label, style: TextStyle(color: c.muted)),
              const SizedBox(width: 4),
              BcIcon(BcIcons.chevronDown, size: 16, color: c.muted),
            ]),
          ),
        );
      },
    );
  }
}

/// Регион каталога для экрана «Поиск».
class _CountryRow extends StatelessWidget {
  const _CountryRow({required this.catalog});

  final PodcastCatalog catalog;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final db = AppScope.of(context).db;
    return StreamBuilder<String?>(
      stream: db.watchSetting(CatalogSettings.country),
      builder: (context, s) {
        final saved = s.data ?? '';
        final system = catalogCountries[catalog.defaultCountry] ?? catalog.defaultCountry.toUpperCase();
        final label = saved.isEmpty ? 'Как в системе ($system)' : (catalogCountries[saved] ?? saved.toUpperCase());
        return BcMenu<String>(
          tooltip: 'Регион каталога',
          alignEnd: true,
          selected: saved,
          onSelected: (code) async {
            await db.setSetting(CatalogSettings.country, code);
            catalog.setCountry(code.isEmpty ? null : code);
          },
          options: [
            MenuOption('', 'Как в системе ($system)'),
            for (final e in catalogCountries.entries) MenuOption(e.key, e.value),
          ],
          child: _Row(
            label: 'Регион каталога',
            hint: 'Популярное и подборки на экране «Поиск»',
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              Flexible(child: Text(label, style: TextStyle(color: c.muted))),
              const SizedBox(width: 4),
              BcIcon(BcIcons.chevronDown, size: 16, color: c.muted),
            ]),
          ),
        );
      },
    );
  }
}

/// Выбор темы тремя кнопками.
class _ThemePicker extends StatelessWidget {
  const _ThemePicker({required this.value, required this.onChanged});

  final ThemeMode value;
  final ValueChanged<ThemeMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    const options = {ThemeMode.system: 'Системная', ThemeMode.light: 'Светлая', ThemeMode.dark: 'Тёмная'};
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: c.raised, borderRadius: BorderRadius.circular(12)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        for (final e in options.entries)
          Semantics(
            selected: e.key == value,
            button: true,
            child: GestureDetector(
              onTap: () => onChanged(e.key),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(
                  color: e.key == value ? c.bg : Colors.transparent,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Text(e.value,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: e.key == value ? c.text : c.muted,
                    )),
              ),
            ),
          ),
      ]),
    );
  }
}
