import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// iPhone colours (design/Relay.fig, page "iPhone · Liquid Glass"; light).
abstract final class MC {
  static const bg = Color(0xFFF2F2F7);
  static const card = Colors.white;
  static const text = Color(0xFF0A0A0A);
  static const text2 = Color(0xFF6C6C70);
  static const text3 = Color(0xFFA1A1A6);
  static const separator = Color(0xFFE3E3E8);
  static const accent = Color(0xFF0A64D8);
  static const green = Color(0xFF248A3D);
  static const greenWash = Color(0xFFE3F5E8);
  static const orange = Color(0xFFC77C02);
  static const orangeWash = Color(0xFFFFF1D6);
  static const red = Color(0xFFD70015);
  static const fill = Color(0xFFE9E9EE);
}

/// Text in the phone's type scale (SF via the system font).
TextStyle mt(double size, {FontWeight w = FontWeight.w400, Color color = MC.text, String? family, double? height}) =>
    TextStyle(fontSize: size, fontWeight: w, color: color, fontFamily: family, height: height, letterSpacing: size >= 28 ? -0.6 : (size >= 17 ? -0.3 : 0));

/// Liquid Glass (M8-01), drawn by Flutter: a blurred, lightly tinted pane
/// with a bright rim and a soft shadow. Panes inside one [BackdropGroup]
/// share a single backdrop read, which keeps the blur budget (≤ 4 glass
/// layers on screen) cheap.
class Glass extends StatelessWidget {
  const Glass({super.key, required this.child, this.radius = 999, this.padding = EdgeInsets.zero, this.tint, this.blur = 22, this.shadow = true});

  final Widget child;
  final double radius;
  final EdgeInsets padding;
  final Color? tint;
  final double blur;
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(radius);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: r,
        boxShadow: shadow ? const [BoxShadow(color: Color(0x1F000000), blurRadius: 24, offset: Offset(0, 8))] : null,
      ),
      child: ClipRRect(
        borderRadius: r,
        child: BackdropFilter.grouped(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: r,
              color: tint ?? const Color(0xB8FFFFFF),
              border: Border.all(color: const Color(0xCCFFFFFF), width: 0.8),
              gradient: const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x33FFFFFF), Color(0x00FFFFFF)],
              ),
            ),
            child: Padding(padding: padding, child: child),
          ),
        ),
      ),
    );
  }
}

/// A round glass button (back, search, +).
class GlassCircle extends StatelessWidget {
  const GlassCircle({super.key, required this.icon, this.onTap, this.size = 46, this.color = MC.text, this.semantics});
  final IconData icon;
  final VoidCallback? onTap;
  final double size;
  final Color color;
  final String? semantics;
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: semantics,
    child: GestureDetector(
      onTap: onTap,
      child: SizedBox(width: size, height: size, child: Glass(child: Center(child: Icon(icon, size: size * 0.42, color: color)))),
    ),
  );
}

/// A glass capsule holding a few icon buttons (top-right toolbar).
class GlassPill extends StatelessWidget {
  const GlassPill({super.key, required this.items});
  final List<(IconData, VoidCallback?, String)> items;
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 46,
    child: Glass(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        for (final (icon, onTap, label) in items)
          Semantics(
            button: true,
            label: label,
            child: GestureDetector(
              onTap: onTap,
              behavior: HitTestBehavior.opaque,
              child: SizedBox(width: 42, height: 46, child: Icon(icon, size: 20, color: MC.text)),
            ),
          ),
      ]),
    ),
  );
}

/// The top-left glass capsule: an icon tile, a title and an optional ⌄.
class GlassTitlePill extends StatelessWidget {
  const GlassTitlePill({super.key, required this.leading, required this.title, this.onTap, this.chevron = true});
  final Widget leading;
  final String title;
  final VoidCallback? onTap;
  final bool chevron;
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: SizedBox(
      height: 46,
      child: Glass(
        padding: const EdgeInsets.fromLTRB(7, 0, 14, 0),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          leading,
          const SizedBox(width: 9),
          ConstrainedBox(constraints: const BoxConstraints(maxWidth: 180), child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: mt(16, w: FontWeight.w600))),
          if (chevron) ...[const SizedBox(width: 6), const Icon(LucideIcons.chevronDown, size: 18, color: MC.text2)],
        ]),
      ),
    ),
  );
}

/// The app's blue square tile (logo, project initial).
class Tile extends StatelessWidget {
  const Tile(this.child, {super.key, this.color = MC.accent, this.size = 32, this.radius});
  final Widget child;
  final Color color;
  final double size;
  final double? radius;
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(radius ?? size * 0.28)),
    child: DefaultTextStyle(style: mt(size * 0.45, w: FontWeight.w700, color: Colors.white), child: child),
  );
}

