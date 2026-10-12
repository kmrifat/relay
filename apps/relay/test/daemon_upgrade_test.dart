import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay/app/theme.dart';
import 'package:relay/app/upgrade_banner.dart';
import 'package:relay/data/daemon_upgrade.dart';
import 'package:relay/data/relay_data.dart';
import 'package:relay_protocol/relay_protocol.dart';

/// An in-memory relayd at [version] with [liveRuns] agent runs; [shutdown]
/// false is a relayd from before the `shutdown` method.
class FakeRelayd {
  FakeRelayd({required this.version, this.pid = 41, this.liveRuns = 0, this.shutdown = true});

  final String version;
  final int pid;
  int liveRuns;
  final bool shutdown;
  final shutdownCalls = <Map<String, Object?>>[];

  /// Called after answering runs.list (a run starting just then).
  void Function()? afterRunsList;
  late final RpcPeer _server;

  Future<RelayClient> connect() {
    final toServer = StreamController<List<int>>();
    final toClient = StreamController<List<int>>();
    _server = RpcPeer(toServer.stream, toClient.sink, name: 'fake-relayd');
    _server.registerMethod(M.hello, (_) => {'version': version, 'protocol': protocolVersion, 'pid': pid, 'deviceId': 'dev'});
    _server.registerMethod(M.runsList, (_) {
      final runs = [
        for (var i = 0; i < liveRuns; i++) {'id': 'run$i', 'status': 'running', 'live': true},
        {'id': 'teammate', 'status': 'running', 'live': false},
      ];
      afterRunsList?.call();
      return runs;
    });
    if (shutdown) {
      _server.registerMethod(M.shutdown, (p) {
        shutdownCalls.add(p);
        if (liveRuns > 0 && p['force'] != true) throw RpcError(RpcError.busy, 'busy', {'activeRuns': liveRuns});
        return {'pid': pid, 'version': version, 'stoppedRuns': liveRuns};
      });
    }
    return RelayClient.attach(toClient.stream, toServer.sink, token: 't');
  }
}

class FakeHost implements DaemonHost {
  FakeHost({this.bundled, this.manager, this.goneAfter = 2, required this.next});

  final String? bundled;
  final ServiceManager? manager;
  final FakeRelayd next;

  /// isGone answers true from this poll on (never when null).
  final int? goneAfter;
  final log = <String>[];
  int _polls = 0;

  @override
  Future<String?> bundledVersion() async => bundled;
  @override
  Future<ServiceManager?> managerOf(int pid) async {
    log.add('managerOf $pid');
    return manager;
  }

  @override
  Future<void> terminate(int pid) async => log.add('terminate $pid');
  @override
  Future<bool> isGone(int pid) async => goneAfter != null && ++_polls >= goneAfter!;
  @override
  Future<void> start(ServiceManager? via) async => log.add('start ${via?.name ?? 'detached'}');
  @override
  Future<RelayClient> connect() => next.connect();
}

