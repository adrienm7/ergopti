// video/scripts/make-audio.mjs
//
// Synthesises the film's audio into public/audio/: a soundtrack whose
// intensity follows the scenes of src/data/timeline.json, and the short
// interface sounds the scenes trigger. Pure arithmetic, deterministic, so
// the film needs no licensed music and re-renders identically.

import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const VIDEO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const OUT_DIR = join(VIDEO_ROOT, 'public/audio');
const TIMELINE = JSON.parse(readFileSync(join(VIDEO_ROOT, 'src/data/timeline.json'), 'utf-8'));

const RATE = 44100;
const BPM = 104;
const BEAT = 60 / BPM;
const TAU = Math.PI * 2;

// =======================================
// =======================================
// ======= 1/ Primitives =================
// =======================================
// =======================================

/** Deterministic noise in [-1, 1]. */
function makeNoise(seed = 1) {
	let s = seed >>> 0;
	return () => {
		s = (s * 1664525 + 1013904223) >>> 0;
		return (s / 4294967296) * 2 - 1;
	};
}

/** @param {number} midi */
const hz = (midi) => 440 * 2 ** ((midi - 69) / 12);

/**
 * Write interleaved stereo float samples as a 16-bit PCM WAV.
 * @param {string} name
 * @param {Float32Array} left
 * @param {Float32Array} right
 */
function writeWav(name, left, right = left) {
	const n = left.length;
	const buf = Buffer.alloc(44 + n * 4);
	buf.write('RIFF', 0);
	buf.writeUInt32LE(36 + n * 4, 4);
	buf.write('WAVEfmt ', 8);
	buf.writeUInt32LE(16, 16);
	buf.writeUInt16LE(1, 20);
	buf.writeUInt16LE(2, 22);
	buf.writeUInt32LE(RATE, 24);
	buf.writeUInt32LE(RATE * 4, 28);
	buf.writeUInt16LE(4, 32);
	buf.writeUInt16LE(16, 34);
	buf.write('data', 36);
	buf.writeUInt32LE(n * 4, 40);
	for (let i = 0; i < n; i++) {
		buf.writeInt16LE(Math.round(Math.max(-1, Math.min(1, left[i])) * 32767), 44 + i * 4);
		buf.writeInt16LE(Math.round(Math.max(-1, Math.min(1, right[i])) * 32767), 46 + i * 4);
	}
	writeFileSync(join(OUT_DIR, `${name}.wav`), buf);
}

/**
 * Render a mono sound of a given length from a sample function.
 * @param {number} seconds
 * @param {(t: number, i: number) => number} fn
 */
function render(seconds, fn) {
	const out = new Float32Array(Math.ceil(seconds * RATE));
	for (let i = 0; i < out.length; i++) out[i] = fn(i / RATE, i);
	return out;
}

/** One-pole low-pass filter state. */
function lowpass() {
	let y = 0;
	return (x, cutoff) => {
		const a = 1 - Math.exp((-TAU * cutoff) / RATE);
		y += a * (x - y);
		return y;
	};
}

/** Peak-normalise a buffer to a target level. */
function normalise(buf, level = 0.9) {
	let peak = 0;
	for (const v of buf) peak = Math.max(peak, Math.abs(v));
	if (peak === 0) throw new Error('Silent buffer');
	for (let i = 0; i < buf.length; i++) buf[i] = (buf[i] / peak) * level;
	return buf;
}

// =======================================
// =======================================
// ======= 2/ Interface sounds ===========
// =======================================
// =======================================

