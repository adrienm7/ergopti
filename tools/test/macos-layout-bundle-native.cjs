// tools/test/macos-layout-bundle-native.cjs

/**
 * ==============================================================================
 * MODULE: macOS Layout Bundle Native Check
 * DESCRIPTION:
 * Proves on a real Mac that the bundle the layout source generator writes is
 * one macOS loads: it compiles the source fixture with an icon, installs the
 * bundle in ~/Library/Keyboard Layouts, registers it with the Text Input
 * Sources API and types the source's own expectations through UCKeyTranslate
 * on the layout data macOS read from the installed files, for ISO and ANSI.
 *
 * FEATURES & RATIONALE:
 * 1. The expectations come from the TOML source and the decided ANSI rule
 *    (IntlBackslash <-> ansi_extra_key, then each ansi_swaps pair), never from
 *    the compiled XML, so a compiler bug cannot agree with itself.
 * 2. `--plan <out.json>` writes the vectors on any OS (the Linux unit test
 *    checks them); the native run needs macOS and swiftc and refuses elsewhere.
 * 3. Selecting the layout needs a logout on macOS (TISSelectInputSource answers
 *    paramErr for a source registered in the session), so selection stays a
 *    maintainer check; loading, listing, the icon and the typed output are
 *    proven here.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const zlib = require('node:zlib');
const { spawnSync } = require('node:child_process');
const { loadLayoutSource } = require('../lib/layout-source.cjs');
const { shared } = require('../lib/paths.cjs');

const FIXTURE = shared('tests', 'corpus', 'layouts', 'source', 'source.toml');
const PROBE = path.join(__dirname, 'macos-layout-bundle-native.swift');
const ICON_SIZE = 32;

// Carbon modifierKeyState bits UCKeyTranslate takes (EventModifiers >> 8).
const MODIFIER_BITS = Object.freeze({
	shift: 0x02,
	caps_lock: 0x04,
	alt_right: 0x40
});

/** A valid square RGBA PNG the compiler wraps into each variant's .icns. */
function iconPng(size = ICON_SIZE) {
	const chunk = (type, data) => {
		const body = Buffer.concat([Buffer.from(type, 'latin1'), data]);
		const length = Buffer.alloc(4);
		length.writeUInt32BE(data.length);
		const crc = Buffer.alloc(4);
		crc.writeUInt32BE(zlib.crc32(body));
		return Buffer.concat([length, body, crc]);
	};
	const header = Buffer.alloc(13);
	header.writeUInt32BE(size, 0);
	header.writeUInt32BE(size, 4);
	header.set([8, 6, 0, 0, 0], 8);
	const row = Buffer.concat([Buffer.from([0]), Buffer.alloc(size * 4, 0xc0)]);
	return new Uint8Array(
		Buffer.concat([
			Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
			chunk('IHDR', header),
			chunk('IDAT', zlib.deflateSync(Buffer.concat(Array(size).fill(row)))),
			chunk('IEND', Buffer.alloc(0))
		])
	);
}

/** The fixture with an icon, as the generator's caller passes it. */
function iconicSource(source) {
	const document = source.read(fs.readFileSync(FIXTURE, 'utf8'));
	document.exports.macos.icon = 'layout.png';
	return document;
}

/**
 * Typing vectors per variant, from the source alone: each one-scalar text of
 * the base, shift and option layers, the Caps Lock alternative, a native
 * remap and three dead-key sequences (plain, a dead key inside another, and
 * one reached under a modifier).
 */
