import 'package:flutter/material.dart';

/// Relay's colour tokens (design/Relay.fig, Desktop · macOS), taken from
/// DevVault's desktop palette so both apps look like one family.
@immutable
class RelayColors extends ThemeExtension<RelayColors> {
  const RelayColors({
    required this.window,
    required this.sidebar,
    required this.toolbar,
    required this.bar,
    required this.separator,
    required this.inner,
    required this.zebra,
    required this.box,
    required this.boxInner,
    required this.boxStroke,
    required this.field,
    required this.fieldStroke,
    required this.toolbarField,
    required this.segment,
    required this.control,
    required this.text,
    required this.text2,
    required this.text3,
    required this.accent,
    required this.accentIcon,
    required this.success,
    required this.successWash,
    required this.warning,
    required this.warningWash,
    required this.danger,
    required this.dangerWash,
    required this.purple,
    required this.purpleWash,
    required this.codeBg,
  });

  final Color window, sidebar, toolbar, bar, separator, inner, zebra;
  final Color box, boxInner, boxStroke, field, fieldStroke, toolbarField, segment, control;
  final Color text, text2, text3, accent, accentIcon;
  final Color success, successWash, warning, warningWash, danger, dangerWash, purple, purpleWash, codeBg;

  static const dark = RelayColors(
    window: Color(0xFF1E1E1E),
    sidebar: Color(0xFF29272E),
    toolbar: Color(0xFF2B2B2D),
    bar: Color(0xFF252527),
    separator: Color(0xFF000000),
    inner: Color(0xFF3A3A3C),
    zebra: Color(0xFF242426),
    box: Color(0xFF2A2A2C),
    boxInner: Color(0xFF252527),
    boxStroke: Color(0xFF3A3A3C),
    field: Color(0xFF1C1C1E),
    fieldStroke: Color(0xFF48484A),
    toolbarField: Color(0xFF3A3A3C),
    segment: Color(0xFF5A5A5E),
    control: Color(0xFF5A5A5E),
    text: Color(0xFFF5F5F7),
    text2: Color(0xFF98989D),
    text3: Color(0xFF8D8D93),
    accent: Color(0xFF0A64D8),
    accentIcon: Color(0xFF4D9BFF),
    success: Color(0xFF32D74B),
    successWash: Color(0xFF1B3A24),
    warning: Color(0xFFFFB340),
    warningWash: Color(0xFF3D2E12),
    danger: Color(0xFFFF6961),
    dangerWash: Color(0xFF3D1A1A),
    purple: Color(0xFFD49BF5),
    purpleWash: Color(0xFF3A2846),
    codeBg: Color(0xFF1C1C1E),
  );

  static const light = RelayColors(
    window: Color(0xFFFFFFFF),
    sidebar: Color(0xFFECEAEF),
    toolbar: Color(0xFFFAFAFA),
    bar: Color(0xFFFAFAFA),
    separator: Color(0xFFE3E3E6),
    inner: Color(0xFFE3E3E6),
    zebra: Color(0xFFF5F5F7),
    box: Color(0xFFF6F6F8),
    boxInner: Color(0xFFFFFFFF),
    boxStroke: Color(0xFFE3E3E6),
    field: Color(0xFFFFFFFF),
    fieldStroke: Color(0xFFD1D1D6),
    toolbarField: Color(0xFFEBEBED),
    segment: Color(0xFFFFFFFF),
    control: Color(0xFFE5E5EA),
    text: Color(0xFF1D1D1F),
    text2: Color(0xFF66666B),
    text3: Color(0xFF8E8E93),
    accent: Color(0xFF0A64D8),
    accentIcon: Color(0xFF0A64D8),
    success: Color(0xFF1F9D55),
    successWash: Color(0xFFE3F5EA),
    warning: Color(0xFFC77700),
    warningWash: Color(0xFFFFF1D6),
    danger: Color(0xFFD70015),
    dangerWash: Color(0xFFFDE8EA),
    purple: Color(0xFF8944AB),
    purpleWash: Color(0xFFF1E4F8),
    codeBg: Color(0xFFF6F6F8),
  );

  @override
  RelayColors copyWith() => this;

  @override
  RelayColors lerp(RelayColors? other, double t) => t < 0.5 ? this : (other ?? this);
}

extension RelayTheme on BuildContext {
  RelayColors get c => Theme.of(this).extension<RelayColors>()!;
  bool get isDark => Theme.of(this).brightness == Brightness.dark;
}

const mono = 'JetBrains Mono';

ThemeData buildTheme(Brightness b) {
  final c = b == Brightness.dark ? RelayColors.dark : RelayColors.light;
  final base = ThemeData(
    brightness: b,
    useMaterial3: true,
    fontFamily: 'Inter',
    scaffoldBackgroundColor: c.window,
    colorScheme: ColorScheme.fromSeed(seedColor: c.accent, brightness: b).copyWith(primary: c.accent, surface: c.window),
    extensions: [c],
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    hoverColor: c.text.withValues(alpha: 0.05),
    dividerColor: c.inner,
    textSelectionTheme: TextSelectionThemeData(cursorColor: c.accentIcon, selectionColor: c.accent.withValues(alpha: 0.35)),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: c.box, borderRadius: BorderRadius.circular(6), border: Border.all(color: c.boxStroke)),
      textStyle: TextStyle(color: c.text, fontSize: 11),
      waitDuration: const Duration(milliseconds: 500),
    ),
    scrollbarTheme: ScrollbarThemeData(thickness: WidgetStateProperty.all(6), radius: const Radius.circular(3), thumbColor: WidgetStateProperty.all(c.text3.withValues(alpha: 0.4))),
    popupMenuTheme: PopupMenuThemeData(
      color: c.box,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: c.boxStroke)),
      textStyle: TextStyle(color: c.text, fontSize: 13, fontFamily: 'Inter'),
    ),
    dialogTheme: DialogThemeData(backgroundColor: c.box, surfaceTintColor: Colors.transparent),
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: c.text, displayColor: c.text, fontFamily: 'Inter'),
  );
}

Color hexColor(String? hex, [Color fallback = const Color(0xFF5A5A5E)]) {
  if (hex == null || !hex.startsWith('#') || (hex.length != 7 && hex.length != 9)) return fallback;
  final v = int.tryParse(hex.substring(1), radix: 16);
  if (v == null) return fallback;
  return hex.length == 7 ? Color(0xFF000000 | v) : Color(((v & 0xFF) << 24) | (v >> 8));
}
