// tools/codegen/codegen-layout-source-emulation.cjs

/**
 * ==============================================================================
 * MODULE: Layout Source Emulation Golden Tables
 * DESCRIPTION:
 * Writes the emulation tables of the two layout source fixtures, per platform,
 * with the one source compiler (compileEmulation). The web engine and both Lua
 * drivers replay the shared typing vectors on emulation.json; the drivers'
 * composer host tests store source_emulation.json beside source.toml. A
 * compiler change regenerates both here, never by hand.
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
	['source.toml', 'source_emulation.json']
];
const PLATFORMS = ['macos', 'linux', 'windows'];

/** The tables of one source as the committed JSON text. */
function render(source, text) {
	const document = source.read(text);
	const tables = Object.fromEntries(
		PLATFORMS.map((platform) => [platform, source.compileEmulation(document, { platform })])
	);
	return `${JSON.stringify(tables, null, '\t')}\n`;
}

if (require.main === module) {
	const source = loadLayoutSource();
	const check = process.argv.includes('--check');
	for (const [input, output] of OUTPUTS) {
		const result = render(source, fs.readFileSync(path.join(ROOT, CORPUS, input), 'utf8'));
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

module.exports = { render };
