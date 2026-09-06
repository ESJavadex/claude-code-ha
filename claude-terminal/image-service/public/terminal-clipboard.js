/**
 * Clipboard bridge for the embedded ttyd terminal. See CHANGELOG 2.1.0 and #30.
 *
 * ttyd 1.7.7 copies a selection with execCommand, which cannot see an xterm.js
 * one, and registers no OSC 52 handler. Patched from here via window.term.
 */
(function (root, factory) {
    'use strict';
    var api = factory();
    if (typeof module === 'object' && module.exports) {
        module.exports = api;
    }
    if (root) {
        root.ClaudeTerminalClipboard = api;
    }
})(typeof self !== 'undefined' ? self : null, function () {
    'use strict';

    var OSC_CLIPBOARD = 52;
    var INSTALL_FLAG = '__claudeClipboardInstalled';
    var TERM_POLL_INTERVAL_MS = 100;
    var TERM_POLL_TIMEOUT_MS = 20000;

    /** Decode the OSC 52 payload (base64 of UTF-8 bytes) using the frame's own globals. */
    function decodeBase64Utf8(win, base64) {
        var binary = win.atob(base64.replace(/\s+/g, ''));
        var bytes = new win.Uint8Array(binary.length);
        for (var i = 0; i < binary.length; i++) {
            bytes[i] = binary.charCodeAt(i);
        }
        return new win.TextDecoder().decode(bytes);
    }

    // Insecure-origin fallback. Chrome only allows it during a user gesture,
    // so it must stay synchronous.
    function copyWithTextarea(win, text, nativeExecCommand) {
        var doc = win.document;
        if (!doc.body) return false;

        var textarea = doc.createElement('textarea');
        textarea.value = text;
        textarea.setAttribute('readonly', '');
        textarea.style.cssText = 'position:fixed;top:0;left:-9999px;width:1px;height:1px;opacity:0;';
        doc.body.appendChild(textarea);

        var previous = doc.activeElement;
        var copied = false;
        try {
            textarea.focus();
            textarea.select();
            if (typeof textarea.setSelectionRange === 'function') {
                textarea.setSelectionRange(0, text.length);
            }
            copied = nativeExecCommand('copy') === true;
        } catch (err) {
            copied = false;
        }

        doc.body.removeChild(textarea);
        if (previous && typeof previous.focus === 'function') {
            try { previous.focus(); } catch (err) { /* detached node */ }
        }
        return copied;
    }

    /** The single clipboard writer every path goes through. Resolves to success. */
    function makeCopyText(win, nativeExecCommand) {
        return function copyText(text) {
            if (!text) return Promise.resolve(false);

            var clipboard = win.navigator && win.navigator.clipboard;
            if (clipboard && typeof clipboard.writeText === 'function') {
                return clipboard.writeText(text).then(
                    function () { return true; },
                    // Rejects when the document is not focused, or when the
                    // permission was denied - the textarea may still work.
                    function () { return copyWithTextarea(win, text, nativeExecCommand); }
                );
            }
            // No clipboard API: insecure context (http://homeassistant.local:8123).
            return Promise.resolve(copyWithTextarea(win, text, nativeExecCommand));
        };
    }

    // ttyd's overlay, reimplemented: its own is private and shows the scissors
    // even when nothing was copied, which is the bug being fixed.
    function createOverlay(win, term) {
        var doc = win.document;
        var node = doc.createElement('div');
        node.className = 'claude-clipboard-overlay';
        node.style.cssText = [
            'border-radius: 15px',
            'font-size: xx-large',
            'opacity: 0.75',
            'padding: 0.2em 0.5em 0.2em 0.5em',
            'position: absolute',
            'color: #101010',
            'background-color: #f0f0f0',
            'user-select: none',
            '-webkit-user-select: none',
            'transition: opacity 180ms ease-in',
            'z-index: 10'
        ].join(';');

        var timer;

        node.addEventListener('mousedown', function (event) {
            // Never let the overlay start a new terminal selection.
            event.preventDefault();
            event.stopPropagation();
        }, true);

        function hide() {
            if (timer) { win.clearTimeout(timer); timer = undefined; }
            if (node.parentNode) node.parentNode.removeChild(node);
        }

        // Status only - never interactive. A control floating over the
        // terminal has no room to explain itself; the page says it in words.
        function show(message, timeoutMs) {
            if (!term.element) return;
            if (timer) { win.clearTimeout(timer); timer = undefined; }

            node.textContent = message;
            node.style.opacity = '0.75';

            if (!node.parentNode) term.element.appendChild(node);

            var box = term.element.getBoundingClientRect();
            var size = node.getBoundingClientRect();
            node.style.top = (box.height - size.height) / 2 + 'px';
            node.style.left = (box.width - size.width) / 2 + 'px';

            if (timeoutMs) timer = win.setTimeout(hide, timeoutMs);
        }

        return { show: show, hide: hide, node: node };
    }

    /**
     * Terminal text from the xterm.js buffer - the only copy path a touch
     * device has, since xterm.js has no touch selection and paints to a canvas.
     *
     * @param {'selection'|'screen'|'screen-down'|'all'} mode 'screen-down' adds
     *   the rows below the viewport, so a line past the fold is not cut in half.
     * @param {boolean} [joinWrapped=true]
     */
    function readTerminalText(term, mode, joinWrapped) {
        return readRows(term, mode, joinWrapped).text;
    }

    /** The raw rows for a mode, each tagged with whether it filled the width. */
    function rawRows(term, mode) {
        var buffer = term.buffer.active;
        var cols = term.cols;
        var from;
        var to;
        if (mode === 'all') {
            from = 0;
            to = buffer.length - 1;
        } else if (mode === 'screen-down') {
            from = buffer.viewportY;
            to = buffer.length - 1;
        } else {
            // The rows currently on screen, wherever the viewport is scrolled.
            from = buffer.viewportY;
            to = Math.min(from + term.rows - 1, buffer.length - 1);
        }

        var rows = [];
        for (var y = from; y <= to; y++) {
            var line = buffer.getLine(y);
            if (!line) continue;
            var text = line.translateToString(true);
            rows.push({ text: text, full: text.length >= cols, wrapped: !!line.isWrapped });
        }
        return rows;
    }

    // As above, plus whether the last row was full. That flag is the only
    // truncation signal: a URL cut mid-path reads as valid.
    function readRows(term, mode, joinWrapped) {
        if (mode === 'selection') {
            return { text: term.getSelection() || '', lastRowFull: false };
        }

        var joined = joinRows(rawRows(term, mode), term.cols, joinWrapped !== false);
        var lines = joined.lines;

        // Drop the empty rows below the last output so a mostly-empty screen
        // does not copy 20 blank lines.
        while (lines.length && lines[lines.length - 1] === '') lines.pop();

        return { text: lines.join('\n'), lastRowFull: joined.lastRowFull };
    }

    // Boundaries have to be guessed: exclude box-drawing glyphs, or Claude
    // Code's prompt frame gets copied into the link.
    var URL_PATTERN = /https?:\/\/[^\s"'<>`─-▟]+/g;
    var TRAILING_PUNCTUATION = /[.,;:!?'"]+$/;
    // A hostname with at least one dot and a letters-only TLD. "http://claude"
    // or "http://…" is not something worth putting on the clipboard.
    var PLAUSIBLE_HOST = /^https?:\/\/[^/?#\s]*[a-z0-9]([a-z0-9-]*[a-z0-9])?\.[a-z]{2,}(:\d+)?([/?#]|$)/i;

    // Why a candidate is not worth copying. Half a URL is worse than none: it
    // fails on paste with nothing on screen explaining why.
    function urlProblem(url) {
        if (!url) return 'none';
        // A TUI that ran out of width ends the line with an ellipsis.
        if (/(…|\.\.\.)$/.test(url)) return 'truncated';
        // Cut inside a percent-escape, e.g. ".../a%3" or ".../a%".
        if (/%[0-9a-f]?$/i.test(url)) return 'truncated';
        // A query cut between parameters: "?a=1&" or "...&code=".
        if (/[?&=]$/.test(url)) return 'truncated';
        if (!PLAUSIBLE_HOST.test(url)) return 'invalid';
        return null;
    }

    /**
     * The last usable URL in terminal text, or null.
     *
     * @param {string} text
     * @param {boolean} [reportProblem] return {url, problem} instead of a string
     */
    function findLastUrl(text, reportProblem) {
        var fail = function (problem) {
            return reportProblem ? { url: null, problem: problem } : null;
        };
        if (!text) return fail('none');
        var matches = text.match(URL_PATTERN);
        if (!matches) return fail('none');

        var raw = matches[matches.length - 1];
        // Checked before punctuation is stripped: "…" and "..." are how a TUI
        // says "cut off here", and stripping them first would turn a truncated
        // link into a plausible one. A single trailing dot is just a full stop.
        if (/(…|\.\.\.)$/.test(raw)) return fail('truncated');

        var url = raw.replace(TRAILING_PUNCTUATION, '');
        // A closing bracket belongs to the URL only if it was opened inside it,
        // so "(see http://x/a)" keeps the paren out but "http://x/a_(b)" keeps
        // it in.
        var pairs = { ')': '(', ']': '[', '}': '{' };
        while (url && pairs[url.charAt(url.length - 1)]) {
            var close = url.charAt(url.length - 1);
            var open = pairs[close];
            // Keep it when the URL opens at least as many as it closes.
            if (url.split(open).length >= url.split(close).length) break;
            url = url.slice(0, -1).replace(TRAILING_PUNCTUATION, '');
        }

        var problem = urlProblem(url);
        if (problem) return fail(problem);
        return reportProblem ? { url: url, problem: null } : url;
    }

    // What a wrapped URL may resume with. Letters are out: a row starting with
    // one is usually the next line of output, not the rest of a link.
    var URL_RESUMES = /^[/?&=#%~+.\-_0-9]/;
    // A continuation holding any of these is a link tail, not a word.
    var URL_TAIL = /[0-9/?&=#%~+.\-_]/;

    // The column rows are really wrapped at - not the pane width, because
    // Claude Code lays its output out one column short. A wrap column repeats,
    // so take the widest length two rows share, near the pane width.
    function wrapWidth(rows, cols) {
        var floor = Math.max(1, cols - 2);
        var counts = {};
        var best = 0;
        for (var i = 0; i < rows.length; i++) {
            var len = rows[i].text.length;
            if (len < floor || len > cols) continue;
            counts[len] = (counts[len] || 0) + 1;
            if (counts[len] >= 2 && len > best) best = len;
        }
        return best || cols;
    }

    // Rebuild the lines the terminal broke into rows. Three splits, each with
    // its own trace: see CHANGELOG 2.1.0. The glue per boundary is nothing, one
    // space, or a line break.
    function joinRows(rows, cols, join) {
        var lines = [];
        var previousFull = false;
        var previousLength = 0;
        var width = wrapWidth(rows, cols);

        for (var i = 0; i < rows.length; i++) {
            var row = rows[i];
            // Recomputed against the measured width, not the pane width.
            row = { text: row.text, wrapped: row.wrapped, full: row.text.length >= width };
            var chunk = row.text.replace(/^\s+/, '');
            var indented = chunk !== row.text;
            var glue = null;

            if (join && lines.length && chunk !== '') {
                if (previousFull || row.wrapped) {
                    // One line; the question is whether the wrap ate a space.
                    // A full or unindented row had no room for one. Otherwise
                    // judge by shape: URL chars mean a tail, letters a word.
                    if (!indented || row.full) {
                        glue = '';
                    } else {
                        glue = URL_TAIL.test(chunk.split(/\s/)[0]) ? '' : ' ';
                    }
                } else {
                    // A short row means the renderer chose to break. Rejoin
                    // only when the next token could not have fitted anyway and
                    // reads as the rest of a URL.
                    var token = chunk.split(/\s/)[0];
                    if (previousLength + token.length > width && URL_RESUMES.test(token)) {
                        glue = '';
                    }
                }
            }

            if (glue === null) {
                lines.push(row.text);
            } else {
                lines[lines.length - 1] += glue + chunk;
            }
            previousFull = row.full;
            previousLength = row.text.length;
        }

        return { lines: lines, lastRowFull: previousFull };
    }

    // atEdge means the link runs off the rows given - widen, do not copy it.
    function findLinkInRows(rows, cols) {
        var joined = joinRows(rows, cols, true);
        var text = joined.lines.join('\n');
        var found = findLastUrl(text, true);

        // Still growing when the rows ran out.
        var atEdge = !!(found.url && joined.lastRowFull &&
            text.slice(-found.url.length) === found.url);

        return { url: found.url, problem: found.problem, atEdge: atEdge };
    }

    var TOUCH_LINES_PER_MOVE = 8;

    /**
     * Scroll by swiping. xterm.js 5.5 drops touchstart/touchmove outright while
     * the app has mouse reporting on, and never turns touch into a mouse
     * report - so with Claude Code (reporting on, alternate screen) a phone
     * cannot scroll at all. The wheel has its own path, which is why a mouse
     * works. Swipes become wheel events, so xterm.js encodes them exactly as it
     * would a real wheel: a mouse report if the app wants one, else a scroll.
     */
    function installTouchScroll(win, term) {
        var el = term.element;
        if (!el) return;

        // Vertical is ours; leave pinch-zoom and horizontal pan to the browser.
        el.style.touchAction = 'pan-x pinch-zoom';

        var lastY = null;
        var pending = 0;

        el.addEventListener('touchstart', function (ev) {
            lastY = ev.touches.length === 1 ? ev.touches[0].clientY : null;
            pending = 0;
        }, { passive: true });

        el.addEventListener('touchmove', function (ev) {
            // xterm.js prevents the default when it scrolled the viewport
            // itself - its signal that the gesture is already handled.
            if (lastY === null || ev.defaultPrevented || ev.touches.length !== 1) return;

            var touch = ev.touches[0];
            var step = Math.max(1, el.getBoundingClientRect().height / Math.max(1, term.rows));
            pending += lastY - touch.clientY;
            lastY = touch.clientY;

            var lines = Math.trunc(pending / step);
            if (!lines) return;
            pending -= lines * step;
            ev.preventDefault();

            // One event per line: a mouse report carries a direction, not a
            // distance, so a single large delta would scroll one line.
            var count = Math.min(Math.abs(lines), TOUCH_LINES_PER_MOVE);
            for (var i = 0; i < count; i++) {
                el.dispatchEvent(new win.WheelEvent('wheel', {
                    deltaY: lines > 0 ? step : -step,
                    deltaMode: 0,
                    clientX: touch.clientX,
                    clientY: touch.clientY,
                    bubbles: true,
                    cancelable: true
                }));
            }
        }, { passive: false });

        el.addEventListener('touchend', function () {
            lastY = null;
            pending = 0;
        }, { passive: true });
    }

    /**
     * Stop the on-screen keyboard from composing.
     *
     * Gboard's predictive text keeps a composing region, and xterm.js re-emits
     * a commit it has already sent (xtermjs/xterm.js#6060, open), so the same
     * phrase lands in the prompt several times over. Nothing outside xterm.js
     * can cancel what it sends, so the only lever left is to stop the keyboard
     * composing at all: inputmode=url puts it in a plain, no-suggestions mode.
     * The cost is the suggestion strip.
     */
    function installMobileInput(win, term) {
        var textarea = term.textarea;
        var coarse = !!(win.matchMedia && win.matchMedia('(pointer: coarse)').matches);
        if (!textarea || !coarse) return false;

        textarea.setAttribute('inputmode', 'url');
        textarea.setAttribute('autocomplete', 'off');
        return true;
    }

    function install(win, options) {
        var opts = options || {};
        var term = win.term;
        if (!term || term[INSTALL_FLAG]) return false;

        var doc = win.document;
        // Captured before the patch below, so our own fallback never recurses.
        var originalExecCommand = doc.execCommand;
        var nativeExecCommand = function (command) {
            return originalExecCommand.call(doc, command);
        };
        var copyText = makeCopyText(win, nativeExecCommand);
        var overlay = createOverlay(win, term);

        // Scissors only on a real success. A refusal - only reachable for
        // /copy on an insecure origin - goes to the page, which can say it in
        // words and point at a button that has a gesture.
        function report(text, copied) {
            if (copied) {
                overlay.show('✂', 200);
                return;
            }
            overlay.show('⚠', 1200);
            if (opts.onRefused) opts.onRefused(text);
        }

        // --- 1. Mouse selection ---
        // Make ttyd's own execCommand('copy') throw, so it returns before
        // showing its unconditional overlay. The real copy happens below.
        doc.execCommand = function (command) {
            if (command === 'copy' && term.getSelection()) {
                throw new Error('claude-terminal: selection copy handled by the clipboard bridge');
            }
            return originalExecCommand.apply(doc, arguments);
        };

        var dragging = false;
        var pending = null;

        function flush() {
            var text = pending;
            pending = null;
            if (!text) return;
            copyText(text).then(function (copied) { report(text, copied); });
        }

        term.onSelectionChange(function () {
            var selection = term.getSelection();
            if (!selection) return;
            pending = selection;
            // While dragging, wait for mouseup: one copy per gesture, and the
            // textarea fallback stays inside the gesture that Chrome requires.
            if (!dragging) flush();
        });

        if (term.element) {
            term.element.addEventListener('mousedown', function () { dragging = true; }, true);
        }
        win.addEventListener('mouseup', function () {
            if (!dragging) return;
            dragging = false;
            flush();
        }, true);

        // --- 2. OSC 52 (Claude Code's /copy, via tmux) -------------------------
        term.parser.registerOscHandler(OSC_CLIPBOARD, function (data) {
            var separator = data.indexOf(';');
            // `data` is everything after "52;", i.e. "<Pc>;<Pd>". Some senders
            // omit Pc, leaving just the payload.
            var payload = separator === -1 ? data : data.slice(separator + 1);

            // A read request would hand the host clipboard to whatever runs in
            // the terminal. Swallow it instead of answering.
            if (payload === '?') return true;

            var text = '';
            try {
                text = decodeBase64Utf8(win, payload);
            } catch (err) {
                return true;
            }
            if (!text) return true;

            copyText(text).then(function (copied) { report(text, copied); });
            return true; // handled - do not print the escape sequence
        });

        // --- 3. Touch devices --------------------------------------------------
        // Nothing above helps a phone: no mouse selection exists, and /copy's
        // fallback needs a gesture. The controller lets the page drive a copy
        // from a button tap, which is a gesture.
        var controller = {
            copy: function (mode, joinWrapped) {
                var text = readTerminalText(term, mode || 'screen', joinWrapped);
                if (!text) return Promise.resolve({ copied: false, text: '' });
                return copyText(text).then(function (copied) {
                    if (copied) overlay.show('✂', 200);
                    return { copied: copied, text: text };
                });
            },
            read: function (mode, joinWrapped) {
                return readTerminalText(term, mode || 'screen', joinWrapped);
            },
            // Widens screen -> screen-down -> scrollback, because a link
            // running off the rows read is the half-URL users end up pasting.
            // Returns {url, problem: 'none'|'truncated'|'invalid'}.
            findLink: function () {
                var modes = ['screen', 'screen-down', 'all'];
                var last = { url: null, problem: 'none' };
                for (var i = 0; i < modes.length; i++) {
                    var found = findLinkInRows(rawRows(term, modes[i]), term.cols);

                    if (found.atEdge) {
                        last = { url: null, problem: 'truncated' };
                        continue;
                    }
                    if (found.url) return { url: found.url, problem: null };
                    if (found.problem !== 'none') last = { url: null, problem: found.problem };
                }
                return last;
            },
            hasSelection: function () { return !!term.getSelection(); },
            /**
             * Settle the terminal after the viewport changed size.
             *
             * ttyd exposes fit() on the terminal it exports. Calling it pushes
             * the new size through to the pty, and that SIGWINCH is what makes
             * a full-screen app redraw with its prompt at the new bottom - the
             * iframe's own resize event does not reliably land while the
             * keyboard is still animating.
             */
            scrollToBottom: function () {
                if (typeof term.fit === 'function') {
                    try { term.fit(); } catch (err) { /* mid-teardown */ }
                }
                if (typeof term.scrollToBottom === 'function') term.scrollToBottom();
            },
            copyTextDirect: copyText
        };

        installTouchScroll(win, term);
        installMobileInput(win, term);

        term[INSTALL_FLAG] = true;
        term.__claudeClipboard = controller;
        return controller;
    }

    /**
     * Attach to a same-origin iframe running ttyd. Re-arms on every reload,
     * and waits for `window.term`, which ttyd sets when the terminal opens.
     */
    function attach(iframe, options) {
        var opts = options || {};
        var timeoutMs = opts.timeoutMs || TERM_POLL_TIMEOUT_MS;
        var intervalMs = opts.intervalMs || TERM_POLL_INTERVAL_MS;
        var scheduler = opts.scheduler || {
            setTimeout: function (fn, ms) { return setTimeout(fn, ms); },
            clearTimeout: function (id) { return clearTimeout(id); }
        };
        var timer;
        var controller = null;

        function poll(deadline) {
            var win;
            try {
                win = iframe.contentWindow;
            } catch (err) {
                return; // cross-origin: nothing we can do
            }
            // ttyd assigns window.term just before terminal.open(), so wait for
            // the DOM element too - the mousedown listener needs it.
            if (win && win.term && win.term.element) {
                try {
                    controller = install(win, { onRefused: opts.onRefused }) ||
                        win.term.__claudeClipboard || null;
                    if (controller && opts.onReady) opts.onReady(controller);
                } catch (err) {
                    if (opts.onError) opts.onError(err);
                }
                return;
            }
            if (deadline <= 0) {
                if (opts.onTimeout) opts.onTimeout();
                return;
            }
            timer = scheduler.setTimeout(function () { poll(deadline - intervalMs); }, intervalMs);
        }

        function restart() {
            if (timer) scheduler.clearTimeout(timer);
            poll(timeoutMs);
        }

        iframe.addEventListener('load', restart);
        restart();
        return {
            restart: restart,
            // null until the terminal is up; the page must handle that.
            getController: function () { return controller; }
        };
    }

    return {
        attach: attach,
        install: install,
        readTerminalText: readTerminalText,
        findLastUrl: findLastUrl,
        findLinkInRows: findLinkInRows,
        installMobileInput: installMobileInput,
        urlProblem: urlProblem,
        decodeBase64Utf8: decodeBase64Utf8,
        copyWithTextarea: copyWithTextarea,
        makeCopyText: makeCopyText,
        createOverlay: createOverlay,
        OSC_CLIPBOARD: OSC_CLIPBOARD
    };
});
