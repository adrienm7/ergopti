// tools/test/test-structure-tool-lua-roots.cjs

/**
 * ==============================================================================
 * MODULE: Structure Plan Lua Roots Of A Tool
 * DESCRIPTION:
 * A Lua tool outside the trees runs on the package.path its caller sets.
 * tools/diagnostics/hs_karabiner_config_native.lua names no driver, so the
 * plan read its requires against the shared tree only and left
 * require("adapters.json_codec") behind when S04 moved the macOS adapters;
 * the macOS Karabiner config fixture then failed to load the tool. A tool
 * that requires a module only one driver has now loads that driver's names.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const Plan = require('../audit/structure/plan.cjs');
const Apply = require('../audit/structure/apply-step.cjs');

const FILE = 'tools/diagnostics/zz_probe_tool.lua';
const MAP = new Map([
	['macos/adapters/json_codec.lua', 'macos/core/fs/adapters/json_codec.lua'],
	['macos/adapters/file_system.lua', 'macos/core/fs/adapters/file_system.lua'],
	['linux/adapters/file_system.lua', 'linux/core/fs/adapters/file_system.lua'],
	['linux/adapters/clipboard.lua', 'linux/core/ui/adapters/clipboard.lua']
]);

/** Scans `text` as the probe tool under MAP and applies its rows. */
function rewrite(text) {
	const rows = Plan.scanFile(FILE, text, Plan.referenceContext(MAP));
	return Apply.rewriteText(text, rows, new Map(), FILE);
}

function run() {
	// adapters.json_codec exists in macOS only: the tool runs there, and its
	// file_system is macOS's too.
	const out = rewrite(
		'local Codec = require("adapters.json_codec")\nlocal FS = require("adapters.file_system")\n'
	);
	assert.ok(out.includes('require("core.fs.adapters.json_codec")'), out);
	assert.ok(out.includes('require("core.fs.adapters.file_system")'), out);

	// A module both drivers have proves no driver: the tool keeps its names.
	const both = 'local FS = require("adapters.file_system")\n';
	assert.equal(rewrite(both), both);
	// A JavaScript test that runs Lua with its working directory joined as
	// path.join(root, 'macos'): that piece names the driver its chunk loads.
	const JS = 'tools/test/zz_probe_runner.cjs';
	const js =
		"const cwd = path.join(root, 'macos');\n" +
		'const chunk = "package.loaded[\'adapters.file_system\'].read = nil";\n';
	const jsMap = new Map([
		['macos/adapters/file_system.lua', 'macos/core/fs/adapters/file_system.lua'],
		['linux/adapters/file_system.lua', 'linux/system/adapters/file_system.lua']
	]);
	const jsRows = Plan.scanFile(JS, js, Plan.referenceContext(jsMap));
	const jsOut = Apply.rewriteText(js, jsRows, new Map(), JS);
	assert.ok(jsOut.includes("package.loaded['core.fs.adapters.file_system']"), jsOut);

	// A tool on one driver's files names them under its root: the exemption
	// list of the Linux shared-path guard ('infra/paths.lua') kept its old
	// entry after S04 moved the resolver, and the guard flagged the resolver.
	const GUARD = 'tools/test/zz_probe_guard.cjs';
	const guard =
		"const DRIVER = path.join(ROOT, 'static', 'ergopti_plus', 'linux');\n" +
		"const EXEMPT = new Set(['infra/paths.lua', 'ui/webkit_host.lua']);\n";
	const guardMap = new Map([
		['linux/infra/paths.lua', 'linux/core/fs/engine/paths.lua'],
		['linux/ui/webkit_host.lua', 'linux/ui/webkit_host.lua']
	]);
	const guardRows = Plan.scanFile(GUARD, guard, Plan.referenceContext(guardMap));
	const guardOut = Apply.rewriteText(guard, guardRows, new Map(), GUARD);
	assert.ok(
		guardOut.includes("new Set(['core/fs/engine/paths.lua', 'ui/webkit_host.lua'])"),
		guardOut
	);

	// A driver module escaped in a tool's regular expression: the config
	// surface ratchet's /require\("adapters\.file_system"\)/ kept its name
	// after S04, and the ratchet lost the secondary owner it checks.
	const RX = 'tools/test/zz_probe_ratchet.cjs';
	const rx =
		"const src = read(path.join(DRIVERS_DIR, 'macos', 'x.lua'));\n" +
		'const ok = /require\\("adapters\\.file_system"\\)/.test(src);\n';
	const rxRows = Plan.scanFile(RX, rx, Plan.referenceContext(jsMap));
	const rxOut = Apply.rewriteText(rx, rxRows, new Map(), RX);
	assert.ok(rxOut.includes('/require\\("core\\.fs\\.adapters\\.file_system"\\)/'), rxOut);

	console.log('[OK] a Lua tool that requires a module only one driver has loads that driver.');
}

run();
