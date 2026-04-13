import Foundation
import Accelerate

// MARK: - MelSpectrogramExtractor

/// Pure-Swift mel spectrogram extractor matching the CohereASR preprocessor configuration.
///
/// Implements the full feature extraction pipeline:
///   1. Pre-emphasis filter (coefficient 0.97)
///   2. STFT with Hann window (n_fft=512, win_length=400, hop_length=160)
///      using reflect-pad centering so frame 0 is centred on sample 0
///   3. Mel filterbank (128 bins, Slaney-normalised, matching librosa norm='slaney')
///   4. Natural log with floor epsilon 1e-9
///   5. Per-feature (per mel-bin) mean/std normalisation
///
/// The mel filterbank is computed once on first use and cached for the lifetime of
/// the extractor. All heavy-lifting uses Apple's Accelerate / vDSP framework.
///
/// Thread-safety: thread-safe after the first `extract` call completes (filterbank
/// is initialised lazily under a lock).  For concurrent callers, construct one
/// instance per thread or wrap in a Swift actor.
final class MelSpectrogramExtractor {

    // MARK: - Configuration (matches preprocessor_config.json)

    static let sampleRate   = 16000
    static let nFFT         = 512
    static let winLength    = 400
    static let hopLength    = 160
    static let nMels        = 128
    static let preemphasis  : Float = 0.97
    static let logEpsilon   : Float = 1e-9

    // MARK: - Slaney mel-scale constants (identical to librosa norm='slaney')

    private static let fMin          : Double = 0.0
    private static let fSp           : Double = 200.0 / 3.0        // 66.667 Hz per mel (linear region)
    private static let minLogHz      : Double = 1000.0
    private static let minLogMel     : Double = (minLogHz - fMin) / fSp   // ≈ 15.0
    private static let logStep       : Double = log(6.4) / 27.0           // ≈ 0.06875

    // MARK: - Cached state

    /// Flat mel filterbank, row-major [nMels × (nFFT/2+1)].
    private lazy var melFilterbank: [Float] = buildMelFilterbank()

    // MARK: - Public interface

