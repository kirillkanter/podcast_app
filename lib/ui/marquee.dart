import 'package:flutter/material.dart';

/// Бегущая строка для плееров: если текст не помещается и [running],
/// он медленно прокручивается по кругу с паузой в начале. Когда [running]
/// снимается (пауза), строка плавно возвращается к началу и стоит
/// с многоточием. Помещается — обычный текст. С отключёнными анимациями
/// в системе — тоже обычный текст.
class Marquee extends StatefulWidget {
  const Marquee({
    super.key,
    required this.text,
    required this.style,
    required this.running,
    this.gap = 48,
    this.velocity = 32,
    this.pause = const Duration(milliseconds: 1800),
  });

  final String text;
  final TextStyle style;
  final bool running;

  /// Расстояние между концом строки и её началом на следующем круге.
  final double gap;

  /// Скорость, пикселей в секунду.
  final double velocity;

  /// Пауза в начале каждого круга: успеть прочитать начало.
  final Duration pause;

  @override
  State<Marquee> createState() => _MarqueeState();
}

class _MarqueeState extends State<Marquee> with SingleTickerProviderStateMixin {
  late final AnimationController _scroll = AnimationController(vsync: this);
  double _textWidth = 0;
  double _boxWidth = 0;
  int _cycle = 0;
  bool _moving = false;

  bool get _overflows => _textWidth > _boxWidth + 0.5;

  @override
  void didUpdateWidget(Marquee old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) {
      _cycle++;
      _scroll.value = 0;
      _moving = false;
    }
    if (old.running != widget.running || old.text != widget.text) _update();
  }

  @override
  void dispose() {
    _cycle++;
    _scroll.dispose();
    super.dispose();
  }

  void _update() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final animate = widget.running && _overflows && !MediaQuery.disableAnimationsOf(context);
      if (animate && !_moving) {
        _loop();
      } else if (!animate && _moving) {
        _stop();
      }
    });
  }

  Future<void> _loop() async {
    final cycle = ++_cycle;
    setState(() => _moving = true);
    while (mounted && cycle == _cycle) {
      await Future<void>.delayed(widget.pause);
      if (!mounted || cycle != _cycle) return;
      final distance = _textWidth + widget.gap;
      _scroll.duration = Duration(milliseconds: (distance / widget.velocity * 1000).round());
      try {
        await _scroll.forward(from: 0).orCancel;
      } on TickerCanceled {
        return;
      }
      if (!mounted || cycle != _cycle) return;
      // Второй экземпляр строки встал на место первого — незаметно в начало.
      _scroll.value = 0;
    }
  }

  Future<void> _stop() async {
    _cycle++;
    _scroll.stop();
    if (_scroll.value > 0) {
      try {
        await _scroll.animateBack(0, duration: const Duration(milliseconds: 450), curve: Curves.easeOutCubic).orCancel;
      } on TickerCanceled {
        // Виджет убран или строка поменялась.
      }
    }
    if (mounted) setState(() => _moving = false);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      // Тот же стиль, что получит Text (шрифт темы + свой стиль), иначе
      // ширина посчитается для другого шрифта.
      final painter = TextPainter(
        text: TextSpan(text: widget.text, style: DefaultTextStyle.of(context).style.merge(widget.style)),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        textHeightBehavior: DefaultTextStyle.of(context).textHeightBehavior,
        maxLines: 1,
      )..layout();
      final changed = painter.width != _textWidth || box.maxWidth != _boxWidth;
      _textWidth = painter.width;
      _boxWidth = box.maxWidth;
      if (changed) _update();

      final plain = Text(widget.text, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis, style: widget.style);
      if (!_overflows || !_moving) return plain;

      final line = Text(widget.text, maxLines: 1, softWrap: false, style: widget.style);
      final strip = Row(mainAxisSize: MainAxisSize.min, children: [line, SizedBox(width: widget.gap), line]);
      // Размер задаёт тот же неподвижный текст (невидимый), что и на паузе:
      // высота строки не меняется, когда она начинает или перестаёт бежать.
      return Stack(children: [
        Visibility(
          visible: false,
          maintainSize: true,
          maintainAnimation: true,
          maintainState: true,
          child: SizedBox(width: box.maxWidth, child: plain),
        ),
        Positioned.fill(
        child: AnimatedBuilder(
          animation: _scroll,
          child: strip,
          builder: (context, child) {
            // Края растворяются, чтобы текст не обрывался резко; слева —
            // только когда строка уже поехала, иначе съест первую букву.
            final left = _scroll.value > 0 ? 0.04 : 0.0;
            return ShaderMask(
              shaderCallback: (rect) => LinearGradient(
                colors: const [Colors.transparent, Colors.black, Colors.black, Colors.transparent],
                stops: [0, left, 0.92, 1],
              ).createShader(rect),
              blendMode: BlendMode.dstIn,
              child: ClipRect(
                child: OverflowBox(
                  alignment: Alignment.centerLeft,
                  minWidth: 0,
                  maxWidth: double.infinity,
                  child: Transform.translate(
                    offset: Offset(-_scroll.value * (_textWidth + widget.gap), 0),
                    child: child,
                  ),
                ),
              ),
            );
          },
        ),
        ),
      ]);
    });
  }
}
