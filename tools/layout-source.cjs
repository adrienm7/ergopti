// tools/layout-source.cjs

/**
 * ==============================================================================
 * MODULE: Ergopti Layout Source CLI
 * DESCRIPTION:
 * Imports .keylayout into the versioned TOML source, validates source documents,
 * reports implemented target support, and exports preserved .keylayout files.
 * Existing destinations are refused so a failed experiment cannot replace a
 * user's source. See docs/design/layout-source-format.md for the current limits.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const { loadLayoutSource } = require('./lib/layout-source.cjs');

/** Decode UTF-8 strictly while retaining an original byte-order mark. */
function readText(file) {
	return new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(fs.readFileSync(file));
}

/** Run one operation; invalid argument shapes never write an output file. */
function main(args) {
	const source = loadLayoutSource();
	const [command, ...values] = args;
	if (command === 'import' && values.length === 4) {
		const [id, convention, input, output] = values;
		const document = source.importKeylayout(readText(input), id, convention);
		fs.writeFileSync(output, source.write(document), { encoding: 'utf8', flag: 'wx' });
		return;
	}
	if (command === 'export-keylayout' && values.length === 2) {
		const [input, output] = values;
		const xml = source.exportKeylayout(source.read(readText(input)));
		fs.writeFileSync(output, xml, { encoding: 'utf8', flag: 'wx' });
		return;
	}
	if ((command === 'validate' || command === 'report') && values.length === 1) {
		const document = source.read(readText(values[0]));
		const report =
			command === 'report'
				? source.capabilities(document)
				: {
						valid: true,
						format: document.format,
						version: document.version,
						id: document.layout.id
					};
		process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
		return;
	}
	throw new Error(
		'Usage: layout-source.cjs import <id> <iso|ansi> <input.keylayout> <output.toml> | validate <source.toml> | report <source.toml> | export-keylayout <source.toml> <output.keylayout>'
	);
}

if (require.main === module) {
	try {
		main(process.argv.slice(2));
	} catch (error) {
		console.error(`layout-source: ${error.message}`);
		process.exitCode = 1;
	}
}

module.exports = { main };
