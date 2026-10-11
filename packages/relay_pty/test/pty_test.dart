import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:relay_pty/relay_pty.dart';
import 'package:test/test.dart';

void main() {
  final helper = Pty.findHelper(near: '${Directory.current.parent.parent.path}/tool/out');

  test('runs a command in a real terminal', () async {
    final pty = await Pty.start('/bin/sh', ['-c', 'test -t 1 && echo is-a-tty; stty size'], helper: helper!, cols: 100, rows: 30);
    final out = await pty.output.transform(utf8.decoder).join();
    expect(out, contains('is-a-tty'));
    expect(out, contains('30 100'));
    expect(await pty.exitCode, 0);
  }, testOn: '!windows', skip: helper == null ? 'run tool/build_pty.sh first' : false);

  test('input, resize and exit code', () async {
    final pty = await Pty.start('/bin/sh', [], helper: helper!, cols: 80, rows: 24);
    final buf = StringBuffer();
    final sub = pty.output.transform(utf8.decoder).listen(buf.write);
    pty.resize(120, 40);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    pty.writeString('stty size; exit 3\n');
    expect(await pty.exitCode.timeout(const Duration(seconds: 5)), 3);
    await sub.cancel();
    expect(buf.toString(), contains('40 120'));
  }, testOn: '!windows', skip: helper == null ? 'run tool/build_pty.sh first' : false);

  test('interrupt stops a long command', () async {
    final pty = await Pty.start('/bin/sleep', ['30'], helper: helper!);
    pty.output.listen((_) {});
    await Future<void>.delayed(const Duration(milliseconds: 200));
    pty.interrupt();
    expect(await pty.exitCode.timeout(const Duration(seconds: 5)), 130);
  }, testOn: '!windows', skip: helper == null ? 'run tool/build_pty.sh first' : false);

  // ConPTY (relay_pty_win.c): the same frames, Windows commands.
  test('Windows: runs a command in a pseudoconsole and reports its exit code', testOn: 'windows', () async {
    final pty = await Pty.start('cmd.exe', ['/d', '/c', 'echo relay-ok & exit 3'], helper: helper!, cols: 100, rows: 30);
    final buf = StringBuffer();
    pty.output.listen((b) => buf.write(utf8.decode(b, allowMalformed: true)));
    expect(await pty.exitCode.timeout(const Duration(seconds: 15)), 3);
    expect(buf.toString(), contains('relay-ok'));
  }, skip: helper == null ? 'run tool/build_pty.sh first' : false);

  test('Windows: input reaches the shell; resize; closing ends it', testOn: 'windows', () async {
    final pty = await Pty.start('cmd.exe', ['/d', '/q'], helper: helper!, cols: 80, rows: 24);
    final buf = StringBuffer();
    pty.output.listen((b) => buf.write(utf8.decode(b, allowMalformed: true)));
    pty.resize(120, 40);
    pty.writeString('echo typed-%COMSPEC:~0,1%-ok\r\nexit 5\r\n');
    expect(await pty.exitCode.timeout(const Duration(seconds: 15)), 5);
    expect(buf.toString(), contains('typed-'));
  }, skip: helper == null ? 'run tool/build_pty.sh first' : false);

  test('Windows: kill ends the command tree', testOn: 'windows', () async {
    final pty = await Pty.start('cmd.exe', ['/d', '/c', 'ping -n 60 127.0.0.1'], helper: helper!);
    pty.output.listen((_) {});
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await pty.kill();
    await pty.exitCode.timeout(const Duration(seconds: 10));
  }, skip: helper == null ? 'run tool/build_pty.sh first' : false);
}
