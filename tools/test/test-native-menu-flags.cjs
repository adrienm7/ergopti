/**
 * tools/test/test-native-menu-flags.cjs
 * ==============================================================================
 * MODULE: Native Language Menu Bitmap Regression Tests
 * DESCRIPTION:
 * Verifies generated Windows bitmaps against every authoritative RGB PNG pixel.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const zlib = require('node:zlib');
const root = path.resolve(__dirname, '../..');
const flags = path.join(root, 'static/img/flags');

function pngPixels(data) {
	assert.equal(data.subarray(0, 8).toString('hex'), '89504e470d0a1a0a');
	const chunks = [];
	let width, height;
	for (let offset = 8; offset < data.length; ) {
		const length = data.readUInt32BE(offset);
		const type = data.toString('ascii', offset + 4, offset + 8);
		const body = data.subarray(offset + 8, offset + 8 + length);
		if (type === 'IHDR') {
			width = body.readUInt32BE(0);
			height = body.readUInt32BE(4);
			assert.deepEqual([...body.subarray(8)], [8, 2, 0, 0, 0], '8-bit, non-interlaced RGB');
		}
		if (type === 'IDAT') chunks.push(body);
		offset += length + 12;
	}
	assert.equal(width, 32);
	assert.equal(height, 24);
	const raw = zlib.inflateSync(Buffer.concat(chunks));
	const stride = width * 3;
	assert.equal(raw.length, (stride + 1) * height);
	const pixels = Buffer.alloc(stride * height);
	for (let y = 0; y < height; y++) {
		const filter = raw[y * (stride + 1)];
		assert.ok(filter <= 4, 'known PNG row filter');
		for (let x = 0; x < stride; x++) {
			const left = x >= 3 ? pixels[y * stride + x - 3] : 0;
			const up = y > 0 ? pixels[(y - 1) * stride + x] : 0;
			const upperLeft = y > 0 && x >= 3 ? pixels[(y - 1) * stride + x - 3] : 0;
			const prediction = left + up - upperLeft;
			const a = Math.abs(prediction - left),
				b = Math.abs(prediction - up),
				c = Math.abs(prediction - upperLeft);
			const paeth = a <= b && a <= c ? left : b <= c ? up : upperLeft;
			const predictor = [0, left, up, Math.floor((left + up) / 2), paeth][filter];
			pixels[y * stride + x] = (raw[y * (stride + 1) + x + 1] + predictor) & 255;
		}
	}
	return pixels;
}

function bmpPixels(data) {
	assert.equal(data.toString('ascii', 0, 2), 'BM');
	assert.equal(data.readUInt32LE(2), data.length);
	assert.equal(data.readUInt32LE(14), 40);
	assert.equal(data.readInt32LE(18), 32);
	assert.equal(data.readInt32LE(22), -24, 'top-down native rows');
	assert.equal(data.readUInt16LE(26), 1);
	assert.equal(data.readUInt16LE(28), 32, 'opaque BGRA preserves native scaling');
	assert.equal(data.readUInt32LE(30), 0, 'uncompressed native bitmap');
	const offset = data.readUInt32LE(10);
	assert.equal(data.length, offset + 32 * 4 * 24);
	const pixels = Buffer.alloc(32 * 3 * 24);
	for (let y = 0; y < 24; y++) {
		for (let x = 0; x < 32; x++) {
			const from = offset + (y * 32 + x) * 4;
			const to = (y * 32 + x) * 3;
			pixels[to] = data[from + 2];
			pixels[to + 1] = data[from + 1];
			pixels[to + 2] = data[from];
			assert.equal(data[from + 3], 255, 'every native pixel retains opaque alpha');
		}
	}
	return pixels;
}

const names = fs
	.readdirSync(flags)
	.filter((name) => name.endsWith('.png'))
	.sort();
assert.ok(names.length > 0, 'authoritative flag assets exist');
assert.deepEqual(
	fs
		.readdirSync(flags)
		.filter((name) => name.endsWith('.bmp'))
		.sort(),
	names.map((name) => name.replace('.png', '.bmp'))
);
for (const name of names) {
	const expected = pngPixels(fs.readFileSync(path.join(flags, name)));
	const actual = bmpPixels(fs.readFileSync(path.join(flags, name.replace('.png', '.bmp'))));
	assert.deepEqual(actual, expected, `${name}: every native pixel matches the PNG`);
	const corrupted = Buffer.from(actual);
	corrupted[0] ^= 1;
	assert.notDeepEqual(corrupted, expected, 'the pixel comparison detects a changed asset');
}
const driver = fs.readFileSync(
	path.join(root, 'static/ergopti_plus/windows/infra/i18n.ahk'),
	'utf8'
);
const iconBody = /\nI18nFlagIconPath\([^\n]*\) \{([\s\S]*?)\n\}/.exec(driver)?.[1];
assert.ok(iconBody, 'the native icon path owner must exist');
assert.ok(iconBody.includes('.bmp'), 'Windows loads generated native bitmaps');
const generator = fs.readFileSync(path.join(root, 'tools/locale/generate_flags.py'), 'utf8');
assert.ok(generator.includes('parents[2]'));
assert.ok(generator.includes('write_native_bitmap(img, bmp_path)'));
console.log(`Native flags: ${names.length} bitmaps match every authoritative PNG pixel.`);
