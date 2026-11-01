#!/usr/bin/env node
// Uploads through ingress arrive the way the Supervisor forwards them with
// ingress_stream: chunked, with no Content-Length. A file over the
// Supervisor's 16 MiB buffer limit must be stored whole, and one over our
// own limit must get our "File too large" message, not a hang or a bare error.
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
const MB = 1024 * 1024;

// Without ingress_stream none of this reaches the add-on through the panel
const config = fs.readFileSync(path.join(import.meta.dirname, '../claude-terminal/config.yaml'), 'utf8');
assert.match(config, /^ingress_stream: true$/m, 'config.yaml must set ingress_stream: true');

const freePort = () => new Promise((resolve, reject) => {
    const s = net.createServer().listen(0, '127.0.0.1', () => {
        const { port } = s.address();
        s.close(() => resolve(port));
    }).on('error', reject);
});

// A multipart upload written in 1 MiB chunks with Transfer-Encoding: chunked
function streamedUpload(port, name, size) {
    const boundary = 'streamed-upload-test';
    return new Promise((resolve, reject) => {
        const req = http.request({
            host: '127.0.0.1', port, method: 'POST', path: '/upload',
            headers: { 'Content-Type': `multipart/form-data; boundary=${boundary}` }
        }, (res) => {
            let body = '';
            res.setEncoding('utf8');
            res.on('data', (c) => { body += c; });
            res.on('end', () => resolve({ status: res.statusCode, body }));
        });
        // The server may answer and close before the body is all sent
        req.on('error', (err) => (err.code === 'EPIPE' || err.code === 'ECONNRESET') ? null : reject(err));
        assert.strictEqual(req.getHeader('content-length'), undefined);
        req.write(`--${boundary}\r\nContent-Disposition: form-data; name="file"; filename="${name}"\r\n` +
            'Content-Type: application/octet-stream\r\n\r\n');
        const chunk = Buffer.alloc(MB, 0x61);
        let left = size;
        const pump = () => {
            while (left > 0) {
                const part = left >= MB ? chunk : chunk.subarray(0, left);
                left -= part.length;
                if (!req.write(part)) return req.once('drain', pump);
            }
            req.end(`\r\n--${boundary}--\r\n`);
        };
        pump();
    });
}

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'upload-streamed-'));
const port = await freePort();
const child = spawn(process.execPath, [server], {
    cwd: path.dirname(server),
    env: { ...process.env, UPLOAD_DIR: dir, IMAGE_SERVICE_PORT: String(port) },
    stdio: ['ignore', 'ignore', 'inherit']
});

try {
    for (let i = 0; ; i++) {
        try {
            if ((await fetch(`http://127.0.0.1:${port}/health`)).ok) break;
        } catch {}
        // Up to 30 s, like CI's /health check
        if (i > 300) throw new Error('image service did not start');
        await new Promise((r) => setTimeout(r, 100));
    }

    const big = await streamedUpload(port, 'twenty.bin', 20 * MB);
    assert.strictEqual(big.status, 200, `20 MiB streamed upload failed: ${big.body}`);
    const stored = JSON.parse(big.body).path;
    assert.strictEqual(fs.statSync(stored).size, 20 * MB, 'stored file is not the whole upload');
    console.log('ok   a 20 MiB upload with no Content-Length is stored whole');

    const tooBig = await streamedUpload(port, 'too-big.bin', 51 * MB);
    assert.strictEqual(tooBig.status, 400, `expected our 400, got ${tooBig.status}`);
    assert.match(tooBig.body, /File too large \(the limit is 50 MB\)/);
    assert.deepStrictEqual(fs.readdirSync(dir), [path.basename(stored)], 'the rejected upload left a file behind');
    console.log('ok   a streamed upload over 50 MB gets our "File too large" message and leaves no file');
} finally {
    child.kill();
    fs.rmSync(dir, { recursive: true, force: true });
}
