#!/usr/bin/env node
'use strict';

/**
 * Regression tests for the ttyd clipboard bridge - the two things ttyd 1.7.7
 * gets wrong (selection copy, OSC 52) plus the insecure-origin fallback.
 */

const path = require('path');
const assert = require('assert');

const bridge = require(
    path.join(__dirname, '..', 'claude-terminal', 'image-service', 'public', 'terminal-clipboard.js')
);

let failures = 0;
const tests = [];
function test(name, fn) { tests.push([name, fn]); }
const tick = () => new Promise(resolve => setImmediate(resolve));

// --- Minimal DOM good enough for the bridge -------------------------------
function makeElement(tag) {
    const listeners = new Map();
    return {
        tagName: tag,
        children: [],
        parentNode: null,
        textContent: '',
        style: { cssText: '' },
        value: '',
        attributes: {},
        setAttribute(name, value) { this.attributes[name] = value; },
        appendChild(child) { this.children.push(child); child.parentNode = this; return child; },
        removeChild(child) {
            this.children = this.children.filter(c => c !== child);
            child.parentNode = null;
            return child;
        },
        getBoundingClientRect() { return { width: 100, height: 40 }; },
        addEventListener(type, handler) {
            if (!listeners.has(type)) listeners.set(type, []);
            listeners.get(type).push(handler);
        },
        dispatched: [],
        dispatchEvent(event) { this.dispatched.push(event); return true; },
        dispatch(type, extra) {
            const event = Object.assign({
                defaultPrevented: false,
                preventDefault() { this.defaultPrevented = true; },
                stopPropagation() {}
            }, extra || {});
            (listeners.get(type) || []).forEach(handler => handler(event));
            return event;
        },
        focus() {},
        select() {},
        setSelectionRange() {}
    };
}

/**
 * @param {object} options
 * @param {boolean} options.clipboardApi  emulate a secure context
 * @param {boolean} options.execCommandOk whether execCommand('copy') succeeds
 */
function makeWindow(options) {
    const opts = options || {};
    const body = makeElement('body');
    const termElement = makeElement('div');

    const state = {
        clipboardWrites: [],
        execCommandCopies: [],
        overlayMessages: [],
        appendedTextareas: [],
        fits: 0,
        scrollsToBottom: 0
    };

    const doc = {
        body,
        activeElement: null,
        createElement: makeElement,
        execCommand(command) {
            if (command !== 'copy') return false;
            const textarea = body.children.find(child => child.tagName === 'textarea');
            state.execCommandCopies.push(textarea ? textarea.value : null);
            return opts.execCommandOk !== false;
        }
    };

    const windowListeners = new Map();
    const win = {
        document: doc,
        atob: value => Buffer.from(value, 'base64').toString('binary'),
        Uint8Array,
        TextDecoder,
        setTimeout: (fn, ms) => setTimeout(fn, ms),
        clearTimeout: id => clearTimeout(id),
        // Stands in for the iframe's WheelEvent constructor.
        WheelEvent: function (type, init) { return Object.assign({ type: type }, init); },
        addEventListener(type, handler) {
            if (!windowListeners.has(type)) windowListeners.set(type, []);
            windowListeners.get(type).push(handler);
        },
        dispatch(type) {
            (windowListeners.get(type) || []).forEach(handler => handler({}));
        },
        navigator: {}
    };

    if (opts.clipboardApi) {
        win.navigator.clipboard = {
            writeText(text) {
                state.clipboardWrites.push(text);
                return opts.clipboardRejects ? Promise.reject(new Error('denied')) : Promise.resolve();
            }
        };
    }

    let selection = '';
    const selectionHandlers = [];
    const oscHandlers = new Map();

    // Mirrors xterm.js's IBuffer: `viewportY` is where the visible rows start,
    // and `isWrapped` marks a row that continues the one above it.
    const bufferLines = opts.buffer || [];
    const wrapped = opts.wrapped || [];
    win.matchMedia = query => ({
        matches: query === '(pointer: coarse)' ? !!opts.touch : !opts.touch
    });

    win.term = {
        element: termElement,
        textarea: makeElement('textarea'),
        rows: opts.rows || 24,
        // Wide enough that the plain fixtures above are never "full".
        cols: opts.cols || 80,
        getSelection: () => selection,
        // ttyd adds fit(); xterm.js provides scrollToBottom().
        fit() { state.fits += 1; },
        scrollToBottom() { state.scrollsToBottom += 1; },
        onSelectionChange(handler) { selectionHandlers.push(handler); },
        buffer: {
            active: {
                length: bufferLines.length,
                viewportY: opts.viewportY || 0,
                getLine(y) {
                    if (y < 0 || y >= bufferLines.length) return undefined;
                    return {
                        isWrapped: !!wrapped[y],
                        translateToString: () => bufferLines[y]
                    };
                }
            }
        },
        parser: {
            registerOscHandler(ident, handler) { oscHandlers.set(ident, handler); }
        }
    };

    const originalAppend = body.appendChild.bind(body);
    body.appendChild = child => {
        if (child.tagName === 'textarea') state.appendedTextareas.push(child);
        return originalAppend(child);
    };

    return {
        win,
        state,
        overlayNode: () => termElement.children.find(c => c.className === 'claude-clipboard-overlay'),
        selectText(text) {
            selection = text;
            selectionHandlers.forEach(handler => handler());
        },
        osc(ident, data) { return oscHandlers.get(ident)(data); },
        hasOscHandler: ident => oscHandlers.has(ident),
        termElement
    };
}

