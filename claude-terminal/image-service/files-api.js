/**
 * Read-only file browser API for the sidebar: list folders, preview text
 * files, list recently changed files, and run Home Assistant's config check.
 *
 * Nothing here writes to disk. Paths are resolved with realpath and must stay
 * inside one of the allowed roots (FILE_ROOTS, default /config), so a symlink
 * can't point the browser elsewhere. The routes sit behind the same
 * ingress-only socket check as the terminal itself.
 */

const fs = require('fs');
const path = require('path');
const { execFile } = require('child_process');

const ROOTS = (process.env.FILE_ROOTS || '/config')
    .split(':')
    .filter(Boolean)
    .map((root) => {
        try { return fs.realpathSync(root); } catch { return null; }
    })
    .filter(Boolean);

const MAX_ENTRIES = 2000;
const MAX_PREVIEW_BYTES = 256 * 1024;
const MAX_RECENT = 50;
const MAX_RECENT_DEPTH = 6;
const MAX_RECENT_VISITS = 20000;

// Folders HA rewrites constantly or that hold dependencies, not user files
const RECENT_SKIP_DIRS = new Set([
    '.git', '.storage', '.cache', 'node_modules', '__pycache__', 'deps', 'tts',
    '.cloud', 'backups', 'claude-config'
]);
const RECENT_SKIP_FILE = /^home-assistant_v2\.db|\.log(\.\d+)?$|\.db-(shm|wal)$/;

// Resolve a requested path to its real location, or null if it is outside
// every allowed root or doesn't exist
function resolveInsideRoots(requested) {
    if (typeof requested !== 'string' || requested === '' || requested.includes('\0')) {
        return null;
    }
    let real;
    try {
        real = fs.realpathSync(path.resolve('/', requested));
    } catch {
        return null;
    }
    const inside = ROOTS.some((root) => real === root || real.startsWith(root + path.sep));
    // .git/config can hold credentials (tokens in remote URLs)
    if (real.split(path.sep).includes('.git')) return null;
    return inside ? real : null;
}

function entryInfo(dir, dirent) {
    const full = path.join(dir, dirent.name);
    let stat;
    try { stat = fs.statSync(full); } catch { return null; }
    return {
        name: dirent.name,
        path: full,
        type: stat.isDirectory() ? 'dir' : 'file',
        size: stat.isDirectory() ? null : stat.size,
        mtime: stat.mtimeMs
    };
}

// A file is shown as text if its first bytes contain no NUL
function looksBinary(buffer) {
    const sample = buffer.subarray(0, Math.min(buffer.length, 8000));
    return sample.includes(0);
}

function recentFiles(hours) {
    const since = Date.now() - hours * 3600 * 1000;
    const found = [];
    let visits = 0;

    function walk(dir, depth) {
        if (depth > MAX_RECENT_DEPTH || visits > MAX_RECENT_VISITS) return;
        let entries;
        try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
        for (const dirent of entries) {
            if (++visits > MAX_RECENT_VISITS) return;
            const full = path.join(dir, dirent.name);
            if (dirent.isDirectory()) {
                if (!RECENT_SKIP_DIRS.has(dirent.name)) walk(full, depth + 1);
            } else if (dirent.isFile() && !RECENT_SKIP_FILE.test(dirent.name)) {
                let stat;
                try { stat = fs.statSync(full); } catch { continue; }
                if (stat.mtimeMs >= since) {
                    found.push({ name: dirent.name, path: full, type: 'file', size: stat.size, mtime: stat.mtimeMs });
                }
            }
        }
    }

    ROOTS.forEach((root) => walk(root, 0));
    return found.sort((a, b) => b.mtime - a.mtime).slice(0, MAX_RECENT);
}

function register(app) {
    app.get('/api/roots', (req, res) => {
        res.json({ roots: ROOTS });
    });

    app.get('/api/files', (req, res) => {
        const dir = resolveInsideRoots(req.query.path || ROOTS[0] || '');
        if (!dir) return res.status(404).json({ error: 'Folder not found or not allowed' });
        let entries;
        try {
            entries = fs.readdirSync(dir, { withFileTypes: true });
        } catch (err) {
            return res.status(400).json({ error: `Cannot read folder: ${err.code || err.message}` });
        }
        const items = entries
            .filter((dirent) => dirent.name !== '.git')
            .slice(0, MAX_ENTRIES)
            .map((dirent) => entryInfo(dir, dirent))
            .filter(Boolean)
            .sort((a, b) => (a.type === b.type ? a.name.localeCompare(b.name) : a.type === 'dir' ? -1 : 1));
        res.json({ path: dir, entries: items, truncated: entries.length > MAX_ENTRIES });
    });

    app.get('/api/file', (req, res) => {
        const file = resolveInsideRoots(req.query.path || '');
        if (!file) return res.status(404).json({ error: 'File not found or not allowed' });
        let stat;
        try { stat = fs.statSync(file); } catch { return res.status(404).json({ error: 'File not found' }); }
        if (!stat.isFile()) return res.status(400).json({ error: 'Not a file' });

        const length = Math.min(stat.size, MAX_PREVIEW_BYTES);
        const buffer = Buffer.alloc(length);
        try {
            const fd = fs.openSync(file, 'r');
            try { fs.readSync(fd, buffer, 0, length, 0); } finally { fs.closeSync(fd); }
        } catch (err) {
            return res.status(400).json({ error: `Cannot read file: ${err.code || err.message}` });
        }
        if (looksBinary(buffer)) {
            return res.json({ path: file, size: stat.size, mtime: stat.mtimeMs, binary: true });
        }
        res.json({
            path: file,
            size: stat.size,
            mtime: stat.mtimeMs,
            binary: false,
            truncated: stat.size > MAX_PREVIEW_BYTES,
            content: buffer.toString('utf8')
        });
    });

    app.get('/api/recent', (req, res) => {
        const hours = Math.min(Math.max(Number(req.query.hours) || 24, 1), 24 * 30);
        res.json({ hours, entries: recentFiles(hours) });
    });

    // Fixed command, no user input. The ha CLI reads SUPERVISOR_TOKEN from
    // the environment the add-on runs with.
    let checkRunning = false;
    app.post('/api/ha/check', (req, res) => {
        if (checkRunning) return res.status(409).json({ ok: false, message: 'A check is already running' });
        checkRunning = true;
        execFile('ha', ['core', 'check', '--raw-json'], { timeout: 180000, maxBuffer: 1024 * 1024 }, (err, stdout, stderr) => {
            checkRunning = false;
            let parsed = null;
            try { parsed = JSON.parse(stdout); } catch { /* not JSON */ }
            if (parsed && parsed.result === 'ok') {
                return res.json({ ok: true, message: 'Configuration is valid' });
            }
            const message = (parsed && parsed.message) || (stderr || stdout || (err && err.message) || 'Check failed').trim();
            res.json({ ok: false, message });
        });
    });
}

module.exports = { register, resolveInsideRoots, recentFiles };
