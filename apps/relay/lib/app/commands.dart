import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ui/platform.dart';

/// Relay's keyboard commands (design P06): one table for the key handler,
/// the macOS menu bar and the keyboard map sheet.
///
/// Keys are checked in a [HardwareKeyboard] handler, before the focused
/// widget sees them, so ⌘K works with the terminal or the editor focused.
/// Commands with [Command.whenTyping] false (single keys, ⌥ digits) leave
/// text fields, the terminal and the editor alone.
class Command {
  const Command(this.id, this.label, this.group, this.keys, {this.whenTyping = true, this.menu = true});
  final String id;
  final String label;
  final CommandGroup group;

  /// The first one is shown in menus and the keyboard map.
  final List<ShortcutActivator> keys;
  final bool whenTyping;

  /// Listed in the macOS menu bar.
  final bool menu;
}

enum CommandGroup {
  go('Go anywhere'),
  product('Inside a product'),
  task('On a task');

  const CommandGroup(this.title);
  final String title;
}

/// ⌘ on the Mac, Ctrl elsewhere.
SingleActivator _mod(LogicalKeyboardKey k, {bool shift = false}) => Desk.key(k, shift: shift);
SingleActivator _alt(LogicalKeyboardKey k) => SingleActivator(k, alt: true);

const _digits = [
  LogicalKeyboardKey.digit1, LogicalKeyboardKey.digit2, LogicalKeyboardKey.digit3,
  LogicalKeyboardKey.digit4, LogicalKeyboardKey.digit5, LogicalKeyboardKey.digit6,
  LogicalKeyboardKey.digit7, LogicalKeyboardKey.digit8, LogicalKeyboardKey.digit9,
];

/// Command ids. Views are `view.0`…`view.5`, projects `project.0`…`project.8`.
abstract final class Cmd {
  static const quickFind = 'quickFind';
  static const askAgent = 'askAgent';
  static const home = 'home';
  static const activity = 'activity';
  static const needsYou = 'needsYou';
  static const agents = 'agents';
  static const back = 'back';
  static const forward = 'forward';
  static const settings = 'settings';
  static const newTask = 'newTask';
  static const toggleTerminal = 'toggleTerminal';
  static const leaveFocus = 'leaveFocus';
  static const switchPane = 'switchPane';
  static const keyboardMap = 'keyboardMap';
  static String view(int i) => 'view.$i';
  static String project(int i) => 'project.$i';
}

const viewNames = ['Board', 'List', 'Timeline', 'Git', 'Code', 'Repos'];

List<Command> get commands => [
  Command(Cmd.quickFind, 'Jump to anything', CommandGroup.go, [_mod(LogicalKeyboardKey.keyK)]),
  Command(Cmd.askAgent, 'Ask an agent', CommandGroup.go, [_mod(LogicalKeyboardKey.keyJ)]),
  Command(Cmd.home, 'Mission control', CommandGroup.go, [_mod(LogicalKeyboardKey.digit0)]),
  Command(Cmd.activity, 'Activity', CommandGroup.go, [_mod(LogicalKeyboardKey.keyA, shift: true)]),
  for (var i = 0; i < 9; i++) Command(Cmd.project(i), 'Project ${i + 1}', CommandGroup.go, [_mod(_digits[i])], menu: false),
  Command(Cmd.needsYou, 'Needs you', CommandGroup.go, [_mod(LogicalKeyboardKey.keyY, shift: true)]),
  Command(Cmd.agents, 'Agents', CommandGroup.go, [_mod(LogicalKeyboardKey.keyE, shift: true)]),
  Command(Cmd.back, 'Back', CommandGroup.go, [_mod(LogicalKeyboardKey.bracketLeft)]),
  Command(Cmd.forward, 'Forward', CommandGroup.go, [_mod(LogicalKeyboardKey.bracketRight)]),
  Command(Cmd.switchPane, 'Sidebar ↔ content', CommandGroup.go, [const SingleActivator(LogicalKeyboardKey.tab, control: true)], whenTyping: false),
  Command(Cmd.settings, 'Settings…', CommandGroup.go, [_mod(LogicalKeyboardKey.comma)]),
  Command(Cmd.keyboardMap, 'Keyboard shortcuts', CommandGroup.go, [_mod(LogicalKeyboardKey.slash), const CharacterActivator('?')]),
  for (var i = 0; i < viewNames.length; i++)
    Command(Cmd.view(i), viewNames[i], CommandGroup.product, [_alt(_digits[i])], whenTyping: false),
  Command(Cmd.newTask, 'New task', CommandGroup.product, [_mod(LogicalKeyboardKey.keyN)]),
  Command(Cmd.toggleTerminal, 'Show or hide the terminal', CommandGroup.product, [const SingleActivator(LogicalKeyboardKey.backquote, control: true)]),
  Command(Cmd.leaveFocus, 'Leave the terminal or editor', CommandGroup.product,
      [Desk.isMac ? const SingleActivator(LogicalKeyboardKey.escape, meta: true) : const SingleActivator(LogicalKeyboardKey.f6)]),
];