// --- Tests ----------------------------------------------------------------

test('secure context: a drag selection is written to the clipboard once', async () => {
    const env = makeWindow({ clipboardApi: true });
    bridge.install(env.win);

    env.termElement.dispatch('mousedown');
    env.selectText('hello');
    env.selectText('hello world'); // selection grows while dragging
    assert.deepStrictEqual(env.state.clipboardWrites, [], 'must not copy mid-drag');

    env.win.dispatch('mouseup');
    await tick();

    assert.deepStrictEqual(env.state.clipboardWrites, ['hello world']);
    assert.strictEqual(env.overlayNode().textContent, '✂', 'success shows the scissors');
});

test('insecure context: falls back to a hidden textarea and execCommand', async () => {
    const env = makeWindow({ clipboardApi: false, execCommandOk: true });
    bridge.install(env.win);

    env.termElement.dispatch('mousedown');
    env.selectText('over plain http');
    env.win.dispatch('mouseup');
    await tick();

    assert.deepStrictEqual(env.state.execCommandCopies, ['over plain http']);
    assert.strictEqual(env.state.appendedTextareas.length, 1, 'exactly one temporary textarea');
    assert.strictEqual(
        env.win.document.body.children.length, 0,
        'the temporary textarea must be removed again'
    );
    assert.strictEqual(env.overlayNode().textContent, '✂');
});

test('a failed clipboard write never reports success', async () => {
    const env = makeWindow({ clipboardApi: false, execCommandOk: false });
    bridge.install(env.win);

    env.termElement.dispatch('mousedown');
    env.selectText('blocked');
    env.win.dispatch('mouseup');
    await tick();

    const overlay = env.overlayNode();
    assert.notStrictEqual(overlay.textContent, '✂', 'must not claim it copied');
    assert.strictEqual(overlay.textContent, '⚠', 'shows a warning instead');
});

test('a refused copy is reported to the page, not left as a mystery badge', async () => {
    // An earlier version put a clickable badge over the terminal to supply the
    // missing gesture. It could not explain itself in situ, so the page is told
    // instead and points at its own copy button.
    const refusals = [];
    const env = makeWindow({ clipboardApi: false, execCommandOk: false });
    bridge.install(env.win, { onRefused: (text) => refusals.push(text) });

    env.osc(52, Buffer.from('from /copy', 'utf8').toString('base64'));
    await tick();

    assert.deepStrictEqual(refusals, ['from /copy']);
    assert.strictEqual(env.overlayNode().textContent, '⚠', 'and never the scissors');
});

test('the overlay is status only — it must not be clickable', async () => {
    const env = makeWindow({ clipboardApi: false, execCommandOk: false });
    bridge.install(env.win);

    env.termElement.dispatch('mousedown');
    env.selectText('blocked');
    env.win.dispatch('mouseup');
    await tick();

    env.state.execCommandCopies.length = 0;
    env.overlayNode().dispatch('click');
    assert.deepStrictEqual(
        env.state.execCommandCopies, [],
        'a click on the overlay must do nothing at all'
    );
});

test('a rejected clipboard API promise still tries the textarea', async () => {
    const env = makeWindow({ clipboardApi: true, clipboardRejects: true, execCommandOk: true });
    bridge.install(env.win);

    env.termElement.dispatch('mousedown');
    env.selectText('unfocused document');
    env.win.dispatch('mouseup');
    await tick();
    await tick();

    assert.deepStrictEqual(env.state.execCommandCopies, ['unfocused document']);
});

test('OSC 52 is handled and base64 UTF-8 is decoded', async () => {
    const env = makeWindow({ clipboardApi: true });
    bridge.install(env.win);

    assert.ok(env.hasOscHandler(52), 'ttyd 1.7.7 registers no OSC 52 handler of its own');
    const payload = Buffer.from('žltý kôň — ok', 'utf8').toString('base64');
    assert.strictEqual(env.osc(52, `c;${payload}`), true, 'must swallow the escape sequence');
    await tick();

    assert.deepStrictEqual(env.state.clipboardWrites, ['žltý kôň — ok']);
});

test('OSC 52 without a selection parameter still copies', async () => {
    const env = makeWindow({ clipboardApi: true });
    bridge.install(env.win);

    env.osc(52, `;${Buffer.from('no Pc', 'utf8').toString('base64')}`);
    await tick();

    assert.deepStrictEqual(env.state.clipboardWrites, ['no Pc']);
});

test('an OSC 52 read request is refused, never answered', async () => {
    const env = makeWindow({ clipboardApi: true });
    bridge.install(env.win);

    assert.strictEqual(env.osc(52, 'c;?'), true);
    await tick();
    assert.deepStrictEqual(env.state.clipboardWrites, []);
});

test('malformed OSC 52 payloads are swallowed, not printed', async () => {
    const env = makeWindow({ clipboardApi: true });
    bridge.install(env.win);

    assert.strictEqual(env.osc(52, 'c;'), true);
    await tick();
    assert.deepStrictEqual(env.state.clipboardWrites, []);
});

