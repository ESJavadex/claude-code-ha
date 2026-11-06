#!/usr/bin/env node
// Terminal reconnect (image-service/public/terminal-reconnect.js): spotting
// ttyd's "Press ⏎ to Reconnect", retrying /health with growing gaps, and
// reloading the terminal frame once the add-on answers.
'use strict';

const assert = require('assert');
const path = require('path');

const publicDir = path.join(__dirname, '../claude-terminal/image-service/public');
const reconnect = require(path.join(publicDir, 'terminal-reconnect.js'));

const tests = [];
function test(name, fn) { tests.push([name, fn]); }

// A frame whose xterm element holds ttyd's overlay, a manual clock, a
// MutationObserver that fires on demand and a scripted /health.
function makeSetup(healthResults) {
    const results = (healthResults || []).slice();
    const overlay = { textContent: '' };
    const xterm = { children: [] };
    let frameDoc;
    let hasTerminal = true;
    function newDoc() {
        return {
            body: {},
            querySelector: sel => (sel === '.xterm' && hasTerminal ? xterm : null)
        };
    }
    frameDoc = newDoc();

    const frameListeners = {};
    const iframe = {
        src: 'terminal/',
        reloads: 0,
        get contentDocument() { return frameDoc; },
        contentWindow: { location: { reload() { iframe.reloads++; } } },
        addEventListener(type, fn) { (frameListeners[type] = frameListeners[type] || []).push(fn); }
    };

    const observers = [];
    const winListeners = {};
    const docListeners = {};
    const win = {
        AbortController,
        MutationObserver: class {
            constructor(cb) { this.cb = cb; this.target = null; observers.push(this); }
            observe(target) { this.target = target; }
            disconnect() { this.target = null; }
        },
        addEventListener(type, fn) { (winListeners[type] = winListeners[type] || []).push(fn); }
    };
    const doc = {
        hidden: false,
        addEventListener(type, fn) { (docListeners[type] = docListeners[type] || []).push(fn); }
    };

    let timers = [];
    let nextId = 1;
    const fetches = [];
    const api = reconnect.install(iframe, {
        window: win,
        document: doc,
        setTimeout(fn, ms) { const id = nextId++; timers.push({ id, fn, ms }); return id; },
        clearTimeout(id) { timers = timers.filter(t => t.id !== id); },
        log() {},
        fetch(url, init) {
            fetches.push({ url, init });
            const r = results.length ? results.shift() : { ok: true };
            return r instanceof Error ? Promise.reject(r) : Promise.resolve(r);
        }
    });

    return {
        api, iframe, fetches,
        get timers() { return timers; },
        setStuck(text) {
            overlay.textContent = text;
            xterm.children = text === null ? [] : [overlay];
            // ttyd appends or changes the overlay: the observer sees it
            for (const o of observers) if (o.target) o.cb([]);
        },
        // Run the pending timer and let its /health promise settle
        async fire() {
            assert.strictEqual(timers.length, 1, `expected one timer, got ${timers.length}`);
            const t = timers.shift();
            await t.fn();
            await new Promise(r => setImmediate(r));
            return t.ms;
        },
        emitWindow(type) { (winListeners[type] || []).forEach(fn => fn()); },
        emitDoc(type) { (docListeners[type] || []).forEach(fn => fn()); },
        frameLoad(terminal = true) {
            hasTerminal = terminal;
            frameDoc = newDoc();
            (frameListeners.load || []).forEach(fn => fn());
        },
        observers,
        doc
    };
}

const STUCK = reconnect.STUCK_TEXT;

test('isStuck: only ttyd\'s "Press ⏎ to Reconnect" overlay counts', () => {
    const doc = children => ({ querySelector: () => ({ children }) });
    assert.strictEqual(STUCK, 'Press ⏎ to Reconnect');
    assert.strictEqual(reconnect.isStuck(doc([{ textContent: STUCK }])), true);
    assert.strictEqual(reconnect.isStuck(doc([{ textContent: 'Reconnecting...' }])), false);
    assert.strictEqual(reconnect.isStuck(doc([])), false);
    assert.strictEqual(reconnect.isStuck({ querySelector: () => null }), false);
    assert.strictEqual(reconnect.isStuck(null), false);
    assert.strictEqual(reconnect.isStuck({ querySelector() { throw new Error('cross-origin'); } }), false);
});

test('nothing happens while the terminal is connected', async () => {
    const s = makeSetup();
    s.setStuck('Reconnecting...');
    assert.strictEqual(s.timers.length, 0);
    s.emitWindow('online');
    s.emitDoc('visibilitychange');
    assert.strictEqual(s.timers.length, 0);
    assert.strictEqual(s.fetches.length, 0);
});

