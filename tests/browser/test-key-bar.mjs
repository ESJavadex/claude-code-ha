// Exercise real browser touch activation: calling a click listener directly
// cannot detect WebKit suppressing that click after a cancelled pointerdown.
import assert from 'node:assert/strict';
import http from 'node:http';
import { readFile } from 'node:fs/promises';
import { chromium, webkit } from 'playwright';

const script = await readFile(new URL('../../claude-terminal/image-service/public/key-bar.js', import.meta.url));
const keys = {
    esc: '\x1b', up: '\x1b[A', down: '\x1b[B', tab: '\t',
    'shift-tab': '\x1b[Z', 'ctrl-c': '\x03', newline: '\\\r', enter: '\r'
};
const html = `<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
<iframe src="/terminal"></iframe>
<div id="key-bar">${Object.keys(keys).map(key => `<button data-key="${key}">${key}</button>`).join('')}</div>
<script src="/key-bar.js"></script>
<script>ClaudeKeyBar.install(document.getElementById('key-bar'), () => document.querySelector('iframe').contentWindow.term, { ctrlCWindowMs: 60000 });</script>`;
const terminal = `<!doctype html><textarea></textarea><script>
window.sent = [];
window.term = { textarea: document.querySelector('textarea'), input(data, user) { sent.push([data, user]); } };
</script>`;
const server = http.createServer((req, res) => {
    res.setHeader('Content-Type', req.url === '/key-bar.js' ? 'text/javascript' : 'text/html');
    res.end(req.url === '/key-bar.js' ? script : req.url === '/terminal' ? terminal : html);
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));

try {
    for (const engine of [chromium, webkit]) {
        const browser = await engine.launch();
        try {
            const page = await browser.newPage({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
            await page.goto(`http://127.0.0.1:${server.address().port}/`);
            await page.waitForFunction(() => document.querySelector('iframe').contentWindow.term);
            const frame = page.frames().find(candidate => candidate.url().endsWith('/terminal'));
            assert.ok(frame);
            await frame.waitForFunction(() => window.term);
            await frame.evaluate(() => window.term.textarea.focus());
            const expected = [];
            for (const [key, sequence] of Object.entries(keys)) {
                await page.locator(`[data-key="${key}"]`).tap();
                expected.push([sequence, true]);
                await frame.waitForFunction(count => window.sent.length >= count, expected.length, { timeout: 3000 });
                assert.deepEqual(await frame.evaluate(() => window.sent), expected, `${engine.name()}: ${key} sent exactly once`);
                assert.equal(await frame.evaluate(() => document.activeElement === window.term.textarea), true,
                    `${engine.name()}: ${key} keeps terminal focus`);
            }
            // A rapid second Ctrl+C is still ignored after a real touch tap.
            await page.locator('[data-key="ctrl-c"]').tap();
            assert.deepEqual(await frame.evaluate(() => window.sent), expected);
            console.log(`PASS ${engine.name()}: all touch keys, terminal focus and Ctrl+C guard`);
        } finally {
            await browser.close();
        }
    }
} finally {
    await new Promise(resolve => server.close(resolve));
}
