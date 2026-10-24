// Names for files uploaded through the panel (paste, drag-drop or 📎).
// The saved path is typed at Claude's prompt, so the name keeps only
// characters that need no quoting there, and keeps the extension, which
// tells Claude what kind of file it is.

import fs from 'node:fs';
import path from 'node:path';

// Clipboard images often arrive with no usable name
export const MIME_EXTENSIONS = {
    'image/jpeg': '.jpg',
    'image/png': '.png',
    'image/gif': '.gif',
    'image/webp': '.webp',
    'image/svg+xml': '.svg'
};

function stamp(now) {
    const pad = (n) => String(n).padStart(2, '0');
    return `${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}` +
        `-${pad(now.getHours())}${pad(now.getMinutes())}${pad(now.getSeconds())}`;
}

const clean = (s) => s.replace(/[^A-Za-z0-9._-]+/g, '-').replace(/-{2,}/g, '-').replace(/^[-._]+|[-._]+$/g, '');

// "My Report (final).PDF" -> "20261020-141233-My-Report-final.pdf"
export function uploadFileName(originalName, mimetype, now = new Date()) {
    // Browsers send a bare name; drop any path a client might add anyway
    const base = String(originalName || '').split(/[\\/]/).pop();
    const dot = base.lastIndexOf('.');
    let stem = dot > 0 ? base.slice(0, dot) : base;
    let ext = dot > 0 ? base.slice(dot).toLowerCase() : '';
    if (!/^\.[a-z0-9]{1,10}$/.test(ext)) {
        stem = base;
        ext = '';
    }
    if (!ext) ext = MIME_EXTENSIONS[mimetype] || '';
    stem = clean(stem).slice(0, 60).replace(/[-._]+$/, '');
    if (!stem) stem = String(mimetype || '').startsWith('image/') ? 'pasted' : 'upload';
    return `${stamp(now)}-${stem}${ext}`;
}

// Two uploads of the same name in the same second get -2, -3, ...
// The name is claimed by creating the file with O_EXCL ('wx'), so two
// requests racing for the same name can never both get it; checking first
// and creating later would let both pick the name and overwrite each other.
// The caller then writes into the (empty) file it now owns.
export async function reserveName(dir, name) {
    const ext = path.extname(name);
    const stem = name.slice(0, name.length - ext.length);
    for (let n = 1; ; n++) {
        const candidate = n === 1 ? name : `${stem}-${n}${ext}`;
        try {
            const handle = await fs.promises.open(path.join(dir, candidate), 'wx', 0o644);
            await handle.close();
            return candidate;
        } catch (err) {
            if (err.code !== 'EEXIST') throw err;
        }
    }
}
