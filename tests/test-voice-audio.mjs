import assert from 'node:assert/strict';
import { pcm16, terminalText, recordAudio } from '../claude-terminal/image-service/public/voice-audio.mjs';

const encoded = new DataView(pcm16(new Float32Array([-2, -1, 0, 0.5, 1, 2, NaN])));
assert.deepEqual(Array.from({ length: 7 }, (_, i) => encoded.getInt16(i * 2, true)), [-32768, -32768, 0, 16384, 32767, 32767, 0]);
assert.equal(terminalText('hello\r\nworld\x1b[200~\t\0\x7f\x85\u2028\u2029'), 'hello  world [200~');
assert.equal(terminalText('  español, Grüße!  '), 'español, Grüße!');

// A permission prompt can resolve after the dialog has closed. Every track
// must still be stopped and the audio context released; no recorder starts.
let permission;
let closed = 0;
let trackStopped = 0;
globalThis.AudioContext = class {
    resume() { return Promise.resolve(); }
    close() { closed++; return Promise.resolve(); }
};
Object.defineProperty(globalThis, 'navigator', { configurable: true, value: {
    mediaDevices: { getUserMedia: () => new Promise((resolve) => { permission = resolve; }) }
} });
const controller = new AbortController();
const pending = recordAudio(() => assert.fail('recording started'), controller.signal);
await new Promise((resolve) => setImmediate(resolve));
controller.abort();
permission({ getTracks: () => [{ stop: () => trackStopped++ }] });
await assert.rejects(pending, /cancelled/);
assert.ok(closed > 0);
assert.equal(trackStopped, 1);
console.log('Voice PCM encoding, terminal control stripping and delayed permission cancellation passed');