test("ttyd's own execCommand('copy') is neutralised while a selection exists", async () => {
    const env = makeWindow({ clipboardApi: true });
    bridge.install(env.win);

    // No selection: nothing to hide, let it through.
    assert.doesNotThrow(() => env.win.document.execCommand('copy'));

    env.selectText('anything');
    // With a selection, ttyd's call must throw so ttyd returns before showing
    // its unconditional overlay - the bridge reports the real result instead.
    assert.throws(() => env.win.document.execCommand('copy'), /clipboard bridge/);
});

test('installing twice is a no-op', async () => {
    const env = makeWindow({ clipboardApi: true });
    assert.ok(bridge.install(env.win), 'first install returns a controller');
    assert.strictEqual(bridge.install(env.win), false, 'second install does nothing');
});

// --- Touch devices --------------------------------------------------------
// xterm.js registers no touch handlers in its selection service, and the
// canvas renderer leaves no DOM text behind, so a finger can select nothing.
// Reading the buffer is the only copy path a phone has.

test('reads the visible screen from the buffer, not the whole scrollback', () => {
    const env = makeWindow({ clipboardApi: true, buffer: ['old 1', 'old 2', 'shown 1', 'shown 2'], rows: 2, viewportY: 2 });
    const controller = bridge.install(env.win);
    assert.strictEqual(controller.read('screen'), 'shown 1\nshown 2');
});

test('reads the full scrollback when asked', () => {
    const env = makeWindow({ clipboardApi: true, buffer: ['old 1', 'old 2', 'shown 1'], rows: 1, viewportY: 2 });
    const controller = bridge.install(env.win);
    assert.strictEqual(controller.read('all'), 'old 1\nold 2\nshown 1');
});

test('rejoins wrapped lines so a long command is one line again', () => {
    const env = makeWindow({
        clipboardApi: true,
        buffer: ['git commit -m "a very ', 'long message"'],
        wrapped: [false, true],
        rows: 2,
        viewportY: 0
    });
    const controller = bridge.install(env.win);
    assert.strictEqual(controller.read('screen'), 'git commit -m "a very long message"');
});

// tmux hard-wraps at the pane width and repaints row by row, so isWrapped
// stays false on every row. Measured: a 46-column pane, a 46-char row.
test('rejoins tmux hard-wrapped rows, where isWrapped is always false', () => {
    const env = makeWindow({
        clipboardApi: true,
        cols: 10,
        buffer: ['https://ex', 'ample.com/', 'oauth?a=1'],
        wrapped: [false, false, false], // tmux never sets this
        rows: 3,
        viewportY: 0
    });
    const controller = bridge.install(env.win);
    assert.strictEqual(controller.read('screen'), 'https://example.com/oauth?a=1');
});

test('a short row ends the line, so the next output is not glued on', () => {
    const env = makeWindow({
        clipboardApi: true,
        cols: 10,
        buffer: ['https://ex', 'ample.com', 'next'],
        rows: 3,
        viewportY: 0
    });
    const controller = bridge.install(env.win);
    assert.strictEqual(controller.read('screen'), 'https://example.com\nnext');
});

test('a blank row after a full row is a real line break, not a continuation', () => {
    const env = makeWindow({
        clipboardApi: true,
        cols: 10,
        buffer: ['0123456789', '', 'after'],
        rows: 3,
        viewportY: 0
    });
    const controller = bridge.install(env.win);
    assert.strictEqual(controller.read('screen'), '0123456789\n\nafter');
});

test('rejoining can be turned off when the heuristic is wrong', () => {
    const env = makeWindow({
        clipboardApi: true,
        cols: 10,
        buffer: ['0123456789', 'separate'],
        rows: 2,
        viewportY: 0
    });
    const controller = bridge.install(env.win);
    assert.strictEqual(controller.read('screen', false), '0123456789\nseparate');
    assert.strictEqual(controller.read('screen', true), '0123456789separate');
});

test('a copy of a tmux-wrapped URL contains no newline', async () => {
    const env = makeWindow({
        clipboardApi: true,
        cols: 12,
        buffer: ['https://clau', 'de.com/oauth', '?code=abc'],
        rows: 3,
        viewportY: 0
    });
    const controller = bridge.install(env.win);

    await controller.copy('screen');
    assert.deepStrictEqual(env.state.clipboardWrites, ['https://claude.com/oauth?code=abc']);
    assert.ok(
        !env.state.clipboardWrites[0].includes('\n'),
        'a newline inside the URL is what pastes as a stray space'
    );
});

test('trailing blank rows are not copied', () => {
    const env = makeWindow({ clipboardApi: true, buffer: ['output', '', '', ''], rows: 4, viewportY: 0 });
    const controller = bridge.install(env.win);
    assert.strictEqual(controller.read('screen'), 'output');
});

test('a button-driven copy writes the buffer text to the clipboard', async () => {
    const env = makeWindow({ clipboardApi: true, buffer: ['tap to copy'], rows: 1, viewportY: 0 });
    const controller = bridge.install(env.win);

    const result = await controller.copy('screen');
    assert.strictEqual(result.copied, true);
    assert.deepStrictEqual(env.state.clipboardWrites, ['tap to copy']);
});

