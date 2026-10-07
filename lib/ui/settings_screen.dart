import 'package:flutter/material.dart';

import '../catalog/podcast_catalog.dart';
import '../data/db/database.dart';
import '../sync/sync_service.dart';
import 'app_scope.dart';
import 'diagnostics_dialog.dart';
import 'episode_actions.dart';
import 'format.dart';
import 'sync_screen.dart';
import 'icons.dart';
import 'theme.dart';

/// Версия для экрана настроек; совпадает с pubspec.yaml.
const appVersion = '0.8.0';

/// Настройки. Полный набор разделов появится позже; сейчас — синхронизация,
/// тема и служебное.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final scope = AppScope.of(context);
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: EdgeInsets.fromLTRB(20, 16, 20, MediaQuery.paddingOf(context).bottom + 16),
          children: [
            Text('Настройки', style: screenTitleStyle(context)),
            const SizedBox(height: 16),
            if (scope.sync != null) const _SyncCard(),
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
            if (scope.catalog != null) ...[
              const _SectionTitle('ПОИСК'),
              _Card(children: [_CountryRow(catalog: scope.catalog!)]),
            ],
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
            ]),
            const _SectionTitle('ПРИЛОЖЕНИЕ'),
            _Card(children: [
              _Row(
                label: 'Диагностика',
                hint: 'Состояние плеера и уведомлений',
                onTap: () => showDiagnosticsDialog(context),
                trailing: BcIcon(BcIcons.chevronRight, size: 20, color: c.muted),
              ),
              _Row(label: 'Версия', trailing: Text(appVersion, style: TextStyle(color: c.muted))),
            ]),
            Padding(
              padding: const EdgeInsets.only(top: 24),
              child: Text('Basic Caster · bcaster.ru',
                  textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: c.muted)),
            ),
          ],
        ),
      ),
    );
  }
}

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
  const _SwitchRow({required this.label, required this.settingKey, this.hint});

  final String label;
  final String? hint;
  final String settingKey;

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
          onTap: () => db.setSetting(settingKey, '${!on}'),
          trailing: Switch(value: on, onChanged: (v) => db.setSetting(settingKey, '$v')),
        );
      },
    );
  }
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
        return PopupMenuButton<SwipeAction>(
          tooltip: label,
          initialValue: value,
          onSelected: (a) => db.setSetting(settingKey, a.name),
          itemBuilder: (_) => [
            for (final a in SwipeAction.values) PopupMenuItem(value: a, child: Text(a.label)),
          ],
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
        return PopupMenuButton<String>(
          tooltip: 'Регион каталога',
          initialValue: saved,
          onSelected: (code) async {
            await db.setSetting(CatalogSettings.country, code);
            catalog.setCountry(code.isEmpty ? null : code);
          },
          itemBuilder: (_) => [
            PopupMenuItem(value: '', child: Text('Как в системе ($system)')),
            for (final e in catalogCountries.entries) PopupMenuItem(value: e.key, child: Text(e.value)),
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
