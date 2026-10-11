import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:relay_protocol/relay_protocol.dart';

import '../app/theme.dart';
import '../data/relay_data.dart';

/// Pane sizes the person dragged, kept in relayd per device (`ui.panes`).
class PaneSizes {
  PaneSizes(this._client) {
    ready = _load();
  }
  final RelayClient _client;
  final _sizes = <String, double>{};
  late final Future<void> ready;
  Timer? _save;

  Future<void> _load() async {
    try {
      final raw = await _client.call<String?>(M.uiGet, {'key': 'panes'});
      if (raw != null) {
        for (final e in (jsonDecode(raw) as Map).entries) {
          if (e.value is num) _sizes['${e.key}'] = (e.value as num).toDouble();
        }
      }
    } on Object catch (_) {
      // Nothing usable saved; defaults it is.
    }
  }

  double? operator [](String id) => _sizes[id];

  void set(String id, double? size) {
    if (size == null) {
      _sizes.remove(id);
    } else {
      _sizes[id] = size.roundToDouble();
    }
    _save?.cancel();
    _save = Timer(const Duration(milliseconds: 400), () {
      _client.call(M.uiSet, {'key': 'panes', 'value': jsonEncode(_sizes)}).catchError((Object _) => true);
    });
  }

  void dispose() => _save?.cancel();
}

final paneSizesProvider = Provider<PaneSizes>((ref) {
  final p = PaneSizes(ref.watch(clientProvider));
  ref.onDispose(p.dispose);
  return p;
});

/// Which pane has the dragged size; the other takes the rest.
enum SplitSide { first, second }

/// Two panes with a divider you can drag. The sized pane keeps between
/// [min] and (total − [keepOther]); double-click the divider to reset.
///
/// Dragging only relays out: [first] and [second] are the same widgets on
/// every frame, so an editor or terminal inside doesn't rebuild.
class ResizableSplit extends ConsumerStatefulWidget {
  const ResizableSplit({
    super.key,
    required this.id,
    required this.first,
    required this.second,
    this.axis = Axis.horizontal,
    this.sized = SplitSide.first,
    required this.initial,
    this.min = 120,
    this.keepOther = 200,
    this.dividerColor,
    this.collapsedTo,
  });

  /// Where the size is remembered, e.g. `code.terminal`.
  final String id;
  final Widget first, second;

  /// horizontal: side by side; vertical: one above the other.
  final Axis axis;
  final SplitSide sized;
  final double initial, min, keepOther;
  final Color? dividerColor;

  /// When set, the sized pane is held at this extent and can't be dragged
  /// (a folded panel). The tree stays the same, so nothing remounts.
  final double? collapsedTo;

  @override
  ConsumerState<ResizableSplit> createState() => _ResizableSplitState();
}

class _ResizableSplitState extends ConsumerState<ResizableSplit> {
  late final ValueNotifier<double> _size;
  final _active = ValueNotifier(false);
  bool _hover = false, _dragging = false;

  static const _grab = 8.0;

  @override
  void initState() {
    super.initState();
    final sizes = ref.read(paneSizesProvider);
    _size = ValueNotifier(sizes[widget.id] ?? widget.initial);
    // Saved sizes load once at start; pick them up if they come late.
    sizes.ready.then((_) {
      final saved = sizes[widget.id];
      if (mounted && saved != null && !_dragging) _size.value = saved;
    });
  }

  @override
  void dispose() {
    _size.dispose();
    _active.dispose();
    super.dispose();
  }

  double _clamp(double v, double total) {
    final max = total - widget.keepOther - 1;
    return v.clamp(widget.min, max < widget.min ? widget.min : max);
  }

  void _state({bool? hover, bool? dragging}) {
    _hover = hover ?? _hover;
    _dragging = dragging ?? _dragging;
    _active.value = _hover || _dragging;
  }

  @override
  Widget build(BuildContext context) {
    final horizontal = widget.axis == Axis.horizontal;
    final c = context.c;
    return LayoutBuilder(builder: (context, box) {
      final total = horizontal ? box.maxWidth : box.maxHeight;
      return ValueListenableBuilder<double>(
        valueListenable: _size,
        builder: (context, raw, _) {
          final collapsed = widget.collapsedTo != null;
          final size = collapsed ? widget.collapsedTo!.clamp(0.0, total - 1) : _clamp(raw, total);
          final firstSize = widget.sized == SplitSide.first ? size : total - size - 1;
          Widget pane(Widget child, double? extent) => extent == null
              ? Expanded(child: child)
              : SizedBox(width: horizontal ? extent : null, height: horizontal ? null : extent, child: child);
          final divider = ValueListenableBuilder<bool>(
            valueListenable: _active,
            builder: (context, active, _) => Container(
              width: horizontal ? 1 : null,
              height: horizontal ? null : 1,
              color: active ? c.accent : (widget.dividerColor ?? c.separator),
            ),
          );
          return Stack(fit: StackFit.expand, children: [
            Flex(direction: widget.axis, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              pane(widget.first, widget.sized == SplitSide.first ? size : null),
              divider,
              pane(widget.second, widget.sized == SplitSide.second ? size : null),
            ]),
            Positioned(
              left: horizontal ? firstSize - _grab / 2 + 0.5 : 0,
              right: horizontal ? null : 0,
              top: horizontal ? 0 : firstSize - _grab / 2 + 0.5,
              bottom: horizontal ? 0 : null,
              width: horizontal ? _grab : null,
              height: horizontal ? null : _grab,
              child: collapsed ? const SizedBox() : MouseRegion(
                cursor: horizontal ? SystemMouseCursors.resizeColumn : SystemMouseCursors.resizeRow,
                onEnter: (_) => _state(hover: true),
                onExit: (_) => _state(hover: false),
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  // Follow the pointer from where it went down, not from
                  // where the drag was recognised.
                  dragStartBehavior: DragStartBehavior.down,
                  onDoubleTap: () {
                    _size.value = widget.initial;
                    ref.read(paneSizesProvider).set(widget.id, null);
                  },
                  onPanStart: (_) {
                    _size.value = size;
                    _state(dragging: true);
                  },
                  onPanUpdate: (d) {
                    final delta = horizontal ? d.delta.dx : d.delta.dy;
                    _size.value = _clamp(_size.value + (widget.sized == SplitSide.first ? delta : -delta), total);
                  },
                  onPanEnd: (_) {
                    _state(dragging: false);
                    ref.read(paneSizesProvider).set(widget.id, _size.value);
                  },
                  onPanCancel: () => _state(dragging: false),
                ),
              ),
            ),
          ]);
        },
      );
    });
  }
}
