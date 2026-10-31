// Audio stays in memory. The page stops capture after at most 60 seconds.
class VoiceRecorder extends AudioWorkletProcessor {
    process(inputs) {
        const channel = inputs[0]?.[0];
        if (channel) this.port.postMessage(channel.slice());
        return true;
    }
}
registerProcessor('voice-recorder', VoiceRecorder);
