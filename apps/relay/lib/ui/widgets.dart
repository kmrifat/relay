import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:relay_core/relay_core.dart';

import '../app/nav_bar.dart';
import '../app/theme.dart';

/// Small text styles used everywhere.
extension Txt on BuildContext {
  TextStyle t(double size, {FontWeight w = FontWeight.w400, Color? color, String? family, double? height}) =>
      TextStyle(fontSize: size, fontWeight: w, color: color ?? c.text, fontFamily: family, height: height);
  TextStyle get label => t(11, w: FontWeight.w600, color: c.text3);
}

class Hairline extends StatelessWidget {
  const Hairline({super.key, this.vertical = false, this.color});
  final bool vertical;
  final Color? color;
  @override
  Widget build(BuildContext context) => Container(
    width: vertical ? 1 : null,
    height: vertical ? null : 1,
    color: color ?? context.c.inner,
  );
}

class Pill extends StatelessWidget {
  const Pill(this.text, {super.key, this.fg, this.bg, this.icon, this.mono = false, this.radius = 4});
  final String text;
  final Color? fg, bg;
  final IconData? icon;
  final bool mono;
  final double radius;
  @override
  Widget build(BuildContext context) {
    final f = fg ?? context.c.text2;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: bg ?? context.c.inner, borderRadius: BorderRadius.circular(radius)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[Icon(icon, size: 10, color: f), const SizedBox(width: 4)],
        Text(text, style: context.t(10, w: FontWeight.w600, color: f, family: mono ? mono_ : null)),
      ]),
    );
  }
}

const mono_ = mono;

class Dot extends StatelessWidget {
  const Dot(this.color, {super.key, this.size = 7});
  final Color color;
  final double size;
  @override
  Widget build(BuildContext context) =>
      Container(width: size, height: size, decoration: BoxDecoration(color: color, shape: BoxShape.circle));
}

/// The coloured letter tile for an agent (no brand logos).
class AgentTile extends StatelessWidget {
  const AgentTile({super.key, this.agent, this.agentId, this.size = 16});
  final AgentProfile? agent;
  final String? agentId;
  final double size;
  @override
  Widget build(BuildContext context) {
    final a = agent;
    final color = hexColor(a?.color, context.c.control);
    final letter = a?.letter ?? (agentId == null || agentId!.isEmpty ? '?' : agentId!.substring(0, 1).toUpperCase());
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(size * 0.27)),
      child: Text(letter, style: TextStyle(fontSize: size * 0.52, fontWeight: FontWeight.w700, color: Colors.white, height: 1)),
    );
  }
}

class Avatar extends StatelessWidget {
  const Avatar(this.name, {super.key, this.size = 16, this.color});
  final String name;
  final double size;
  final Color? color;
  @override
  Widget build(BuildContext context) {
    final parts = name.trim().split(RegExp(r'\s+'));
    final initials = parts.isEmpty || parts.first.isEmpty
        ? '?'
        : (parts.length > 1 ? parts[0][0] + parts[1][0] : parts[0].substring(0, parts[0].length > 1 ? 2 : 1)).toUpperCase();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color ?? context.c.accent, shape: BoxShape.circle),
      child: Text(initials, style: TextStyle(fontSize: size * 0.42, fontWeight: FontWeight.w700, color: Colors.white, height: 1)),
    );
  }
}

/// Mouse and keyboard in one: hover, click, and Tab focus with Space or
/// Enter to activate. [builder] gets whether it is hovered and whether it
/// shows keyboard focus (only after keyboard use, not after a click).
class Pressable extends StatefulWidget {
  const Pressable({super.key, required this.builder, this.onTap, this.onDoubleTap, this.onSecondaryTapDown, this.focusNode, this.opaque = true});
  final Widget Function(BuildContext context, bool hover, bool focus) builder;
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;
  final GestureTapDownCallback? onSecondaryTapDown;
  final FocusNode? focusNode;
  final bool opaque;
  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _hover = false, _focus = false;
  late final _actions = <Type, Action<Intent>>{
    ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
      widget.onTap?.call();
      return null;
    }),
  };

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    return FocusableActionDetector(
      enabled: enabled,
      focusNode: widget.focusNode,
      mouseCursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      actions: _actions,
      onShowHoverHighlight: (v) => setState(() => _hover = v),
      onShowFocusHighlight: (v) => setState(() => _focus = v),
      child: GestureDetector(
        behavior: widget.opaque ? HitTestBehavior.opaque : HitTestBehavior.deferToChild,
        onTap: widget.onTap,
        onDoubleTap: widget.onDoubleTap,
        onSecondaryTapDown: widget.onSecondaryTapDown,
        child: widget.builder(context, _hover && enabled, _focus && enabled),
      ),
    );
  }
}