test('stuck, and the add-on answers: the frame is reloaded once', async () => {
    const s = makeSetup([{ ok: true }]);
    s.setStuck(STUCK);
    assert.strictEqual(await s.fire(), 1000);
    assert.deepStrictEqual(s.fetches.map(f => f.url), ['health']);
    assert.strictEqual(s.fetches[0].init.cache, 'no-store');
    assert.strictEqual(s.iframe.reloads, 1);
    assert.strictEqual(s.timers.length, 1, 'navigation watchdog remains active');
    s.setStuck(null);
    s.frameLoad();
    await s.fire();
    assert.strictEqual(s.timers.length, 0);
});

test('a refused session (401) or no network: retries at 1, 2, 5, then every 10 s', async () => {
    const s = makeSetup([{ ok: false, status: 401 }, new Error('offline'), { ok: false, status: 401 },
        { ok: false, status: 502 }, { ok: false, status: 401 }, { ok: true }]);
    s.setStuck(STUCK);
    const delays = [];
    for (let i = 0; i < 6; i++) delays.push(await s.fire());
    assert.deepStrictEqual(delays, [1000, 2000, 5000, 10000, 10000, 10000]);
    assert.strictEqual(s.fetches.length, 6);
    assert.strictEqual(s.iframe.reloads, 1);
});

test('back online or tab shown again: checks at once', async () => {
    const s = makeSetup([{ ok: false, status: 401 }, { ok: true }]);
    s.setStuck(STUCK);
    await s.fire();                       // 401, next try in 2 s
    assert.strictEqual(s.timers[0].ms, 2000);
    s.emitWindow('online');
    assert.strictEqual(s.timers.length, 1);
    assert.strictEqual(s.timers[0].ms, 0);
    await s.fire();
    assert.strictEqual(s.iframe.reloads, 1);

    const t = makeSetup([{ ok: true }]);
    t.setStuck(STUCK);
    t.doc.hidden = true;
    t.emitDoc('visibilitychange');
    assert.strictEqual(t.timers[0].ms, 1000, 'a hidden tab keeps the normal wait');
    t.doc.hidden = false;
    t.emitDoc('visibilitychange');
    assert.strictEqual(t.timers.length, 1);
    assert.strictEqual(t.timers[0].ms, 0);
});

test('reconnected by Enter while /health was pending: no reload', async () => {
    const s = makeSetup([{ ok: true }]);
    s.setStuck(STUCK);
    const t = s.timers.shift();
    const pending = t.fn();
    s.setStuck(null);                     // ttyd reconnected meanwhile
    await pending;
    await new Promise(r => setImmediate(r));
    assert.strictEqual(s.iframe.reloads, 0);
    assert.strictEqual(s.timers.length, 0);
});

test('after a reload, the new frame document is watched', async () => {
    const s = makeSetup([{ ok: true }, { ok: true }]);
    s.setStuck(STUCK);
    await s.fire();
    assert.strictEqual(s.iframe.reloads, 1);
    s.setStuck(null);
    s.frameLoad();
    await s.fire();
    const live = s.observers.filter(o => o.target);
    assert.strictEqual(live.length, 1, 'only the new document is observed');
    s.setStuck(STUCK);
    assert.strictEqual(await s.fire(), 1000, 'the wait starts again from 1 s');
    assert.strictEqual(s.iframe.reloads, 2);
});

test('a hung health request times out and retries', async () => {
    const s = makeSetup([new Promise(() => {}), { ok: true }]);
    s.setStuck(STUCK);
    const pending = s.timers.shift().fn();
    await new Promise(r => setImmediate(r));
    assert.strictEqual(s.timers[0].ms, 10000);
    const signal = s.fetches[0].init.signal;
    s.timers.shift().fn();
    await pending;
    assert.strictEqual(signal.aborted, true);
    assert.strictEqual(s.timers[0].ms, 2000);
    await s.fire();
    assert.strictEqual(s.iframe.reloads, 1);
});

test('failed navigation keeps retrying until a terminal document loads', async () => {
    const s = makeSetup([{ ok: true }, { ok: false, status: 502 }, { ok: true }]);
    s.setStuck(STUCK);
    await s.fire();
    s.setStuck(null);
    s.frameLoad(false); // ingress error page, without xterm
    await s.fire();
    assert.strictEqual(s.iframe.reloads, 1);
    s.emitWindow('online');
    assert.strictEqual(s.timers[0].ms, 0);
    await s.fire();
    assert.strictEqual(s.iframe.reloads, 2);
    s.frameLoad();
    await s.fire();
    assert.strictEqual(s.timers.length, 0);
});

test('a navigation that never loads is retried', async () => {
    const s = makeSetup();
    s.setStuck(STUCK);
    await s.fire();
    await s.fire();
    assert.strictEqual(s.iframe.reloads, 2);
});

(async () => {
    let failed = 0;
    for (const [name, fn] of tests) {
        try {
            await fn();
            console.log(`  ok  ${name}`);
        } catch (err) {
            failed++;
            console.log(`  FAIL ${name}\n       ${err.message}`);
        }
    }
    if (failed) {
        console.log(`Terminal reconnect tests: ${failed} failed`);
        process.exit(1);
    }
    console.log('Terminal reconnect tests passed');
})();
