/**
 * Changes tab: what changed in /config since the last checkpoint, using git.
 *
 * Reads: the list of changed files and the diff of one file.
 * Writes, each only on an explicit click in the UI:
 *   - start tracking: `git init` plus a first commit, if /config has no repo
 *   - revert one file to the last checkpoint
 *   - accept all changes as a new checkpoint (a local commit; never pushes)
 *
 * git always runs through execFile with an argument array and `--` before
 * paths, so nothing is interpreted by a shell. Every path must resolve inside
 * the repository, and the repository must sit inside /config.
 */

import fs from 'node:fs';
import path from 'node:path';
import { execFile } from 'node:child_process';

const CONFIG_DIR = (() => {
    try { return fs.realpathSync(process.env.GIT_CONFIG_DIR || '/config'); } catch { return '/config'; }
})();
const MAX_DIFF_BYTES = 512 * 1024;
const COMMIT_TIMEOUT = 180000;

// Never listed, diffed or committed by the panel, whatever the repository's
// .gitignore says: an existing repo may not ignore secrets.yaml, and a
// checkpoint that later gets pushed would publish it
const SENSITIVE = [
    '**/secrets.yaml', '**/secrets.yml', '**/.storage/**', '**/.cloud/**',
    '**/*.db', '**/*.db-shm', '**/*.db-wal', '**/.git-credentials',
    '**/.ssh/**', '**/*.pem', '**/*.key', '**/.env'
];
const SAFE_PATHSPEC = ['--', '.', ...SENSITIVE.map((glob) => `:(exclude,glob)${glob}`)];

function isSensitive(relative) {
    const name = relative.split('/').pop();
    return /^secrets\.ya?ml$/.test(name) || /\.(db|db-shm|db-wal|pem|key)$/.test(name) ||
        name === '.git-credentials' || name === '.env' ||
        /(^|\/)(\.storage|\.cloud|\.ssh)\//.test(relative);
}

// Used only when the user has no git identity of their own
const FALLBACK_IDENTITY = ['-c', 'user.name=Claude Terminal Pro', '-c', 'user.email=claude-terminal@localhost'];

// Written only when starting to track a /config that has no .gitignore.
// Keeps secrets, databases, logs and things HA rewrites on its own out.
const DEFAULT_GITIGNORE = `# Created by Claude Terminal Pro when it started tracking /config
secrets.yaml
.storage/
.cloud/
.cache/
deps/
tts/
backups/
node_modules/
__pycache__/
*.db
*.db-shm
*.db-wal
*.log
*.log.*
.HA_VERSION
home-assistant.log*
claude-config/
`;

function git(args, options = {}) {
    return new Promise((resolve) => {
        // safe.directory: /config is often owned by another uid than root
        const fullArgs = ['-c', `safe.directory=${CONFIG_DIR}`, '-c', 'core.quotepath=off', ...args];
        execFile('git', fullArgs, {
            cwd: CONFIG_DIR,
            timeout: options.timeout || 30000,
            maxBuffer: 8 * 1024 * 1024,
            env: { ...process.env, GIT_TERMINAL_PROMPT: '0', GIT_OPTIONAL_LOCKS: '0' }
        }, (err, stdout, stderr) => {
            resolve({ ok: !err, code: err ? err.code : 0, stdout: stdout || '', stderr: (stderr || '').trim() });
        });
    });
}

// The repository top level, or null if /config is not inside one we accept
async function repoRoot() {
    const res = await git(['rev-parse', '--show-toplevel']);
    if (!res.ok) return null;
    let top;
    try { top = fs.realpathSync(res.stdout.trim()); } catch { return null; }
    // A repo rooted above /config (e.g. at /) would expose other folders
    if (top !== CONFIG_DIR && !top.startsWith(CONFIG_DIR + path.sep)) return null;
    return top;
}

// Resolve a repo-relative path and make sure it stays inside the repo.
// Not realpath: a deleted file no longer exists but still has a diff.
function insideRepo(top, relative) {
    if (typeof relative !== 'string' || relative === '' || relative.includes('\0')) return null;
    const full = path.resolve(top, relative);
    if (full !== top && !full.startsWith(top + path.sep)) return null;
    return path.relative(top, full);
}

async function identityArgs() {
    const res = await git(['config', 'user.email']);
    return res.ok && res.stdout.trim() ? [] : FALLBACK_IDENTITY;
}

// True if the file exists in the last checkpoint, i.e. has a version to
// compare with or go back to
async function inLastCheckpoint(file) {
    return (await git(['cat-file', '-e', `HEAD:${file}`])).ok;
}

// Parse `git status --porcelain=v1 -z`
function parseStatus(stdout) {
    const parts = stdout.split('\0');
    const files = [];
    for (let i = 0; i < parts.length; i++) {
        const entry = parts[i];
        if (entry.length < 4) continue;
        const x = entry[0];
        const y = entry[1];
        const file = entry.slice(3);
        // Renames and copies carry the original path as the next field
        if (x === 'R' || x === 'C') i++;
        let status;
        if (x === '?' && y === '?') status = 'added';
        else if (x === 'D' || y === 'D') status = 'deleted';
        else if (x === 'A') status = 'added';
        else if (x === 'R') status = 'renamed';
        else status = 'modified';
        files.push({ path: file, status, untracked: x === '?' });
    }
    return files;
}

let busy = false;
function exclusive(handler) {
    return async (req, res) => {
        if (busy) return res.status(409).json({ ok: false, message: 'Another git operation is running' });
        busy = true;
        try { await handler(req, res); } finally { busy = false; }
    };
}