/// The keyboard focus ring, drawn over a control without moving it.
BoxDecoration? focusRing(BuildContext context, bool focus, double radius) => focus
    ? BoxDecoration(border: Border.all(color: context.c.accentIcon, width: 2), borderRadius: BorderRadius.circular(radius))
    : null;

enum BtnKind { primary, secondary, plain, danger }

class Btn extends StatefulWidget {
  const Btn(this.label, {super.key, this.onTap, this.icon, this.kind = BtnKind.secondary, this.small = false, this.tooltip});
  final String label;
  final VoidCallback? onTap;
  final IconData? icon;
  final BtnKind kind;
  final bool small;
  final String? tooltip;
  @override
  State<Btn> createState() => _BtnState();
}

class _BtnState extends State<Btn> {
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final enabled = widget.onTap != null;
    final (bg, fg) = switch (widget.kind) {
      BtnKind.primary => (c.accent, Colors.white),
      BtnKind.secondary => (c.control, c.text),
      BtnKind.plain => (Colors.transparent, c.accentIcon),
      BtnKind.danger => (c.control, c.danger),
    };
    Widget b = Pressable(
      onTap: widget.onTap,
      builder: (context, hover, focus) => AnimatedOpacity(
        duration: const Duration(milliseconds: 80),
        opacity: enabled ? 1 : 0.45,
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: widget.small ? 8 : 10, vertical: widget.small ? 3 : 5),
          decoration: BoxDecoration(
            color: hover ? Color.lerp(bg, Colors.white, widget.kind == BtnKind.plain ? 0 : 0.08) : bg,
            borderRadius: BorderRadius.circular(6),
          ),
          foregroundDecoration: focusRing(context, focus, 6),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (widget.icon != null) ...[Icon(widget.icon, size: widget.small ? 11 : 13, color: fg), if (widget.label.isNotEmpty) const SizedBox(width: 6)],
            if (widget.label.isNotEmpty)
              Flexible(
                child: Text(widget.label, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: context.t(widget.small ? 11 : 12, w: widget.kind == BtnKind.primary ? FontWeight.w600 : FontWeight.w400, color: fg)),
              ),
          ]),
        ),
      ),
    );
    if (widget.tooltip != null) b = Tooltip(message: widget.tooltip!, child: b);
    return b;
  }
}

class IconBtn extends StatelessWidget {
  const IconBtn(this.icon, {super.key, this.onTap, this.tooltip, this.size = 15, this.color});
  final IconData icon;
  final VoidCallback? onTap;
  final String? tooltip;
  final double size;
  final Color? color;
  @override
  Widget build(BuildContext context) {
    Widget w = Pressable(
      onTap: onTap,
      builder: (context, hover, focus) => Container(
        padding: const EdgeInsets.all(4),
        foregroundDecoration: focusRing(context, focus, 5),
        child: Icon(icon, size: size, color: color ?? context.c.text2),
      ),
    );
    if (tooltip != null) w = Tooltip(message: tooltip!, child: w);
    return w;
  }
}