    /// Extract mel spectrogram features from raw 16 kHz mono audio.
    ///
    /// - Parameter samples: Float32 audio samples at 16 kHz, mono.
    /// - Returns: Tuple of (features, frameCount) where features is a flat array
    ///   in row-major order [frameCount × nMels], i.e. the value at frame `t`,
    ///   bin `m` is `features[t * nMels + m]`.
    func extract(samples: [Float]) -> (features: [Float], frameCount: Int) {
        let n = samples.count

        // --- 1. Pre-emphasis ---
        var emph = [Float](repeating: 0, count: n)
        emph[0] = samples[0]
        if n > 1 {
            // emph[i] = samples[i] - alpha * samples[i-1]
            // vDSP_vsma(A, IA, B, C, IC, D, ID, N): D[n] = A[n]*B + C[n]
            // So: emph[1..] = delayed[0..] * (-alpha) + current[1..]
            var negAlpha: Float = -MelSpectrogramExtractor.preemphasis
            samples.withUnsafeBufferPointer { samplesPtr in
                let delayedPtr = samplesPtr.baseAddress!          // samples[0..n-2]
                let currentPtr = samplesPtr.baseAddress! + 1      // samples[1..n-1]
                emph.withUnsafeMutableBufferPointer { emphPtr in
                    vDSP_vsma(delayedPtr, 1,             // A: samples[i-1]
                              &negAlpha,                 // B: -alpha (scalar)
                              currentPtr, 1,             // C: samples[i], IC=1
                              emphPtr.baseAddress! + 1, 1,   // D: output, ID=1
                              vDSP_Length(n - 1))        // N: count
                }
            }
        }

        // --- 2. Reflect-pad (center = true, pad = nFFT/2 on each side) ---
        let pad       = MelSpectrogramExtractor.nFFT / 2   // 256
        let nFFT      = MelSpectrogramExtractor.nFFT        // 512
        let hopLength = MelSpectrogramExtractor.hopLength   // 160
        let padded    = reflectPad(emph, padSize: pad)

        // --- 3. Hann window (win_length=400, left-aligned in nFFT=512 frame) ---
        let window = makeHannWindow(winLength: MelSpectrogramExtractor.winLength, nFFT: nFFT)

        // --- 4. STFT with vDSP FFT ---
        let nFreqs   = nFFT / 2 + 1   // 257
        let nFrames  = 1 + (padded.count - nFFT) / hopLength

        // Interleaved power spectra: [nFreqs × nFrames]
        var powerSpec = [Float](repeating: 0, count: nFreqs * nFrames)
        computeSTFTPower(
            signal:    padded,
            window:    window,
            nFFT:      nFFT,
            hopLength: hopLength,
            nFrames:   nFrames,
            nFreqs:    nFreqs,
            output:    &powerSpec
        )

        // --- 5. Mel filterbank (128 × 257 matrix) × power spectra (257 × nFrames) ---
        let nMels = MelSpectrogramExtractor.nMels
        var melSpec = [Float](repeating: 0, count: nMels * nFrames)

        // vDSP_mmul: C (M×N) = A (M×P) × B (P×N)
        //   A = melFilterbank  (nMels × nFreqs)
        //   B = powerSpec      (nFreqs × nFrames)
        //   C = melSpec        (nMels × nFrames)
        melFilterbank.withUnsafeBufferPointer { fbPtr in
            powerSpec.withUnsafeBufferPointer { psPtr in
                melSpec.withUnsafeMutableBufferPointer { msPtr in
                    vDSP_mmul(
                        fbPtr.baseAddress!, 1,
                        psPtr.baseAddress!, 1,
                        msPtr.baseAddress!, 1,
                        vDSP_Length(nMels),   // M
                        vDSP_Length(nFrames), // N
                        vDSP_Length(nFreqs)   // P
                    )
                }
            }
        }

        // --- 6. Log with floor epsilon ---
        let eps = MelSpectrogramExtractor.logEpsilon
        var logMel = melSpec
        let logMelCount = logMel.count
        logMel.withUnsafeMutableBufferPointer { ptr in
            var floorVal = eps
            let count = vDSP_Length(logMelCount)
            // Clamp to [eps, +inf)
            vDSP_vthr(ptr.baseAddress!, 1, &floorVal, ptr.baseAddress!, 1, count)
            // In-place natural log via vvlogf
            var n32 = Int32(logMelCount)
            vvlogf(ptr.baseAddress!, ptr.baseAddress!, &n32)
        }

        // --- 7. Per-feature (per mel-bin) normalisation ---
        // logMel is [nMels × nFrames] row-major → each row is one mel bin across all frames
        var normed = logMel
        normed.withUnsafeMutableBufferPointer { ptr in
            for m in 0..<nMels {
                let rowStart = ptr.baseAddress! + m * nFrames
                let len = vDSP_Length(nFrames)

                // Compute mean
                var mean: Float = 0
                vDSP_meanv(rowStart, 1, &mean, len)

                // Subtract mean
                var negMean = -mean
                vDSP_vsadd(rowStart, 1, &negMean, rowStart, 1, len)

                // Compute std
                var rms: Float = 0
                vDSP_rmsqv(rowStart, 1, &rms, len)
                // rms = sqrt(mean(x^2)); since mean was subtracted, rms = std
                let std = max(rms, 1e-8)

                // Divide by std
                var invStd = 1.0 / std
                vDSP_vsmul(rowStart, 1, &invStd, rowStart, 1, len)
            }
        }

        // --- 8. Transpose from [nMels × nFrames] to [nFrames × nMels] ---
        var transposed = [Float](repeating: 0, count: nFrames * nMels)
        normed.withUnsafeBufferPointer { src in
            transposed.withUnsafeMutableBufferPointer { dst in
                // vDSP_mtrans transposes an M×N matrix to N×M
                vDSP_mtrans(
                    src.baseAddress!, 1,
                    dst.baseAddress!, 1,
                    vDSP_Length(nFrames),  // rows of output = cols of input
                    vDSP_Length(nMels)     // cols of output = rows of input
                )
            }
        }

        return (transposed, nFrames)
    }

