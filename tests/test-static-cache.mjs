#!/usr/bin/env node
// The panel's page and scripts must be revalidated on every load, so an
// add-on update takes effect without a hard refresh, and revalidation must
// stay cheap (a 304 from the ETag).
// Needs the service's npm dependencies; the server path is the first argument
// (default: the repo copy, which needs `npm install` in image-service).
import assert from 'node:assert';
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';

const server = path.resolve(process.argv[2] ||
    path.join(import.meta.dirname, '../claude-terminal/image-service/server.mjs'));

const freePort = () => new Promise((resolve, reject) => {
    const s = net.createServer().listen(0, '127.0.0.1', () => {
        const { port } = s.address();
        s.close(() => resolve(port));
    }).on('error', reject);
});

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'static-cache-'));
const port = await freePort();
const child = spawn(process.execPath, [server], {
    cwd: path.dirname(server),
    env: { ...process.env, UPLOAD_DIR: dir, IMAGE_SERVICE_PORT: String(port) },
    stdio: ['ignore', 'ignore', 'inherit']
});
const base = `http://127.0.0.1:${port}`;

try {
    for (let i = 0; ; i++) {
        try {
            if ((await fetch(`${base}/health`)).ok) break;
        } catch {}
        // Up to 30 s, like CI's /health check
        if (i > 300) throw new Error('image service did not start');
        await new Promise((r) => setTimeout(r, 100));
    }

    for (const file of ['/', '/terminal-clipboard.js', '/voice-input.mjs']) {
        const res = await fetch(base + file);
        assert.strictEqual(res.status, 200, `${file} not served`);
        assert.strictEqual(res.headers.get('cache-control'), 'no-cache', `${file} may be cached`);
        const etag = res.headers.get('etag');
        assert.ok(etag, `${file} has no ETag`);
        // fetch adds "Cache-Control: no-cache" to a conditional request unless
        // one is given, and Express never answers that with a 304. Browsers
        // revalidate with max-age=0.
        const again = await fetch(base + file, {
            headers: { 'If-None-Match': etag, 'Cache-Control': 'max-age=0' }
        });
        assert.strictEqual(again.status, 304, `${file} is not revalidated by its ETag`);
    }
    console.log('ok   the page and its scripts are served no-cache and revalidate with a 304');
} finally {
    child.kill();
    fs.rmSync(dir, { recursive: true, force: true });
}