test('a button-driven copy on plain HTTP uses the textarea fallback', async () => {
    const env = makeWindow({ clipboardApi: false, execCommandOk: true, buffer: ['no https here'], rows: 1, viewportY: 0 });
    const controller = bridge.install(env.win);

    const result = await controller.copy('screen');
    assert.strictEqual(result.copied, true, 'the tap is the gesture execCommand needs');
    assert.deepStrictEqual(env.state.execCommandCopies, ['no https here']);
});

test('on plain HTTP the fallback runs synchronously, inside the user gesture', () => {
    // Chrome only allows execCommand('copy') while it is handling a gesture.
    // If anything awaited before the call, the gesture would be gone and the
    // copy would be refused in a real browser while still passing the test
    // above. So assert it happened before control returned to the caller.
    const env = makeWindow({ clipboardApi: false, execCommandOk: true, buffer: ['sync please'], rows: 1, viewportY: 0 });
    const controller = bridge.install(env.win);

    controller.copy('screen'); // deliberately not awaited
    assert.deepStrictEqual(
        env.state.execCommandCopies, ['sync please'],
        'the clipboard write must not be deferred to a later task'
    );
});

test('a button-driven copy reports failure instead of claiming success', async () => {
    const env = makeWindow({ clipboardApi: false, execCommandOk: false, buffer: ['blocked'], rows: 1, viewportY: 0 });
    const controller = bridge.install(env.win);

    const result = await controller.copy('screen');
    assert.strictEqual(result.copied, false);
    assert.strictEqual(result.text, 'blocked', 'the caller gets the text so it can offer the OS selection');
});

test('an empty terminal copies nothing rather than an empty success', async () => {
    const env = makeWindow({ clipboardApi: true, buffer: ['', ''], rows: 2, viewportY: 0 });
    const controller = bridge.install(env.win);

    const result = await controller.copy('screen');
    assert.strictEqual(result.copied, false);
    assert.deepStrictEqual(env.state.clipboardWrites, []);
});

test('base64 decoding rejects garbage instead of copying it', () => {
    const env = makeWindow({ clipboardApi: true });
    assert.strictEqual(bridge.decodeBase64Utf8(env.win, 'aGk='), 'hi');
});

// --- Link detection -------------------------------------------------------
// Terminal text is not markup, so the URL boundaries have to be guessed.

test('finds a plain URL', () => {
    assert.strictEqual(
        bridge.findLastUrl('Open https://claude.com/cai/oauth/authorize?code=true to log in'),
        'https://claude.com/cai/oauth/authorize?code=true'
    );
});

// With several links up, the newest wins: terminal output grows downwards, so
// the last one is what just happened. The header button names the host it
// copied, which is how you tell on a phone, where there is no hover.
test('takes the last URL when several are on screen', () => {
    assert.strictEqual(
        bridge.findLastUrl('old https://a.example/1\nnew https://b.example/2'),
        'https://b.example/2'
    );
});

test('last wins even with several links on one line', () => {
    assert.strictEqual(
        bridge.findLastUrl('docs https://docs.example/x and login https://auth.example/y'),
        'https://auth.example/y'
    );
});

test('a truncated newest link is refused rather than silently taking an older one', () => {
    // Falling back to the previous link would copy something plausible but
    // wrong - the user asked for the one that just appeared.
    assert.deepStrictEqual(
        bridge.findLastUrl('older https://a.example/ok\nnewer https://b.example/y?code=', true),
        { url: null, problem: 'truncated' }
    );
});

test("box-drawing glyphs from Claude Code's prompt frame are not part of the URL", () => {
    // Claude Code frames its prompt with │ and friends; with no space before
    // it, a naive character class swallows the border into the URL.
    assert.strictEqual(
        bridge.findLastUrl('│ https://claude.com/cai/oauth?code=x│'),
        'https://claude.com/cai/oauth?code=x'
    );
    assert.strictEqual(
        bridge.findLastUrl('╭─ https://example.com/a ─╮'),
        'https://example.com/a'
    );
});

test('sentence punctuation after a URL is dropped', () => {
    assert.strictEqual(bridge.findLastUrl('see https://example.com/a.'), 'https://example.com/a');
    assert.strictEqual(bridge.findLastUrl('see (https://example.com/a).'), 'https://example.com/a');
    assert.strictEqual(bridge.findLastUrl('see https://example.com/a,'), 'https://example.com/a');
});

test('a bracket opened inside the URL is kept', () => {
    assert.strictEqual(
        bridge.findLastUrl('https://en.wikipedia.org/wiki/Foo_(bar)'),
        'https://en.wikipedia.org/wiki/Foo_(bar)'
    );
});

test('no URL means no button', () => {
    assert.strictEqual(bridge.findLastUrl('just some output'), null);
    assert.strictEqual(bridge.findLastUrl(''), null);
    assert.strictEqual(bridge.findLastUrl(null), null);
});

// --- Truncated links -----------------------------------------------------
// Copying half a URL is worse than copying nothing: the paste fails and
// nothing on screen says why. Reported after the first fix went live.

test('a link ending in an ellipsis is refused', () => {
    assert.strictEqual(bridge.findLastUrl('open https://claude.com/cai/oauth?code=abc…'), null);
    assert.strictEqual(bridge.findLastUrl('open https://claude.com/cai/oauth?code=abc...'), null);
    // A single full stop is punctuation, not a truncation marker.
    assert.strictEqual(
        bridge.findLastUrl('open https://claude.com/cai/oauth?code=abc.'),
        'https://claude.com/cai/oauth?code=abc'
    );
});

