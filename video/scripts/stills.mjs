// video/scripts/stills.mjs
//
// Renders a few frames of every scene into out/stills/ for a quick visual
// review without playing the film. Usage:
//   node scripts/stills.mjs [scene-id ...] [--at=0.3,0.6,0.95]

import { bundle } from '@remotion/bundler';
import { renderStill, selectComposition } from '@remotion/renderer';
import { mkdirSync, rmSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const VIDEO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const OUT_DIR = join(VIDEO_ROOT, 'out/stills');

const args = process.argv.slice(2);
const atArg = args.find((a) => a.startsWith('--at='));
const fractions = atArg ? atArg.slice(5).split(',').map(Number) : [0.3, 0.6, 0.95];
const only = args.filter((a) => !a.startsWith('--'));

mkdirSync(OUT_DIR, { recursive: true });
const serveUrl = await bundle({
	entryPoint: join(VIDEO_ROOT, 'src/index.ts'),
	publicDir: join(VIDEO_ROOT, 'public')
});
// The bundle is a copy of the project in the temp folder; never leave it behind.
try {
	const timeline = (await import('../src/data/timeline.json', { with: { type: 'json' } })).default;
	const ids = only.length > 0 ? only : timeline.scenes.map((s) => s.id);

	for (const id of ids) {
		const composition = await selectComposition({
			serveUrl,
			id: `Scene-${id}`,
			chromiumOptions: { gl: 'angle' }
		});
		for (const fraction of fractions) {
			const frame = Math.min(
				composition.durationInFrames - 1,
				Math.round(fraction * composition.durationInFrames)
			);
			const output = join(OUT_DIR, `${id}-${String(frame).padStart(3, '0')}.jpeg`);
			await renderStill({
				serveUrl,
				composition,
				frame,
				output,
				imageFormat: 'jpeg',
				scale: 0.5,
				chromiumOptions: { gl: 'angle' },
				timeoutInMilliseconds: 60000
			});
			console.log(`stills: ${output}`);
		}
	}
} finally {
	rmSync(serveUrl, { recursive: true, force: true });
}
