// The header message after an upload: a short note that fades when the path
// was typed at the prompt, and a tap-to-copy path that stays only when it
// could not be. Runs the real panel page against a fake terminal and upload.
import assert from 'node:assert/strict';
import http from 'node:http';
import path from 'node:path';
import { readFile } from 'node:fs/promises';
import { chromium, webkit } from 'playwright';

const publicDir = new URL('../../claude-terminal/image-service/public/', import.meta.url);
const types = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript' };
// ?paste=0 gives a terminal without term.paste, so the path can't be inserted
const terminal = (canPaste) => `<!doctype html><script>
window.pasted = [];
window.term = { focus() {}, ${canPaste ? 'paste(text) { pasted.push(text); },' : ''}
    textarea: null, parser: { registerOscHandler() {} }, attachCustomKeyEventHandler() {} };
</script>`;
let canPaste = true;

const server = http.createServer(async (req, res) => {
    const url = new URL(req.url, 'http://x');
    if (url.pathname === '/upload') {
        req.resume();
        res.setHeader('Content-Type', 'application/json');
        res.end(JSON.stringify({ success: true, path: '/data/uploads/20261126-003753-pasted.png' }));
    } else if (url.pathname === '/config') {
        res.setHeader('Content-Type', 'application/json');
        res.end('{"ttydPort":7681,"uploadDir":"/data/uploads"}');
    } else if (url.pathname.startsWith('/terminal')) {
        res.setHeader('Content-Type', 'text/html');
        res.end(terminal(canPaste));
    } else {
        const file = url.pathname === '/' ? 'index.html' : url.pathname.slice(1);
        try {
            const body = await readFile(new URL(file, publicDir));
            res.setHeader('Content-Type', types[path.extname(file)] || 'application/octet-stream');
            res.end(body);
        } catch {
            res.statusCode = 404;
            res.end('{}');
        }
    }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const base = `http://127.0.0.1:${server.address().port}/`;

async function openPanel(browser) {
    const page = await browser.newPage();
    await page.clock.install();
    await page.goto(base);
    await page.waitForFunction(() => document.getElementById('terminal-frame').contentWindow.term);
    return page;
}

async function upload(page) {
    await page.setInputFiles('#file-input', { name: 'pasted.png', mimeType: 'image/png', buffer: Buffer.from('png') });
}

const statusText = (page) => page.locator('#status').textContent();

try {
    for (const engine of [chromium, webkit]) {
        const browser = await engine.launch();
        const name = engine.name();
        try {
            // Inserted: a short note with the file name, which fades
            canPaste = true;
            let page = await openPanel(browser);
            await upload(page);
            await page.waitForFunction(() => document.getElementById('status').textContent.includes('Inserted'));
            assert.equal(await statusText(page), '📋 Inserted 20261126-003753-pasted.png', `${name}: inserted note`);
            const frame = page.frames().find(f => f.url().includes('/terminal'));
            assert.deepEqual(await frame.evaluate(() => window.pasted), ['/data/uploads/20261126-003753-pasted.png '],
                `${name}: path typed at the prompt once`);
            assert.equal(await page.evaluate(() => document.getElementById('status').onclick), null,
                `${name}: the inserted note is not tap-to-copy`);
            await page.clock.runFor(5100);
            assert.equal(await statusText(page), '', `${name}: the inserted note fades`);
            await page.close();

            // Not inserted: the full path stays and a tap copies it
            canPaste = false;
            page = await openPanel(browser);
            await upload(page);
            await page.waitForFunction(() => document.getElementById('status').textContent.includes('tap to copy'));
            assert.equal(await statusText(page), '📋 /data/uploads/20261126-003753-pasted.png (tap to copy)',
                `${name}: copyable path`);
            await page.clock.runFor(60000);
            assert.match(await statusText(page), /tap to copy/, `${name}: the copyable path stays`);
            assert.equal(await page.evaluate(() => typeof document.getElementById('status').onclick), 'function',
                `${name}: the path is tap-to-copy`);

            // A later message replaces it completely: no tap handler left
            // behind, and the old path's restore can't overwrite it
            await page.evaluate(() => setStatus('📥 Pasted into the terminal', 'success'));
            assert.equal(await page.evaluate(() => document.getElementById('status').onclick), null,
                `${name}: a later message drops the old tap-to-copy handler`);
            await page.clock.runFor(5100);
            assert.equal(await statusText(page), '', `${name}: the later message fades as usual`);
            await page.close();
            console.log(`PASS ${name}: upload note fades, copyable path only when not inserted, no stale tap handler`);
        } finally {
            await browser.close();
        }
    }
} finally {
    await new Promise(resolve => server.close(resolve));
}
