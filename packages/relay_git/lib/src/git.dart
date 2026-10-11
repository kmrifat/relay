import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

class GitException implements Exception {
  GitException(this.args, this.code, this.stderr);
  final List<String> args;
  final int code;
  final String stderr;
  @override
  String toString() => 'git ${args.join(' ')} failed ($code): ${stderr.trim()}';
}

/// One changed file from `git status`.
class FileStatus {
  FileStatus(this.path, this.index, this.worktree);

  final String path;

  /// Porcelain v1 codes: ' ', 'M', 'A', 'D', 'R', '?', …
  final String index;
  final String worktree;

  /// One letter for the UI: M, A, D, R or U (untracked).
  String get letter {
    if (index == '?' || worktree == '?') return 'U';
    if (index == 'A' || worktree == 'A') return 'A';
    if (index == 'D' || worktree == 'D') return 'D';
    if (index == 'R') return 'R';
    return 'M';
  }

  Map<String, Object?> toJson() => {'path': path, 'letter': letter};
}

class DiffStat {
  DiffStat(this.files, this.additions, this.deletions, [this.perFile = const []]);
  final int files;
  final int additions;
  final int deletions;
  final List<Map<String, Object?>> perFile;
  Map<String, Object?> toJson() =>
      {'files': files, 'additions': additions, 'deletions': deletions, 'perFile': perFile};
}

class Commit {
  Commit({
    required this.hash,
    required this.parents,
    required this.author,
    required this.email,
    required this.date,
    required this.subject,
    required this.refs,
    required this.trailers,
  });

  final String hash;
  final List<String> parents;
  final String author;
  final String email;
  final DateTime date;
  final String subject;
  final List<String> refs;
  final Map<String, String> trailers;

  /// The agent that made this commit, from a `Relay-Agent:` trailer or a
  /// known co-author line.
  String? get agent {
    final t = trailers['Relay-Agent'];
    if (t != null) return t;
    final co = trailers['Co-Authored-By'] ?? '';
    if (co.contains('Claude')) return 'claude-code';
    if (co.contains('Codex')) return 'codex';
    if (co.contains('Gemini')) return 'gemini';
    return null;
  }

  Map<String, Object?> toJson() => {
    'hash': hash,
    'parents': parents,
    'author': author,
    'email': email,
    'date': date.toUtc().toIso8601String(),
    'subject': subject,
    'refs': refs,
    'agent': agent,
    'task': trailers['Relay-Task'],
  };
}

class Worktree {
  Worktree(this.path, this.branch, this.head);
  final String path;
  final String? branch;
  final String head;
  Map<String, Object?> toJson() => {'path': path, 'branch': branch, 'head': head};
}

/// A thin, testable wrapper over the `git` command line.
class Git {
  Git({this.executable = 'git'});

  final String executable;

  Future<String> run(String dir, List<String> args, {bool allowFail = false}) async {
    final r = await Process.run(
      executable,
      ['-C', dir, ...args],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
      environment: const {'GIT_TERMINAL_PROMPT': '0', 'LC_ALL': 'C'},
    );
    if (r.exitCode != 0 && !allowFail) {
      throw GitException(args, r.exitCode, r.stderr as String);
    }
    return r.stdout as String;
  }

  Future<bool> isRepo(String dir) async {
    if (!Directory(dir).existsSync()) return false;
    final out = await run(dir, ['rev-parse', '--is-inside-work-tree'], allowFail: true);
    return out.trim() == 'true';
  }

  Future<String> topLevel(String dir) async => nativePath((await run(dir, ['rev-parse', '--show-toplevel'])).trim());

  /// git prints `C:/Users/…` on Windows; Relay keeps native paths.
  static String nativePath(String path) => Platform.isWindows ? p.normalize(path) : path;

  Future<String?> currentBranch(String dir) async {
    final out = (await run(dir, ['branch', '--show-current'], allowFail: true)).trim();
    return out.isEmpty ? null : out;
  }

  Future<String?> remoteUrl(String dir) async {
    final out = (await run(dir, ['remote', 'get-url', 'origin'], allowFail: true)).trim();
    return out.isEmpty ? null : out;
  }

  /// The branch `origin/HEAD` points at, else `main`, `master` or the current one.
  Future<String> defaultBranch(String dir) async {
    final head = (await run(dir, ['symbolic-ref', '--short', 'refs/remotes/origin/HEAD'], allowFail: true)).trim();
    if (head.isNotEmpty) return head.replaceFirst('origin/', '');
    final branches = await localBranches(dir);
    for (final b in ['main', 'master', 'develop']) {
      if (branches.contains(b)) return b;
    }
    return await currentBranch(dir) ?? 'main';
  }

