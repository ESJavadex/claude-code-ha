// Preloaded into the image service by test-upload-concurrency.mjs. Delays
// fs.open (which write streams use) so the gap between choosing a name and
// creating the file is wide on every machine, not just a slow one.
import fs from 'node:fs';

const open = fs.open;
fs.open = function (...args) {
    setTimeout(() => open.apply(fs, args), 20);
};
