# Real-time FFT candidate on AZ

Base: AZ published commit 5e80c3c. User confirmed E cycles wave -> XY -> FFT ->
wave; existing default XY retained. Separate branch codex/fft-spectrum-az-20261014.
No audio feature removed, no new hardware or PLL, no CPU/HLS/PCM, no push/main
replacement/board flash. Existing HDMI clock circuitry unchanged.

## Interface and fixed-point contract

fft_spectrum_core: clk/rst/enable, signed-16 sample + valid in; ascending bins
0..N/2 inclusive with signed-18 real/imag, frame ID/done, busy, sticky arithmetic
overflow and saturating dropped-input counter out. No ready output to audio.
LOG2_N=6..11, production 11 (2048); WINDOW_EN defaults to periodic Hann.
Output units: 4*DFT(window*input)/N. Q1.15 twiddle/window coefficients are generated
math constants, not audio recordings. One radix-2 butterfly at a time, registered
products/sums/rotation/outputs, per-stage /2 scaling and saturating output.
Capture bank stays owned until work-memory load ends. At the real 1024-clock
sample interval, compute finishes before the next complete input block.

fft_spectrum_view: signed-24 audio tap converted to signed-16 high bits; 512
paired-bin maximum bars cover the full 0..24.4140625 kHz half spectrum, including
Nyquist in the last bar. Height uses approximate log2(abs(real)+abs(imag)), NOT
a calibrated dB/power measurement. Default bin spacing 23.8418579 Hz, acquisition
42 ms, about 23.84 input blocks/s. Window/update latency is display-only and does
not enter the control-to-audio path. Header shows FFT and configured Test N;
N is metadata, not a claim of measured spectral peak count.

## CDC and frame ownership

Sample domain writes one of two histogram banks. A completed publication is
immutable until acknowledged. Request, bank, frame ID and N launch on the sys
falling edge. Pixel domain samples through two stages, snapshots the bundled
metadata and copies the complete bank only at x=0,y=480. Pixel-local bars stay
immutable during visible scan. Ack returns through two sys stages. If video
does not consume a publication, only newer DISPLAY frames are dropped and
counted; audio/FFT producer is not stalled and the locked bank is never reused.
RGB and de/hs/vs retain the existing two-register pixel latency. FFT selection
also commits in vertical blanking. New source-falling-edge paths have explicit
10 ns max delay, no blanket false-path or asynchronous clock-group exception.

## Initial evidence (not final acceptance)

- 64 and production 2048-point, six-frame numerical tests match independent
  O(N^2) floating direct DFT within 40 signed-18 output codes; exact ordering,
  no nominal input drops or arithmetic overflow. Cases: silence, DC, single
  tone, two tones, Nyquist and deterministic noise.
- Real FFT-to-pixel test: correct tone bars, known black off-tone pixels,
  vertical-blank publication and atomic metadata. No forced private producer.
- Burst test: exactly 32 rejected samples counted, two complete captured blocks
  uncorrupted; disable/reset discard partial frames and restart sequence.
- Real UART E mode test: three-mode cycle; 97703 audio/UART cycles equal between
  FFT enabled/disabled, with 21216 DIN ones (not silence-only equivalence).
- Original atomic dump/notification fixture still PASS, with identical public
  UART/SPI/I2S trace to AZ (SHA E80E96100E5EC6C8058FEC0A60903324028CC6F4126214702A88D78A79A6CD1E).
- Core-only synthesis at build/fft_core_syn02 exit 0: 12 BSRAM, 5 MULTALU27X18,
  442 LUT, 150 ALU, 457 registers. This preceded explicit-width cleanup and is
  NOT the integrated resource/physical timing verdict. First attempt lacked
  copied inputs and failed before valid synthesis; not counted as evidence.
- Full integrated regression/PnR and board acceptance still pending. AZ kept
  intact and available; no claim of a ready-to-burn FFT version yet.

## Primary references

ROM initialization/synchronous read follows the supported inference style in
[Gowin HDL Coding, section 9.1.5](https://cdn.gowinsemi.com.cn/SUG949E.pdf).
Forward-transform sign and real-input half-spectrum convention follow the
[FFTW mathematical definition](https://fftw.org/fftw3_doc/The-1d-Real_002ddata-DFT.html);
our explicit fixed-point 4/N scale differs from FFTW's unnormalized convention.
No software FFT executes in the hardware signal path.