void main() {
  DaemonUpdater updater(FakeHost h) => DaemonUpdater(h, appVersion: '0.1.2', pollEvery: Duration.zero, stopTimeout: const Duration(milliseconds: 300));
  FakeHost host({String? bundled = '0.1.2', ServiceManager? manager, int? goneAfter = 2}) =>
      FakeHost(bundled: bundled, manager: manager, goneAfter: goneAfter, next: FakeRelayd(version: '0.1.2', pid: 42));

  test('compareVersions', () {
    expect(compareVersions('0.1.1', '0.1.2'), lessThan(0));
    expect(compareVersions('0.2.0', '0.1.9'), greaterThan(0));
    expect(compareVersions('1.0', '1.0.0'), 0);
    expect(compareVersions('0.1.2+3', '0.1.2-dev'), 0);
    expect(compareVersions('0.10.0', '0.9.0'), greaterThan(0));
    expect(compareVersions('test', '0.1.2'), isNull);
  });

  group('check', () {
    Future<DaemonUpgrade?> check(String running, {String? bundled = '0.1.2'}) async =>
        updater(host(bundled: bundled)).check(await FakeRelayd(version: running).connect());

    test('an older relayd with a newer bundled helper is replaced', () async {
      final u = await check('0.1.1');
      expect((u!.running, u.bundled, u.pid), ('0.1.1', '0.1.2', 41));
    });

    test('never a downgrade, nor the same version', () async {
      expect(await check('0.1.3'), isNull);
      expect(await check('0.1.2'), isNull);
    });

    test('left alone without a helper, with a stale one, or at an unknown version', () async {
      expect(await check('0.1.1', bundled: null), isNull);
      expect(await check('0.1.1', bundled: '0.1.1'), isNull);
      expect(await check('0.1.1', bundled: '0.1.0'), isNull);
      expect(await check('dev'), isNull);
    });
  });

  group('restart', () {
    const u = DaemonUpgrade(running: '0.1.1', bundled: '0.1.2', pid: 41);

    test('idle: shutdown, wait for it to go, start through the service manager that ran it', () async {
      final old = FakeRelayd(version: '0.1.1');
      final h = host(manager: ServiceManager.launchd);
      var stopping = false;
      final c = await updater(h).restart(await old.connect(), u, onStopping: () => stopping = true);
      expect(old.shutdownCalls, [{'force': false}]);
      expect(stopping, isTrue);
      expect(h.log, ['managerOf 41', 'start launchd']);
      expect(c.hello['version'], '0.1.2');
    });

    test('nothing manages it: started detached', () async {
      final h = host();
      await updater(h).restart(await FakeRelayd(version: '0.1.1').connect(), u);
      expect(h.log.last, 'start detached');
    });

    test('active runs: refused, relayd left running', () async {
      final old = FakeRelayd(version: '0.1.1', liveRuns: 2);
      final h = host();
      await expectLater(
        updater(h).restart(await old.connect(), u),
        throwsA(isA<RpcError>().having((e) => e.code, 'code', RpcError.busy).having((e) => (e.data as Map)['activeRuns'], 'runs', 2)),
      );
      expect(old.shutdownCalls, isEmpty);
      expect(h.log, isEmpty);
    });

    test('a run that started since the check: relayd refuses, nothing started', () async {
      // runs.list says idle, then relayd's own check sees a run.
      final old = FakeRelayd(version: '0.1.1');
      old.afterRunsList = () => old.liveRuns = 1;
      final h = host();
      await expectLater(updater(h).restart(await old.connect(), u), throwsA(isA<RpcError>().having((e) => e.code, 'code', RpcError.busy)));
      expect(old.shutdownCalls, [{'force': false}]);
      expect(h.log.where((l) => l.startsWith('start')), isEmpty);
    });

    test('forced: stops relayd with its runs', () async {
      final old = FakeRelayd(version: '0.1.1', liveRuns: 2);
      await updater(host()).restart(await old.connect(), u, force: true);
      expect(old.shutdownCalls, [{'force': true}]);
    });

    test('a relayd from before shutdown gets SIGTERM', () async {
      final h = host(manager: ServiceManager.systemd);
      await updater(h).restart(await FakeRelayd(version: '0.1.1', shutdown: false).connect(), u);
      expect(h.log, ['managerOf 41', 'terminate 41', 'start systemd']);
    });

    test('one that never stops: an error, and no second relayd', () async {
      final h = host(goneAfter: null);
      await expectLater(updater(h).restart(await FakeRelayd(version: '0.1.1').connect(), u), throwsA(isA<StateError>()));
      expect(h.log.where((l) => l.startsWith('start')), isEmpty);
    });
  });

  testWidgets('the banner says what is waiting and asks before stopping runs', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(upgradeProvider.notifier).set(const UpgradeState(DaemonUpgrade(running: '0.1.1', bundled: '0.1.2', pid: 41), activeRuns: 2));
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: buildTheme(Brightness.light), home: const Scaffold(body: UpgradeBanner())),
    ));
    expect(find.textContaining('relayd 0.1.1 is still running 2 agent runs'), findsOneWidget);
    await tester.tap(find.text('Restart now'));
    await tester.pumpAndSettle();
    expect(find.textContaining('This stops 2 agent runs'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Restart relayd now?'), findsNothing);

    container.read(upgradeProvider.notifier).set(const UpgradeState(DaemonUpgrade(running: '0.1.1', bundled: '0.1.2', pid: 41), error: 'Could not stop relayd'));
    await tester.pump();
    expect(find.text('Could not stop relayd'), findsOneWidget);
    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pump();
    expect(container.read(upgradeProvider), isNull);
  });
}
