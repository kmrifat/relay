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
  }, skip: helper == null ? 'run tool/build_pty.sh first' : false);

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
  }, skip: helper == null ? 'run tool/build_pty.sh first' : false);

  test('interrupt stops a long command', () async {
    final pty = await Pty.start('/bin/sleep', ['30'], helper: helper!);
    pty.output.listen((_) {});
    await Future<void>.delayed(const Duration(milliseconds: 200));
    pty.interrupt();
    expect(await pty.exitCode.timeout(const Duration(seconds: 5)), 130);
  }, skip: helper == null ? 'run tool/build_pty.sh first' : false);
}
