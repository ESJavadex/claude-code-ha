/**
 * Phone key bar (index.html #key-bar): the keys Claude Code needs that an
 * on-screen keyboard lacks - Esc, arrows, Tab, Shift+Tab, Ctrl+C, a new line
 * and Enter. Each sends what xterm.js would send for the real key, through
 * term.input(), so it goes out exactly like typed keys.
 *
 * Adapted from Claude Workbench 3.5.0 (Eifel-Joe/claude-workbench), with the
 * DECCKM arrows from mattbsea's fork (ed215953).
 */
(function (root, factory) {
    'use strict';
    var api = factory();
    if (typeof module === 'object' && module.exports) {
        module.exports = api;
    }
    if (root) {
        root.ClaudeKeyBar = api;
    }
})(typeof self !== 'undefined' ? self : null, function () {
    'use strict';

    var KEYBAR_FLAG = '__claudeKeyBarInstalled';
    var CTRL_C_WINDOW_MS = 2000;

    // 'newline' is backslash + return, which Claude Code reads as "insert a
    // newline": an on-screen keyboard has no Shift+Enter.
    var KEY_SEQUENCES = {
        'esc': '\x1b',
        'up': '\x1b[A',
        'down': '\x1b[B',
        'tab': '\t',
        'shift-tab': '\x1b[Z',
        'ctrl-c': '\x03',
        'newline': '\\\r',
        'enter': '\r'
    };
    // Full-screen programs switch the arrows to the SS3 form (DECCKM), so the
    // mode is read on every tap.
    var APP_CURSOR_SEQUENCES = { 'up': '\x1bOA', 'down': '\x1bOB' };

    function has(map, name) {
        return Object.prototype.hasOwnProperty.call(map, name);
    }

    function keySequence(name, term) {
        if (!has(KEY_SEQUENCES, name)) return null;
        var appCursor = !!(term && term.modes && term.modes.applicationCursorKeysMode === true);
        if (appCursor && has(APP_CURSOR_SEQUENCES, name)) return APP_CURSOR_SEQUENCES[name];
        return KEY_SEQUENCES[name];
    }

    /**
     * Two Ctrl+C in a row quit Claude Code, and on a phone a double tap is
     * easy. Lets one through per window, counted from the last one let through.
     */
    function createCtrlCGuard(now, windowMs) {
        var clock = now || Date.now;
        var span = windowMs === undefined ? CTRL_C_WINDOW_MS : windowMs;
        var lastSent = null;
        return function allow() {
            var t = clock();
            if (lastSent !== null && t - lastSent < span) return false;
            lastSent = t;
            return true;
        };
    }

    /**
     * Wire the bar. getTerm is asked on every tap: the ttyd frame reloads on
     * reconnect and then has a new term. pointerdown and mousedown are
     * cancelled so a tap doesn't move the focus out of the terminal - that
     * would close the on-screen keyboard.
     */
    function install(bar, getTerm, options) {
        if (!bar || bar[KEYBAR_FLAG]) return false;
        bar[KEYBAR_FLAG] = true;
        var opts = options || {};
        var windowMs = opts.ctrlCWindowMs === undefined ? CTRL_C_WINDOW_MS : opts.ctrlCWindowMs;
        var allowCtrlC = createCtrlCGuard(opts.now, windowMs);
        var later = opts.setTimeout || function (fn, ms) { return setTimeout(fn, ms); };

        function keyButton(target) {
            for (var el = target; el && el !== bar; el = el.parentNode) {
                if (el.dataset && el.dataset.key) return el;
            }
            return null;
        }

        function keepFocus(e) {
            if (keyButton(e.target)) e.preventDefault();
        }
        bar.addEventListener('pointerdown', keepFocus);
        bar.addEventListener('mousedown', keepFocus);
        // iOS Safari applies :active only under a touch listener; without the
        // pressed look people tap twice. Passive and empty: it must not cancel
        // the click that follows.
        bar.addEventListener('touchstart', function () {}, { passive: true });

        bar.addEventListener('click', function (e) {
            var button = keyButton(e.target);
            if (!button) return;
            var term = getTerm();
            if (!term || typeof term.input !== 'function') return; // not connected yet
            var name = button.dataset.key;
            var seq = keySequence(name, term);
            if (seq === null) return;
            if (name === 'ctrl-c') {
                if (!allowCtrlC()) return;
                var label = button.textContent;
                button.textContent = 'wait';
                button.classList.add('key-wait');
                later(function () {
                    button.textContent = label;
                    button.classList.remove('key-wait');
                }, windowMs);
            }
            term.input(seq, true);
        });
        return true;
    }

    return {
        install: install,
        keySequence: keySequence,
        createCtrlCGuard: createCtrlCGuard,
        CTRL_C_WINDOW_MS: CTRL_C_WINDOW_MS
    };
});
