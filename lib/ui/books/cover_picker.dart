/// «Найти обложку»: варианты из Google Books и Open Library, выбор одной.
library;

import 'package:flutter/material.dart';

import '../../books/book_library.dart';
import '../../books/book_metadata.dart';
import '../../data/db/database.dart';
import '../../platform/books_platform.dart';
import '../icons.dart';
import '../theme.dart';

Future<void> showCoverPicker(BuildContext context, {required BookLibrary library, required Book book}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      useRootNavigator: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.8,
        maxChildSize: 0.95,
        builder: (context, controller) => _CoverPicker(library: library, book: book, controller: controller),
      ),
    );

class _CoverPicker extends StatefulWidget {
  const _CoverPicker({required this.library, required this.book, required this.controller});

  final BookLibrary library;
  final Book book;
  final ScrollController controller;

  @override
  State<_CoverPicker> createState() => _CoverPickerState();
}

class _CoverPickerState extends State<_CoverPicker> {
  late final _query = TextEditingController(
      text: [widget.book.title, if (widget.book.author != null) widget.book.author!].join(' '));
  late Future<List<CoverCandidate>> _found = widget.library.findCovers(widget.book);
  String? _saving;

  void _search() {
    final q = _query.text.trim();
    if (q.isEmpty) return;
    setState(() => _found = widget.library.findCovers(widget.book, query: q));
  }

  Future<void> _pick(CoverCandidate c) async {
    setState(() => _saving = c.imageUrl);
    final ok = await widget.library.setCoverFrom(widget.book, c).catchError((_) => false);
    if (!mounted) return;
    setState(() => _saving = null);
    if (ok) {
      Navigator.pop(context);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Не удалось скачать эту обложку. Выберите другую.')));
    }
  }

  Future<void> _own() async {
    final file = await pickImage();
    if (file == null || !mounted) return;
    setState(() => _saving = file);
    final ok = await widget.library.setCoverFromFile(widget.book, file).catchError((_) => false);
    if (!mounted) return;
    setState(() => _saving = null);
    if (ok) {
      Navigator.pop(context);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Это не картинка. Подойдут JPG, PNG или WebP.')));
    }
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = BcColors.of(context);
    return CustomScrollView(controller: widget.controller, slivers: [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Center(
              child: Container(
                width: 40,
                height: 5,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(color: c.line, borderRadius: BorderRadius.circular(3)),
              ),
            ),
            Row(children: [
              Expanded(
                child: Text('Обложка', style: TextStyle(fontFamily: displayFont, fontWeight: FontWeight.w600, fontSize: 19, color: c.text)),
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(shape: const StadiumBorder()),
                onPressed: _saving == null ? _own : null,
                icon: const Icon(Icons.image_outlined, size: 18),
                label: const Text('Своя картинка'),
              ),
            ]),
            const SizedBox(height: 12),
            TextField(
              controller: _query,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
              decoration: InputDecoration(
                hintText: 'Название и автор',
                filled: true,
                fillColor: c.raised,
                prefixIcon: Padding(padding: const EdgeInsets.all(12), child: BcIcon(BcIcons.search, size: 20, color: c.muted)),
                suffixIcon: IconButton(tooltip: 'Искать', onPressed: _search, icon: BcIcon(BcIcons.chevronRight, size: 20, color: c.text)),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide.none),
              ),
            ),
          ]),
        ),
      ),
      FutureBuilder<List<CoverCandidate>>(
        future: _found,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              sliver: SliverGrid.count(
                crossAxisCount: 3,
                childAspectRatio: 0.66,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                children: [
                  for (var i = 0; i < 6; i++)
                    DecoratedBox(decoration: BoxDecoration(color: c.raised, borderRadius: BorderRadius.circular(10))),
                ],
              ),
            );
          }
          final list = snap.data ?? const [];
          if (list.isEmpty) {
            return SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  snap.hasError
                      ? 'Каталоги не ответили. Проверьте интернет и попробуйте ещё раз.'
                      : 'Ничего не нашлось. Попробуйте написать название иначе — например, без номера тома или только фамилию автора.',
                  style: TextStyle(color: c.muted, height: 1.4),
                ),
              ),
            );
          }
          return SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 160,
                childAspectRatio: 0.52,
                mainAxisSpacing: 14,
                crossAxisSpacing: 12,
              ),
              delegate: SliverChildBuilderDelegate(childCount: list.length, (context, i) {
                final cand = list[i];
                final saving = _saving == cand.imageUrl;
                return InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: _saving == null ? () => _pick(cand) : null,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    AspectRatio(
                      aspectRatio: 0.68,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Stack(fit: StackFit.expand, children: [
                          ColoredBox(color: c.raised),
                          Image.network(
                            cand.imageUrl,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => Center(child: BcIcon(BcIcons.book, color: c.muted)),
                          ),
                          if (saving) const ColoredBox(color: Color(0x88000000)),
                          if (saving)
                            const Center(child: SizedBox(width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 2.5))),
                        ]),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(cand.title ?? '', maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, height: 1.25, color: c.text)),
                    Text([cand.source, if (cand.year != null) '${cand.year}'].join(' · '),
                        maxLines: 1, style: TextStyle(fontSize: 11, color: c.muted)),
                  ]),
                );
              }),
            ),
          );
        },
      ),
    ]);
  }
}
