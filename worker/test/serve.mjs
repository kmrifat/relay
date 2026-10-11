// Runs the Worker locally (Miniflare: workerd, local R2 and Durable Objects)
// and prints its URL. Used by relay_sync's Worker tests.
//   node test/serve.mjs [setup-token]
import { Miniflare } from 'miniflare';
import { fileURLToPath } from 'node:url';

export function start(setupToken = 'setup-secret', port = 0) {
  return new Miniflare({
    modules: true,
    scriptPath: fileURLToPath(new URL('../src/index.js', import.meta.url)),
    compatibilityDate: '2026-07-01',
    r2Buckets: ['BUCKET'],
    durableObjects: { ROOM: 'TeamRoom' },
    bindings: { SETUP_TOKEN: setupToken },
    port,
  });
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const mf = start(process.argv[2], Number(process.argv[3] ?? 0));
  const url = await mf.ready;
  console.log(url.href.replace(/\/$/, ''));
  process.on('SIGTERM', async () => {
    await mf.dispose();
    process.exit(0);
  });
}
