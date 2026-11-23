// tools/test/test-macos-app-icon-shape.cjs

/**
 * ==============================================================================
 * MODULE: macOS App Icon Shape
 * DESCRIPTION:
 * The build turned the full-bleed square logo into ErgoptiPlus.icns. macOS 26
 * draws an app icon in its own rounded shape only when it stays inside the app
 * icon grid, so Finder and Quick Look showed the square logo shrunk onto a white
 * rounded plate (field report 2026-11-23, 1.0.10-dev.177).
 *
 * ROOT CAUSE ENCODED:
 * 1. build_icon makes the .icns from the shaped master logo_macos_app_icon.png,
 *    never from the square logo, and gives the same .icns to the embedded engine;
 * 2. the master is the 1024 px app icon grid: an 824 px body centred with a
 *    transparent 100 px margin, rounded (transparent) corners, and an opaque
 *    body with no translucent seam inside it.
 *
 * The PNG is decoded here with zlib alone, so the check needs no image library.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const zlib = require('zlib');
const { GRID, MARGIN } = require('../codegen/codegen-macos-app-icon.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const BUILD_SCRIPT = path.join(ROOT, 'tools', 'build', 'build_macos_app.sh');
const MASTER_REL = 'static/img/logo/logo_macos_app_icon.png';

const failures = [];
let checks = 0;
const expect = (condition, message) => {
	checks += 1;
	if (!condition) failures.push(message);
};

// ==========================================
// ==========================================
// ======= 1/ PNG decoding ==================
// ==========================================
// ==========================================

/**
 * Decodes an 8- or 16-bit, non-interlaced RGB or RGBA PNG.
 * @param {Buffer} buf The file.
 * @returns {{width: number, height: number, alpha: (x: number, y: number) => number}} The image.
 */
function decodePng(buf) {
	if (!buf.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10])))
		throw new Error('not a PNG');
	let offset = 8;
	let header = null;
	const idat = [];
	while (offset < buf.length) {
		const length = buf.readUInt32BE(offset);
		const type = buf.toString('latin1', offset + 4, offset + 8);
		const data = buf.subarray(offset + 8, offset + 8 + length);
		if (type === 'IHDR')
			header = {
				width: data.readUInt32BE(0),
				height: data.readUInt32BE(4),
				depth: data[8],
				colour: data[9],
				interlace: data[12]
			};
		else if (type === 'IDAT') idat.push(data);
		else if (type === 'IEND') break;
		offset += 12 + length;
	}
	if (!header) throw new Error('PNG has no IHDR');
	if (![8, 16].includes(header.depth) || header.interlace !== 0 || ![2, 6].includes(header.colour))
		throw new Error(`unsupported PNG (depth ${header.depth}, colour ${header.colour})`);
	const channels = header.colour === 6 ? 4 : 3;
	// Filters work on whole pixels: bytes per pixel, not channels.
	const bpp = (channels * header.depth) / 8;
	const stride = header.width * bpp;
	const raw = zlib.inflateSync(Buffer.concat(idat));
	const pixels = Buffer.alloc(stride * header.height);
	for (let y = 0; y < header.height; y++) {
		const filter = raw[y * (stride + 1)];
		const line = raw.subarray(y * (stride + 1) + 1, (y + 1) * (stride + 1));
		for (let i = 0; i < stride; i++) {
			const left = i >= bpp ? pixels[y * stride + i - bpp] : 0;
			const up = y > 0 ? pixels[(y - 1) * stride + i] : 0;
			const upLeft = y > 0 && i >= bpp ? pixels[(y - 1) * stride + i - bpp] : 0;
			let predictor;
			if (filter === 0) predictor = 0;
			else if (filter === 1) predictor = left;
			else if (filter === 2) predictor = up;
			else if (filter === 3) predictor = (left + up) >> 1;
			else if (filter === 4) {
				const p = left + up - upLeft;
				const pa = Math.abs(p - left);
				const pb = Math.abs(p - up);
				const pc = Math.abs(p - upLeft);
				predictor = pa <= pb && pa <= pc ? left : pb <= pc ? up : upLeft;
			} else throw new Error(`unknown PNG filter ${filter}`);
			pixels[y * stride + i] = (line[i] + predictor) & 0xff;
		}
	}
	return {
		width: header.width,
		height: header.height,
		// The most significant byte of a 16-bit alpha is its 8-bit value.
		alpha: (x, y) =>
			channels === 4 ? pixels[(y * header.width + x) * bpp + (3 * header.depth) / 8] : 255
	};
}

