// HA's STT API consumes raw PCM, without a WAV container header.
export function pcm16(samples) {
    const bytes = new ArrayBuffer(samples.length * 2);
    const view = new DataView(bytes);
    for (let i = 0; i < samples.length; i++) {
        const value = Number.isFinite(samples[i]) ? Math.max(-1, Math.min(1, samples[i])) : 0;
        view.setInt16(i * 2, Math.round(value * (value < 0 ? 32768 : 32767)), true);
    }
    return bytes;
}

// Never paste control sequences or line breaks into a root shell. The user
// still reviews the text and presses Enter in the terminal themselves.
export function terminalText(text) {
    return text.replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029]/g, ' ').trim();
}

export async function recordAudio(onLimit, signal) {
    let stream, context, source, recorder;
    let stopped = false;
    const chunks = [];
    let frames = 0;
    let timer;
    const release = () => {
        clearTimeout(timer);
        if (recorder) { recorder.port.onmessage = null; recorder.disconnect(); }
        source?.disconnect();
        stream?.getTracks().forEach((track) => track.stop());
        context?.close().catch(() => {});
    };
    signal.addEventListener('abort', release, { once: true });
    try {
        // Resume inside the click handler, before waiting for permission.
        // Use the device's rate for capture. Firefox may refuse to connect a
        // microphone stream to a context forced to a different sample rate.
        // OfflineAudioContext converts to the STT rate after recording.
        context = new AudioContext();
        // Request resume during the click, but do not wait before asking for
        // the microphone: some browsers defer audio startup until permission.
        context.resume().catch(() => {});
        stream = await navigator.mediaDevices.getUserMedia({ audio: { channelCount: 1 }, video: false });
        if (signal.aborted) throw new Error('Recording cancelled.');
        await context.audioWorklet.addModule('voice-recorder-worklet.js');
        if (signal.aborted) throw new Error('Recording cancelled.');
        source = context.createMediaStreamSource(stream);
        recorder = new AudioWorkletNode(context, 'voice-recorder');
        recorder.port.onmessage = ({ data }) => {
            if (stopped) return;
            const remaining = context.sampleRate * 60 - frames;
            if (remaining > 0) {
                const chunk = data.slice(0, remaining);
                chunks.push(chunk);
                frames += chunk.length;
            }
            if (frames >= context.sampleRate * 60) onLimit();
        };
        source.connect(recorder);
        // The processor outputs silence, but needs a destination to be pulled.
        recorder.connect(context.destination);
        let startupTimer;
        try {
            await Promise.race([
                context.resume(),
                new Promise((_, reject) => {
                    startupTimer = setTimeout(() => reject(new Error('Audio could not start. Check your microphone and audio device permissions.')), 10000);
                })
            ]);
        } finally { clearTimeout(startupTimer); }
        if (signal.aborted) throw new Error('Recording cancelled.');
        timer = setTimeout(onLimit, 60000);
        return {
            cancel() { stopped = true; chunks.length = 0; signal.removeEventListener('abort', release); release(); },
            async stop() {
                if (stopped) throw new Error('Recording already stopped.');
                stopped = true;
                signal.removeEventListener('abort', release);
                const rate = context.sampleRate;
                release();
                if (!frames) throw new Error('No audio captured. Try again.');
                const samples = new Float32Array(frames);
                let offset = 0;
                for (const chunk of chunks) { samples.set(chunk, offset); offset += chunk.length; }
                chunks.length = 0;
                if (rate === 16000) return pcm16(samples);
                const offline = new OfflineAudioContext(1, Math.min(960000, Math.ceil(frames * 16000 / rate)), 16000);
                const buffer = offline.createBuffer(1, frames, rate);
                buffer.copyToChannel(samples, 0);
                const input = offline.createBufferSource();
                input.buffer = buffer;
                input.connect(offline.destination);
                input.start();
                return pcm16((await offline.startRendering()).getChannelData(0));
            }
        };
    } catch (error) {
        signal.removeEventListener('abort', release);
        release();
        throw error;
    }
}
