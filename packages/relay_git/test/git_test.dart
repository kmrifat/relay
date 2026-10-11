import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:relay_git/relay_git.dart';
import 'package:test/test.dart';

Future<String> makeRepo(Git git) async {
  final dir = Directory.systemTemp.createTempSync('relay_git_').path;
  await git.run(dir, ['init', '-q', '-b', 'main']);
  await git.run(dir, ['config', 'user.email', 't@example.com']);
  await git.run(dir, ['config', 'user.name', 'Test']);
  await git.run(dir, ['config', 'commit.gpgsign', 'false']);
  File(p.join(dir, 'a.txt')).writeAsStringSync('one\n');
  await git.commitAll(dir, 'first');
  return dir;
}

void main() {
  final git = Git();

  test('worktree per task, status and diff stat', () async {
    final repo = await makeRepo(git);
    final wt = p.join(Directory.systemTemp.createTempSync('relay_wt_').path, 'tm-1');
    final w = await git.worktreeAdd(repo, wt, 'tm-1', base: 'main');
    expect(w.branch, 'tm-1');
    expect(await git.currentBranch(wt), 'tm-1');

    // Reusing the same path returns the same worktree.
    final again = await git.worktreeAdd(repo, wt, 'tm-1', base: 'main');
    expect(p.basename(again.path), 'tm-1');

    File(p.join(wt, 'a.txt')).writeAsStringSync('one\ntwo\n');
    File(p.join(wt, 'b.txt')).writeAsStringSync('new\nfile\n');
    final st = await git.status(wt);
    expect(st.map((s) => s.letter).toSet(), {'M', 'U'});

    final stat = await git.diffStat(wt, 'main');
    expect(stat.files, 2);
    expect(stat.additions, 3);

    // The main checkout is untouched.
    expect(File(p.join(repo, 'a.txt')).readAsStringSync(), 'one\n');
    expect((await git.worktrees(repo)).length, 2);
    await git.worktreeRemove(repo, wt, force: true);
    expect((await git.worktrees(repo)).length, 1);
  });

  test('log reads refs and agent trailers; merge into base', () async {
    final repo = await makeRepo(git);
    final wt = p.join(Directory.systemTemp.createTempSync('relay_wt_').path, 'tm-2');
    await git.worktreeAdd(repo, wt, 'tm-2', base: 'main');
    File(p.join(wt, 'c.txt')).writeAsStringSync('c\n');
    await git.commitAll(wt, 'add c\n\nRelay-Task: TM-2\nRelay-Agent: claude-code');

    final log = await git.log(repo);
    final top = log.firstWhere((c) => c.subject == 'add c');
    expect(top.agent, 'claude-code');
    expect(top.trailers['Relay-Task'], 'TM-2');
    expect(top.refs.any((r) => r.contains('tm-2')), isTrue);

    final head = await git.mergeInto(repo, 'tm-2', message: 'Merge TM-2');
    expect(head, hasLength(40));
    expect(File(p.join(repo, 'c.txt')).existsSync(), isTrue);
    final merged = await git.log(repo, limit: 1, all: false, ref: 'HEAD');
    expect(merged.single.parents, hasLength(2));

    final shown = await git.show(repo, top.hash);
    expect((shown['files'] as List).single['path'], 'c.txt');
    expect(await git.listFiles(repo), containsAll(['a.txt', 'c.txt']));
  });

  test('graph layout: branch and merge use two lanes', () {
    // m3 merges f1 into m2; f1 branched from m1.
    final rows = layoutGraph([
      ('m3', ['m2', 'f1']),
      ('f1', ['m1']),
      ('m2', ['m1']),
      ('m1', []),
    ]);
    expect(rows[0].lane, 0);
    expect(rows[1].lane, 1); // feature commit on its own lane
    expect(rows[2].lane, 0);
    expect(rows[3].lane, 0);
    expect(rows.map((r) => r.laneCount).reduce((a, b) => a > b ? a : b), 2);
  });

  test('defaultBranch falls back to main', () async {
    final repo = await makeRepo(git);
    expect(await git.defaultBranch(repo), 'main');
    expect(await git.isRepo(repo), isTrue);
    expect(await git.isRepo(Directory.systemTemp.path), isFalse);
  });
}