function makeSfx() {
	const noise = makeNoise(7);
	const hp = lowpass();
	// A soft mechanical key: filtered click plus a short body.
	writeWav(
		'key',
		normalise(
			render(0.06, (t) => {
				const n = noise();
				const click = (n - hp(n, 1800)) * Math.exp(-t * 160);
				const body = Math.sin(TAU * 310 * t) * Math.exp(-t * 90) * 0.5;
				return click + body;
			}),
			0.8
		)
	);
	// Expansion pop: a quick rising sine.
	writeWav(
		'pop',
		normalise(
			render(0.18, (t) => {
				const f = 520 + 900 * Math.min(1, t / 0.06);
				return Math.sin(TAU * f * t) * Math.min(1, t * 400) * Math.exp(-t * 26);
			}),
			0.7
		)
	);
	// Whoosh: band-limited noise swelling then fading.
	const lp1 = lowpass();
	const lp2 = lowpass();
	writeWav(
		'whoosh',
		normalise(
			render(0.7, (t) => {
				const env = Math.sin(Math.PI * Math.min(1, t / 0.7)) ** 2;
				const cutoff = 300 + 3500 * env;
				const n = noise();
				return (lp1(n, cutoff) - lp2(n, cutoff * 0.25)) * env;
			}),
			0.6
		)
	);
	// Tab key "thock": low body and a damped click.
	writeWav(
		'thock',
		normalise(
			render(0.22, (t) => {
				const f = 180 - 90 * Math.min(1, t / 0.05);
				return Math.sin(TAU * f * t) * Math.exp(-t * 22) + noise() * Math.exp(-t * 120) * 0.35;
			}),
			0.85
		)
	);
	// Chime: two bell partials.
	writeWav(
		'chime',
		normalise(
			render(1.6, (t) => {
				const a = Math.min(1, t * 300);
				return (
					a *
					(Math.sin(TAU * 1318.5 * t) * Math.exp(-t * 3) +
						0.6 * Math.sin(TAU * 1975.5 * t) * Math.exp(-t * 4.5) +
						0.3 * Math.sin(TAU * 2637 * t) * Math.exp(-t * 7))
				);
			}),
			0.6
		)
	);
}

// =======================================
// =======================================
// ======= 3/ Soundtrack =================
// =======================================
// =======================================

/** Scene intensity: 0 = pad only, 1 = full groove. */
const INTENSITY = {
	hook: 0.25,
	menu: 0.5,
	'three-os': 0.65,
	'extreme-hotstrings': 0.85,
	'personal-hotstrings': 0.85,
	'ai-predictions': 1,
	'ai-everywhere': 1,
	'ai-local': 1,
	'ai-actions': 1,
	'tap-holds': 0.85,
	'nav-layer': 0.9,
	shortcuts: 0.9,
	'shortcut-teleport': 0.95,
	'shortcut-any': 0.95,
	'shortcut-select-line': 0.95,
	'shortcut-case': 0.95,
	'shortcut-color': 0.95,
	'shortcut-search': 0.95,
	'shortcut-wrap': 0.95,
	gestures: 0.9,
	metrics: 1,
	'screen-time': 1,
	private: 0.6,
	real: 0.75,
	outro: 0.3
};

/** Start time in seconds of every scene in the film, transitions included. */
function sceneStarts() {
	const starts = [];
	let t = 0;
	// Scenes marked "film": false are kept for their GIF but not played.
	for (const scene of TIMELINE.scenes.filter((s) => s.film !== false)) {
		if (!(scene.id in INTENSITY)) throw new Error(`No soundtrack intensity for scene ${scene.id}`);
		starts.push({ id: scene.id, start: t });
		t += scene.seconds - TIMELINE.transitionFrames / TIMELINE.fps;
	}
	return { starts, total: t + TIMELINE.transitionFrames / TIMELINE.fps };
}

/** Fmaj7, G6, Am7, Cmaj7: hopeful, unresolved, loops cleanly. */
const CHORDS = [
	[53, 57, 60, 64],
	[55, 59, 62, 64],
	[57, 60, 64, 67],
	[48, 55, 59, 64]
];

