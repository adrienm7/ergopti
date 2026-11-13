// tools/lib/layout-source.cjs

/**
 * ==============================================================================
 * MODULE: Ergopti Layout Source Loader
 * DESCRIPTION:
 * Loads the browser's source model and compiler with the existing composer
 * reader and the page's vendored TOML codec, and binds the physical key tables the compiler reads.
 * The CLI and tests use the same contract a shared editor can load.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { shared } = require('./paths.cjs');
// The page's own vendored codec (smol-toml's CommonJS build, byte for byte):
// one TOML reader for the editor and the tools, and none from node_modules, so
// a CI job without `npm ci` (the Linux E2E rows) can build an install payload.
const codec = vendoredCodec();

/** The vendored codec, run as the page runs it: a classic script writing `exports`. */
function vendoredCodec() {
	const filename = shared('ui', 'vendor', 'smol-toml.js');
	// In this realm, so the arrays and tables it parses are this realm's own.
	const loaded = {};
	vm.compileFunction(fs.readFileSync(filename, 'utf8'), ['exports'], { filename })(loaded);
	if (typeof loaded.parse !== 'function' || typeof loaded.stringify !== 'function')
		throw new Error(`${filename} does not define the TOML codec`);
	return loaded;
}

/** The key tables a page passes the compiler, read from their owners. */
function keyTables() {
	return {
		macKeycodes: JSON.parse(
			fs.readFileSync(shared('layouts', 'data', 'mac_keycodes.json'), 'utf8')
		),
		physicalKeys: JSON.parse(
			fs.readFileSync(shared('layouts', 'data', 'keycodes', 'physical_keys.json'), 'utf8')
		),
		hidUsages: JSON.parse(
			fs.readFileSync(shared('layouts', 'data', 'keycodes', 'hid_usages.json'), 'utf8')
		)
	};
}

/** Load the pure source model in the same classic-script order as a page. */
function loadLayoutSource() {
	const context = vm.createContext({});
	for (const file of [
		'composer_model.js',
		'source_model.js',
		'source_compiler.js',
		'source_emulation.js',
		'target_compiler.js',
		'target_export.js'
	]) {
		const filename = path.join(shared('ui', 'layout_composer'), file);
		vm.runInContext(fs.readFileSync(filename, 'utf8'), context, { filename });
	}
	const model = vm.runInContext('LayoutSource', context);
	const compiler = vm.runInContext('LayoutSourceCompiler', context);
	const composer = vm.runInContext('LayoutComposer', context);
	const emulation = vm.runInContext('LayoutSourceEmulation', context);
	const targetExport = vm.runInContext('LayoutTargetExport', context);
	const targetCompiler = vm.runInContext('LayoutTargetCompiler', context);
	const tables = keyTables();
	return {
		...model,
		composer,
		emulation,
		targetExport,
		targetCompiler,
		tables,
		read: (text) => model.read(text, codec),
		write: (source) => model.write(source, codec),
		importStructured: (text, id, convention) =>
			compiler.importStructured(text, id, convention, tables),
		compileKeylayout: (source, options) => compiler.compileKeylayout(source, tables, options),
		exportMacos: (source, format, icons) => compiler.exportMacos(source, tables, format, icons),
		compileEmulation: (source, options) => compiler.compileEmulation(source, tables, options),
		targetKeylayout: (source, platform) => compiler.targetKeylayout(source, tables, platform),
		target: (source, platform) => targetCompiler.target(source, tables, platform)
	};
}

module.exports = { loadLayoutSource };
