#!/usr/bin/env node
// The panel opens as soon as the image service answers, a few seconds before
// run.sh starts ttyd. Until ttyd listens, the terminal frame must get a page
// that reloads itself, not a bare 502 that stays on screen; other requests
// still get the 502. Once ttyd listens, requests go through to it.
// Needs the service's npm dependencies; the server path is the first argument
// (default: the repo copy, which needs `npm install` in image-service).
import assert from 'node:assert';
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
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

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'terminal-starting-'));
const port = await freePort();
const ttydPort = await freePort();
const child = spawn(process.execPath, [server], {
    cwd: path.dirname(server),
    env: { ...process.env, UPLOAD_DIR: dir, IMAGE_SERVICE_PORT: String(port), TTYD_PORT: String(ttydPort) },
    stdio: ['ignore', 'ignore', 'ignore']
});
const base = `http://127.0.0.1:${port}`;
let ttyd;

try {
    for (let i = 0; ; i++) {
        try {
            if ((await fetch(`${base}/health`)).ok) break;
        } catch {}
        // Up to 30 s, like CI's /health check
        if (i > 300) throw new Error('image service did not start');
        await new Promise((r) => setTimeout(r, 100));
    }

    // What the iframe asks for: a document
    const page = await fetch(`${base}/terminal/`, { headers: { Accept: 'text/html,*/*;q=0.8' } });
    assert.strictEqual(page.status, 503, `expected the starting page, got ${page.status}`);
    assert.strictEqual(page.headers.get('cache-control'), 'no-store', 'the starting page may be cached');
    const html = await page.text();
    assert.match(html, /<meta http-equiv="refresh" content="1">/, 'the starting page does not reload itself');
    assert.match(html, /Starting the terminal/);
    console.log('ok   before ttyd listens, the terminal frame gets a page that reloads itself');

    const token = await fetch(`${base}/terminal/token`, { headers: { Accept: 'application/json' } });
    assert.strictEqual(token.status, 502, `expected a 502 for a non-page request, got ${token.status}`);
    console.log('ok   other requests still get a 502');

    ttyd = http.createServer((req, res) => res.end('ttyd page')).listen(ttydPort, '127.0.0.1');
    await new Promise((r) => ttyd.once('listening', r));
    const ready = await fetch(`${base}/terminal/`, { headers: { Accept: 'text/html' } });
    assert.strictEqual(ready.status, 200);
    assert.strictEqual(await ready.text(), 'ttyd page');
    console.log('ok   once ttyd listens, the frame gets its page');
} finally {
    child.kill();
    ttyd?.close();
    fs.rmSync(dir, { recursive: true, force: true });
}
