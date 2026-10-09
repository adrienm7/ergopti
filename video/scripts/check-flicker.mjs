// video/scripts/check-flicker.mjs
//
// Fails when a rendered video flickers. Remotion captures frames in several
// browser tabs at once; a scene whose look depends on more than the frame
// (a window still computing, a chart drawn late) then alternates between the
// tabs' states, which reads on screen as stutter. The signature is exact: the
// picture leaves a state for one to three frames and comes back to it
// identically, which no real animation does.
//
// Usage: node scripts/check-flicker.mjs <video.mp4> [...]

import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';

const WIDTH = 240;
const HEIGHT = 135;
const FPS = 30;
/** Mean absolute difference (0-255) above which two frames differ visibly. */
const DIFFERENT = 0.25;
/** Below this, a frame is back to the earlier picture. */
const SAME = 0.03;
/** Longest excursion that counts as flicker, in frames. */
const MAX_EXCURSION = 3;

/**
 * The ffmpeg binary inside Remotion's platform compositor package.
 * @returns {string}
 */
function remotionFfmpeg() {
	const require = createRequire(import.meta.url);
	const suffixes = { win32: ['-msvc'], linux: ['-gnu', '-musl'], darwin: [''] }[process.platform];
	if (!suffixes) throw new Error(`No Remotion compositor for ${process.platform}`);
	for (const suffix of suffixes) {
		let dir;
		try {
			dir = dirname(
				require.resolve(
					`@remotion/compositor-${process.platform}-${process.arch}${suffix}/package.json`
				)
			);
		} catch {
			continue;
		}
		const bin = join(dir, process.platform === 'win32' ? 'ffmpeg.exe' : 'ffmpeg');
		if (existsSync(bin)) return bin;
	}
	throw new Error('Remotion compositor ffmpeg not found; run npm install in video/');
}

/**
 * Every frame of a video as small greyscale buffers.
 * @param {string} file
 * @returns {Uint8Array[]}
 */
function frames(file) {
	const raw = execFileSync(
		remotionFfmpeg(),
		[
			'-loglevel',
			'error',
			'-i',
			file,
			'-vf',
			`scale=${WIDTH}:${HEIGHT}`,
			'-pix_fmt',
			'gray',
			'-c:v',
			'rawvideo',
			'-f',
			'image2pipe',
			'-'
		],
		{ maxBuffer: 1024 * 1024 * 1024 }
	);
	const size = WIDTH * HEIGHT;
	const out = [];
	for (let at = 0; at + size <= raw.length; at += size) out.push(raw.subarray(at, at + size));
	return out;
}

/**
 * @param {Uint8Array} a
 * @param {Uint8Array} b
 * @returns {number} Mean absolute difference.
 */
function diff(a, b) {
	let sum = 0;
	for (let i = 0; i < a.length; i++) sum += Math.abs(a[i] - b[i]);
	return sum / a.length;
}

/**
 * Frames where the picture leaves a state and returns to it exactly.
 * @param {Uint8Array[]} list
 * @returns {number[]}
 */
function flickers(list) {
	const found = [];
	for (let i = 1; i < list.length; i++) {
		if (diff(list[i - 1], list[i]) < DIFFERENT) continue;
		for (let k = 1; k <= MAX_EXCURSION && i + k < list.length; k++) {
			if (diff(list[i - 1], list[i + k]) < SAME) {
				found.push(i);
				break;
			}
		}
	}
	return found;
}

const files = process.argv.slice(2);
if (files.length === 0) throw new Error('Usage: node scripts/check-flicker.mjs <video.mp4> [...]');
let failed = false;
for (const file of files) {
	const found = flickers(frames(file));
	if (found.length === 0) {
		console.log(`check-flicker: ${file} OK`);
		continue;
	}
	failed = true;
	// Grouped into time ranges: one flickering scene yields dozens of frames.
	const ranges = [];
	for (const f of found) {
		const last = ranges[ranges.length - 1];
		if (last && f - last[1] <= FPS) last[1] = f;
		else ranges.push([f, f]);
	}
	const text = ranges.map(([a, b]) => `${(a / FPS).toFixed(1)}-${(b / FPS).toFixed(1)} s`);
	console.error(
		`check-flicker: ${file} flickers at ${found.length} frame(s), in ${text.join(', ')}`
	);
}
if (failed) process.exit(1);
