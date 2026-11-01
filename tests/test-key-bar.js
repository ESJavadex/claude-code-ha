#!/usr/bin/env node
// Phone key bar (image-service/public/key-bar.js): what each key sends, the
// Ctrl+C guard, and that a tap never takes the focus from the terminal.
'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');

const publicDir = path.join(__dirname, '../claude-terminal/image-service/public');
const keyBar = require(path.join(publicDir, 'key-bar.js'));

const tests = [];
function test(name, fn) { tests.push([name, fn]); }

function makeButton(key, label, bar) {
    const classes = new Set();
    return {
        dataset: { key },
        textContent: label,
        parentNode: bar,
        classList: {
            add: c => classes.add(c),
            remove: c => classes.delete(c),
            contains: c => classes.has(c)
        }
    };
}

// A bar with one button per key, a fake term and a manual clock.
function makeBar(options) {
    const opts = options || {};
    const listeners = {};
    const bar = {
        dataset: {},
        addEventListener(type, fn, listenerOptions) {
            (listeners[type] = listeners[type] || []).push({ fn, options: listenerOptions });
        }
    };
    const buttons = {};
    for (const [key, label] of [['esc', 'Esc'], ['up', '↑'], ['down', '↓'], ['tab', 'Tab'], ['shift-tab', '⇧Tab'],
        ['ctrl-c', '^C'], ['newline', '⇧↵'], ['enter', '↵'], ['bogus', '?']]) {
        buttons[key] = makeButton(key, label, bar);
    }
    const sent = [];
    let term = opts.noTerm ? null : {
        modes: { applicationCursorKeysMode: !!opts.appCursor },
        input(data, wasUserInput) { sent.push([data, wasUserInput]); }
    };
    let now = 0;
    const timers = [];
    keyBar.install(bar, () => term, {
        now: () => now,
        setTimeout: (fn, ms) => timers.push({ fn, at: now + ms })
    });

    function fire(type, target) {
        let prevented = false;
        const event = { target, preventDefault() { prevented = true; } };
        (listeners[type] || []).forEach(l => l.fn(event));
        return prevented;
    }

    return {
        bar, buttons, sent, listeners,
        tap: key => fire('click', buttons[key]),
        fire,
        advance(ms) {
            now += ms;
            timers.filter(t => t.at <= now && !t.done).forEach(t => { t.done = true; t.fn(); });
        },
        setTerm(t) { term = t; }
    };
}

test('each key sends what xterm.js sends for the real key', () => {
    const env = makeBar();
    for (const key of ['esc', 'up', 'down', 'tab', 'shift-tab', 'ctrl-c', 'newline', 'enter']) env.tap(key);
    assert.deepStrictEqual(env.sent.map(([data]) => data),
        ['\x1b', '\x1b[A', '\x1b[B', '\t', '\x1b[Z', '\x03', '\\\r', '\r']);
    assert.ok(env.sent.every(([, user]) => user === true), 'sent as user input');
});

test('arrows follow the cursor-key mode of full-screen programs', () => {
    const env = makeBar({ appCursor: true });
    env.tap('up');
    env.tap('down');
    env.tap('esc');
    assert.deepStrictEqual(env.sent.map(([data]) => data), ['\x1bOA', '\x1bOB', '\x1b']);
});

test('an unknown key sends nothing', () => {
    const env = makeBar();
    env.tap('bogus');
    assert.strictEqual(keyBar.keySequence('constructor'), null);
    assert.deepStrictEqual(env.sent, []);
});

test('a second Ctrl+C inside two seconds is held back, and the key says wait', () => {
    const env = makeBar();
    env.tap('ctrl-c');
    assert.strictEqual(env.buttons['ctrl-c'].textContent, 'wait');
    assert.ok(env.buttons['ctrl-c'].classList.contains('key-wait'));

    env.advance(1999);
    env.tap('ctrl-c');
    assert.strictEqual(env.sent.length, 1, 'double tap must not quit Claude Code');

    env.advance(1);
    assert.strictEqual(env.buttons['ctrl-c'].textContent, '^C', 'label restored');
    assert.ok(!env.buttons['ctrl-c'].classList.contains('key-wait'));
    env.tap('ctrl-c');
    assert.strictEqual(env.sent.length, 2, 'allowed again after the window');
});

test('other keys are never held back', () => {
    const env = makeBar();
    env.tap('enter');
    env.tap('enter');
    env.tap('up');
    env.tap('up');
    assert.strictEqual(env.sent.length, 4);
});

test('a tap keeps the focus in the terminal, so the on-screen keyboard stays open', () => {
    const env = makeBar();
    assert.ok(env.fire('pointerdown', env.buttons.enter), 'pointerdown cancelled');
    assert.ok(env.fire('mousedown', env.buttons.enter), 'mousedown cancelled');
    assert.ok(!env.fire('pointerdown', env.bar), 'the gap between keys is left alone');
});

test('the touchstart listener is passive, so it cannot cancel the click', () => {
    const env = makeBar();
    const touch = env.listeners.touchstart;
    assert.strictEqual(touch.length, 1);
    assert.deepStrictEqual(touch[0].options, { passive: true });
});

test('before the terminal is up a tap does nothing, and the next terminal is used', () => {
    const env = makeBar({ noTerm: true });
    env.tap('enter');
    assert.deepStrictEqual(env.sent, []);

    const reconnected = [];
    env.setTerm({ modes: {}, input: data => reconnected.push(data) });
    env.tap('enter');
    assert.deepStrictEqual(reconnected, ['\r']);
});

test('installing twice is a no-op', () => {
    const bar = { addEventListener() {} };
    assert.strictEqual(keyBar.install(bar, () => null), true);
    assert.strictEqual(keyBar.install(bar, () => null), false);
});

test('the page loads the key bar and shows it on touch screens only', () => {
    const page = fs.readFileSync(path.join(publicDir, 'index.html'), 'utf8');
    assert.ok(page.includes('<script src="key-bar.js"></script>'));
    assert.ok(page.includes('ClaudeKeyBar.install(document.getElementById(\'key-bar\')'));
    assert.match(page, /@media \(pointer: coarse\) \{\s*#key-bar \{\s*display: flex;/);
    for (const key of ['esc', 'up', 'down', 'tab', 'shift-tab', 'ctrl-c', 'newline', 'enter']) {
        assert.ok(page.includes(`data-key="${key}"`), `${key} key missing`);
        assert.notStrictEqual(keyBar.keySequence(key), null, `${key} sends nothing`);
    }
});

let failures = 0;
for (const [name, fn] of tests) {
    try {
        fn();
        console.log(`ok   ${name}`);
    } catch (err) {
        failures++;
        console.error(`FAIL ${name}\n     ${err.message}`);
    }
}
if (failures) {
    console.error(`\n${failures} key bar test(s) failed`);
    process.exit(1);
}
console.log(`\nAll ${tests.length} key bar tests passed`);