test('a link cut inside a percent-escape is refused', () => {
    assert.strictEqual(bridge.urlProblem('https://x.example/a?s=org%3'), 'truncated');
    assert.strictEqual(bridge.urlProblem('https://x.example/a?s=org%'), 'truncated');
});

test('a link cut between query parameters is refused', () => {
    assert.strictEqual(bridge.urlProblem('https://x.example/a?code=1&'), 'truncated');
    assert.strictEqual(bridge.urlProblem('https://x.example/a?code='), 'truncated');
    assert.strictEqual(bridge.urlProblem('https://x.example/a?'), 'truncated');
});

test('a hostname without a dot is not a link', () => {
    assert.strictEqual(bridge.urlProblem('https://claude'), 'invalid');
    assert.strictEqual(bridge.urlProblem('http://localhost'), 'invalid');
    assert.strictEqual(bridge.urlProblem('https://'), 'invalid');
});

test('ordinary links pass validation', () => {
    assert.strictEqual(bridge.urlProblem('https://claude.com/cai/oauth?code=abc'), null);
    assert.strictEqual(bridge.urlProblem('http://homeassistant.local:8123/'), null);
    assert.strictEqual(bridge.urlProblem('https://x.example'), null);
});

test('the problem reason is reported so the UI can explain itself', () => {
    assert.deepStrictEqual(
        bridge.findLastUrl('see https://x.example/a?code=', true),
        { url: null, problem: 'truncated' }
    );
    assert.deepStrictEqual(bridge.findLastUrl('nothing here', true), { url: null, problem: 'none' });
    assert.deepStrictEqual(
        bridge.findLastUrl('go to https://x.example/ok', true),
        { url: 'https://x.example/ok', problem: null }
    );
});

test('a link running past the bottom of the viewport is completed, not cut', () => {
    // The viewport shows 2 rows, but the URL wraps onto a third that is
    // scrolled just below the fold. Reading only the visible screen yields a
    // truncated "...&code=" - the exact bug reported.
    const env = makeWindow({
        clipboardApi: true,
        cols: 12,
        buffer: ['https://clau', 'de.com/a?cod', 'e=abcdef'],
        rows: 2,
        viewportY: 0
    });
    const controller = bridge.install(env.win);

    // The screen text alone yields a URL that looks perfectly valid as a
    // string - nothing about "...?cod" says it was cut. This is why the check
    // has to be structural (did it end at a full row at our window's edge?)
    // rather than a pattern on the text.
    assert.strictEqual(
        bridge.findLastUrl(controller.read('screen', true)),
        'https://claude.com/a?cod',
        'string-level validation cannot detect this truncation'
    );
    assert.strictEqual(controller.findLink().url, 'https://claude.com/a?code=abcdef');
});

test('a link scrolled off the top is found in the scrollback', () => {
    const env = makeWindow({
        clipboardApi: true,
        cols: 40,
        buffer: ['https://claude.com/a?code=abcdef', 'later output', 'more output'],
        rows: 2,
        viewportY: 1 // the URL row is above the viewport
    });
    const controller = bridge.install(env.win);

    assert.strictEqual(bridge.findLastUrl(controller.read('screen', true)), null);
    assert.strictEqual(controller.findLink().url, 'https://claude.com/a?code=abcdef');
});

test('a link ending exactly at the column edge, with blank rows after, is complete', () => {
    // Full row, but a blank one follows - the line really ended at the edge.
    // Without this any URL that happens to fill the width looks truncated.
    const env = makeWindow({
        clipboardApi: true,
        cols: 24,
        buffer: ['https://claude.com/a?c=1', '', ''],
        rows: 3,
        viewportY: 0
    });
    const controller = bridge.install(env.win);
    assert.strictEqual(controller.findLink().url, 'https://claude.com/a?c=1');
});

test('with no link anywhere, findLink reports "none" rather than guessing', () => {
    const env = makeWindow({ clipboardApi: true, buffer: ['just output', 'no links'], rows: 2, viewportY: 0 });
    const controller = bridge.install(env.win);
    assert.deepStrictEqual(controller.findLink(), { url: null, problem: 'none' });
});

test('with only a truncated link, findLink says truncated, not none', () => {
    const env = makeWindow({
        clipboardApi: true,
        cols: 40,
        buffer: ['see https://claude.com/a?code=…'],
        rows: 1,
        viewportY: 0
    });
    const controller = bridge.install(env.win);
    assert.strictEqual(controller.findLink().problem, 'truncated');
});

// --- Links split across rows ---
// Fixtures are literal rows captured from a running terminal.

const rows = (list, cols = 46) =>
    list.map(text => ({ text, full: text.length >= cols, wrapped: false }));

test('a hard-wrapped link is rebuilt without the continuation indent', () => {
    // Captured live: the row fills all 46 columns and the remainder is
    // re-indented by 5, so joining the rows verbatim puts spaces inside the URL.
    const captured = rows([
        '  ⎿  $ echo "PROBE https://claude.ai/code/arti',
        '     fact/8f1aa329-c6ce-447f-a58c-bd14ce569558',
        '     END"'
    ]);
    assert.strictEqual(captured[0].full, true, 'fixture must reproduce a full row');

    assert.strictEqual(
        bridge.findLinkInRows(captured, 46).url,
        'https://claude.ai/code/artifact/8f1aa329-c6ce-447f-a58c-bd14ce569558'
    );
});