  Future<List<String>> localBranches(String dir) async => (await run(dir, ['branch', '--format=%(refname:short)'], allowFail: true))
      .split('\n')
      .where((l) => l.trim().isNotEmpty)
      .toList();

  Future<bool> branchExists(String dir, String branch) async =>
      (await run(dir, ['rev-parse', '--verify', '--quiet', 'refs/heads/$branch'], allowFail: true)).trim().isNotEmpty;

  // ---------------------------------------------------------------- worktrees

  /// Creates (or reuses) a worktree at [path] on [branch], branching from
  /// [base] when the branch doesn't exist yet.
  Future<Worktree> worktreeAdd(String repo, String path, String branch, {required String base}) async {
    final existing = (await worktrees(repo)).where((w) => p.equals(w.path, path) || p.equals(_real(w.path), _real(path)));
    if (existing.isNotEmpty) return existing.first;
    Directory(p.dirname(path)).createSync(recursive: true);
    if (await branchExists(repo, branch)) {
      await run(repo, ['worktree', 'add', path, branch]);
    } else {
      await run(repo, ['worktree', 'add', '-b', branch, path, base]);
    }
    final head = (await run(path, ['rev-parse', 'HEAD'])).trim();
    return Worktree(path, branch, head);
  }

  /// A detached worktree at [ref], for reading another repo's code without
  /// touching the user's checkout.
  Future<void> worktreeAddDetached(String repo, String path, String ref) async {
    Directory(p.dirname(path)).createSync(recursive: true);
    await run(repo, ['worktree', 'add', '--detach', path, ref]);
  }

  Future<void> worktreeRemove(String repo, String path, {bool force = false}) async {
    await run(repo, ['worktree', 'remove', if (force) '--force', path], allowFail: true);
    await run(repo, ['worktree', 'prune'], allowFail: true);
  }

  Future<List<Worktree>> worktrees(String repo) async {
    final out = await run(repo, ['worktree', 'list', '--porcelain'], allowFail: true);
    final result = <Worktree>[];
    String? path, head, branch;
    for (final line in out.split('\n')) {
      if (line.startsWith('worktree ')) {
        path = nativePath(line.substring(9));
      } else if (line.startsWith('HEAD ')) {
        head = line.substring(5);
      } else if (line.startsWith('branch ')) {
        branch = line.substring(7).replaceFirst('refs/heads/', '');
      } else if (line.isEmpty && path != null) {
        result.add(Worktree(path, branch, head ?? ''));
        path = head = branch = null;
      }
    }
    if (path != null) result.add(Worktree(path, branch, head ?? ''));
    return result;
  }

  // ---------------------------------------------------------------- status & diff

  Future<List<FileStatus>> status(String dir) async {
    final out = await run(dir, ['status', '--porcelain=v1', '-z', '--untracked-files=all'], allowFail: true);
    final parts = out.split('\x00');
    final result = <FileStatus>[];
    for (var i = 0; i < parts.length; i++) {
      final e = parts[i];
      if (e.length < 4) continue;
      final x = e[0], y = e[1];
      result.add(FileStatus(e.substring(3), x, y));
      if (x == 'R' || x == 'C') i++; // skip the "from" path
    }
    return result;
  }

  /// Changes on this branch since it left [base], including uncommitted work.
  Future<DiffStat> diffStat(String dir, String base) async {
    final mergeBase = (await run(dir, ['merge-base', base, 'HEAD'], allowFail: true)).trim();
    final from = mergeBase.isEmpty ? base : mergeBase;
    final out = await run(dir, ['diff', '--numstat', from], allowFail: true);
    var adds = 0, dels = 0;
    final perFile = <Map<String, Object?>>[];
    for (final line in out.split('\n')) {
      final cols = line.split('\t');
      if (cols.length < 3) continue;
      final a = int.tryParse(cols[0]) ?? 0, d = int.tryParse(cols[1]) ?? 0;
      adds += a;
      dels += d;
      perFile.add({'path': cols[2], 'additions': a, 'deletions': d});
    }
    // Untracked files count as additions.
    for (final s in await status(dir)) {
      if (s.letter == 'U') {
        final f = File(p.join(dir, s.path));
        final lines = f.existsSync() ? _countLines(f) : 0;
        adds += lines;
        perFile.add({'path': s.path, 'additions': lines, 'deletions': 0, 'untracked': true});
      }
    }
    return DiffStat(perFile.length, adds, dels, perFile);
  }

