import AVFoundation

/// Utility for extracting a downsampled amplitude array from an audio file.
/// Used to render waveform bars in audio message cells.
public enum AudioWaveformHelper {

    /// Extracts `count` normalised amplitude samples (each in [0, 1]) from the audio file at `url`.
    /// Runs off the main thread; calls `completion` on the main thread.
    /// Returns an empty array on any error.
    public static func extractSamples(from url: URL,
                                      count: Int = 40,
                                      completion: @escaping ([Float]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let samples = readSamples(from: url, count: count)
            DispatchQueue.main.async {
                completion(samples)
            }
        }
    }

    // MARK: - Private

    private static func readSamples(from url: URL, count: Int) -> [Float] {
        guard let audioFile = try? AVAudioFile(forReading: url) else { return [] }

        let format = audioFile.processingFormat
        let channelCount = Int(format.channelCount)
        guard channelCount > 0 else { return [] }

        // Cap at 2M frames to avoid excess memory usage on very long files
        let maxFrames: AVAudioFrameCount = 2_000_000
        let totalFrames = min(AVAudioFrameCount(audioFile.length), maxFrames)
        guard totalFrames > 0 else { return [] }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames) else { return [] }

        do {
            try audioFile.read(into: buffer, frameCount: totalFrames)
        } catch {
            return []
        }

        guard let channelData = buffer.floatChannelData else { return [] }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return [] }

        // Average channels into mono
        var monoSamples = [Float](repeating: 0, count: frameCount)
        for ch in 0 ..< channelCount {
            let channel = channelData[ch]
            for i in 0 ..< frameCount {
                monoSamples[i] += abs(channel[i])
            }
        }
        if channelCount > 1 {
            let divisor = Float(channelCount)
            for i in 0 ..< frameCount {
                monoSamples[i] /= divisor
            }
        }

        // Downsample to `count` buckets using max-abs per chunk
        let chunkSize = max(1, frameCount / count)
        var result = [Float](repeating: 0, count: count)
        for i in 0 ..< count {
            let start = i * chunkSize
            let end = min(start + chunkSize, frameCount)
            var peak: Float = 0
            for j in start ..< end {
                if monoSamples[j] > peak { peak = monoSamples[j] }
            }
            result[i] = peak
        }

        // Normalise so the loudest bar = 1.0
        let maxVal = result.max() ?? 1
        if maxVal > 0 {
            for i in 0 ..< count {
                result[i] /= maxVal
            }
        }

        return result
    }
}
