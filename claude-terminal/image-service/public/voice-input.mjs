import { recordAudio, terminalText } from './voice-audio.mjs';

const get = (id) => document.getElementById(`voice-${id}`);
const modal = get('modal');
const status = get('status');
const transcript = get('transcript');
const record = get('record-btn');
const copy = get('copy-btn');
const send = get('send-btn');
const language = get('language');
const SpeechRecognition = window.SpeechRecognition || window.webkitSpeechRecognition;
let config = null;
let active = null;
let generation = 0;
let state = 'idle';

function message(text) { status.textContent = text; }
function update() {
    record.disabled = !config || (config.configured && !config.enabled) || state === 'starting' || state === 'transcribing';
    record.textContent = state === 'recording' ? 'Stop Recording' : state === 'transcribing' ? 'Transcribing…' : 'Start Recording';
    language.disabled = state !== 'idle';
    const ready = state === 'idle' && Boolean(transcript.textContent.trim());
    copy.style.display = send.style.display = ready ? 'inline-block' : 'none';
    transcript.classList.toggle('listening', state === 'recording');
    get('btn').classList.toggle('recording', state === 'recording');
}

function cancel() {
    generation++;
    active?.controller.abort();
    active?.audio?.cancel();
    active?.recognition?.abort();
    clearTimeout(active?.timer);
    active = null;
    state = 'idle';
    update();
}
function close() { cancel(); modal.classList.remove('active'); }

get('btn').addEventListener('click', async () => {
    cancel();
    modal.classList.add('active');
    transcript.textContent = '';
    update();
    if (!config) {
        const id = generation;
        try {
            const response = await fetch('api/voice/config', { cache: 'no-store' });
            if (!response.ok) throw new Error();
            const value = await response.json();
            if (id !== generation) return;
            config = value;
            language.value = config.language || navigator.language || 'en-US';
        } catch {
            if (id === generation) message('Could not load voice settings. Close and try again.');
            return;
        }
    }
    message(config.enabled
        ? 'Uses your configured Home Assistant speech-to-text engine. Up to 60 seconds per recording.'
        : config.configured
            ? 'Home Assistant STT is configured but unavailable. Check voice_stt_provider and Supervisor access.'
            : SpeechRecognition
            ? 'Uses your browser’s speech service. Set voice_stt_provider to use Home Assistant instead.'
            : 'Set voice_stt_provider in the add-on options to use Home Assistant speech-to-text in this browser.');
    update();
});

get('close-btn').addEventListener('click', close);
modal.addEventListener('click', (event) => { if (event.target === modal) close(); });
modal.addEventListener('keydown', (event) => { if (event.key === 'Escape') close(); });
window.addEventListener('pagehide', cancel);
transcript.addEventListener('input', update);

record.addEventListener('click', async () => {
    if (state === 'recording') { await stop(); return; }
    if (state !== 'idle' || !config) return;
    if (config.configured && !config.enabled) return;
    if (!/^[a-zA-Z]{2,3}(?:[-_][a-zA-Z0-9]{2,8}){0,2}$/.test(language.value.trim())) {
        message('Enter a language code such as en, en-US, es or de-DE.');
        return;
    }
    if (!window.isSecureContext) {
        message('Microphone access requires HTTPS (or localhost). Open Home Assistant over HTTPS.');
        return;
    }
    if (!config.enabled && !SpeechRecognition) {
        message('Set voice_stt_provider in the add-on options first.');
        return;
    }
    const session = { id: ++generation, controller: new AbortController() };
    active = session;
    state = 'starting';
    transcript.textContent = '';
    message('Requesting microphone access…');
    update();
    try {
        if (config.enabled) {
            if (!navigator.mediaDevices?.getUserMedia || !window.AudioWorkletNode) {
                throw new Error('Audio recording is unavailable. Check microphone permissions and use a current browser over HTTPS.');
            }
            session.audio = await recordAudio(() => { if (state === 'recording') void stop(); }, session.controller.signal);
            if (session.id !== generation) { session.audio.cancel(); return; }
        } else {
            const recognition = session.recognition = new SpeechRecognition();
            recognition.lang = language.value.trim();
            recognition.continuous = true;
            recognition.interimResults = true;
            recognition.onresult = (event) => {
                if (session.id !== generation) return;
                // Read the entire result list: interim results can be revised.
                transcript.textContent = Array.from(event.results).map((result) => result[0].transcript).join(' ');
            };
            recognition.onerror = (event) => {
                if (session.id !== generation) return;
                cancel();
                message(event.error === 'not-allowed'
                    ? 'Microphone access denied. Allow it in your browser or Companion app settings.'
                    : 'Browser speech recognition failed. Try again, or configure voice_stt_provider to use Home Assistant.');
            };
            recognition.onend = () => {
                if (session.id !== generation) return;
                clearTimeout(session.timer);
                state = 'idle';
                active = null;
                message('Recording stopped. Review the text before copying or inserting it.');
                update();
            };
            recognition.start();
            session.timer = setTimeout(() => { if (state === 'recording') void stop(); }, 60000);
        }
        state = 'recording';
        message('Listening… Press Stop Recording when finished.');
        update();
    } catch (error) {
        if (session.id !== generation) return;
        cancel();
        message(error.name === 'NotAllowedError' ? 'Microphone access denied. Allow it in your browser or Companion app settings.' : error.message);
    }
});

async function stop() {
    const session = active;
    if (!session || state !== 'recording') return;
    state = 'transcribing';
    update();
    if (session.recognition) { session.recognition.stop(); return; }
    message('Transcribing with Home Assistant…');
    const timer = setTimeout(() => session.controller.abort(), 35000);
    try {
        const audio = await session.audio.stop();
        if (session.id !== generation) return;
        const response = await fetch('api/voice/transcribe', {
            method: 'POST', signal: session.controller.signal,
            headers: { 'Content-Type': 'application/octet-stream', 'X-Voice-Request': '1', 'X-Voice-Language': language.value.trim() },
            body: audio
        });
        const result = await response.json();
        if (session.id !== generation) return;
        if (!response.ok) throw new Error(result.error || 'Transcription failed.');
        transcript.textContent = result.text;
        message(result.text.trim() ? 'Transcript ready. Review and edit before copying or inserting it.' : 'No speech detected. Try again.');
    } catch (error) {
        if (session.id === generation) message(error.name === 'AbortError' ? 'Transcription timed out. Try a shorter recording.' : error.message);
    } finally {
        clearTimeout(timer);
        if (session.id === generation) { active = null; state = 'idle'; update(); }
    }
}

copy.addEventListener('click', async () => {
    const ok = await window.copyToClipboard(transcript.textContent.trim());
    message(ok ? 'Copied to clipboard.' : 'Copy was blocked. Select the text and copy it manually.');
});
send.addEventListener('click', () => {
    const text = terminalText(transcript.textContent);
    if (!text) return;
    try {
        const term = document.getElementById('terminal-frame').contentWindow.term;
        if (typeof term?.paste !== 'function') throw new Error();
        term.paste(text);
        close();
        term.focus();
    } catch { message('Terminal unavailable. Copy the text and paste it manually.'); }
});
update();