/// The floating tab bar: four tabs in a glass capsule, search on its own.
class GlassTabBar extends StatelessWidget {
  const GlassTabBar({super.key, required this.index, required this.onTap, required this.onSearch, required this.tabs});
  final int index;
  final ValueChanged<int> onTap;
  final VoidCallback onSearch;
  final List<(IconData, String)> tabs;
  @override
  Widget build(BuildContext context) => Row(children: [
    Expanded(
      child: SizedBox(
        height: 62,
        child: Glass(
          padding: const EdgeInsets.all(5),
          child: Row(children: [
            for (final (i, (icon, label)) in tabs.indexed)
              Expanded(
                child: Semantics(
                  selected: i == index,
                  button: true,
                  label: label,
                  child: GestureDetector(
                    onTap: () => onTap(i),
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      decoration: BoxDecoration(color: i == index ? const Color(0x14000000) : Colors.transparent, borderRadius: BorderRadius.circular(999)),
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Icon(icon, size: 21, color: i == index ? MC.accent : MC.text),
                        const SizedBox(height: 2),
                        Text(label, style: mt(10, w: FontWeight.w500, color: i == index ? MC.accent : MC.text)),
                      ]),
                    ),
                  ),
                ),
              ),
          ]),
        ),
      ),
    ),
    const SizedBox(width: 10),
    GlassCircle(icon: LucideIcons.search, size: 62, onTap: onSearch, semantics: 'Search'),
  ]);
}

/// A glass segmented control (Queued · Running · Review; Live · Plan · …).
class GlassSegments<T> extends StatelessWidget {
  const GlassSegments({super.key, required this.options, required this.value, required this.onChanged});
  final List<(T, String)> options;
  final T value;
  final ValueChanged<T> onChanged;
  @override
  Widget build(BuildContext context) => Container(
    height: 38,
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(color: const Color(0x14000000), borderRadius: BorderRadius.circular(999)),
    child: Row(children: [
      for (final (v, label) in options)
        Expanded(
          child: GestureDetector(
            onTap: () => onChanged(v),
            behavior: HitTestBehavior.opaque,
            child: Container(
              alignment: Alignment.center,
              decoration: v == value
                  ? BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(999), boxShadow: const [BoxShadow(color: Color(0x1A000000), blurRadius: 6, offset: Offset(0, 2))])
                  : null,
              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: mt(14, w: v == value ? FontWeight.w600 : FontWeight.w500)),
            ),
          ),
        ),
    ]),
  );
}

/// A white rounded card (lists, task cards).
class MCard extends StatelessWidget {
  const MCard({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.border, this.onTap});
  final Widget child;
  final EdgeInsets padding;
  final Color? border;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: padding,
      decoration: BoxDecoration(
        color: MC.card,
        borderRadius: BorderRadius.circular(22),
        border: border == null ? null : Border.all(color: border!, width: 1.2),
      ),
      child: child,
    ),
  );
}

/// The inset glass sheet (permission requests, new task): floats 8 pt in
/// from the screen edges with the big Liquid Glass corner radius.
Future<T?> showGlassSheet<T>(BuildContext context, Widget Function(BuildContext) builder) => showModalBottomSheet<T>(
  context: context,
  isScrollControlled: true,
  backgroundColor: Colors.transparent,
  barrierColor: const Color(0x33000000),
  elevation: 0,
  builder: (context) => Padding(
    padding: EdgeInsets.fromLTRB(8, 0, 8, 8 + MediaQuery.of(context).viewInsets.bottom),
    child: BackdropGroup(
      child: Glass(
        radius: 38,
        tint: const Color(0xE6F7F7F9),
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: SafeArea(
          top: false,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 36, height: 5, margin: const EdgeInsets.only(bottom: 14), decoration: BoxDecoration(color: const Color(0x33000000), borderRadius: BorderRadius.circular(3))),
            builder(context),
          ]),
        ),
      ),
    ),
  ),
);

/// Big pill buttons used in sheets and cards.
class MButton extends StatelessWidget {
  const MButton(this.label, {super.key, this.onTap, this.primary = false, this.destructive = false, this.height = 48});
  final String label;
  final VoidCallback? onTap;
  final bool primary;
  final bool destructive;
  final double height;
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      height: height,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: primary ? MC.accent : MC.fill, borderRadius: BorderRadius.circular(999)),
      child: Text(label, style: mt(17, w: FontWeight.w600, color: primary ? Colors.white : (destructive ? MC.red : MC.text))),
    ),
  );
}

/// A small coloured status pill ("Live · 12 min", "2 min", "Awake").
class MPill extends StatelessWidget {
  const MPill(this.text, {super.key, this.fg = MC.green, this.bg = MC.greenWash, this.dot = false});
  final String text;
  final Color fg;
  final Color bg;
  final bool dot;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      if (dot) ...[Container(width: 6, height: 6, decoration: BoxDecoration(color: fg, shape: BoxShape.circle)), const SizedBox(width: 5)],
      Text(text, style: mt(12, w: FontWeight.w600, color: fg)),
    ]),
  );
}

/// Section header in caps ("READY FOR REVIEW").
class MSection extends StatelessWidget {
  const MSection(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.fromLTRB(4, 18, 4, 8), child: Text(text.toUpperCase(), style: mt(13, w: FontWeight.w500, color: MC.text2)));
}

/// The agent's coloured tile on the phone.
class AgentSquare extends StatelessWidget {
  const AgentSquare({super.key, required this.letter, required this.color, this.size = 36});
  final String letter;
  final Color color;
  final double size;
  @override
  Widget build(BuildContext context) => Tile(Text(letter), color: color, size: size, radius: size * 0.25);
}