/// Keys that live in a view (board, list) rather than the global table;
/// listed in the keyboard map only.
const viewKeys = <(String, String)>[
  ('Move focus', '← → ↑ ↓  or  J K'),
  ('Open', '↵'),
  ('Move to the next or previous column', '⌥→  ⌥←'),
  ('Assign · run now · queue', 'A  R  Q'),
  ('Activate a focused button or row', 'Space  ↵'),
  ('Close the task', 'Esc'),
];

/// Focus nodes where keys are typing (terminal, code editor). Text fields
/// are recognised on their own.
final _typing = Expando<bool>('typing');
FocusNode typingFocusNode({String? debugLabel}) {
  final n = FocusNode(debugLabel: debugLabel);
  _typing[n] = true;
  return n;
}

/// True while keys go to text: a text field, the terminal or the editor.
bool get typingFocused {
  final f = FocusManager.instance.primaryFocus;
  if (f == null) return false;
  if (_typing[f] == true) return true;
  final ctx = f.context;
  return ctx != null && (ctx.widget is EditableText || ctx.findAncestorWidgetOfExactType<EditableText>() != null);
}

/// True while the terminal or the code editor has focus (not a text field).
bool get terminalFocused {
  final f = FocusManager.instance.primaryFocus;
  return f != null && _typing[f] == true;
}

/// Where commands run. The shell registers what each id does while it is
/// on screen; the key handler and the menu bar call [run].
class Commands {
  Commands._();
  static final instance = Commands._();

  final _handlers = <String, VoidCallback>{};

  /// False while a dialog or sheet is in front of the shell.
  bool Function() enabled = () => true;

  void register(Map<String, VoidCallback> handlers) => _handlers
    ..clear()
    ..addAll(handlers);
  void unregister() => _handlers.clear();
  bool has(String id) => _handlers.containsKey(id);

  bool run(String id) {
    final h = _handlers[id];
    if (h == null || !enabled()) return false;
    h();
    return true;
  }

  /// The [HardwareKeyboard] handler: true when a command took the key.
  bool handleKey(KeyEvent e) {
    if (e is KeyUpEvent || _handlers.isEmpty || !enabled()) return false;
    final keyboard = HardwareKeyboard.instance;
    final typing = typingFocused;
    for (final c in commands) {
      if (typing && !c.whenTyping) continue;
      // Off the Mac the commands use Ctrl, which the shell in the terminal
      // needs (Ctrl+K, Ctrl+N…); leave the terminal its keys there.
      if (!Desk.isMac && terminalFocused && c.id != Cmd.leaveFocus && c.id != Cmd.toggleTerminal) continue;
      // A bare character (?) is always typing when text has focus.
      if (!c.keys.any((k) => k.accepts(e, keyboard) && !(typing && k is CharacterActivator))) continue;
      if (e is KeyRepeatEvent && c.id != Cmd.back && c.id != Cmd.forward) return true;
      return run(c.id);
    }
    return false;
  }
}

/// "⌘K", "⌥1", "Ctrl+K": how an activator is written in menus and sheets.
String keyLabel(ShortcutActivator a) {
  if (a is CharacterActivator) return a.character;
  if (a is! SingleActivator) return '';
  final k = a.trigger;
  final name = switch (k) {
    LogicalKeyboardKey.escape => 'Esc',
    LogicalKeyboardKey.tab => 'Tab',
    LogicalKeyboardKey.enter => '↵',
    LogicalKeyboardKey.backquote => '`',
    LogicalKeyboardKey.bracketLeft => '[',
    LogicalKeyboardKey.bracketRight => ']',
    LogicalKeyboardKey.comma => ',',
    LogicalKeyboardKey.slash => '/',
    LogicalKeyboardKey.arrowLeft => '←',
    LogicalKeyboardKey.arrowRight => '→',
    LogicalKeyboardKey.arrowUp => '↑',
    LogicalKeyboardKey.arrowDown => '↓',
    _ => k.keyLabel.toUpperCase(),
  };
  if (Desk.isMac) {
    return '${a.control ? '⌃' : ''}${a.alt ? '⌥' : ''}${a.shift ? '⇧' : ''}${a.meta ? '⌘' : ''}$name';
  }
  return [if (a.control) 'Ctrl', if (a.alt) 'Alt', if (a.shift) 'Shift', if (a.meta) 'Win', name].join('+');
}

/// Bumped when keyboard focus should go to the main view (⌃Tab, ⌘Esc);
/// views with their own keys (board, list) take it.
final focusContent = ValueNotifier(0);

/// Focus nodes that hold focus only as a fallback (the shell, the content
/// area): a view may take focus from them when it opens.
final _idle = Expando<bool>('idle');
FocusNode idleFocusNode({String? debugLabel, bool skipTraversal = false}) {
  final n = FocusNode(debugLabel: debugLabel, skipTraversal: skipTraversal);
  _idle[n] = true;
  return n;
}

/// True when nothing in particular has keyboard focus, so a view that just
/// opened can take it without pulling it from the sidebar or a field.
bool get focusIsIdle {
  final f = FocusManager.instance.primaryFocus;
  // A node whose widget just went away (the view that was replaced) still
  // counts as focused for a moment; it has no parent by then.
  return f == null || f.context == null || f.parent == null || _idle[f] == true || f is FocusScopeNode;
}
