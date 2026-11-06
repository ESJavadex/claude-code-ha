/**
 * Reconnect the terminal after sleep or a network drop.
 *
 * ttyd 1.7.7 retries a dropped connection once, straight away, and if that
 * fails it stops at "Press ⏎ to Reconnect". That one try often comes too
 * early: after sleep the network isn't back yet, or Home Assistant's ingress
 * session has expired and every request from the panel gets a 401 until Home
 * Assistant's page creates a new one when it next checks, up to a minute
 * later (ha-panel-app.ts).
 * While Home Assistant restarts, the add-on can't be reached at all (502).
 *
 * While ttyd shows that message, this asks the add-on's /health with growing
 * gaps (1, 2, 5, then every 10 s), and at once when the browser comes back
 * online or the tab is shown again. When the add-on answers, the terminal
 * frame is reloaded, which attaches to the same tmux session.
 */
(function (root, factory) {
    'use strict';
    var api = factory();
    if (typeof module === 'object' && module.exports) {
        module.exports = api;
    }
    if (root) {
        root.ClaudeTerminalReconnect = api;
    }
})(typeof self !== 'undefined' ? self : null, function () {
    'use strict';

    // ttyd's own text (xterm/index.ts), shown in an overlay div that it
    // appends to the xterm element (addons/overlay.ts)
    var STUCK_TEXT = 'Press ⏎ to Reconnect';
    var DELAYS_MS = [1000, 2000, 5000, 10000];

    function isStuck(doc) {
        var term;
        try {
            term = doc && doc.querySelector('.xterm');
        } catch (e) {
            return false;
        }
        if (!term || !term.children) {
            return false;
        }
        for (var i = 0; i < term.children.length; i++) {
            if (term.children[i].textContent === STUCK_TEXT) {
                return true;
            }
        }
        return false;
    }

    function install(iframe, options) {
        var opts = options || {};
        var win = opts.window || window;
        var doc = opts.document || document;
        var fetchFn = opts.fetch || function (url, init) { return win.fetch(url, init); };
        var setTimer = opts.setTimeout || function (fn, ms) { return win.setTimeout(fn, ms); };
        var clearTimer = opts.clearTimeout || function (id) { win.clearTimeout(id); };
        var healthUrl = opts.healthUrl || 'health';
        var log = opts.log || function (msg) {
            if (win.console) {
                win.console.info('[terminal-reconnect] ' + msg);
            }
        };
        var attempt = 0;
        var timer = null;
        var checking = false;
        var observer = null;
        var recovering = false;
        var reloading = false;
        var reloadDoc = null;

        function frameDoc() {
            try {
                return iframe.contentDocument;
            } catch (e) {
                return null;
            }
        }

        function stuck() {
            return isStuck(frameDoc());
        }

        function needsRecovery() {
            if (stuck()) recovering = true;
            var d = frameDoc();
            // Only a replacement terminal document can finish a reload.
            if (recovering && (!reloading || d !== reloadDoc) && !stuck()) {
                try {
                    if (d && d.querySelector('.xterm')) {
                        recovering = false;
                        reloading = false;
                        attempt = 0;
                    }
                } catch (e) { /* a browser error page may be inaccessible */ }
            }
            return recovering;
        }

        function healthCheck() {
            var controller = new win.AbortController();
            var timeout;
            var request = Promise.resolve().then(function () {
                return fetchFn(healthUrl, { cache: 'no-store', signal: controller.signal });
            });
            var deadline = new Promise(function (resolve, reject) {
                timeout = setTimer(function () {
                    reject(new Error('health check timed out'));
                    controller.abort();
                }, 10000);
            });
            return Promise.race([request, deadline]).finally(function () {
                clearTimer(timeout);
            });
        }

        function schedule(now) {
            if (timer !== null) {
                clearTimer(timer);
            }
            var delay = 0;
            if (!now) {
                delay = DELAYS_MS[Math.min(attempt, DELAYS_MS.length - 1)];
                attempt++;
            }
            timer = setTimer(check, delay);
        }

        function reload() {
            try {
                iframe.contentWindow.location.reload();
            } catch (e) {
                iframe.src = iframe.src;
            }
        }

        function check() {
            timer = null;
            // A check already in flight schedules the next one itself
            if (checking) {
                return Promise.resolve();
            }
            if (!needsRecovery()) {
                attempt = 0;
                return Promise.resolve();
            }
            checking = true;
            return Promise.resolve()
                .then(function () {
                    return healthCheck();
                })
                .then(function (resp) {
                    if (resp && resp.ok) {
                        return true;
                    }
                    log('health answered ' + (resp ? resp.status : 'nothing'));
                    return false;
                }, function (err) {
                    log('health failed: ' + (err && err.message ? err.message : err));
                    return false;
                })
                .then(function (ok) {
                    checking = false;
                    // Enter pressed in the meantime may have reconnected it
                    if (!needsRecovery()) {
                        attempt = 0;
                    } else if (ok) {
                        log('add-on reachable, reloading the terminal');
                        reloadDoc = frameDoc();
                        reloading = true;
                        reload();
                        // Navigation can fail after health succeeds. Keep a watchdog
                        // until a replacement terminal document appears.
                        timer = setTimer(check, 10000);
                    } else {
                        schedule(false);
                        log('retrying in ' + DELAYS_MS[Math.min(attempt - 1, DELAYS_MS.length - 1)] / 1000 + ' s');
                    }
                });
        }

        function onMutation() {
            if (timer === null && !checking && needsRecovery()) {
                schedule(false);
            }
        }

        // A reload gives the frame a new document, so watch each one
        function watch() {
            if (observer) {
                observer.disconnect();
                observer = null;
            }
            var d = frameDoc();
            if (!d || !d.body || typeof win.MutationObserver !== 'function') {
                return;
            }
            observer = new win.MutationObserver(onMutation);
            observer.observe(d.body, { childList: true, subtree: true });
            onMutation();
        }

        iframe.addEventListener('load', watch);
        watch();
        win.addEventListener('online', function () {
            if (needsRecovery()) {
                schedule(true);
            }
        });
        doc.addEventListener('visibilitychange', function () {
            if (!doc.hidden && needsRecovery()) {
                schedule(true);
            }
        });

        return { check: check };
    }

    return {
        install: install,
        isStuck: isStuck,
        STUCK_TEXT: STUCK_TEXT,
        DELAYS_MS: DELAYS_MS
    };
});
