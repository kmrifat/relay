import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:relay_protocol/relay_protocol.dart';

import '../data/relay_data.dart';
import 'glass.dart';

/// First run on the phone: pair with your Mac by scanning the QR code it
/// shows in Settings → Team → Pair iPhone (or pasting the code).
class PairScreen extends ConsumerStatefulWidget {
  const PairScreen({super.key});
  @override
  ConsumerState<PairScreen> createState() => _PairScreenState();
}

class _PairScreenState extends ConsumerState<PairScreen> {
  bool scanning = false;
  bool busy = false;
  String? error;

  Future<void> _pair(String code) async {
    if (busy) return;
    setState(() {
      busy = true;
      scanning = false;
      error = null;
    });
    try {
      final s = await ref.read(clientProvider).map(M.syncPair, {'code': code.trim()});
      ref.read(syncStatusProvider.notifier).set(s);
      await ref.read(dataProvider.notifier).reload(ref.read(clientProvider));
    } on RpcError catch (e) {
      error = e.message;
    } catch (e) {
      error = '$e';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    return Scaffold(
      backgroundColor: MC.bg,
      body: ListView(
        padding: EdgeInsets.fromLTRB(24, top + 40, 24, 40),
        children: [
          const Center(child: Tile(Icon(LucideIcons.listChecks, color: Colors.white, size: 30), size: 64)),
          const SizedBox(height: 20),
          Text('Pair with your Mac', textAlign: TextAlign.center, style: mt(28, w: FontWeight.w700)),
          const SizedBox(height: 8),
          Text('Your agents run on your Mac. This phone shows them, answers them and queues work — from anywhere, through your team\'s Worker.',
              textAlign: TextAlign.center, style: mt(16, color: MC.text2, height: 1.35)),
          const SizedBox(height: 24),
          if (scanning)
            ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: SizedBox(
                height: 320,
                child: MobileScanner(
                  onDetect: (capture) {
                    final code = capture.barcodes.map((b) => b.rawValue).whereType<String>().firstWhere((v) => v.startsWith('relay-pair:'), orElse: () => '');
                    if (code.isNotEmpty) _pair(code);
                  },
                ),
              ),
            )
          else
            MCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _Step(1, 'On your Mac, open Relay → Settings → Team.'),
                _Step(2, 'Choose Pair iPhone. A QR code appears.'),
                _Step(3, 'Scan it here.'),
              ]),
            ),
          const SizedBox(height: 20),
          MButton(scanning ? 'Cancel' : 'Scan the QR code', primary: !scanning, height: 52, onTap: busy ? null : () => setState(() => scanning = !scanning)),
          const SizedBox(height: 10),
          MButton('Paste a code', height: 52, onTap: busy
              ? null
              : () async {
                  final clip = await Clipboard.getData('text/plain');
                  final text = clip?.text ?? '';
                  if (text.startsWith('relay-pair:')) {
                    await _pair(text);
                  } else {
                    setState(() => error = 'Copy the pairing code on your Mac first (Pair iPhone → Copy code).');
                  }
                }),
          if (busy) Padding(padding: const EdgeInsets.only(top: 18), child: Text('Pairing…', textAlign: TextAlign.center, style: mt(15, color: MC.text2))),
          if (error != null) Padding(padding: const EdgeInsets.only(top: 18), child: Text(error!, textAlign: TextAlign.center, style: mt(15, color: MC.red))),
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step(this.n, this.text);
  final int n;
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        width: 24,
        height: 24,
        alignment: Alignment.center,
        decoration: const BoxDecoration(color: MC.accent, shape: BoxShape.circle),
        child: Text('$n', style: mt(13, w: FontWeight.w700, color: Colors.white)),
      ),
      const SizedBox(width: 12),
      Expanded(child: Text(text, style: mt(16))),
    ]),
  );
}