/// A macOS-style segmented control.
class Segmented<T> extends StatelessWidget {
  const Segmented({super.key, required this.options, required this.value, required this.onChanged, this.small = false});
  final List<(T, String)> options;
  final T value;
  final ValueChanged<T> onChanged;
  final bool small;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(color: c.toolbarField, borderRadius: BorderRadius.circular(6)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        for (final (v, label) in options)
          Pressable(
            onTap: () => onChanged(v),
            builder: (context, hover, focus) => Container(
              padding: EdgeInsets.symmetric(horizontal: small ? 8 : 10, vertical: small ? 2 : 3),
              decoration: BoxDecoration(color: v == value ? c.segment : Colors.transparent, borderRadius: BorderRadius.circular(5)),
              foregroundDecoration: focusRing(context, focus, 5),
              child: Text(label, style: context.t(small ? 11 : 12, w: v == value ? FontWeight.w600 : FontWeight.w400)),
            ),
          ),
      ]),
    );
  }
}

/// A rounded group box (fields tables, cards).
class Box extends StatelessWidget {
  const Box({super.key, required this.child, this.padding = EdgeInsets.zero, this.color, this.border, this.radius = 8});
  final Widget child;
  final EdgeInsets padding;
  final Color? color;
  final Color? border;
  final double radius;
  @override
  Widget build(BuildContext context) => Container(
    padding: padding,
    decoration: BoxDecoration(
      color: color ?? context.c.box,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: border ?? context.c.boxStroke),
    ),
    child: child,
  );
}

class FieldInput extends StatelessWidget {
  const FieldInput({
    super.key,
    this.controller,
    this.hint,
    this.onSubmitted,
    this.onChanged,
    this.maxLines = 1,
    this.minLines,
    this.autofocus = false,
    this.mono = false,
    this.focusNode,
    this.size = 13,
  });
  final TextEditingController? controller;
  final String? hint;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final int? maxLines;
  final int? minLines;
  final bool autofocus;
  final bool mono;
  final FocusNode? focusNode;
  final double size;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return TextField(
      controller: controller,
      focusNode: focusNode,
      autofocus: autofocus,
      onSubmitted: onSubmitted,
      onChanged: onChanged,
      maxLines: maxLines,
      minLines: minLines,
      style: context.t(size, family: mono ? mono_ : null),
      cursorWidth: 1.5,
      // The default fading caret on Apple platforms repaints every frame
      // while a field has focus (docs/perf.md). A plain blink is enough.
      cursorOpacityAnimates: false,
      decoration: InputDecoration(
        isDense: true,
        hintText: hint,
        hintStyle: context.t(size, color: c.text3),
        filled: true,
        fillColor: c.field,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(5), borderSide: BorderSide(color: c.fieldStroke)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(5), borderSide: BorderSide(color: c.accent, width: 2)),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(5)),
      ),
    );
  }
}

/// A row of a fields table: label on the left, value on the right.
class FieldRow extends StatelessWidget {
  const FieldRow(this.label, this.child, {super.key, this.labelWidth = 90});
  final String label;
  final Widget child;
  final double labelWidth;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    child: Row(children: [
      SizedBox(width: labelWidth, child: Text(label, style: context.t(12, color: context.c.text2))),
      Expanded(child: child),
    ]),
  );
}

class Toolbar extends StatelessWidget {
  const Toolbar({super.key, required this.title, this.subtitle, this.leading, this.center, this.actions = const [], this.middle = const []});
  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? center;
  final List<Widget> middle;
  final List<Widget> actions;
  @override
  Widget build(BuildContext context) => Container(
    height: 52,
    color: context.c.toolbar,
    padding: const EdgeInsets.fromLTRB(10, 0, 16, 0),
    child: Row(children: [
      const NavButtons(),
      const SizedBox(width: 8),
      ?leading,
      if (leading != null) const SizedBox(width: 10),
      // Title and middle on the left, actions on the right. The left side
      // gives way when the page is narrow (the chat open, a small window);
      // the actions keep their size.
      Expanded(
        child: Row(children: [
          Flexible(
            flex: 2,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(mainAxisSize: MainAxisSize.min, children: [
                  const Flexible(child: SingleChildScrollView(scrollDirection: Axis.horizontal, reverse: true, child: CrumbTrail())),
                  Flexible(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(13, w: FontWeight.w700))),
                ]),
                if (subtitle != null) Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(11, color: context.c.text2)),
              ]),
            ),
          ),
          const SizedBox(width: 14),
          if (middle.isNotEmpty) Flexible(flex: 3, child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: middle))),
          if (center != null) ...[const Spacer(), center!, const Spacer()],
        ]),
      ),
      for (final a in actions) Padding(padding: const EdgeInsets.only(left: 8), child: a),
      const ChatToggle(),
    ]),
  );
}

