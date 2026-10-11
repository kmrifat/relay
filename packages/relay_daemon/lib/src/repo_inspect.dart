import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:relay_core/relay_core.dart';
import 'package:relay_git/relay_git.dart';

import 'context.dart';

/// What Relay can tell about a folder before adding it as a repo: git
/// facts, the stack from its manifest files, a test command, and likely
/// contract files.
Future<Map<String, Object?>> inspectRepo(Git git, String path) async {
  final dir = Directory(path);
  if (!dir.existsSync()) return {'isRepo': false, 'error': 'No folder $path'};
  if (!await git.isRepo(path)) return {'isRepo': false};
  final top = await git.topLevel(path);
  bool has(String f) => File(p.join(top, f)).existsSync();
  final (stack, role, test) = switch (true) {
    _ when has('pubspec.yaml') && Directory(p.join(top, 'lib')).existsSync() && (Directory(p.join(top, 'ios')).existsSync() || Directory(p.join(top, 'android')).existsSync() || Directory(p.join(top, 'macos')).existsSync()) =>
      ('Flutter', 'app', 'flutter test'),
    _ when has('pubspec.yaml') => ('Dart', 'library', 'dart test'),
    _ when has('artisan') => ('Laravel', 'api', 'php artisan test'),
    _ when has('composer.json') => ('PHP', 'api', 'composer test'),
    _ when has('next.config.js') || has('next.config.mjs') || has('next.config.ts') => ('Next.js', 'web', 'npm test'),
    _ when has('wrangler.toml') || has('wrangler.jsonc') => ('Cloudflare Worker', 'worker', 'npm test'),
    _ when has('package.json') => ('Node', 'web', 'npm test'),
    _ when has('go.mod') => ('Go', 'api', 'go test ./...'),
    _ when has('Cargo.toml') => ('Rust', 'library', 'cargo test'),
    _ when has('pyproject.toml') || has('requirements.txt') => ('Python', 'api', 'pytest'),
    _ when has('Package.swift') => ('Swift', 'library', 'swift test'),
    _ when Directory(top).listSync().any((e) => e.path.endsWith('.tf')) => ('Terraform', 'infra', null),
    _ => ('', '', null),
  };
  final contracts = <String>[
    for (final c in ['openapi.yaml', 'openapi.yml', 'openapi.json', 'schema.graphql', 'proto', 'api.yaml'])
      if (FileSystemEntity.typeSync(p.join(top, c)) != FileSystemEntityType.notFound) c,
  ];
  return {
    'isRepo': true,
    'topLevel': top,
    'name': p.basename(top),
    'defaultBranch': await git.defaultBranch(top),
    'currentBranch': await git.currentBranch(top),
    'remoteUrl': await git.remoteUrl(top),
    'stack': stack,
    'role': contracts.isNotEmpty && stack.isEmpty ? 'shared' : role,
    'testCommand': test,
    'contractPaths': contracts,
  };
}

/// Which repos a task probably touches, from its words and the repo map.
///
/// A heuristic stand-in for asking an agent: repo names, roles and stacks
/// mentioned in the text, UI words for app repos, API words for api repos,
/// and the contract repo whenever both sides of a contract are involved.
List<Map<String, Object?>> suggestRepos(DaemonContext ctx, String projectId, String text, List<String> already) {
  final repos = ctx.reposOf(projectId);
  final t = text.toLowerCase();
  final out = <Map<String, Object?>>[];
  bool any(List<String> words) => words.any((w) => RegExp('\\b${RegExp.escape(w)}').hasMatch(t));
  for (final r in repos) {
    if (already.contains(r.id)) continue;
    String? reason;
    final role = r.role.toLowerCase();
    final stack = r.stack.toLowerCase();
    if (t.contains(r.name.toLowerCase())) {
      reason = 'mentions ${r.name}';
    } else if ((role == 'app' || stack.contains('flutter') || stack.contains('swift')) &&
        any(['screen', 'button', 'ios', 'android', 'mobile', 'app ', 'widget', 'tap', 'share sheet'])) {
      reason = 'UI work on the app';
    } else if ((role == 'web' || stack.contains('react') || stack.contains('next')) && any(['dashboard', 'admin', 'web', 'page'])) {
      reason = 'web dashboard';
    } else if ((role == 'api' || stack.contains('laravel') || stack.contains('go')) &&
        any(['endpoint', 'api', 'server', 'database', 'migration', 'link', 'auth', 'field'])) {
      reason = 'server-side change';
    } else if ((role == 'worker') && any(['queue', 'job', 'email', 'notification', 'cron', 'background'])) {
      reason = 'background job';
    } else if (role == 'infra' && any(['deploy', 'bucket', 'dns', 'terraform', 'infra'])) {
      reason = 'infrastructure';
    }
    if (reason != null) out.add({'repoId': r.id, 'name': r.name, 'reason': reason});
  }
  // A contract repo is needed when repos on both sides of it are touched.
  final chosen = {...already, ...out.map((o) => o['repoId'] as String)};
  for (final r in repos.where((r) => r.contractPaths.isNotEmpty && !chosen.contains(r.id))) {
    final dependents = repos.where((x) => x.dependsOn.contains(r.id) && chosen.contains(x.id)).toList();
    if (dependents.isNotEmpty && any(['field', 'endpoint', 'api', 'link', 'model', 'schema', 'time', 'new'])) {
      out.add({
        'repoId': r.id,
        'name': r.name,
        'reason': '${dependents.map((d) => d.name).join(' and ')} share its contract (${r.contractPaths.first})',
      });
    }
  }
  return out;
}

/// Seeds the demo agent so Relay can be tried without any CLI logged in.
void ensureDemoAgent(DaemonContext ctx) {
  if (ctx.relayBinary == null) return;
  final existing = ctx.agent('demo');
  final fields = {
    'adapter': 'demo',
    'name': 'Demo agent',
    'binaryPath': ctx.relayBinary,
    'color': '#0A64D8',
    'letter': 'D',
    'goodAt': ['trying Relay'],
    'plan': 'Built in, no account',
  };
  if (existing == null) {
    ctx.store.create<AgentProfile>(Kind.agent, {'id': 'demo', 'enabled': true, 'slots': 3, ...fields});
  } else if (existing.binaryPath != ctx.relayBinary) {
    ctx.store.patch<AgentProfile>(Kind.agent, 'demo', {'binaryPath': ctx.relayBinary});
  }
}