function register(app) {
    app.get('/api/git/status', async (req, res) => {
        const top = await repoRoot();
        if (!top) return res.json({ repo: false, configDir: CONFIG_DIR });
        const status = await git(['status', '--porcelain=v1', '-z', '--untracked-files=all', ...SAFE_PATHSPEC]);
        if (!status.ok) return res.status(500).json({ repo: true, error: status.stderr || 'git status failed' });
        const last = await git(['log', '-1', '--format=%ct%x00%s']);
        let lastCheckpoint = null;
        if (last.ok && last.stdout) {
            const [time, subject] = last.stdout.trim().split('\0');
            lastCheckpoint = { time: Number(time) * 1000, subject };
        }
        res.json({ repo: true, root: top, files: parseStatus(status.stdout), lastCheckpoint });
    });

    app.get('/api/git/diff', async (req, res) => {
        const top = await repoRoot();
        if (!top) return res.status(400).json({ error: 'Not a git repository' });
        const file = insideRepo(top, req.query.path);
        if (!file || isSensitive(file)) return res.status(400).json({ error: 'Path not allowed' });

        let result;
        if (await inLastCheckpoint(file)) {
            result = await git(['diff', '--no-color', '--no-ext-diff', 'HEAD', '--', file]);
        } else {
            // New file: show all of it as added. --no-index exits 1 when the
            // files differ, which here is always.
            result = await git(['diff', '--no-color', '--no-ext-diff', '--no-index', '--', '/dev/null', file]);
            if (result.code === 1) result.ok = true;
        }
        if (!result.ok) return res.status(500).json({ error: result.stderr || 'git diff failed' });
        let diff = result.stdout;
        const truncated = Buffer.byteLength(diff) > MAX_DIFF_BYTES;
        if (truncated) diff = diff.slice(0, MAX_DIFF_BYTES);
        const binary = /^Binary files .* differ$/m.test(diff);
        res.json({ path: file, fullPath: path.join(top, file), diff, truncated, binary });
    });

    app.post('/api/git/init', exclusive(async (req, res) => {
        if (await repoRoot()) return res.status(400).json({ ok: false, message: 'Already tracked' });
        const init = await git(['init', '-q']);
        if (!init.ok) return res.json({ ok: false, message: init.stderr || 'git init failed' });
        const gitignore = path.join(CONFIG_DIR, '.gitignore');
        if (!fs.existsSync(gitignore)) {
            try { fs.writeFileSync(gitignore, DEFAULT_GITIGNORE, { mode: 0o644 }); } catch { /* commit anyway */ }
        }
        const add = await git(['add', '-A', ...SAFE_PATHSPEC], { timeout: COMMIT_TIMEOUT });
        if (!add.ok) return res.json({ ok: false, message: add.stderr || 'git add failed' });
        const commit = await git([...await identityArgs(), 'commit', '-q', '--allow-empty', '-m', 'Starting point (Claude Terminal Pro)'], { timeout: COMMIT_TIMEOUT });
        res.json({ ok: commit.ok, message: commit.ok ? 'Now tracking changes in /config' : (commit.stderr || 'git commit failed') });
    }));

    app.post('/api/git/revert', exclusive(async (req, res) => {
        const top = await repoRoot();
        if (!top) return res.status(400).json({ ok: false, message: 'Not a git repository' });
        const file = insideRepo(top, req.query.path);
        if (!file || isSensitive(file)) return res.status(400).json({ ok: false, message: 'Path not allowed' });

        if (!await inLastCheckpoint(file)) {
            // A new file has no previous version to go back to. Deleting it
            // is irreversible, so leave that to the user.
            return res.json({ ok: false, message: 'This file is new, so there is no earlier version to restore. Delete it yourself if you don\'t want it.' });
        }
        // git writes the restored file as root; give it back to whoever owned
        // it (or its folder, if Claude deleted it)
        const full = path.join(top, file);
        let owner = null;
        for (const candidate of [full, path.dirname(full)]) {
            try { const st = fs.statSync(candidate); owner = { uid: st.uid, gid: st.gid }; break; } catch { /* try the folder */ }
        }
        // Restores both the index and the working tree to the last checkpoint
        const restore = await git(['checkout', 'HEAD', '--', file]);
        if (restore.ok && owner) {
            try { fs.chownSync(full, owner.uid, owner.gid); } catch { /* not fatal */ }
        }
        res.json({ ok: restore.ok, message: restore.ok ? `Restored ${file}` : (restore.stderr || 'Restore failed') });
    }));

    app.post('/api/git/checkpoint', exclusive(async (req, res) => {
        const top = await repoRoot();
        if (!top) return res.status(400).json({ ok: false, message: 'Not a git repository' });
        const add = await git(['add', '-A', ...SAFE_PATHSPEC], { timeout: COMMIT_TIMEOUT });
        if (!add.ok) return res.json({ ok: false, message: add.stderr || 'git add failed' });
        const message = `Checkpoint ${new Date().toISOString().replace('T', ' ').slice(0, 16)} (Claude Terminal Pro)`;
        const commit = await git([...await identityArgs(), 'commit', '-q', '-m', message], { timeout: COMMIT_TIMEOUT });
        if (!commit.ok && /nothing to commit/.test(commit.stdout + commit.stderr)) {
            return res.json({ ok: true, message: 'Nothing to accept' });
        }
        res.json({ ok: commit.ok, message: commit.ok ? 'Changes accepted as a new checkpoint' : (commit.stderr || 'git commit failed') });
    }));
}

export { register, parseStatus, insideRepo, isSensitive };
