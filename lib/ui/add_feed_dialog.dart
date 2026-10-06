import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/podcast_repository.dart';
import 'app_scope.dart';

/// Диалог «Добавить подкаст по ссылке». Возвращает id добавленного подкаста
/// или `null`, если пользователь закрыл диалог.
Future<int?> showAddFeedDialog(BuildContext context) =>
    showDialog<int>(context: context, builder: (_) => const AddFeedDialog());

class AddFeedDialog extends StatefulWidget {
  const AddFeedDialog({super.key});

  @override
  State<AddFeedDialog> createState() => _AddFeedDialogState();
}

class _AddFeedDialogState extends State<AddFeedDialog> {
  final _controller = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty || !mounted) return;
    _controller.text = text;
    _controller.selection = TextSelection.collapsed(offset: text.length);
  }

  Future<void> _submit() async {
    final input = _controller.text.trim();
    if (input.isEmpty || _loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final repository = AppScope.of(context).repository;
    try {
      final id = await repository.addAndSubscribe(input);
      if (mounted) Navigator.of(context).pop(id);
    } on PodcastException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Неожиданная ошибка: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Добавить подкаст'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const Key('feedUrlField'),
              controller: _controller,
              autofocus: true,
              enabled: !_loading,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: 'Ссылка на RSS или Apple Podcasts',
                hintText: 'https://example.com/feed.xml',
                errorText: _error,
                errorMaxLines: 4,
                suffixIcon: IconButton(
                  tooltip: 'Вставить',
                  icon: const Icon(Icons.content_paste),
                  onPressed: _loading ? null : _paste,
                ),
              ),
            ),
            if (_loading) ...[
              const SizedBox(height: 16),
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              const Text('Загружаю фид…'),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _loading ? null : () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
        FilledButton(
          key: const Key('addFeedButton'),
          onPressed: _loading ? null : _submit,
          child: const Text('Добавить'),
        ),
      ],
    );
  }
}
