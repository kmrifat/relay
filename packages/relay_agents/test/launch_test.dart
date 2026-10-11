import 'dart:io';

import 'package:relay_agents/relay_agents.dart';
import 'package:test/test.dart';

void main() {
  test('cmd.exe quoting escapes metacharacters and keeps quotes and backslashes', () {
    expect(Launch.cmdQuote('plain'), '^"plain^"');
    expect(Launch.cmdQuote('a & b'), '^"a^ ^&^ b^"');
    expect(Launch.cmdQuote('50% off'), '^"50^%^ off^"');
    expect(Launch.cmdQuote(r'say "hi"'), r'^"say^ \^"hi\^"^"');
    expect(Launch.cmdQuote(r'C:\dir\'), r'^"C:\dir\\^"');
  });

  test('an npm .cmd shim resolves to node + the script', () {
    final dir = Directory.systemTemp.createTempSync('shim_');
    final sep = Platform.pathSeparator;
    Directory('${dir.path}${sep}node_modules$sep@openai${sep}codex${sep}bin').createSync(recursive: true);
    File('${dir.path}${sep}node_modules$sep@openai${sep}codex${sep}bin${sep}codex.js').writeAsStringSync('');
    File('${dir.path}${sep}node.exe').writeAsStringSync('');
    final shim = File('${dir.path}${sep}codex.cmd')
      ..writeAsStringSync('@ECHO off\r\nGOTO start\r\n:find_dp0\r\nSET dp0=%~dp0\r\nEXIT /b\r\n:start\r\nSETLOCAL\r\nCALL :find_dp0\r\n'
          'endLocal & goto #_undefined_# 2>NUL || title %COMSPEC% & "%_prog%"  "%dp0%\\node_modules\\@openai\\codex\\bin\\codex.js" %*\r\n');
    final t = Launch.npmShimTarget(shim.path)!;
    expect(t.$1, endsWith('node.exe'));
    expect(t.$2.single, endsWith('codex.js'));
    expect(Launch.npmShimTarget(File('${dir.path}${sep}node.exe').path), isNull);
  });

  test('PATH is found whatever its case', () {
    expect(Launch.pathOf({'Path': r'C:\bin'}), r'C:\bin');
    expect(Launch.pathOf({'PATH': '/usr/bin'}), '/usr/bin');
    expect(Launch.pathOf({}), '');
  });

  test('a process tree stops together', testOn: '!windows', () async {
    // sh starts a sleeping child; killing the tree ends both.
    final p = await Process.start('/bin/sh', ['-c', 'sleep 30 & wait']);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final kids = await ProcessTree.descendants(p.pid);
    expect(kids, isNotEmpty);
    await ProcessTree.kill(p, grace: const Duration(seconds: 2));
    await p.exitCode;
    for (final k in kids) {
      expect(Process.killPid(k, ProcessSignal.sigcont), isFalse, reason: 'child $k still alive');
    }
  });
}