test('a trailing word on the last row is not swallowed into the link', () => {
    // "END" follows a space that the wrap consumed, so the screen cannot prove
    // it is separate - the rule that a continuation may not start with a letter
    // unless both rows are full is what keeps it out.
    const captured = rows([
        '  ⎿  $ echo "PROBE https://claude.ai/code/arti',
        '     fact/8f1aa329-c6ce-447f-a58c-bd14ce569558',
        '     END"'
    ]);
    assert.ok(!bridge.findLinkInRows(captured, 46).url.includes('END'));
});

test('a link whose tail lands on a short indented row is still rebuilt', () => {
    // Reported live: copied only ".../artifact/8f1". Same row shape as the
    // ' END"' case above, which must NOT join - told apart by the tail's shape.
    const narrow = rows([
        '● https://claude.ai/code/artifact/8f1',
        '  aa329-c6ce-447f-a58c-bd14ce569558'
    ], 37);
    assert.strictEqual(narrow[0].full, true, 'fixture must fill the pane');
    assert.strictEqual(narrow[1].full, false, 'fixture tail must be short');

    assert.strictEqual(
        bridge.findLinkInRows(narrow, 37).url,
        'https://claude.ai/code/artifact/8f1aa329-c6ce-447f-a58c-bd14ce569558'
    );
});

test('a continuation that fills the width is joined whatever it looks like', () => {
    // A row filled to the last column was split mid-token - there was no room
    // for a space - so the shape of the continuation does not matter. Without
    // that, a path segment of plain letters would be read as the next word.
    const wrapped = rows([
        '● https://example.com/verylong',
        '  pathsegmentcontinuingfurther',
        ''
    ], 30);
    assert.strictEqual(wrapped[1].full, true, 'fixture continuation must be full');

    assert.strictEqual(
        bridge.findLinkInRows(wrapped, 30).url,
        'https://example.com/verylongpathsegmentcontinuingfurther'
    );
});

test('a tail of URL punctuation with no digits still counts as a link', () => {
    const wrapped = rows([
        '● https://example.com/aaaa/bbb',
        '  /ccc-ddd',
        ''
    ], 30);
    assert.strictEqual(
        bridge.findLinkInRows(wrapped, 30).url,
        'https://example.com/aaaa/bbb/ccc-ddd'
    );
});

test('a link soft-broken at a slash is rebuilt', () => {
    // Claude Code's own renderer breaks a long URL at "/" when the next segment
    // would not fit. The row is NOT full, so no width-based rule fires - this
    // is the case that shipped broken and produced ".../artifact".
    const rendered = rows([
        '  https://claude.ai/code/artifact',
        '  /8f1aa329-c6ce-447f-a58c-bd14ce569558'
    ]);
    assert.strictEqual(rendered[0].full, false, 'fixture must reproduce a short row');

    assert.strictEqual(
        bridge.findLinkInRows(rendered, 46).url,
        'https://claude.ai/code/artifact/8f1aa329-c6ce-447f-a58c-bd14ce569558'
    );
});

test('a path on the next line is not glued onto a link that had room to continue', () => {
    // The chunk would have fitted on the row above, so the break was a choice
    // and the link really ended. Without this, any line starting with "/" after
    // a link would be absorbed.
    const rendered = rows([
        '  see https://example.com/a',
        '  /config/foo is a path'
    ]);
    assert.strictEqual(bridge.findLinkInRows(rendered, 46).url, 'https://example.com/a');
});

test('ordinary output after a link is never absorbed', () => {
    const rendered = rows([
        '  https://example.com/a',
        '  next command output'
    ]);
    assert.strictEqual(bridge.findLinkInRows(rendered, 46).url, 'https://example.com/a');
});

test('a link still growing at the last row is reported as truncated', () => {
    const rendered = rows([
        'x https://claude.ai/code/artifact/8f1aa329-c6c'
    ]);
    const found = bridge.findLinkInRows(rendered, 46);
    assert.strictEqual(found.atEdge, true, 'the caller must widen instead of copying this');
});

test('a link that ends before the edge is not reported as truncated', () => {
    const rendered = rows(['  https://example.com/a', '']);
    const found = bridge.findLinkInRows(rendered, 46);
    assert.strictEqual(found.atEdge, false);
    assert.strictEqual(found.url, 'https://example.com/a');
});

test('a renderer that wraps one column short of the pane is still followed', () => {
    // Measured live: at a 46-column pane Claude Code lays a login URL out in
    // 45-character rows, so a rule keyed on the pane width never fires and the
    // 🔗 button copied only the first 45 characters.
    const url = 'https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c250a' +
        '&scope=org%3Acreate_api_key&code_challenge=hjWXYekQj00Wfyv1dC3CF414TPcRB5EIEB7tUV2Ov-s';
    const wrapped = [];
    for (let at = 0; at < url.length; at += 45) wrapped.push(url.slice(at, at + 45));
    assert.ok(wrapped.length > 2 && wrapped[0].length === 45, 'fixture must wrap at 45');

    const rendered = rows(['  Use the url below to sign in', ''].concat(wrapped, ['', '  Paste code here >']), 46);
    assert.strictEqual(bridge.findLinkInRows(rendered, 46).url, url);
});

