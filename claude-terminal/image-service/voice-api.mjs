// Speech goes only to the configured HA STT engine through the Supervisor.
// No browser-supplied URL, token, command or file path is accepted.
import express from 'express';

export const MAX_AUDIO_BYTES = 16000 * 2 * 60;
const PROVIDER = /^(?:stt\.)?[a-z0-9_]+$/;
const LANGUAGE = /^[a-zA-Z]{2,3}(?:[-_][a-zA-Z0-9]{2,8}){0,2}$/;

async function boundedJson(response) {
    if (!response.ok) throw new Error('upstream');
    const reader = response.body.getReader();
    const chunks = [];
    let size = 0;
    try {
        for (;;) {
            const { done, value } = await reader.read();
            if (done) break;
            size += value.length;
            if (size > 65536) throw new Error('upstream');
            chunks.push(Buffer.from(value));
        }
        return JSON.parse(Buffer.concat(chunks).toString('utf8'));
    } finally {
        await reader.cancel().catch(() => {});
    }
}

export function register(app, {
    provider = process.env.VOICE_STT_PROVIDER || '',
    language = process.env.VOICE_LANGUAGE || '',
    token = process.env.SUPERVISOR_TOKEN || '',
    request = globalThis.fetch,
    timeoutMs = 30000
} = {}) {
    const enabled = PROVIDER.test(provider) && Boolean(token);
    const endpoint = `http://supervisor/core/api/stt/${encodeURIComponent(provider)}`;
    let busy = false;

    app.get('/api/voice/config', (req, res) => {
        res.set('Cache-Control', 'no-store').json({ enabled, language });
    });

    app.post('/api/voice/transcribe', (req, res, next) => {
        res.set('Cache-Control', 'no-store');
        // A custom header and non-simple content type prevent cross-site forms
        // from triggering recording uploads. No CORS permission is granted.
        if (req.get('X-Voice-Request') !== '1') return res.sendStatus(403);
        if (!enabled) return res.status(503).json({ error: 'Configure voice_stt_provider in the add-on options first.' });
        if (busy) return res.status(409).json({ error: 'A transcription is already running.' });
        if (!req.is('application/octet-stream')) return res.sendStatus(415);
        busy = true;
        // Reserve before reading the body: concurrent callers cannot allocate
        // a separate full recording each. Also release on parser errors.
        res.once('close', () => { if (!res.locals.voiceProcessing) busy = false; });
        next();
    }, express.raw({ type: 'application/octet-stream', limit: MAX_AUDIO_BYTES }), async (req, res) => {
        res.locals.voiceProcessing = true;
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), timeoutMs);
        const cancel = () => { if (!res.writableFinished) controller.abort(); };
        res.once('close', cancel);
        try {
            if (!Buffer.isBuffer(req.body) || req.body.length < 2 || req.body.length % 2) {
                return res.status(400).json({ error: 'Send 16 kHz, mono, signed 16-bit little-endian PCM audio.' });
            }
            const wanted = req.get('X-Voice-Language') || language;
            if (!LANGUAGE.test(wanted)) return res.status(400).json({ error: 'Choose a valid speech language.' });
            const options = {
                headers: { Authorization: `Bearer ${token}` },
                redirect: 'error', signal: controller.signal
            };
            const info = await boundedJson(await request(endpoint, options));
            const normal = (code) => code.toLowerCase().replaceAll('_', '-');
            const languages = Array.isArray(info.languages) ? info.languages.filter((code) => typeof code === 'string' && LANGUAGE.test(code)) : [];
            const selected = languages.find((code) => normal(code) === normal(wanted)) ||
                languages.find((code) => normal(code) === normal(wanted).split('-')[0]);
            if (!selected) return res.status(400).json({ error: 'This STT engine does not support that language. Set voice_language to one it supports.' });
            if (!info.formats?.includes('wav') || !info.codecs?.includes('pcm') ||
                !info.sample_rates?.includes(16000) || !info.bit_rates?.includes(16) || !info.channels?.includes(1)) {
                return res.status(400).json({ error: 'This STT engine must support 16 kHz mono PCM audio.' });
            }
            const result = await boundedJson(await request(endpoint, {
                ...options, method: 'POST', body: req.body,
                headers: {
                    ...options.headers, 'Content-Type': 'audio/wav',
                    'X-Speech-Content': `format=wav; codec=pcm; sample_rate=16000; bit_rate=16; channel=1; language=${selected}`
                }
            }));
            if (result.result !== 'success' || typeof result.text !== 'string' || result.text.length > 16000) throw new Error('upstream');
            res.json({ text: result.text });
        } catch {
            // Upstream errors can contain credentials or transcription data.
            // Return a fixed message and never log audio, text or the token.
            if (!res.destroyed) res.status(502).json({ error: 'Home Assistant transcription failed or timed out. Check the STT engine and its language settings.' });
        } finally {
            clearTimeout(timer);
            res.removeListener('close', cancel);
            busy = false;
        }
    }, (error, req, res, next) => {
        busy = false;
        if (error.type === 'entity.too.large') return res.status(413).json({ error: 'Record at most 60 seconds of audio.' });
        next(error);
    });
}
