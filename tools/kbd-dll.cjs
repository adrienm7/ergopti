// tools/kbd-dll.cjs

/**
 * ==============================================================================
 * MODULE: Keyboard Layout DLL CLI
 * DESCRIPTION:
 * Builds the Windows keyboard layout DLLs of a KLC file, a layout source or a
 * kbd tables model on any OS: `build <file.klc|source.toml|model.json>
 * <new-directory>` writes model.json, the generated C, resource and
 * module-definition sources, the x86, wow64, x64 and arm64 images
 * (<arch>/<dll>.dll), the unsigned NSIS installer (<dll>-setup.exe and its
 * installer.nsi) and report.json, after reading each image back with the
 * independent reader and comparing it with the model. `model <input> <out.json>`
 * writes the model only. See docs/design/layout-windows-dll.md.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { fromKlc } = require('./lib/kbd-dll/klc.cjs');
const Model = require('./lib/kbd-dll/model.cjs');
const { buildDlls } = require('./lib/kbd-dll/build.cjs');
const { readDll } = require('./lib/kbd-dll/reader.cjs');
const { compareLayout } = require('./lib/kbd-dll/compare.cjs');
const KbdSource = require('./lib/kbd-dll/source.cjs');
const { buildInstaller } = require('./lib/kbd-dll/installer.cjs');
const { loadLayoutSource } = require('./lib/layout-source.cjs');

/**
 * The model of an input file: a .klc is read, a layout source (.toml) is
 * converted (what Windows has no key or column for is in `omitted`), a .json
 * is checked.
 * @returns {{model: object, omitted: object[]}}
 */
function loadInput(file) {
	const bytes = fs.readFileSync(file);
	const lower = file.toLowerCase();
	if (lower.endsWith('.klc')) return { model: fromKlc(bytes), omitted: [] };
	if (lower.endsWith('.toml')) {
		const document = loadLayoutSource().read(bytes.toString('utf8'));
		return KbdSource.fromSource(document);
	}
	return { model: Model.check(JSON.parse(bytes.toString('utf8'))), omitted: [] };
}

/** The model of an input file (see loadInput). */
function loadModel(file) {
	return loadInput(file).model;
}

/**
 * Builds, reads back and compares every image; throws before writing on any
 * difference, so a directory only ever holds verified images.
 * @returns {{model: object, sources: object, dlls: object, report: object}}
 */
function buildVerified(model) {
	const { sources, dlls } = buildDlls(model);
	const images = {};
	for (const [arch, bytes] of Object.entries(dlls)) {
		const read = readDll(bytes);
		const diffs = compareLayout(model, read.layout);
		if (diffs.length) {
			const error = new Error(`kbd_dll_golden: ${arch} differs from its model`);
			error.details = diffs;
			throw error;
		}
		images[arch] = {
			file: `${arch}/${model.dll_name}.dll`,
			bytes: bytes.length,
			machine: read.machine,
			pointer_bytes: read.pointer,
			wow64: read.wow64,
			checked_pointers: read.checks.length
		};
	}
	const report = {
		dll_name: model.dll_name,
		layout_text: model.layout_text,
		lcid: model.lcid,
		columns: model.columns,
		keys: model.keys.length,
		dead_keys: model.dead_keys.length,
		images,
		installer: null
	};
	const installer = buildInstaller(model, dlls);
	report.installer = { file: installer.file, bytes: installer.bytes.length, signed: false };
	return { model, sources, dlls, installer, report };
}

function main(argv) {
	const [command, input, output] = argv;
	if (command === 'model' && input && output) {
		fs.writeFileSync(output, `${JSON.stringify(loadModel(input), null, '\t')}\n`, { flag: 'wx' });
		return;
	}
	if (command === 'build' && input && output) {
		const loaded = loadInput(input);
		const built = buildVerified(loaded.model);
		built.report.omitted = loaded.omitted;
		fs.mkdirSync(output, { recursive: false });
		const name = built.model.dll_name;
		const write = (rel, data) => {
			fs.mkdirSync(path.dirname(path.join(output, rel)), { recursive: true });
			fs.writeFileSync(path.join(output, rel), data, { flag: 'wx' });
		};
		write('model.json', `${JSON.stringify(built.model, null, '\t')}\n`);
		write(`src/${name}.c`, built.sources.c);
		write(`src/${name}.rc`, built.sources.rc);
		write(`src/${name}.def`, built.sources.def);
		for (const [arch, bytes] of Object.entries(built.dlls)) write(`${arch}/${name}.dll`, bytes);
		write('installer.nsi', built.installer.script);
		write(built.installer.file, built.installer.bytes);
		write('report.json', `${JSON.stringify(built.report, null, 2)}\n`);
		process.stdout.write(`${JSON.stringify(built.report, null, 2)}\n`);
		return;
	}
	throw new Error(
		'Usage: kbd-dll.cjs build <file.klc|source.toml|model.json> <new-directory> | model <file.klc|source.toml> <out.json>'
	);
}

if (require.main === module) {
	try {
		main(process.argv.slice(2));
	} catch (error) {
		console.error(`kbd-dll: ${error.message}`);
		if (error.details) console.error(JSON.stringify(error.details.slice(0, 20), null, 2));
		process.exitCode = 1;
	}
}

module.exports = { loadInput, loadModel, buildVerified };