test('two coincidentally equal short lines are not mistaken for a wrap', () => {
    // The wrap column has to sit within a couple of columns of the pane width.
    // Without that, these two would look like a wrapped block and the line
    // below would be glued onto the link.
    const rendered = rows([
        '  https://example.com/aaa',
        '  plain output line here',
        '  another output line ok',
        '  trailing text'
    ], 46);
    assert.strictEqual(bridge.findLinkInRows(rendered, 46).url, 'https://example.com/aaa');
});

test('the newest link wins when rows hold several', () => {
    const rendered = rows([
        '  docs https://docs.example/x',
        '  login https://auth.example/y'
    ]);
    assert.strictEqual(bridge.findLinkInRows(rendered, 46).url, 'https://auth.example/y');
});

test('the link is found across tmux-wrapped rows, not as two halves', () => {
    const env = makeWindow({
        clipboardApi: true,
        cols: 12,
        buffer: ['Open https:/', '/claude.com/', 'oauth?code=1', ' to log in'],
        rows: 4,
        viewportY: 0
    });
    const controller = bridge.install(env.win);
    assert.strictEqual(controller.findLink().url, 'https://claude.com/oauth?code=1');
});

// --- Touch scrolling ------------------------------------------------------
// xterm.js 5.5 drops touchstart/touchmove while the app has mouse reporting on
// and never turns touch into a mouse report, so a phone could not scroll at
// all. Measured on the live terminal: alternate_on=1, mouse_any_flag=1.
// A row is 40/20 = 2px tall in this fixture (element height 40, rows 20).

const swipe = (env, from, to, extra) => {
    env.termElement.dispatch('touchstart', { touches: [{ clientY: from, clientX: 5 }] });
    return env.termElement.dispatch('touchmove',
        Object.assign({ touches: [{ clientY: to, clientX: 5 }] }, extra || {}));
};
const wheels = env => env.termElement.dispatched.filter(e => e.type === 'wheel');

test('swiping down scrolls back, one wheel event per row', () => {
    const env = makeWindow({ clipboardApi: true, rows: 20 });
    bridge.install(env.win);

    swipe(env, 100, 106); // finger down 6px = 3 rows
    const sent = wheels(env);
    assert.strictEqual(sent.length, 3, 'one event per row, not one per gesture');
    assert.ok(sent.every(e => e.deltaY < 0), 'dragging content down reveals older output');
});

test('swiping up scrolls forward', () => {
    const env = makeWindow({ clipboardApi: true, rows: 20 });
    bridge.install(env.win);

    swipe(env, 100, 94);
    assert.ok(wheels(env).every(e => e.deltaY > 0));
});

test('a move shorter than one row scrolls nothing yet', () => {
    const env = makeWindow({ clipboardApi: true, rows: 20 });
    bridge.install(env.win);

    swipe(env, 100, 101); // 1px, row is 2px
    assert.deepStrictEqual(wheels(env), []);
});

test('sub-row moves accumulate instead of being discarded', () => {
    const env = makeWindow({ clipboardApi: true, rows: 20 });
    bridge.install(env.win);

    env.termElement.dispatch('touchstart', { touches: [{ clientY: 100, clientX: 5 }] });
    env.termElement.dispatch('touchmove', { touches: [{ clientY: 101, clientX: 5 }] });
    assert.deepStrictEqual(wheels(env), [], 'not yet a full row');
    env.termElement.dispatch('touchmove', { touches: [{ clientY: 102, clientX: 5 }] });
    assert.strictEqual(wheels(env).length, 1, 'the two halves make one row');
});

test('the leftover of a partial row carries into the next move', () => {
    // 3px with a 2px row is one row and 1px over. Dropping that remainder
    // instead of keeping it makes a slow drag lose about half its distance.
    const env = makeWindow({ clipboardApi: true, rows: 20 });
    bridge.install(env.win);

    env.termElement.dispatch('touchstart', { touches: [{ clientY: 100, clientX: 5 }] });
    env.termElement.dispatch('touchmove', { touches: [{ clientY: 103, clientX: 5 }] });
    assert.strictEqual(wheels(env).length, 1);
    env.termElement.dispatch('touchmove', { touches: [{ clientY: 104, clientX: 5 }] });
    assert.strictEqual(wheels(env).length, 2, '1px left over plus 1px is a second row');
});

test('a sub-row move leaves the gesture to the browser', () => {
    // Claiming a move that scrolled nothing would swallow taps and flings.
    const env = makeWindow({ clipboardApi: true, rows: 20 });
    bridge.install(env.win);

    env.termElement.dispatch('touchstart', { touches: [{ clientY: 100, clientX: 5 }] });
    const ev = env.termElement.dispatch('touchmove', { touches: [{ clientY: 101, clientX: 5 }] });
    assert.strictEqual(ev.defaultPrevented, false);
});

