// tools/lib/layout-source-klc.cjs

/**
 * ==============================================================================
 * MODULE: Ergopti Layout Source KLC Export
 * DESCRIPTION:
 * Compiles a structured source straight to the KLC writer's canonical form
 * (_shared/ui/layout_composer/target_compiler.js; a preserved import's XML is
 * read by the shared Lua export adapter instead), then admits it and builds
 * the MSKLC file and report through the shared target export
 * (target_export.js) with the existing Windows generator, the same steps the
 * layout editor page runs. Returns MSKLC bytes and a source-specific report
 * before any publication.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const { shared } = require('./paths.cjs');
const { loadLayoutSource } = require('./layout-source.cjs');
const { runLua, admitted, plain } = require('./layout-source-xkb.cjs');
const Windows = require('../codegen/lib/windows-keyboard-layout.cjs');

/** Create native character files without installing or reserving a Windows KLID. */
function exportKlc(document) {
	const source = loadLayoutSource();
	// The preserved import's XML, or the canonical form of a structured source.
	const target = source.target(document, 'windows');
	const metadata = admitted(() => source.targetExport.klcMetadata(document));
	let canonical = target.canonical;
	if (!canonical) {
		const read = runLua('read', { xml: target.text }, 'klc_runtime');
		if (!read.ok) throw new Error(read.reason);
		canonical = read.canonical;
	}
	const tables = {
		keycodes: JSON.parse(fs.readFileSync(shared('layouts', 'data', 'mac_keycodes.json'), 'utf8')),
		physicalKeys: JSON.parse(
			fs.readFileSync(shared('layouts', 'data', 'keycodes', 'physical_keys.json'), 'utf8')
		)
	};
	const exported = admitted(() =>
		source.targetExport.klcExport(document, target, plain(canonical), tables, Windows)
	);
	const report = plain(exported.report);
	return {
		report,
		files: new Map([
			[`${metadata.dll_name}.klc`, Windows.encodeKlc(exported.klc)],
			['export.json', `${JSON.stringify(report, null, 2)}\n`]
		])
	};
}

module.exports = { exportKlc };
