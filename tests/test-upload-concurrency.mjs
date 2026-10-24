#!/usr/bin/env node
// Concurrent uploads of the same file name through the real image service:
// every upload must get its own path and keep its own contents.
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
const UPLOADS = 50;

const freePort = () => new Promise((resolve, reject) => {
    const s = net.createServer().listen(0, '127.0.0.1', () => {
        const { port } = s.address();
        s.close(() => resolve(port));
    }).on('error', reject);
});

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'upload-race-'));
const port = await freePort();
// slow-open.mjs widens the race window, so the old check-then-create
// naming fails every run instead of now and then
const slowOpen = path.join(import.meta.dirname, 'helpers', 'slow-open.mjs');
const child = spawn(process.execPath, ['--import', slowOpen, server], {
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
        if (i > 50) throw new Error('image service did not start');
        await new Promise((r) => setTimeout(r, 100));
    }

    const results = await Promise.all(Array.from({ length: UPLOADS }, async (_, i) => {
        // Distinct payloads of different lengths, so a truncated or
        // overwritten file can't pass by accident
        const payload = `upload ${i} `.repeat(1000 + i);
        const form = new FormData();
        form.append('file', new Blob([payload], { type: 'text/plain' }), 'same-name.txt');
        const res = await fetch(`${base}/upload`, { method: 'POST', body: form });
        assert.strictEqual(res.status, 200, `upload ${i} failed`);
        return { payload, ...(await res.json()) };
    }));

    const paths = results.map((r) => r.path);
    assert.strictEqual(new Set(paths).size, UPLOADS, 'two uploads were given the same path');
    for (const r of results) {
        assert.strictEqual(fs.readFileSync(r.path, 'utf8'), r.payload, `${r.path} holds another upload`);
    }
    assert.strictEqual(fs.readdirSync(dir).length, UPLOADS);
    console.log(`ok   ${UPLOADS} concurrent same-name uploads each kept their own path and contents`);
} finally {
    child.kill();
    fs.rmSync(dir, { recursive: true, force: true });
}
