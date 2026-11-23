// tools/codegen/codegen-macos-app-icon.cjs

/**
 * ==============================================================================
 * MODULE: macOS App Icon Master Generator
 * DESCRIPTION:
 * Renders static/img/logo/logo_macos_app_icon.png, the 1024 x 1024 master the
 * macOS build turns into ErgoptiPlus.icns for the launcher and the embedded
 * engine. The square logo (logo_simple_square.svg) is clipped to the macOS app
 * icon shape: an 824 x 824 continuous-corner rounded rectangle centred on the
 * canvas, with a transparent 100 px margin on every side.
 *
 * WHY THIS EXISTS:
 * The build fed the full-bleed square logo to iconutil. macOS 26 (Tahoe) only
 * draws an app icon in its own shape when the icon stays inside the app icon
 * grid; anything with pixels past that shape is shrunk onto a gray or white
 * rounded plate, which is what Finder and Quick Look showed (field report
 * 2026-11-23). The same grid is the Big Sur one, so the shaped .icns renders
 * natively on every macOS the app supports (LSMinimumSystemVersion 11.0).
 *
 * WHY THE PNG IS REWRITTEN ONLY WHEN ITS PIXELS CHANGE:
 * The rasteriser is libvips (sharp) and its anti-aliasing may differ by a
 * least-significant bit between hosts. Comparing decoded pixels with a small
 * tolerance keeps a regeneration on another machine from rewriting a binary
 * that did not really change.
 *
 * USAGE:  node tools/codegen/codegen-macos-app-icon.cjs
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const LOGO_SVG = path.join(ROOT, 'static', 'img', 'logo', 'logo_simple_square.svg');
const OUTPUT = path.join(ROOT, 'static', 'img', 'logo', 'logo_macos_app_icon.png');

// ==========================================
// ==========================================
// ======= 1/ App icon grid =================
// ==========================================
// ==========================================

/**
 * Apple's macOS app icon grid (Big Sur and later, unchanged for macOS 26):
 * a 1024 px canvas whose icon body is an 824 px continuous-corner rounded
 * rectangle with a 185.4 px corner radius.
 */
const GRID = Object.freeze({ canvas: 1024, body: 824, cornerRadius: 185.4 });
const MARGIN = (GRID.canvas - GRID.body) / 2;

/** Largest channel difference treated as the same pixel (see module header). */
const PIXEL_TOLERANCE = 2;

/** Backing colour under the logo, so the seams between its segments stay opaque. */
const BACKING = '#ffffff';

/**
 * Builds the continuous-corner ("squircle") outline Apple uses for app icons.
 * The coefficients are those of UIKit's continuous rounded rectangle; every
 * corner is the same curve, mirrored about its diagonal.
 * @param {number} x Left edge.
 * @param {number} y Top edge.
 * @param {number} size Side length.
 * @param {number} r Corner radius.
 * @returns {string} An SVG path.
 */
function squirclePath(x, y, size, r) {
	if (1.52866483 * r * 2 > size) throw new Error(`corner radius ${r} too large for ${size}`);
	// One corner as [along-edge, across-edge] offsets in radii, from its first
	// edge to its second: a curve leaving the edge, a short line, the shoulder
	// curve, a short line and the mirrored curve onto the next edge. A single
	// value is a line; three are a cubic curve (two control points, then the end).
	const corner = [
		[[1.52866483, 0]],
		[
			[1.08849323, 0],
			[0.86840689, 0],
			[0.66993427, 0.065496]
		],
		[[0.63149399, 0.074911]],
		[
			[0.37282392, 0.16905899],
			[0.16905899, 0.37282392],
			[0.074911, 0.63149399]
		],
		[[0.065496, 0.66993427]],
		[
			[0, 0.86840689],
			[0, 1.08849323],
			[0, 1.52866483]
		]
	];
	// Each corner maps (along, across) into canvas coordinates.
	const x2 = x + size;
	const y2 = y + size;
	const corners = [
		(a, b) => [x2 - a * r, y + b * r], // top right: along the top, then down the right
		(a, b) => [x2 - b * r, y2 - a * r], // bottom right
		(a, b) => [x + a * r, y2 - b * r], // bottom left
		(a, b) => [x + b * r, y + a * r] // top left
	];
	const fmt = (p) => p.map((v) => Number(v.toFixed(3))).join(' ');
	const parts = [];
	corners.forEach((map, i) => {
		corner.forEach((segment, k) => {
			const pts = segment.map(([a, b]) => fmt(map(a, b)));
			if (segment.length === 3) parts.push(`C ${pts.join(' ')}`);
			else parts.push(`${i === 0 && k === 0 ? 'M' : 'L'} ${pts[0]}`);
		});
	});
	parts.push('Z');
	return parts.join(' ');
}

