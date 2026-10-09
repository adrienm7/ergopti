// video/scripts/render-gifs.mjs
//
// Renders the README feature GIFs: every scene flagged gif=true in
// src/data/timeline.json, rendered alone from its Scene-<id> composition,
// scaled to GIF_WIDTH, then converted with a per-clip palette by the ffmpeg
// that Remotion ships for this platform. Usage:
//   node scripts/render-gifs.mjs [scene-id ...]

import { bundle } from '@remotion/bundler';
import { renderMedia, selectComposition } from '@remotion/renderer';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, statSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const VIDEO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const OUT_DIR = join(VIDEO_ROOT, '..', 'docs/media/ergoptiplus');
const WORK_DIR = join(VIDEO_ROOT, 'out/gif-work');
const GIF_WIDTH = 800;
const GIF_FPS = 12;
const GIF_COLORS = 192;
/** README budget per GIF; a heavier one fails the run instead of bloating git. */
const MAX_BYTES = 3 * 1024 * 1024;

/**
 * The ffmpeg binary inside Remotion's platform compositor package.
 * @returns {string}
 */
function remotionFfmpeg() {
	const require = createRequire(import.meta.url);
	const suffixes = { win32: ['-msvc'], linux: ['-gnu', '-musl'], darwin: [''] }[process.platform];
	if (!suffixes) throw new Error(`No Remotion compositor for ${process.platform}`);
	for (const suffix of suffixes) {
		const name = `@remotion/compositor-${process.platform}-${process.arch}${suffix}`;
		let dir;
		try {
			dir = dirname(require.resolve(`${name}/package.json`));
		} catch {
			continue;
		}
		const bin = join(dir, process.platform === 'win32' ? 'ffmpeg.exe' : 'ffmpeg');
		if (existsSync(bin)) return bin;
	}
	throw new Error('Remotion compositor ffmpeg not found; run npm install in video/');
}

const timeline = JSON.parse(readFileSync(join(VIDEO_ROOT, 'src/data/timeline.json'), 'utf-8'));
const only = process.argv.slice(2);
const scenes = timeline.scenes.filter((s) => s.gif && (only.length === 0 || only.includes(s.id)));
if (only.length > 0 && scenes.length !== only.length)
	throw new Error(`Unknown or non-GIF scene in: ${only.join(', ')}`);

const ffmpeg = remotionFfmpeg();
mkdirSync(OUT_DIR, { recursive: true });
mkdirSync(WORK_DIR, { recursive: true });
const serveUrl = await bundle({
	entryPoint: join(VIDEO_ROOT, 'src/index.ts'),
	publicDir: join(VIDEO_ROOT, 'public')
});
// The bundle is a copy of the project in the temp folder; never leave it behind.
try {
	for (const scene of scenes) {
		const composition = await selectComposition({
			serveUrl,
			id: `Scene-${scene.id}`,
			chromiumOptions: { gl: 'angle' }
		});
		const mp4 = join(WORK_DIR, `${scene.id}.mp4`);
		await renderMedia({
			serveUrl,
			composition,
			codec: 'h264',
			outputLocation: mp4,
			scale: GIF_WIDTH / composition.width,
			crf: 12,
			muted: true,
			chromiumOptions: { gl: 'angle' },
			timeoutInMilliseconds: 60000
		});
		// A flickering scene never becomes a GIF (scripts/check-flicker.mjs).
		execFileSync(process.execPath, [join(VIDEO_ROOT, 'scripts/check-flicker.mjs'), mp4], {
			stdio: 'inherit'
		});
		// Encoded aside and moved in only within budget, so an oversized GIF never
		// lands in the tracked folder.
		const draft = join(WORK_DIR, `${scene.id}.gif`);
		const gif = join(OUT_DIR, `${scene.id}.gif`);
		// One palette per clip, error diffusion off for flat UI colours: smaller
		// files and no crawling dither on still areas.
		execFileSync(ffmpeg, [
			'-y',
			'-loglevel',
			'error',
			'-i',
			mp4,
			'-r',
			String(scene.gifFps ?? GIF_FPS),
			'-filter_complex',
			`[0:v]split[a][b];[a]palettegen=max_colors=${scene.gifColors ?? GIF_COLORS}:stats_mode=diff[p];[b][p]paletteuse=dither=none:diff_mode=rectangle`,
			'-loop',
			'0',
			draft
		]);
		const size = statSync(draft).size;
		if (size > MAX_BYTES)
			throw new Error(
				`${scene.id}.gif is ${(size / 1024 / 1024).toFixed(2)} MB, over the README budget`
			);
		renameSync(draft, gif);
		console.log(`gifs: ${gif} ${(size / 1024 / 1024).toFixed(2)} MB`);
	}
	rmSync(WORK_DIR, { recursive: true, force: true });
} finally {
	rmSync(serveUrl, { recursive: true, force: true });
}