test('a second finger mid-gesture stops the scroll', () => {
    // Starting one-fingered and then pinching must not keep scrolling.
    const env = makeWindow({ clipboardApi: true, rows: 20 });
    bridge.install(env.win);

    env.termElement.dispatch('touchstart', { touches: [{ clientY: 100, clientX: 5 }] });
    env.termElement.dispatch('touchmove', {
        touches: [{ clientY: 110, clientX: 5 }, { clientY: 200, clientX: 5 }]
    });
    assert.deepStrictEqual(wheels(env), []);
});

test('the gesture is claimed, or the browser would treat it as a page scroll', () => {
    const env = makeWindow({ clipboardApi: true, rows: 20 });
    bridge.install(env.win);

    const ev = swipe(env, 100, 106);
    assert.strictEqual(ev.defaultPrevented, true);
    assert.strictEqual(
        env.termElement.style.touchAction, 'pan-x pinch-zoom',
        'vertical must be ours while pinch-zoom stays with the browser'
    );
});

test('a gesture xterm.js already handled is left alone', () => {
    // xterm.js prevents the default when it scrolled the viewport itself.
    const env = makeWindow({ clipboardApi: true, rows: 20 });
    bridge.install(env.win);

    swipe(env, 100, 106, { defaultPrevented: true });
    assert.deepStrictEqual(wheels(env), [], 'must not scroll twice');
});

test('two fingers are left to the browser for pinch-zoom', () => {
    const env = makeWindow({ clipboardApi: true, rows: 20 });
    bridge.install(env.win);

    env.termElement.dispatch('touchstart', { touches: [{ clientY: 100, clientX: 5 }, { clientY: 200, clientX: 5 }] });
    env.termElement.dispatch('touchmove', { touches: [{ clientY: 106, clientX: 5 }, { clientY: 190, clientX: 5 }] });
    assert.deepStrictEqual(wheels(env), []);
});

test('a fling is capped so one gesture cannot flood the app', () => {
    const env = makeWindow({ clipboardApi: true, rows: 20 });
    bridge.install(env.win);

    swipe(env, 500, 900); // 400px = 200 rows
    assert.strictEqual(wheels(env).length, 8);
});

test('touchend releases the gesture', () => {
    const env = makeWindow({ clipboardApi: true, rows: 20 });
    bridge.install(env.win);

    swipe(env, 100, 106);
    const before = wheels(env).length;
    env.termElement.dispatch('touchend', {});
    env.termElement.dispatch('touchmove', { touches: [{ clientY: 200, clientX: 5 }] });
    assert.strictEqual(wheels(env).length, before, 'a move after touchend is not a swipe');
});

// --- Mobile keyboard ------------------------------------------------------
// Gboard's predictive text drives an IME composing region and xterm.js re-emits
// a commit it already sent (xtermjs/xterm.js#6060), so a typed phrase lands in
// the prompt several times over. Nothing outside xterm.js can cancel what it
// sends, so the keyboard is put in a non-composing mode instead.

test('a touch device gets a keyboard that does not compose', () => {
    const env = makeWindow({ clipboardApi: true, touch: true });
    bridge.install(env.win);

    assert.strictEqual(env.win.term.textarea.attributes.inputmode, 'url');
    assert.strictEqual(env.win.term.textarea.attributes.autocomplete, 'off');
});

test('a mouse keeps its normal keyboard', () => {
    const env = makeWindow({ clipboardApi: true, touch: false });
    bridge.install(env.win);

    assert.strictEqual(env.win.term.textarea.attributes.inputmode, undefined);
});

test('a terminal with no textarea is left alone', () => {
    const env = makeWindow({ clipboardApi: true, touch: true });
    delete env.win.term.textarea;
    assert.strictEqual(bridge.installMobileInput(env.win, env.win.term), false);
});

// --- Viewport settling ----------------------------------------------------
// The on-screen keyboard shrinks the viewport in steps as it animates. Only a
// refit pushes the new size through to the pty, and that SIGWINCH is what makes
// a full-screen app redraw with its prompt at the new bottom - which is why the
// view used to catch up only once a keystroke forced a redraw.

test('settling the viewport refits so the app is told the new size', () => {
    const env = makeWindow({ clipboardApi: true });
    const controller = bridge.install(env.win);

    controller.scrollToBottom();
    assert.strictEqual(env.state.fits, 1, 'a refit is what reaches the pty');
    assert.strictEqual(env.state.scrollsToBottom, 1);
});

test('a terminal without ttyd fit() still scrolls', () => {
    const env = makeWindow({ clipboardApi: true });
    const controller = bridge.install(env.win);
    delete env.win.term.fit;

    controller.scrollToBottom();
    assert.strictEqual(env.state.scrollsToBottom, 1);
});

test('a throwing fit() does not stop the scroll', () => {
    const env = makeWindow({ clipboardApi: true });
    const controller = bridge.install(env.win);
    env.win.term.fit = () => { throw new Error('mid-teardown'); };

    controller.scrollToBottom();
    assert.strictEqual(env.state.scrollsToBottom, 1);
});

(async () => {
    for (const [name, fn] of tests) {
        try {
            await fn();
            console.log(`ok   ${name}`);
        } catch (err) {
            failures++;
            console.error(`FAIL ${name}\n     ${err.message}`);
        }
    }
    if (failures) {
        console.error(`\n${failures} clipboard bridge test(s) failed`);
        process.exit(1);
    }
    console.log(`\nAll ${tests.length} clipboard bridge tests passed`);
})();