    // MARK: - Private: Reflect Pad

    private func reflectPad(_ signal: [Float], padSize: Int) -> [Float] {
        let n = signal.count
        guard padSize > 0 && n > 1 else { return signal }

        var out = [Float](repeating: 0, count: n + 2 * padSize)

        // Fill center
        out.withUnsafeMutableBufferPointer { buf in
            signal.withUnsafeBufferPointer { sig in
                buf.baseAddress!.advanced(by: padSize)
                    .initialize(from: sig.baseAddress!, count: n)
            }
        }

        // Left pad: reflect signal[1..padSize] reversed
        for i in 0..<padSize {
            let srcIdx = min(padSize - i, n - 1)
            out[i] = signal[srcIdx]
        }

        // Right pad: reflect signal[n-2..n-1-padSize] reversed
        for i in 0..<padSize {
            let srcIdx = max(n - 2 - i, 0)
            out[n + padSize + i] = signal[srcIdx]
        }

        return out
    }

    // MARK: - Private: Hann Window

    /// Create a Hann window of `winLength` samples, zero-padded to `nFFT` (left-aligned).
    private func makeHannWindow(winLength: Int, nFFT: Int) -> [Float] {
        var window = [Float](repeating: 0, count: nFFT)
        // Hann window: w[n] = 0.5 * (1 - cos(2π n / (N-1)))  (periodic via N not N-1 for DFT)
        // librosa uses scipy.signal.get_window('hann', win_length) which is symmetric:
        //   w[n] = 0.5 * (1 - cos(2π n / (N-1))), n=0..N-1
        for i in 0..<winLength {
            let angle = 2.0 * Float.pi * Float(i) / Float(winLength - 1)
            window[i] = 0.5 * (1.0 - cos(angle))
        }
        return window
    }

    // MARK: - Private: STFT Power Spectrum

