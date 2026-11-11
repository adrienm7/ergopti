// tools/lib/layout-source.cjs

/**
 * ==============================================================================
 * MODULE: Ergopti Layout Source Loader
 * DESCRIPTION:
 * Loads the browser's source model and compiler with the existing composer
 * reader and TOML codec, and binds the physical key tables the compiler reads.
 * The CLI and tests use the same contract a shared editor can load.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const codec = require('smol-toml');
const { shared } = require('./paths.cjs');

/** The key tables a page passes the compiler, read from their owners. */
function keyTables() {
	return {
		macKeycodes: JSON.parse(
			fs.readFileSync(shared('modules', 'layouts', 'mac_keycodes.json'), 'utf8')
		),
		physicalKeys: JSON.parse(
			fs.readFileSync(shared('data', 'keycodes', 'physical_keys.json'), 'utf8')
		),
		hidUsages: JSON.parse(fs.readFileSync(shared('data', 'keycodes', 'hid_usages.json'), 'utf8'))
	};
}

/** Load the pure source model in the same classic-script order as a page. */
function loadLayoutSource() {
	const context = vm.createContext({});
	for (const file of ['composer_model.js', 'source_model.js', 'source_compiler.js']) {
		const filename = path.join(shared('ui', 'layout_composer'), file);
		vm.runInContext(fs.readFileSync(filename, 'utf8'), context, { filename });
	}
	const model = vm.runInContext('LayoutSource', context);
	const compiler = vm.runInContext('LayoutSourceCompiler', context);
	const composer = vm.runInContext('LayoutComposer', context);
	const tables = keyTables();
	return {
		...model,
		composer,
		tables,
		read: (text) => model.read(text, codec),
		write: (source) => model.write(source, codec),
		importStructured: (text, id, convention) =>
			compiler.importStructured(text, id, convention, tables),
		compileKeylayout: (source, options) => compiler.compileKeylayout(source, tables, options),
		exportMacos: (source, format) => compiler.exportMacos(source, tables, format),
		targetKeylayout: (source, platform) => compiler.targetKeylayout(source, tables, platform)
	};
}

module.exports = { loadLayoutSource };
