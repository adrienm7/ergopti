// tools/layout-source.cjs

/**
 * ==============================================================================
 * MODULE: Ergopti Layout Source CLI
 * DESCRIPTION:
 * Imports .keylayout into the versioned TOML source (preserved or structured),
 * validates source documents, reports per-target support, and runs the one
 * generator: the macOS bundle (ISO + ANSI) or single .keylayout, the Linux
 * XKB and Windows KLC files through their existing converters, and the
 * emulation tables the drivers and the web perform on top of them. Existing
 * destinations are refused so a failed experiment cannot replace a user's
 * source. See docs/design/layout-source-format.md for the current limits.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { loadLayoutSource } = require('./lib/layout-source.cjs');
const { exportXkb } = require('./lib/layout-source-xkb.cjs');
const { exportKlc } = require('./lib/layout-source-klc.cjs');
const { targetReport } = require('./lib/layout-source-report.cjs');

/** Decode UTF-8 strictly while retaining an original byte-order mark. */
function readText(file) {
	return new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(fs.readFileSync(file));
}

/** Publish a compiled file map into a new directory, refusing an existing one. */
function publish(directory, files) {
	fs.mkdirSync(directory, { recursive: false });
	for (const [name, content] of files) {
		const target = path.join(directory, name);
		fs.mkdirSync(path.dirname(target), { recursive: true });
		fs.writeFileSync(target, content, { encoding: 'utf8', flag: 'wx' });
	}
}

/**
 * The PNG files a source names as its macOS icons, read beside the source file.
 * The source model admits only plain file names, so none leaves that folder.
 */
function readIcons(document, sourceFile) {
	const macos = (document.exports && document.exports.macos) || {};
	const icons = {};
	for (const field of ['icon', 'ansi_icon'])
		if (typeof macos[field] === 'string')
			icons[macos[field]] = new Uint8Array(
				fs.readFileSync(path.join(path.dirname(sourceFile), macos[field]))
			);
	return icons;
}

/** The macOS artifacts as a file map; strings and icon files carry their own encoding. */
function macosFiles(compiled) {
	return compiled.files
		.map((file) => [
			file.path,
			file.encoding === 'binary'
				? Buffer.from(file.bytes)
				: file.encoding === 'utf16le'
					? Buffer.from(file.text, 'utf16le')
					: file.text
		])
		.concat([['export.json', `${JSON.stringify(compiled.report, null, 2)}\n`]]);
}

/** The emulation table of every platform, as export-emulation writes it. */
function emulationTables(source, document) {
	return Object.fromEntries(
		['macos', 'linux', 'windows'].map((platform) => [
			platform,
			source.compileEmulation(document, { platform })
		])
	);
}

/**
 * The files the ErgoptiPlus drivers and the web emulation perform: one emulation
 * table per platform, and for the web, which has no installed layout, the macOS
 * .keylayout its keylayout emulation types with.
 */
function emulationFiles(source, document) {
	const tables = emulationTables(source, document);
	const files = Object.entries(tables).map(([platform, table]) => [
		`emulation.${platform}.json`,
		`${JSON.stringify(table, null, '\t')}\n`
	]);
	const report = {
		target: 'emulation',
		status: Object.values(tables).some((table) => table.not_emulated.length)
			? 'partial'
			: 'emulated',
		artifact: 'emulation_table',
		not_emulated: Object.fromEntries(
			Object.entries(tables).map(([platform, table]) => [platform, table.not_emulated])
		)
	};
	return files.concat([['export.json', `${JSON.stringify(report, null, 2)}\n`]]);
}

/** The web emulation: the compiled .keylayout and the table it types on top of. */
function webFiles(source, document) {
	const compiled = source.compileKeylayout(document);
	const table = source.compileEmulation(document, { platform: 'macos' });
	const report = {
		target: 'web',
		status: table.not_emulated.length ? 'partial' : 'emulated',
		artifact: 'web_emulation',
		keylayout: `${compiled.names.internal}.keylayout`,
		not_emulated: table.not_emulated
	};
	return [
		[`${compiled.names.internal}.keylayout`, compiled.text],
		['emulation.json', `${JSON.stringify(table, null, '\t')}\n`],
		['export.json', `${JSON.stringify(report, null, 2)}\n`]
	];
}

/**
 * Every target of one source into a new directory: macos/, linux/, windows/,
 * emulation/ and web/ with each export's report, and report.json naming refused
 * targets. A refused target writes no directory; the others still publish.
 */