  Future<String> diff(String dir, {String? base, String? path}) async {
    final args = ['diff', '--no-color', ?base, if (path != null) ...['--', path]];
    return run(dir, args, allowFail: true);
  }

  // ---------------------------------------------------------------- log

  static const _sep = '\x1f';
  static const _end = '\x1e';

  /// Commits from all branches (or [ref]), newest first, with trailers.
  Future<List<Commit>> log(String dir, {int limit = 300, String? ref, bool all = true, String? grep}) async {
    final fmt = ['%H', '%P', '%an', '%ae', '%aI', '%s', '%D', '%(trailers:unfold,separator=%x1d)'].join(_sep);
    final out = await run(dir, [
      'log',
      '--topo-order',
      '--format=$fmt$_end',
      '-n',
      '$limit',
      if (grep != null) '--grep=$grep',
      if (ref != null) ref else if (all) '--all',
    ], allowFail: true);
    final commits = <Commit>[];
    for (final rec in out.split(_end)) {
      final r = rec.trim();
      if (r.isEmpty) continue;
      final f = r.split(_sep);
      if (f.length < 7) continue;
      final trailers = <String, String>{};
      if (f.length > 7) {
        for (final t in f[7].split('\x1d')) {
          final i = t.indexOf(':');
          if (i > 0) trailers[t.substring(0, i).trim()] = t.substring(i + 1).trim();
        }
      }
      commits.add(Commit(
        hash: f[0],
        parents: f[1].split(' ').where((s) => s.isNotEmpty).toList(),
        author: f[2],
        email: f[3],
        date: DateTime.tryParse(f[4]) ?? DateTime.fromMillisecondsSinceEpoch(0),
        subject: f[5],
        refs: f[6].split(', ').where((s) => s.isNotEmpty).toList(),
        trailers: trailers,
      ));
    }
    return commits;
  }

  /// One commit's message body and changed files.
  Future<Map<String, Object?>> show(String dir, String hash) async {
    final body = await run(dir, ['show', '-s', '--format=%B', hash]);
    final numstat = await run(dir, ['show', '--numstat', '--format=', hash]);
    final files = <Map<String, Object?>>[];
    for (final line in numstat.split('\n')) {
      final c = line.split('\t');
      if (c.length < 3) continue;
      files.add({'path': c[2], 'additions': int.tryParse(c[0]) ?? 0, 'deletions': int.tryParse(c[1]) ?? 0});
    }
    return {'hash': hash, 'body': body.trim(), 'files': files};
  }

  /// Files git knows about plus untracked ones not ignored, relative to [dir].
  Future<List<String>> listFiles(String dir) async {
    final out = await run(dir, ['ls-files', '--cached', '--others', '--exclude-standard', '-z'], allowFail: true);
    return out.split('\x00').where((s) => s.isNotEmpty).toSet().toList()..sort();
  }

  // ---------------------------------------------------------------- write

  Future<void> commitAll(String dir, String message) async {
    await run(dir, ['add', '-A']);
    final st = await status(dir);
    if (st.isEmpty) return;
    await run(dir, ['commit', '-q', '-m', message]);
  }

  /// Merges [branch] into the checkout at [dir] (which must be on the base
  /// branch and clean) with a merge commit.
  Future<String> mergeInto(String dir, String branch, {required String message}) async {
    final dirty = (await status(dir)).where((s) => s.letter != 'U');
    if (dirty.isNotEmpty) {
      throw GitException(['merge', branch], 1, 'The checkout at $dir has uncommitted changes.');
    }
    await run(dir, ['merge', '--no-ff', '-m', message, branch]);
    return (await run(dir, ['rev-parse', 'HEAD'])).trim();
  }

  Future<void> clone(String url, String dest) async {
    Directory(p.dirname(dest)).createSync(recursive: true);
    final r = await Process.run(executable, ['clone', url, dest], environment: const {'GIT_TERMINAL_PROMPT': '0'});
    if (r.exitCode != 0) throw GitException(['clone', url], r.exitCode, r.stderr as String);
  }
}

int _countLines(File f) {
  try {
    if (f.lengthSync() > 2 * 1024 * 1024) return 0;
    return f.readAsLinesSync().length;
  } catch (_) {
    return 0;
  }
}

String _real(String path) {
  try {
    return Directory(path).resolveSymbolicLinksSync();
  } catch (_) {
    return path;
  }
}