// ==========================================
// ==========================================
// ======= 2/ Rendering =====================
// ==========================================
// ==========================================

/**
 * Wraps the square logo into the app icon grid.
 * @param {string} logoSvg The logo_simple_square.svg source.
 * @returns {string} The 1024 px icon SVG.
 */
function iconSvg(logoSvg) {
	const open = logoSvg.match(/<svg\b([^>]*)>/);
	if (!open) throw new Error('logo_simple_square.svg has no <svg> element');
	const viewBox = open[1].match(/viewBox="([^"]+)"/);
	if (!viewBox) throw new Error('logo_simple_square.svg has no viewBox');
	const end = logoSvg.lastIndexOf('</svg>');
	if (end === -1) throw new Error('logo_simple_square.svg is not closed');
	const inner = logoSvg.slice(open.index + open[0].length, end);
	const outline = squirclePath(MARGIN, MARGIN, GRID.body, GRID.cornerRadius);
	return (
		`<svg xmlns="http://www.w3.org/2000/svg" width="${GRID.canvas}" height="${GRID.canvas}" viewBox="0 0 ${GRID.canvas} ${GRID.canvas}">` +
		`<defs><clipPath id="app-icon-body"><path d="${outline}"/></clipPath></defs>` +
		'<g clip-path="url(#app-icon-body)">' +
		`<rect x="${MARGIN}" y="${MARGIN}" width="${GRID.body}" height="${GRID.body}" fill="${BACKING}"/>` +
		`<svg x="${MARGIN}" y="${MARGIN}" width="${GRID.body}" height="${GRID.body}" viewBox="${viewBox[1]}">${inner}</svg>` +
		'</g></svg>'
	);
}

/**
 * Tells whether two raw RGBA buffers hold the same picture within PIXEL_TOLERANCE.
 * @param {Buffer} a First buffer.
 * @param {Buffer} b Second buffer.
 * @returns {boolean} True when every channel is within tolerance.
 */
function samePixels(a, b) {
	if (a.length !== b.length) return false;
	for (let i = 0; i < a.length; i++) if (Math.abs(a[i] - b[i]) > PIXEL_TOLERANCE) return false;
	return true;
}

async function main() {
	const sharp = require('sharp');
	const svg = iconSvg(fs.readFileSync(LOGO_SVG, 'utf8'));
	const png = await sharp(Buffer.from(svg), { density: 72 })
		.ensureAlpha()
		.png({ compressionLevel: 9, adaptiveFiltering: false, palette: false })
		.toBuffer();
	const rendered = await sharp(png).raw().toBuffer({ resolveWithObject: true });
	if (rendered.info.width !== GRID.canvas || rendered.info.height !== GRID.canvas)
		throw new Error(
			`rendered ${rendered.info.width}x${rendered.info.height}, expected ${GRID.canvas}`
		);
	if (fs.existsSync(OUTPUT)) {
		const current = await sharp(OUTPUT).ensureAlpha().raw().toBuffer();
		if (samePixels(current, rendered.data)) {
			console.log('[OK] macOS app icon master is current.');
			return;
		}
	}
	fs.writeFileSync(OUTPUT, png);
	console.log(`[OK] Generated ${path.relative(ROOT, OUTPUT)}.`);
}

module.exports = { GRID, MARGIN, squirclePath };

if (require.main === module)
	main().catch((err) => {
		console.error(`[ERROR] ${err.message}`);
		process.exit(1);
	});
