import 'package:flutter/material.dart';

import '../platform/open_url.dart';
import '../sync/gpodder_client.dart';
import '../sync/sync_service.dart';
import 'app_scope.dart';

/// Вход в аккаунт синхронизации и её состояние.
class SyncScreen extends StatefulWidget {
  const SyncScreen({super.key});

  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> {
  final _server = TextEditingController(text: SyncSettings.defaultServer);
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _showServer = false;
  String? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    AppScope.of(context).db.setting(SyncSettings.server).then((s) {
      if (s != null && s.isNotEmpty && mounted) _server.text = s;
    });
  }

  @override
  void dispose() {
    _server.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    final sync = AppScope.of(context).sync!;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await sync.signIn(server: _server.text, username: _username.text, password: _password.text);
      _password.clear();
      await sync.syncNow();
    } on SyncException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Ошибка: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _syncNow() async {
    final scope = AppScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final r = await scope.sync!.syncNow();
      if (r.subscriptionsAdded > 0) await scope.downloads?.autoDownloadAll();
      final parts = [
        if (r.subscriptionsAdded > 0) 'новых подписок: ${r.subscriptionsAdded}',
        if (r.subscriptionsRemoved > 0) 'отписок: ${r.subscriptionsRemoved}',
        if (r.episodesUpdated > 0) 'обновлено эпизодов: ${r.episodesUpdated}',
        if (r.stateUpdated > 0) 'изменений очереди и архива: ${r.stateUpdated}',
        if (r.feedErrors.isNotEmpty) 'не загрузились фиды: ${r.feedErrors.length}',
      ];
      messenger.showSnackBar(SnackBar(
        content: Text(parts.isEmpty ? 'Всё синхронизировано' : 'Готово: ${parts.join(', ')}'),
      ));
    } on SyncException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _register() async {
    final url = '${GpodderClient.normalizeServer(_server.text)}/register.php';
    final ok = await openUrl(url);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Откройте в браузере: $url')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final db = scope.db;
    return Scaffold(
      appBar: AppBar(title: const Text('Синхронизация')),
      body: StreamBuilder<String?>(
        stream: db.watchSetting(SyncSettings.username),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final username = snapshot.data;
          return username == null || username.isEmpty ? _signInForm(context) : _status(context, username);
        },
      ),
    );
  }

  Widget _signInForm(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          'Войдите в аккаунт, чтобы подписки, позиции и отметки «прослушано» '
          'совпадали на телефоне и компьютере.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _username,
          enabled: !_busy,
          autocorrect: false,
          decoration: const InputDecoration(labelText: 'Логин', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _password,
          enabled: !_busy,
          obscureText: true,
          onSubmitted: (_) => _signIn(),
          decoration: const InputDecoration(labelText: 'Пароль', border: OutlineInputBorder()),
        ),
        if (_showServer) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _server,
            enabled: !_busy,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(labelText: 'Сервер', border: OutlineInputBorder()),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
        ],
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _busy ? null : _signIn,
          child: _busy
              ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Войти'),
        ),
        const SizedBox(height: 8),
        OutlinedButton(onPressed: _busy ? null : _register, child: const Text('Создать аккаунт')),
        const SizedBox(height: 8),
        Text(
          'Регистрация откроется в браузере. После неё вернитесь сюда и войдите.',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          textAlign: TextAlign.center,
        ),
        if (!_showServer)
          TextButton(
            onPressed: () => setState(() => _showServer = true),
            child: const Text('Другой сервер'),
          ),
      ],
    );
  }

  Widget _status(BuildContext context, String username) {
    final scope = AppScope.of(context);
    final db = scope.db;
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        StreamBuilder<String?>(
          stream: db.watchSetting(SyncSettings.server),
          builder: (context, s) => ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.account_circle_outlined),
            title: Text(username),
            subtitle: Text(s.data ?? ''),
          ),
        ),
        StreamBuilder<String?>(
          stream: db.watchSetting(SyncSettings.lastSync),
          builder: (context, s) {
            final last = DateTime.tryParse(s.data ?? '');
            return ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.sync),
              title: const Text('Последняя синхронизация'),
              subtitle: Text(last == null ? 'ещё не было' : _formatTime(last)),
            );
          },
        ),
        StreamBuilder<String?>(
          stream: db.watchSetting(SyncSettings.lastError),
          builder: (context, s) {
            final error = s.data;
            if (error == null || error.isEmpty) return const SizedBox.shrink();
            return Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(error, style: TextStyle(color: theme.colorScheme.onErrorContainer)),
            );
          },
        ),
        StreamBuilder<String?>(
          stream: db.watchSetting(SyncSettings.stateUnsupported),
          builder: (context, s) {
            if (s.data != 'true') return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                'Сервер не синхронизирует очередь и архив: на нём нет файла bcaster.php. '
                'Подписки и прогресс синхронизируются как обычно.',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            );
          },
        ),
        ValueListenableBuilder<bool>(
          valueListenable: scope.sync!.syncing,
          builder: (context, syncing, _) => FilledButton.icon(
            onPressed: syncing ? null : _syncNow,
            icon: syncing
                ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.sync),
            label: Text(syncing ? 'Синхронизация…' : 'Синхронизировать сейчас'),
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: () async {
            await scope.sync!.signOut();
          },
          child: const Text('Выйти'),
        ),
        const SizedBox(height: 16),
        Text(
          'Синхронизация идёт сама: при запуске, при сворачивании приложения, '
          'после паузы, при изменении очереди и раз в 10 минут. '
          'Подкасты, прогресс и очередь на устройстве после выхода сохраняются.',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }

  static String _formatTime(DateTime t) {
    final local = t.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(local.day)}.${two(local.month)}.${local.year} ${two(local.hour)}:${two(local.minute)}';
  }
}