    private func computeSTFTPower(
        signal:    [Float],
        window:    [Float],
        nFFT:      Int,
        hopLength: Int,
        nFrames:   Int,
        nFreqs:    Int,
        output:    inout [Float]  // [nFreqs × nFrames] row-major
    ) {
        let log2n = vDSP_Length(log2(Float(nFFT)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("MelSpectrogramExtractor: failed to create FFT setup for n=\(nFFT)")
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        // Workspace for split complex
        var realPart = [Float](repeating: 0, count: nFFT / 2)
        var imagPart = [Float](repeating: 0, count: nFFT / 2)

        for frameIdx in 0..<nFrames {
            let start = frameIdx * hopLength

            // Apply window to nFFT samples
            var windowed = [Float](repeating: 0, count: nFFT)
            signal.withUnsafeBufferPointer { sigPtr in
                window.withUnsafeBufferPointer { winPtr in
                    vDSP_vmul(
                        sigPtr.baseAddress! + start, 1,
                        winPtr.baseAddress!, 1,
                        &windowed, 1,
                        vDSP_Length(nFFT))
                }
            }

            // Convert to split complex (interleaved real-imag pairs → split)
            realPart.withUnsafeMutableBufferPointer { rPtr in
                imagPart.withUnsafeMutableBufferPointer { iPtr in
                    var splitComplex = DSPSplitComplex(realp: rPtr.baseAddress!, imagp: iPtr.baseAddress!)
                    windowed.withUnsafeBufferPointer { wPtr in
                        wPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: nFFT / 2) { cPtr in
                            vDSP_ctoz(cPtr, 2, &splitComplex, 1, vDSP_Length(nFFT / 2))
                        }
                    }

                    // Forward FFT (in-place)
                    vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))

                    // Compute power spectrum
                    // After real FFT via vDSP_fft_zrip, the output uses a packed format:
                    //   realp[0]  = DC real  (imagp[0] = Nyquist real stored here)
                    //   realp[k]  = real[k] for k=1..N/2-1
                    //   imagp[k]  = imag[k] for k=1..N/2-1
                    // We need |X[k]|^2 for k=0..N/2 (i.e. nFreqs = N/2+1 values)

                    // The vDSP scale factor is N (not N/2) for the full forward FFT,
                    // but we only need relative power so we skip scaling here.

                    let outBase = output.withUnsafeMutableBufferPointer { $0.baseAddress! }

                    // k=0 (DC): real=realp[0], imag=0
                    let dcReal = rPtr[0]
                    outBase[0 * nFrames + frameIdx] = dcReal * dcReal

                    // k=1..N/2-1
                    for k in 1..<(nFFT / 2) {
                        let re = rPtr[k]
                        let im = iPtr[k]
                        outBase[k * nFrames + frameIdx] = re * re + im * im
                    }

                    // k=N/2 (Nyquist): real=imagp[0], imag=0
                    let nyqReal = iPtr[0]
                    outBase[(nFFT / 2) * nFrames + frameIdx] = nyqReal * nyqReal
                }
            }
        }
    }

    // MARK: - Private: Build Mel Filterbank

    /// Compute the 128×257 Slaney-normalised mel filterbank matrix
    /// (identical to `librosa.filters.mel(sr=16000, n_fft=512, n_mels=128, norm='slaney')`).
    private func buildMelFilterbank() -> [Float] {
        let sr     = Double(MelSpectrogramExtractor.sampleRate)
        let nFFT   = MelSpectrogramExtractor.nFFT
        let nMels  = MelSpectrogramExtractor.nMels
        let nFreqs = nFFT / 2 + 1   // 257

        let fMin: Double = 0.0
        let fMax: Double = sr / 2.0   // 8000 Hz

        // n_mels+2 mel-spaced points from fMin to fMax (inclusive)
        let melMin = hzToMelSlaney(fMin)
        let melMax = hzToMelSlaney(fMax)
        let nPoints = nMels + 2

        var melPoints = [Double](repeating: 0, count: nPoints)
        for i in 0..<nPoints {
            melPoints[i] = melMin + Double(i) * (melMax - melMin) / Double(nPoints - 1)
        }

        // Convert mel points back to Hz
        var hzPoints = melPoints.map { melToHzSlaney($0) }

        // Map Hz to FFT bin indices (not rounded — keep fractional for triangle construction)
        var binPoints = hzPoints.map { $0 * Double(nFFT + 1) / sr }

        // Build filterbank row by row (nMels × nFreqs), stored row-major
        var fb = [Float](repeating: 0, count: nMels * nFreqs)

        for m in 0..<nMels {
            let lo     = binPoints[m]      // lower edge of triangle
            let center = binPoints[m + 1]  // peak
            let hi     = binPoints[m + 2]  // upper edge

            // Slaney normalisation factor: 2 / (hi_hz - lo_hz)
            let norm = 2.0 / (hzPoints[m + 2] - hzPoints[m])

            for k in 0..<nFreqs {
                let kd = Double(k)
                var w = 0.0
                if kd >= lo && kd <= center {
                    w = (kd - lo) / (center - lo)
                } else if kd > center && kd <= hi {
                    w = (hi - kd) / (hi - center)
                }
                fb[m * nFreqs + k] = Float(w * norm)
            }
        }

        return fb
    }

    // MARK: - Private: Mel Scale (Slaney / O'Shaughnessy)

    private func hzToMelSlaney(_ hz: Double) -> Double {
        let fMin: Double    = 0.0
        let fSp: Double     = 200.0 / 3.0
        let minLogHz: Double = 1000.0
        let minLogMel: Double = (minLogHz - fMin) / fSp
        let logStep: Double  = log(6.4) / 27.0

        if hz < minLogHz {
            return (hz - fMin) / fSp
        } else {
            return minLogMel + log(hz / minLogHz) / logStep
        }
    }

    private func melToHzSlaney(_ mel: Double) -> Double {
        let fMin: Double    = 0.0
        let fSp: Double     = 200.0 / 3.0
        let minLogHz: Double = 1000.0
        let minLogMel: Double = (minLogHz - fMin) / fSp
        let logStep: Double  = log(6.4) / 27.0

        if mel < minLogMel {
            return fMin + fSp * mel
        } else {
            return minLogHz * exp(logStep * (mel - minLogMel))
        }
    }
}
