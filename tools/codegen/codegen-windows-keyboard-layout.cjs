// tools/codegen/codegen-windows-keyboard-layout.cjs

/**
 * ==============================================================================
 * MODULE: Windows Keyboard Layout Codegen
 * DESCRIPTION:
 * Writes the sources of the Ergopti Windows keyboard layout DLL (C tables,
 * header, resources, module definition) from the registry layout that
 * _shared/layouts/data/windows_system_layout.json names, so the Windows
 * system layout and the macOS and Linux ones come from one .keylayout. With
 * --klc <dir> it also writes the MSKLC source of the same layout there (UTF-16LE,
 * CRLF, as MSKLC reads it): a build output, never tracked.
 *
 * FEATURES & RATIONALE:
 * 1. One reader: the .keylayout is read by the shared Lua parser
 *    (tools/codegen/lib/keylayout_canonical.lua) and converted by
 *    tools/codegen/lib/windows-keyboard-layout.cjs.
 * 2. Deterministic: the same layout gives the same bytes; the generator
 *    registry's drift gate regenerates and compares.
 * 3. Fail fast: a missing Lua runtime, a refused layout or a layout a keyboard
 *    DLL cannot express stops the generation with the reason.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const { parse: parseToml } = require('smol-toml');
const { REPO_ROOT, shared, SHARED_DIR } = require('../lib/paths.cjs');
const { generate, encodeKlc } = require('./lib/windows-keyboard-layout.cjs');

const SPEC_PATH = shared('layouts', 'data', 'windows_system_layout.json');
const KEYCODES_PATH = shared('layouts', 'data', 'mac_keycodes.json');
const PHYSICAL_KEYS_PATH = shared('layouts', 'data', 'keycodes', 'physical_keys.json');
const REGISTRY_DIR = path.join(REPO_ROOT, 'static', 'layouts', 'registry');
const OUT_DIR = path.join(REPO_ROOT, 'static', 'ergopti_plus', 'windows', 'layouts', 'native');
const CANONICAL_SCRIPT = path.join(__dirname, 'lib', 'keylayout_canonical.lua');

/**
 * The first Lua runtime on PATH (the order of the other Lua-backed tools).
 * @returns {string}
 */
function luaRuntime() {
	for (const name of ['luajit', 'lua5.4', 'lua']) {
		if (spawnSync(name, ['-v'], { encoding: 'utf8' }).status === 0) return name;
	}
	throw new Error('codegen:windows-keyboard-layout needs luajit, lua5.4 or lua on PATH');
}

/**
 * Reads the canonical form of a .keylayout through the shared Lua parser.
 * @param {string} keylayoutPath - Absolute path.
 * @returns {object}
 */
function readCanonical(keylayoutPath) {
	const result = spawnSync(luaRuntime(), [CANONICAL_SCRIPT, SHARED_DIR, keylayoutPath], {
		encoding: 'utf8',
		maxBuffer: 64 * 1024 * 1024
	});
	if (result.status !== 0)
		throw new Error(
			`the shared keylayout parser refused ${keylayoutPath}: ${(result.stderr || '').trim()}`
		);
	return JSON.parse(result.stdout);
}

/**
 * Builds every generated source.
 * @returns {{spec: object, files: Map<string, string>, klc: string, model: object}}
 */
function buildSources() {
	const spec = JSON.parse(fs.readFileSync(SPEC_PATH, 'utf8'));
	const layoutDir = path.join(REGISTRY_DIR, spec.registry_id);
	const meta = parseToml(fs.readFileSync(path.join(layoutDir, 'meta.toml'), 'utf8'));
	const keylayoutPath = path.join(layoutDir, `${spec.registry_id}.keylayout`);
	const keycodes = JSON.parse(fs.readFileSync(KEYCODES_PATH, 'utf8'));
	const sourceRel = path.relative(REPO_ROOT, keylayoutPath).split(path.sep).join('/');
	const physicalKeys = JSON.parse(fs.readFileSync(PHYSICAL_KEYS_PATH, 'utf8'));
	const generated = generate(readCanonical(keylayoutPath), {
		meta,
		spec,
		keycodes,
		physicalKeys,
		sourceRel
	});
	return { spec, ...generated };
}

/**
 * The generated file paths, relative to the repository root.
 * @returns {string[]}
 */
function outputs() {
	const spec = JSON.parse(fs.readFileSync(SPEC_PATH, 'utf8'));
	return ['c', 'h', 'rc', 'def'].map((ext) =>
		path
			.relative(REPO_ROOT, path.join(OUT_DIR, `${spec.dll_name}.${ext}`))
			.split(path.sep)
			.join('/')
	);
}

/**
 * Writes the generated sources and, with --klc <dir>, the .klc.
 * @param {string[]} argv - Command-line arguments.
 */
function main(argv) {
	let klcDir = null;
	for (let index = 0; index < argv.length; index++) {
		if (argv[index] === '--klc' && klcDir === null && argv[index + 1])
			klcDir = path.resolve(argv[++index]);
		else throw new Error(`unknown or duplicate argument: ${argv[index]}`);
	}
	console.log('codegen:windows-keyboard-layout — generating the keyboard layout DLL sources…');
	const { spec, files, klc } = buildSources();
	fs.mkdirSync(OUT_DIR, { recursive: true });
	for (const [name, text] of files) fs.writeFileSync(path.join(OUT_DIR, name), text);
	console.log(`codegen:windows-keyboard-layout — wrote ${files.size} files to ${OUT_DIR}`);
	if (klcDir !== null) {
		fs.mkdirSync(klcDir, { recursive: true });
		const klcPath = path.join(klcDir, `${spec.dll_name}.klc`);
		fs.writeFileSync(klcPath, encodeKlc(klc));
		console.log(`codegen:windows-keyboard-layout — wrote ${klcPath}`);
	}
}

if (require.main === module) main(process.argv.slice(2));

module.exports = { buildSources, outputs, OUT_DIR, SPEC_PATH };