// ==========================================
// ==========================================
// ======= 2/ Build wiring ==================
// ==========================================
// ==========================================

const script = fs.readFileSync(BUILD_SCRIPT, 'utf8');
const start = script.indexOf('build_icon() {');
const end = script.indexOf('\n}\n', start);
expect(start !== -1 && end !== -1, 'build_macos_app.sh has no build_icon function');
const buildIcon = script.slice(start, end);
expect(
	buildIcon.includes(`local src="$REPO_ROOT/${MASTER_REL}"`),
	`build_icon must make the .icns from the shaped master ${MASTER_REL}`
);
expect(
	!buildIcon.includes('logo_simple_square'),
	'build_icon must not use the full-bleed square logo, which macOS 26 puts on a plate'
);
expect(
	/sips -z "\$size" "\$size"\s+"\$src"/.test(buildIcon) &&
		/sips -z "\$double" "\$double" "\$src"/.test(buildIcon),
	'every .iconset size must be scaled from the master'
);
expect(
	buildIcon.includes(
		'cp "$APP_PATH/Contents/Resources/ErgoptiPlus.icns" "$hs_app/Contents/Resources/ErgoptiPlus.icns"'
	),
	'the embedded engine must carry the same ErgoptiPlus.icns'
);
expect(
	/<key>CFBundleIconFile<\/key>\s*<string>ErgoptiPlus<\/string>/.test(script),
	'the launcher Info.plist must name ErgoptiPlus as its icon file'
);

// ==========================================
// ==========================================
// ======= 3/ Master shape ==================
// ==========================================
// ==========================================

// Apple's macOS app icon grid: a 1024 px canvas and an 824 px body.
expect(
	GRID.canvas === 1024 && GRID.body === 824,
	'the generator must use the 1024/824 app icon grid'
);
expect(MARGIN === 100, 'the transparent margin must be 100 px on each side');

const image = decodePng(fs.readFileSync(path.join(ROOT, MASTER_REL)));
expect(
	image.width === GRID.canvas && image.height === GRID.canvas,
	'the master must be 1024 x 1024'
);

if (image.width === GRID.canvas && image.height === GRID.canvas) {
	const last = MARGIN + GRID.body - 1;
	let minX = Infinity;
	let minY = Infinity;
	let maxX = -1;
	let maxY = -1;
	let seams = 0;
	for (let y = 0; y < image.height; y++)
		for (let x = 0; x < image.width; x++) {
			const a = image.alpha(x, y);
			if (a === 0) continue;
			minX = Math.min(minX, x);
			minY = Math.min(minY, y);
			maxX = Math.max(maxX, x);
			maxY = Math.max(maxY, y);
			// A translucent pixel belongs on the anti-aliased outline only.
			if (a < 255) {
				let nearEdge = false;
				for (let dy = -2; dy <= 2 && !nearEdge; dy++)
					for (let dx = -2; dx <= 2 && !nearEdge; dx++) {
						const nx = x + dx;
						const ny = y + dy;
						if (nx < 0 || ny < 0 || nx >= image.width || ny >= image.height) continue;
						if (image.alpha(nx, ny) === 0) nearEdge = true;
					}
				if (!nearEdge) seams += 1;
			}
		}
	expect(
		minX === MARGIN && minY === MARGIN && maxX === last && maxY === last,
		`the visible body must span exactly ${MARGIN}..${last} on both axes, got x ${minX}..${maxX}, y ${minY}..${maxY}`
	);
	expect(seams === 0, `${seams} translucent pixel(s) inside the body, away from its outline`);
	for (const [x, y] of [
		[0, 0],
		[GRID.canvas - 1, GRID.canvas - 1],
		[MARGIN, MARGIN],
		[MARGIN + 10, MARGIN + 10],
		[last, MARGIN],
		[MARGIN, last],
		[last - 10, last - 10]
	])
		expect(image.alpha(x, y) === 0, `the rounded corner pixel (${x}, ${y}) must be transparent`);
	const mid = GRID.canvas / 2;
	for (const [x, y] of [
		[mid, MARGIN + 1],
		[MARGIN + 1, mid],
		[last - 1, mid],
		[mid, last - 1],
		[mid, mid]
	])
		expect(image.alpha(x, y) === 255, `the body pixel (${x}, ${y}) must be opaque`);
}

if (failures.length > 0) {
	console.error(`[FAIL] macOS app icon shape: ${failures.length}/${checks} check(s) failed`);
	for (const failure of failures) console.error('  - ' + failure);
	process.exit(1);
}
console.log(`[OK] macOS app icon shape: ${checks} checks`);