function plan(document, report) {
	// The physical key table: `hs` is the ANSI-numbered macOS code, `macos_iso`
	// the code an ISO-convention layout gives the two keys Apple numbers apart.
	const keys = JSON.parse(
		fs.readFileSync(shared('layouts', 'data', 'keycodes', 'physical_keys.json'))
	).keys;
	const macCode = (code, convention) => {
		const row = keys[code];
		assert.ok(row && Number.isInteger(row.hs), `no macOS code for ${code}`);
		return convention === 'iso' && row.macos_iso ? row.macos_iso.hs : row.hs;
	};
	const physical = document.physical;
	// Where a source key sits on ANSI hardware: the decided derivation rule.
	const swaps = [['IntlBackslash', physical.ansi_extra_key || 'Backquote']].concat(
		physical.ansi_swaps || []
	);
	const ansiPosition = (code) =>
		swaps.reduce((at, [a, b]) => (at === a ? b : at === b ? a : at), code);
	// A physical key typing the source key `code`, after the native remap.
	const pressedFor = (code) =>
		Object.entries(document.remap || {}).find(([, target]) => target === code)?.[0];
	const layer = (id) => document.layers.find((entry) => entry.id === id);
	const mask = (tokens) => tokens.reduce((bits, token) => bits | MODIFIER_BITS[token], 0);
	const vectors = [];
	for (const variant of report.variants) {
		const convention = variant.variant;
		// Both variants are numbered with the ISO convention, as the registry ANSI
		// files are (the compiler's `convention: 'iso'`): the ANSI variant holds a
		// source key's mapping at the code of the position the rule moves it to.
		const at = (code) => macCode(convention === 'ansi' ? ansiPosition(code) : code, 'iso');
		const add = (name, keys, expected) =>
			vectors.push({
				variant: convention,
				input_source: variant.inputSource,
				name,
				keys,
				expected
			});
		for (const [id, tokens] of [
			['base', []],
			['shift', ['shift']],
			['shift', ['caps_lock']],
			['option', ['alt_right']]
		])
			for (const [code, mapping] of Object.entries(layer(id).keys)) {
				if (typeof mapping.text !== 'string' || [...mapping.text].length !== 1) continue;
				// A key the remap moves away no longer types its own mapping.
				if (Object.hasOwn(document.remap || {}, code)) continue;
				add(
					`${id}:${tokens.join('+') || 'none'}:${code}`,
					[{ code: at(code), modifiers: mask(tokens) }],
					mapping.text
				);
			}
		for (const [from, to] of Object.entries(document.remap || {})) {
			const mapping = layer('base').keys[to];
			if (mapping && typeof mapping.text === 'string')
				add(`remap:${from}`, [{ code: at(from), modifiers: 0 }], mapping.text);
		}
		const press = (code, tokens = []) => ({
			code: at(pressedFor(code) || code),
			modifiers: mask(tokens)
		});
		const dead = (id) => document.dead_keys.find((entry) => entry.id === id);
		const rule = (id, input) => dead(id).rules.find((entry) => entry.input === input).text;
		add('dead:circumflex+e', [press('BracketLeft'), press('KeyE')], rule('circumflex', 'e'));
		// The circumflex pending, a diaeresis dead key chains to their combination.
		add(
			'dead:circumflex+diaeresis+o',
			[press('BracketLeft'), press('Quote'), press('KeyO')],
			rule('circumflex_diaeresis', 'o')
		);
		add('dead:option-greek+a', [press('KeyE', ['alt_right']), press('KeyA')], rule('greek', 'a'));
	}
	return {
		sources: report.variants.map((variant) => variant.inputSource),
		names: report.variants.map((variant) => variant.display),
		vectors
	};
}

/** Builds the bundle and its vectors without installing anything. */
function build() {
	const source = loadLayoutSource();
	const document = iconicSource(source);
	const compiled = source.exportMacos(document, 'bundle', { 'layout.png': iconPng() });
	return { compiled, plan: plan(document, compiled.report) };
}

/** Writes a file map under a root, refusing an existing bundle. */
function writeFiles(root, files) {
	for (const file of files) {
		const target = path.join(root, file.path);
		fs.mkdirSync(path.dirname(target), { recursive: true });
		const bytes =
			file.encoding === 'binary'
				? Buffer.from(file.bytes)
				: file.encoding === 'utf16le'
					? Buffer.from(file.text, 'utf16le')
					: file.text;
		fs.writeFileSync(target, bytes, { flag: 'wx' });
	}
}

/** Installs, registers and types on this Mac; throws on any mismatch. */
function runNative(work) {
	assert.equal(process.platform, 'darwin', 'the native check runs on macOS only');
	const { compiled, plan: vectors } = build();
	const folder = path.join(os.homedir(), 'Library', 'Keyboard Layouts');
	const bundle = path.join(folder, compiled.files[0].path.split('/')[0]);
	assert.ok(!fs.existsSync(bundle), `refusing to replace an installed ${bundle}`);
	fs.mkdirSync(work, { recursive: true });
	const planFile = path.join(work, 'plan.json');
	fs.writeFileSync(planFile, JSON.stringify({ bundle, ...vectors }, null, 2));
	writeFiles(folder, compiled.files);
	try {
		const binary = path.join(work, 'layout-bundle-probe');
		const built = spawnSync('swiftc', ['-O', '-o', binary, PROBE], { stdio: 'inherit' });
		assert.equal(built.status, 0, 'the probe does not compile');
		const ran = spawnSync(binary, [planFile], { encoding: 'utf8' });
		process.stdout.write(ran.stdout);
		process.stderr.write(ran.stderr);
		fs.writeFileSync(path.join(work, 'receipt.json'), ran.stdout);
		assert.equal(ran.status, 0, 'macOS did not load or type the generated bundle as its source');
	} finally {
		fs.rmSync(bundle, { recursive: true, force: true });
	}
}

if (require.main === module) {
	const [mode, out] = process.argv.slice(2);
	if (mode === '--plan' && out) {
		fs.writeFileSync(out, `${JSON.stringify(build().plan, null, 2)}\n`);
	} else if (mode === '--native' && out) {
		runNative(out);
	} else {
		console.error('Usage: macos-layout-bundle-native.cjs --plan <out.json> | --native <work-dir>');
		process.exitCode = 2;
	}
}

module.exports = { build, iconPng, plan, MODIFIER_BITS };
