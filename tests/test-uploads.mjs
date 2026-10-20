#!/usr/bin/env node
// Names given to files uploaded through the panel
import assert from 'node:assert';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { uploadFileName, uniqueName } from '../claude-terminal/image-service/uploads.mjs';

const now = new Date(2026, 9, 20, 14, 12, 33);
let passed = 0;
const ok = (name, fn) => { fn(); passed++; console.log('ok   ' + name); };
const named = (n, mime = '') => uploadFileName(n, mime, now);

ok('a plain name keeps its name and extension', () =>
    assert.strictEqual(named('automations.yaml'), '20261020-141233-automations.yaml'));
ok('spaces and punctuation become single dashes', () =>
    assert.strictEqual(named('My Report (final).PDF'), '20261020-141233-My-Report-final.pdf'));
ok('nothing that needs quoting at the prompt survives', () =>
    assert.match(named('a;b$(rm -rf)`x` "q" \'s\'.txt'), /^[A-Za-z0-9._-]+$/));
ok('a path in the name is dropped', () => {
    assert.strictEqual(named('../../etc/passwd'), '20261020-141233-passwd');
    assert.strictEqual(named('C:\\Users\\me\\notes.txt'), '20261020-141233-notes.txt');
});
ok('a dotfile is not mistaken for an extension', () =>
    assert.strictEqual(named('.bashrc'), '20261020-141233-bashrc'));
ok('a clipboard image with no name gets one from its type', () => {
    assert.strictEqual(named('', 'image/png'), '20261020-141233-pasted.png');
    assert.strictEqual(named('image', 'image/jpeg'), '20261020-141233-image.jpg');
});
ok('an unnamed non-image is called upload', () =>
    assert.strictEqual(named('', 'application/octet-stream'), '20261020-141233-upload'));
ok('a name of only symbols falls back', () =>
    assert.strictEqual(named('???.pdf', 'application/pdf'), '20261020-141233-upload.pdf'));
ok('long names are cut', () =>
    assert.ok(named('x'.repeat(300) + '.txt').length <= '20261020-141233-'.length + 60 + 4));
ok('a clash gets -2, then -3', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'uploads-'));
    try {
        assert.strictEqual(uniqueName(dir, 'a.txt'), 'a.txt');
        fs.writeFileSync(path.join(dir, 'a.txt'), '');
        assert.strictEqual(uniqueName(dir, 'a.txt'), 'a-2.txt');
        fs.writeFileSync(path.join(dir, 'a-2.txt'), '');
        assert.strictEqual(uniqueName(dir, 'a.txt'), 'a-3.txt');
    } finally {
        fs.rmSync(dir, { recursive: true, force: true });
    }
});

console.log(`\nAll ${passed} upload naming tests passed`);
