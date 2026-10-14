#!/usr/bin/env node
// Path confinement and git status parsing for the sidebar APIs
const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'sidebar-'));
fs.mkdirSync(path.join(root, 'packages'));
fs.writeFileSync(path.join(root, 'packages', 'a.yaml'), 'x: 1\n');
fs.symlinkSync('/etc', path.join(root, 'escape'));
process.env.FILE_ROOTS = root;

const files = require('../claude-terminal/image-service/files-api');
const gitApi = require('../claude-terminal/image-service/git-api');
const realRoot = fs.realpathSync(root);
let passed = 0;
const ok = (name, fn) => { fn(); passed++; console.log('ok   ' + name); };

ok('a file inside the root resolves', () => {
    assert.strictEqual(files.resolveInsideRoots(path.join(root, 'packages', 'a.yaml')), path.join(realRoot, 'packages', 'a.yaml'));
});
ok('the root itself resolves', () => assert.strictEqual(files.resolveInsideRoots(root), realRoot));
ok('../ out of the root is refused', () => assert.strictEqual(files.resolveInsideRoots(path.join(root, '..', '..', 'etc', 'passwd')), null));
ok('an absolute path elsewhere is refused', () => assert.strictEqual(files.resolveInsideRoots('/etc/passwd'), null));
ok('a symlink pointing out is refused', () => assert.strictEqual(files.resolveInsideRoots(path.join(root, 'escape', 'passwd')), null));
ok('NUL bytes are refused', () => assert.strictEqual(files.resolveInsideRoots(root + '/a\0b'), null));
ok('empty and non-string paths are refused', () => {
    assert.strictEqual(files.resolveInsideRoots(''), null);
    assert.strictEqual(files.resolveInsideRoots(['x']), null);
});

ok('repo paths stay inside the repo', () => {
    assert.strictEqual(gitApi.insideRepo('/config', 'packages/a.yaml'), 'packages/a.yaml');
    assert.strictEqual(gitApi.insideRepo('/config', '../etc/passwd'), null);
    assert.strictEqual(gitApi.insideRepo('/config', '/etc/passwd'), null);
    assert.strictEqual(gitApi.insideRepo('/config', 'a/../../etc'), null);
    assert.strictEqual(gitApi.insideRepo('/config', ''), null);
    assert.strictEqual(gitApi.insideRepo('/config', 'x\0y'), null);
});
ok('option-looking names are just file names', () => {
    assert.strictEqual(gitApi.insideRepo('/config', '--output=/tmp/x'), '--output=/tmp/x');
});

ok('git status -z is parsed, including renames and spaces', () => {
    const out = [' M automations.yaml', '?? packages/new file.yaml', ' D scripts.yaml', 'A  added.yaml', 'R  new.yaml', 'old.yaml', ''].join('\0');
    assert.deepStrictEqual(gitApi.parseStatus(out), [
        { path: 'automations.yaml', status: 'modified', untracked: false },
        { path: 'packages/new file.yaml', status: 'added', untracked: true },
        { path: 'scripts.yaml', status: 'deleted', untracked: false },
        { path: 'added.yaml', status: 'added', untracked: false },
        { path: 'new.yaml', status: 'renamed', untracked: false }
    ]);
});

ok('.git is never browsable (remote URLs can hold tokens)', () => {
    fs.mkdirSync(path.join(root, '.git'));
    fs.writeFileSync(path.join(root, '.git', 'config'), '[remote]\n');
    assert.strictEqual(files.resolveInsideRoots(path.join(root, '.git', 'config')), null);
    assert.strictEqual(files.resolveInsideRoots(path.join(root, '.git')), null);
});

ok('secrets and databases are sensitive, normal files are not', () => {
    for (const p of ['secrets.yaml', 'packages/secrets.yaml', 'secrets.yml', '.storage/auth', 'home-assistant_v2.db',
        'x.db-wal', '.ssh/id_rsa', 'certs/server.key', 'certs/a.pem', '.env', '.git-credentials', 'sub/.cloud/x']) {
        assert.strictEqual(gitApi.isSensitive(p), true, p);
    }
    for (const p of ['automations.yaml', 'packages/clima.yaml', 'secrets_example.md', 'storage.yaml', 'keyboard.yaml']) {
        assert.strictEqual(gitApi.isSensitive(p), false, p);
    }
});

fs.rmSync(root, { recursive: true, force: true });
console.log(`\nAll ${passed} sidebar API tests passed`);
