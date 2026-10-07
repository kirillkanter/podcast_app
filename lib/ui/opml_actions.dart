import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../data/opml.dart';
import 'app_scope.dart';
import 'format.dart';
import 'theme.dart';

const _opmlTypes = XTypeGroup(label: 'OPML', extensions: ['opml', 'xml']);

/// Выбрать OPML-файл и подписаться на подкасты из него.
Future<void> importOpmlFromFile(BuildContext context) async {
  final scope = AppScope.of(context);
  final messenger = ScaffoldMessenger.of(context);
  // На Android у OPML нет устойчивого MIME-типа: фильтр спрятал бы файл.
  final file = await openFile(acceptedTypeGroups: Platform.isAndroid ? const [] : const [_opmlTypes]);
  if (file == null || !context.mounted) return;

  final List<OpmlEntry> entries;
  try {
    entries = parseOpml(await file.readAsString());
  } on FormatException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
    return;
  } catch (_) {
    messenger.showSnackBar(const SnackBar(content: Text('Не удалось прочитать файл.')));
    return;
  }
  if (entries.isEmpty) {
    messenger.showSnackBar(const SnackBar(content: Text('В файле нет подкастов.')));
    return;
  }
  final subscribed = {for (final p in await scope.db.subscribedPodcasts()) p.feedUrl};
  final fresh = entries.where((e) => !subscribed.contains(e.url)).length;
  if (!context.mounted) return;
  final added = await showDialog<int>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ImportDialog(entries: entries, fresh: fresh, scope: scope),
  );
  if ((added ?? 0) > 0) unawaited(scope.downloads?.autoDownloadAll());
}

/// Сохранить подписки в OPML: на компьютере — в выбранный файл,
/// на телефоне — через «Поделиться» (в Файлы, на Диск, в мессенджер).
Future<void> exportOpml(BuildContext context) async {
  final scope = AppScope.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final podcasts = await scope.db.subscribedPodcasts();
  if (podcasts.isEmpty) {
    messenger.showSnackBar(const SnackBar(content: Text('Подписок пока нет — сохранять нечего.')));
    return;
  }
  final text = buildOpml(podcasts);
  const name = 'basic-caster-subscriptions.opml';
  try {
    if (Platform.isAndroid || Platform.isIOS) {
      final dir = await getTemporaryDirectory();
      final file = File(p.join(dir.path, name));
      await file.writeAsString(text);
      await SharePlus.instance.share(ShareParams(
        files: [XFile(file.path, mimeType: 'text/x-opml', name: name)],
        subject: 'Подписки Basic Caster',
      ));
      return;
    }
    final location = await getSaveLocation(suggestedName: name, acceptedTypeGroups: const [_opmlTypes]);
    if (location == null) return;
    var path = location.path;
    if (p.extension(path).isEmpty) path = '$path.opml';
    await File(path).writeAsString(text);
    messenger.showSnackBar(SnackBar(
      content: Text('Сохранено ${podcasts.length} ${plural(podcasts.length, 'подкаст', 'подкаста', 'подкастов')}: $path'),
    ));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Не удалось сохранить файл: $e')));
  }
}

class _ImportDialog extends StatefulWidget {
  const _ImportDialog({required this.entries, required this.fresh, required this.scope});

  final List<OpmlEntry> entries;
  final int fresh;
  final AppScope scope;

  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

enum _Stage { confirm, running, done }

class _ImportDialogState extends State<_ImportDialog> {
  var _stage = _Stage.confirm;
  var _done = 0;
  var _cancelled = false;
  OpmlImportResult? _result;

  Future<void> _run() async {
    setState(() => _stage = _Stage.running);
    final result = await importOpml(
      widget.scope.db,
      widget.scope.repository,
      widget.entries,
      onProgress: (n) {
        if (mounted) setState(() => _done = n);
      },
      cancelled: () => _cancelled,
    );
    if (!mounted) return;
    setState(() {
      _result = result;
      _stage = _Stage.done;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    final total = widget.entries.length;
    switch (_stage) {
      case _Stage.confirm:
        final already = total - widget.fresh;
        return AlertDialog(
          title: const Text('Импорт подписок'),
          content: Text(widget.fresh == 0
              ? 'Все $total ${plural(total, 'подкаст', 'подкаста', 'подкастов')} из файла уже в подписках.'
              : 'В файле $total ${plural(total, 'подкаст', 'подкаста', 'подкастов')}. '
                  'Новых — ${widget.fresh}${already > 0 ? ', остальные уже в подписках' : ''}.'),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(0), child: const Text('Отмена')),
            if (widget.fresh > 0)
              FilledButton(onPressed: _run, child: Text('Подписаться на ${widget.fresh}')),
          ],
        );
      case _Stage.running:
        return AlertDialog(
          title: const Text('Импорт подписок'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Загружаются фиды: $_done из $total', style: TextStyle(color: c.muted)),
            const SizedBox(height: 12),
            ThinProgress(value: total == 0 ? 0 : _done / total, height: 6),
          ]),
          actions: [
            TextButton(
              onPressed: _cancelled ? null : () => setState(() => _cancelled = true),
              child: Text(_cancelled ? 'Останавливается…' : 'Остановить'),
            ),
          ],
        );
      case _Stage.done:
        final r = _result!;
        return AlertDialog(
          title: const Text('Импорт завершён'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420, maxHeight: 360),
            child: SingleChildScrollView(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text('Добавлено: ${r.added}'
                    '${r.already > 0 ? '\nУже были в подписках: ${r.already}' : ''}'
                    '${_cancelled && r.added + r.already + r.failed.length < total ? '\nИмпорт остановлен' : ''}'),
                if (r.failed.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text('Не удалось загрузить: ${r.failed.length}',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  for (final (e, message) in r.failed)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text('${e.title} — $message', style: TextStyle(fontSize: 13, color: c.muted)),
                    ),
                ],
              ]),
            ),
          ),
          actions: [
            FilledButton(onPressed: () => Navigator.of(context).pop(r.added), child: const Text('Готово')),
          ],
        );
    }
  }
}
