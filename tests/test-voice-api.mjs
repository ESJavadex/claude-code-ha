import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';

const moduleUrl = process.argv[2] ? pathToFileURL(process.argv[2]) : new URL('../claude-terminal/image-service/voice-api.mjs', import.meta.url);
const { register, MAX_AUDIO_BYTES } = await import(moduleUrl);
const require = createRequire(moduleUrl);
const express = require('express');
const capabilities = { languages: ['en', 'de-DE'], formats: ['wav'], codecs: ['pcm'], sample_rates: [16000], bit_rates: [16], channels: [1] };
const json = (value) => Response.json(value);
const headers = { 'Content-Type': 'application/octet-stream', 'X-Voice-Request': '1', 'X-Voice-Language': 'en-US' };
let passed = 0;

async function test(name, options, run) {
    const app = express();
    register(app, { token: 'server-only-secret', provider: 'stt.whisper', ...options });
    const server = app.listen(0, '127.0.0.1');
    await new Promise((resolve) => server.once('listening', resolve));
    const base = `http://127.0.0.1:${server.address().port}`;
    const post = (body = new Uint8Array([0, 0]), customHeaders = headers, signal) => fetch(`${base}/api/voice/transcribe`, { method: 'POST', headers: customHeaders, body, signal });
    try {
        await run({ base, post });
        console.log(`ok   ${name}`);
        passed++;
    } finally {
        server.closeAllConnections();
        await new Promise((resolve) => server.close(resolve));
    }
}

await test('fixed Supervisor destination, server-only token, raw PCM and language matching', {
    request: async (url, options) => {
        assert.equal(url, 'http://supervisor/core/api/stt/stt.whisper');
        assert.equal(options.headers.Authorization, 'Bearer server-only-secret');
        assert.equal(options.redirect, 'error');
        if (!options.method) return json(capabilities);
        assert.equal(options.method, 'POST');
        assert.equal(options.headers['X-Speech-Content'], 'format=wav; codec=pcm; sample_rate=16000; bit_rate=16; channel=1; language=en');
        assert.deepEqual([...options.body], [0, 0]);
        return json({ result: 'success', text: '<script>literal transcript</script>' });
    }
}, async ({ base, post }) => {
    const config = await fetch(`${base}/api/voice/config`);
    assert.equal(config.headers.get('cache-control'), 'no-store');
    assert.deepEqual(await config.json(), { enabled: true, configured: true, language: '' });
    const result = await post();
    assert.equal(result.status, 200);
    assert.equal(result.headers.get('cache-control'), 'no-store');
    assert.deepEqual(await result.json(), { text: '<script>literal transcript</script>' });
});

for (const options of [{ token: '' }, { provider: 'http://evil.test/steal' }, { provider: '../config' }]) {
    await test('unconfigured or invalid providers never make outbound requests', {
        ...options, request: () => { assert.fail('outbound call'); }
    }, async ({ base, post }) => {
        const config = await (await fetch(`${base}/api/voice/config`)).json();
        assert.equal(config.enabled, false);
        assert.equal(config.configured, true); // never silently fall back to a browser cloud service
        assert.equal((await post()).status, 503);
    });
}
await test('cross-site forms, wrong content types and malformed PCM are refused', {
    request: () => { assert.fail('outbound call'); }
}, async ({ post }) => {
    assert.equal((await post('data', {})).status, 403);
    assert.equal((await post('data', { ...headers, 'Content-Type': 'text/plain' })).status, 415);
    assert.equal((await post(new Uint8Array())).status, 400);
    assert.equal((await post(new Uint8Array([1]))).status, 400);
    assert.equal((await post(undefined, { ...headers, 'X-Voice-Language': 'en; host=evil' })).status, 400);
    assert.equal((await post(new Uint8Array(MAX_AUDIO_BYTES + 2))).status, 413);
    assert.equal((await post(new Uint8Array([1]))).status, 400); // parser error released the slot
});
await test('unsupported language or audio formats never submit audio', {
    request: async (_, options) => {
        assert.equal(options.method, undefined);
        return json(capabilities);
    }
}, async ({ post }) => assert.equal((await post(undefined, { ...headers, 'X-Voice-Language': 'fr' })).status, 400));
await test('unsupported STT formats are explained', {
    request: async () => json({ ...capabilities, codecs: ['opus'] })
}, async ({ post }) => assert.equal((await post()).status, 400));
await test('upstream error details, including tokens, are never returned', {
    request: async () => { throw new Error('server-only-secret'); }
}, async ({ post }) => {
    const response = await post();
    assert.equal(response.status, 502);
    assert.doesNotMatch(await response.text(), /server-only-secret/);
});
await test('oversized upstream responses are bounded', {
    request: async () => new Response('x'.repeat(65537))
}, async ({ post }) => assert.equal((await post()).status, 502));
await test('failed transcriptions do not become successful text', {
    request: async (_, options) => json(options.method ? { result: 'error', text: 'bad' } : capabilities)
}, async ({ post }) => assert.equal((await post()).status, 502));
await test('timeouts abort upstream work and release the transcription slot', {
    timeoutMs: 25,
    request: (_, { signal }) => new Promise((_, reject) => {
        signal.addEventListener('abort', () => reject(new Error('aborted')), { once: true });
    })
}, async ({ post }) => {
    assert.equal((await post()).status, 502);
    assert.equal((await post()).status, 502);
});
let started;
let release;
const startedPromise = new Promise((resolve) => { started = resolve; });
await test('only one recording is processed at a time', {
    request: async (_, options) => {
        if (options.method) return json({ result: 'success', text: 'hello' });
        started();
        await new Promise((resolve) => { release = resolve; });
        return json(capabilities);
    }
}, async ({ post }) => {
    const first = post();
    await startedPromise;
    assert.equal((await post()).status, 409);
    release();
    assert.equal((await first).status, 200);
});
let upstreamAborted = false;
let connected;
const connectedPromise = new Promise((resolve) => { connected = resolve; });
await test('closing the browser request aborts the upstream request', {
    request: (_, { signal }) => new Promise((_, reject) => {
        connected();
        signal.addEventListener('abort', () => { upstreamAborted = true; reject(new Error('aborted')); }, { once: true });
    })
}, async ({ post }) => {
    const controller = new AbortController();
    const first = post(undefined, headers, controller.signal).catch(() => {});
    await connectedPromise;
    controller.abort();
    await first;
    for (let i = 0; i < 50 && !upstreamAborted; i++) await new Promise((resolve) => setTimeout(resolve, 10));
    assert.equal(upstreamAborted, true);
});
console.log(`All ${passed} voice API tests passed`);