function exportAll(source, document, output, icons) {
	const reports = [];
	const outputs = [];
	for (const [target, compile] of [
		['macos', () => macosFiles(source.exportMacos(document, undefined, icons))],
		['linux', () => [...exportXkb(document).files]],
		['windows', () => [...exportKlc(document).files]],
		['emulation', () => emulationFiles(source, document)],
		['web', () => webFiles(source, document)]
	]) {
		try {
			const files = compile();
			outputs.push([target, files]);
			const report = files.find(([name]) => name === 'export.json');
			reports.push(JSON.parse(report[1]));
		} catch (error) {
			reports.push({ target, status: 'unavailable', reason: error.message });
		}
	}
	fs.mkdirSync(output);
	for (const [target, files] of outputs) publish(path.join(output, target), files);
	const text = `${JSON.stringify(reports, null, 2)}\n`;
	fs.writeFileSync(path.join(output, 'report.json'), text, { encoding: 'utf8', flag: 'wx' });
	return reports;
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
	if (command === 'import-structured' && values.length === 4) {
		const [id, convention, input, output] = values;
		const document = source.importStructured(readText(input), id, convention);
		fs.writeFileSync(output, source.write(document), { encoding: 'utf8', flag: 'wx' });
		return;
	}
	if (command === 'export-macos' && (values.length === 2 || values.length === 3)) {
		const [input, output, format] = values;
		const document = source.read(readText(input));
		const compiled = source.exportMacos(document, format, readIcons(document, input));
		publish(output, macosFiles(compiled));
		process.stdout.write(`${JSON.stringify(compiled.report, null, 2)}\n`);
		return;
	}
	if (command === 'export-all' && values.length === 2) {
		const [input, output] = values;
		const document = source.read(readText(input));
		const reports = exportAll(source, document, output, readIcons(document, input));
		process.stdout.write(`${JSON.stringify(reports, null, 2)}\n`);
		return;
	}
	if (command === 'export-emulation' && values.length === 2) {
		const [input, output] = values;
		const tables = emulationTables(source, source.read(readText(input)));
		fs.writeFileSync(output, `${JSON.stringify(tables, null, '\t')}\n`, {
			encoding: 'utf8',
			flag: 'wx'
		});
		return;
	}
	// What the editor's « Install and use » sends the ErgoptiPlus composer host
	// (LayoutSourceIO.installPayload): the source, its .keylayout and emulation table.
	if (command === 'install-payload' && values.length === 3) {
		const [input, platform, output] = values;
		if (platform !== 'macos' && platform !== 'linux')
			throw new Error('install-payload: the platform is macos or linux');
		const document = source.read(readText(input));
		const payload = {
			source: source.write(document),
			keylayout: source.targetKeylayout(document, platform).text,
			emulation: JSON.stringify(source.compileEmulation(document, { platform }))
		};
		// The Linux host writes the installed XKB from this target (composer.lua check_target).
		if (platform === 'linux' && !document.imported_keylayout)
			payload.target = JSON.stringify(source.hostTarget(document));
		fs.writeFileSync(output, `${JSON.stringify(payload)}\n`, { encoding: 'utf8', flag: 'wx' });
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
				? targetReport(document, readIcons(document, values[0]))
				: {
						valid: true,
						format: document.format,
						version: document.version,
						id: document.layout.id
					};
		process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
		return;
	}
	if ((command === 'export-xkb' || command === 'export-klc') && values.length === 2) {
		const [input, output] = values;
		const compile = command === 'export-xkb' ? exportXkb : exportKlc;
		const compiled = compile(source.read(readText(input)));
		publish(output, compiled.files);
		process.stdout.write(`${JSON.stringify(compiled.report, null, 2)}\n`);
		return;
	}
	throw new Error(
		'Usage: layout-source.cjs import <id> <iso|ansi> <input.keylayout> <output.toml> | import-structured <id> <iso|ansi> <input.keylayout> <output.toml> | export-macos <source.toml> <new-output-directory> [bundle|iso|ansi] | export-all <source.toml> <new-output-directory> | export-emulation <source.toml> <output.json> | install-payload <source.toml> <macos|linux> <output.json> | validate <source.toml> | report <source.toml> | export-keylayout <source.toml> <output.keylayout> | export-xkb <source.toml> <new-output-directory> | export-klc <source.toml> <new-output-directory>'
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