class StatusBar extends StatelessWidget {
  const StatusBar({super.key, required this.left, this.right = const []});
  final String left;
  final List<Widget> right;
  @override
  Widget build(BuildContext context) => Container(
    height: 24,
    color: context.c.bar,
    padding: const EdgeInsets.symmetric(horizontal: 14),
    child: Row(children: [
      Expanded(child: Text(left, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(11, color: context.c.text2))),
      for (final r in right) Padding(padding: const EdgeInsets.only(left: 16), child: r),
    ]),
  );
}

/// Hover highlight + click for list rows; Tab reaches it and Space or
/// Enter activates it.
class Hoverable extends StatelessWidget {
  const Hoverable({super.key, required this.child, this.onTap, this.onDoubleTap, this.selected = false, this.radius = 6, this.selectedColor, this.onSecondaryTapDown, this.focusNode, this.focused = false});
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;
  final bool selected;
  final double radius;
  final Color? selectedColor;
  final GestureTapDownCallback? onSecondaryTapDown;
  final FocusNode? focusNode;

  /// Draw the focus ring regardless of Tab focus: the row a view's own
  /// arrow keys have reached (board cards, list rows).
  final bool focused;
  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    onDoubleTap: onDoubleTap,
    onSecondaryTapDown: onSecondaryTapDown,
    focusNode: focusNode,
    builder: (context, hover, focus) => Container(
      decoration: BoxDecoration(
        color: selected
            ? (selectedColor ?? context.c.accent)
            : (hover ? context.c.text.withValues(alpha: 0.05) : Colors.transparent),
        borderRadius: BorderRadius.circular(radius),
      ),
      foregroundDecoration: focusRing(context, focus || focused, radius),
      child: child,
    ),
  );
}

/// Diff numbers: +142 −38.
class DiffNums extends StatelessWidget {
  const DiffNums(this.adds, this.dels, {super.key, this.size = 11, this.onAccent = false});
  final int adds, dels;
  final double size;
  final bool onAccent;
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
    Text('+$adds', style: context.t(size, family: mono_, color: onAccent ? Colors.white : context.c.success)),
    const SizedBox(width: 5),
    Text('−$dels', style: context.t(size, family: mono_, color: onAccent ? Colors.white : context.c.danger)),
  ]);
}

void copyText(String s) => Clipboard.setData(ClipboardData(text: s));

String ago(DateTime? t) {
  if (t == null) return '';
  final d = DateTime.now().difference(t.toLocal());
  if (d.inSeconds < 45) return 'now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  if (d.inDays < 7) return '${d.inDays}d ago';
  return '${t.toLocal().day}/${t.toLocal().month}';
}

String elapsed(DateTime? from, [DateTime? to]) {
  if (from == null) return '';
  final d = (to ?? DateTime.now()).difference(from.toLocal());
  if (d.inMinutes < 1) return '${d.inSeconds}s';
  if (d.inHours < 1) return '${d.inMinutes}m';
  return '${d.inHours}h ${d.inMinutes % 60}m';
}

/// Shows a small menu at a position and returns the chosen value.
Future<T?> showMenuAt<T>(BuildContext context, Offset at, List<(T, String, IconData?)> items) => showMenu<T>(
  context: context,
  position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx + 1, at.dy + 1),
  items: [
    for (final (v, label, icon) in items)
      PopupMenuItem<T>(
        value: v,
        height: 30,
        child: Row(children: [
          if (icon != null) ...[Icon(icon, size: 13, color: context.c.text2), const SizedBox(width: 8)],
          Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(13))),
        ]),
      ),
  ],
);
