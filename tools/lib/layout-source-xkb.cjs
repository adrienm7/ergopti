// tools/lib/layout-source-xkb.cjs

/**
 * ==============================================================================
 * MODULE: Ergopti Layout Source XKB Export
 * DESCRIPTION:
 * Compiles a source through the shared Lua export adapter
 * (_shared/lua/layouts/source_export.lua) and the shared target export
 * (_shared/ui/layout_composer/target_export.js), the same two steps the layout
 * editor page runs. Assets and source travel as explicit input; the API returns
 * artifacts without writing files or installing anything.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { REPO_ROOT, shared } = require('./paths.cjs');
const { loadLayoutSource } = require('./layout-source.cjs');

/** A value built in the source model's context, as plain data of this realm. */
const plain = (value) => JSON.parse(JSON.stringify(value));

/**
 * Run the shared Lua export adapter (source_export.lua) on one step's input.
 * @param {'read'|'xkb'} step
 * @param {object} input
 * @param {string} label - Prefix of a runtime failure's message.
 */
function runLua(step, input, label) {
	const result = spawnSync(
		'lua',
		[path.join(__dirname, 'layout_source_export.lua'), shared(), step],
		{
			encoding: 'utf8',
			input: JSON.stringify(input),
			timeout: 30000,
			maxBuffer: 16 * 1024 * 1024
		}
	);
	if (result.error) throw new Error(`${label}: ${result.error.message}`);
	if (result.status !== 0) throw new Error(`${label}: ${result.stderr.trim()}`);
	return JSON.parse(result.stdout);
}

/** The converter assets the XKB export reads, from their owners. */
function xkbAssets() {
	const data = path.join(REPO_ROOT, 'static', 'ergopti', 'linux', 'xkb_generation', 'data');
	return {
		keycodes: JSON.parse(
			fs.readFileSync(shared('modules', 'layouts', 'mac_keycodes.json'), 'utf8')
		),
		keysyms: JSON.parse(fs.readFileSync(path.join(data, 'key_sym.json'), 'utf8')),
		template: fs.readFileSync(path.join(data, 'xkb_symbols.txt'), 'utf8'),
		types: fs.readFileSync(path.join(data, 'xkb_types.txt'), 'utf8')
	};
}

/**
 * Rethrow a shared-module refusal as an Error of this realm with its details.
 * @param {Function} step
 */
function admitted(step) {
	try {
		return step();
	} catch (error) {
		if (error && error.name === 'TargetExportError') {
			const local = new Error(error.message);
			if (error.details !== undefined) local.details = plain(error.details);
			throw local;
		}
		throw error;
	}
}

/** Compile all artifacts before a caller publishes any output. */
function exportXkb(document) {
	const source = loadLayoutSource();
	// The preserved import, or the compiled .keylayout of a structured source.
	const imported = source.targetKeylayout(document, 'linux');
	const assets = xkbAssets();
	const request = admitted(() => source.targetExport.xkbRequest(document, imported, assets));
	const output = runLua('xkb', request.input, 'xkb_runtime');
	const { report, files } = admitted(() =>
		source.targetExport.xkbFiles(imported, request, output, assets.types)
	);
	return {
		report: plain(report),
		files: new Map(files.map((file) => [file.path, file.text]))
	};
}

module.exports = { exportXkb, runLua, admitted, plain };
