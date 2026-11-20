// tools/codegen/codegen-layout-source-emulation.cjs

/**
 * ==============================================================================
 * MODULE: Layout Source Emulation Golden Tables
 * DESCRIPTION:
 * Writes the emulation tables of the layout source fixtures, per platform,
 * with the one source compiler (compileEmulation). The web engine and the Lua
 * and AutoHotkey drivers replay the shared typing vectors on emulation.json and
 * on neo2_emulation.json (Neo 2's Mod3 and Mod4 on Caps Lock and AltGr, its
 * dead keys on those levels); the drivers' composer host tests store
 * source_emulation.json beside source.toml. ergopti_emulation.json holds the
 * tables of the Ergopti layouts, which declare no custom modifier: it pins that
 * they stay what they were before the emulation held Caps Lock and AltGr. A
 * compiler change regenerates them here, never by hand.
 * ==============================================================================
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { loadLayoutSource } = require('../lib/layout-source.cjs');

const ROOT = path.resolve(__dirname, '../..');
const CORPUS = 'static/ergopti_plus/_shared/tests/corpus/layouts/source';
const OUTPUTS = [
	['emulation_source.toml', 'emulation.json'],
	['source.toml', 'source_emulation.json'],
	['neo2_source.toml', 'neo2_emulation.json']
];
const PLATFORMS = ['macos', 'linux', 'windows'];
// The Ergopti layouts: the structured source and the registry's .keylayout files.
const ERGOPTI_OUTPUT = 'ergopti_emulation.json';
const ERGOPTI_SOURCE = 'static/layouts/sources/ergopti.toml';
const ERGOPTI_REGISTRY = [
	['ergopti', 'iso'],
	['ergopti_plus', 'iso'],
	['ergopti_ansi', 'ansi'],
	['ergopti_plus_ansi', 'ansi']
];

/** The tables of one source document, per platform. */
function tables(source, document) {
	return Object.fromEntries(
		PLATFORMS.map((platform) => [platform, source.compileEmulation(document, { platform })])
	);
}

/** The tables of one source as the committed JSON text. */
function render(source, text) {
	return `${JSON.stringify(tables(source, source.read(text)), null, '\t')}\n`;
}

/** The tables of every Ergopti layout, keyed by the file each is read from. */
function renderErgopti(source) {
	const out = {
		[path.basename(ERGOPTI_SOURCE)]: tables(
			source,
			source.read(fs.readFileSync(path.join(ROOT, ERGOPTI_SOURCE), 'utf8'))
		)
	};
	for (const [id, convention] of ERGOPTI_REGISTRY) {
		const file = `static/layouts/registry/${id}/${id}.keylayout`;
		const imported = source.importStructured(
			fs.readFileSync(path.join(ROOT, file), 'utf8'),
			id,
			convention
		);
		out[`${id}/${id}.keylayout`] = tables(source, imported.source || imported);
	}
	return `${JSON.stringify(out, null, '\t')}\n`;
}

if (require.main === module) {
	const source = loadLayoutSource();
	const check = process.argv.includes('--check');
	const results = OUTPUTS.map(([input, output]) => [
		output,
		render(source, fs.readFileSync(path.join(ROOT, CORPUS, input), 'utf8'))
	]).concat([[ERGOPTI_OUTPUT, renderErgopti(source)]]);
	for (const [output, result] of results) {
		const target = path.join(ROOT, CORPUS, output);
		if (check) {
			if (fs.readFileSync(target, 'utf8') !== result)
				throw new Error(
					`${output} is stale: run node tools/codegen/codegen-layout-source-emulation.cjs.`
				);
		} else fs.writeFileSync(target, result);
	}
	console.log('[OK] Layout source emulation tables match the compiler.');
}

module.exports = { render, renderErgopti };