function makeSoundtrack() {
	const { starts, total } = sceneStarts();
	const seconds = total + 2;
	const n = Math.ceil(seconds * RATE);
	const L = new Float32Array(n);
	const R = new Float32Array(n);
	const noise = makeNoise(11);

	// Smoothed intensity per sample.
	const target = (t) => {
		let id = starts[0].id;
		for (const s of starts) if (t >= s.start) id = s.id;
		return INTENSITY[id];
	};
	const intensity = new Float32Array(n);
	let smooth = target(0);
	for (let i = 0; i < n; i++) {
		smooth += (target(i / RATE) - smooth) * (1 / (RATE * 0.8));
		intensity[i] = smooth;
	}
	const fadeOut = (t) => Math.min(1, Math.max(0, (seconds - t) / 3));
	const fadeIn = (t) => Math.min(1, t / 1.5);

	const bar = BEAT * 4;
	const padLp = [lowpass(), lowpass()];
	const bassLp = lowpass();
	for (let i = 0; i < n; i++) {
		const t = i / RATE;
		const k = intensity[i];
		const chord = CHORDS[Math.floor(t / bar) % CHORDS.length];
		const inBar = t % bar;
		const master = fadeIn(t) * fadeOut(t);

		// Pad: detuned additive voices, filter opening with the intensity.
		let padL = 0;
		let padR = 0;
		for (let v = 0; v < chord.length; v++) {
			const f = hz(chord[v]);
			for (let h = 1; h <= 4; h++) {
				const amp = 1 / (h * 1.6);
				padL += Math.sin(TAU * f * h * t * 1.0015) * amp;
				padR += Math.sin(TAU * f * h * t * 0.9985 + v) * amp;
			}
		}
		const swell = 0.75 + 0.25 * Math.sin((TAU * t) / (bar * 2));
		const cutoff = 700 + 2200 * k;
		padL = padLp[0](padL, cutoff) * 0.06 * swell;
		padR = padLp[1](padR, cutoff) * 0.06 * swell;

		// Bass: root on each beat, plucked.
		const beatPos = t % BEAT;
		const root = hz(chord[0] - 12);
		let bass = Math.sin(TAU * root * t) + 0.3 * Math.sin(TAU * root * 2 * t);
		bass = bassLp(bass * Math.exp(-beatPos * 5), 500) * 0.32 * Math.min(1, k * 1.6);

		// Arpeggio: 16ths through the chord, an octave up, panned.
		const step16 = BEAT / 4;
		const idx = Math.floor(t / step16);
		const arpNote = hz(chord[[0, 2, 1, 3, 2, 1, 3, 2][idx % 8]] + 12);
		const arpPos = t % step16;
		const tri = (2 / Math.PI) * Math.asin(Math.sin(TAU * arpNote * t));
		const arp = tri * Math.exp(-arpPos * 18) * 0.09 * Math.max(0, (k - 0.5) * 2);
		const pan = 0.5 + 0.35 * Math.sin(idx * 0.9);

		// Drums from 0.55 intensity: kick on beats, hats on off-beats,
		// a soft clap on 2 and 4 at full intensity.
		const drums = Math.max(0, (k - 0.5) * 2);
		const kickF = 45 + 90 * Math.exp(-beatPos * 30);
		const kick = Math.sin(TAU * kickF * beatPos) * Math.exp(-beatPos * 9) * 0.55 * drums;
		const off = (t + BEAT / 2) % BEAT;
		const hat = noise() * Math.exp(-off * 70) * 0.05 * drums;
		const beatInBar = Math.floor(inBar / BEAT);
		const clap =
			beatInBar % 2 === 1
				? noise() * Math.exp(-beatPos * 25) * 0.08 * Math.max(0, (k - 0.8) * 5)
				: 0;

		const mono = bass + kick + clap;
		L[i] = (padL + mono + hat * 0.8 + arp * (1 - pan)) * master;
		R[i] = (padR + mono + hat * 1.2 + arp * pan) * master;
	}

	// Short stereo echo for space, then soft limiting.
	const d = Math.round(BEAT * 0.75 * RATE);
	for (let i = d; i < n; i++) {
		L[i] += R[i - d] * 0.22;
		R[i] += L[i - d] * 0.22;
	}
	for (let i = 0; i < n; i++) {
		L[i] = Math.tanh(L[i] * 1.4) * 0.8;
		R[i] = Math.tanh(R[i] * 1.4) * 0.8;
	}
	writeWav('soundtrack', L, R);
	return seconds;
}

mkdirSync(OUT_DIR, { recursive: true });
makeSfx();
const length = makeSoundtrack();
console.log(
	`make-audio: soundtrack ${length.toFixed(1)} s and 5 interface sounds in public/audio/`
);
