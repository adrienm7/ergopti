// tools/test/test-structure-lua-prefix-sweeps.cjs

/**
 * ==============================================================================
 * MODULE: Structure Plan Lua Prefix Sweeps
 * DESCRIPTION:
 * Tests reset package.loaded with a module-name prefix written as a Lua
 * pattern: name:match("^modules%.keymap%.registry"). On the full chain the
 * plan left these literals alone, or respelled the one module the prefix
 * happened to name (registry -> settings%.engine%.registry), so the sweep
 * stopped covering registry_groups and registry_index, which moved apart, and
 * every hotstring matcher case failed on the stale registry they left behind.
 * A sweep literal now follows only when every module under it lands under one
 * new prefix that holds nothing else; a scattering step is refused.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const Plan = require('../audit/structure/plan.cjs');
const Apply = require('../audit/structure/apply-step.cjs');

const FILE = 'static/ergopti_plus/linux/tests/unit/test_probe.lua';
const BASE = [
	['linux/modules/keymap/registry.lua', 'linux/settings/engine/registry.lua'],
	[
		'linux/modules/keymap/registry_groups.lua',
		'linux/hotstrings/engine/expander/registry_groups.lua'
	],
	[
		'linux/modules/keymap/registry_index.lua',
		'linux/hotstrings/engine/expander/registry_index.lua'
	],
	['linux/modules/llm/client.lua', 'linux/ai/engine/client.lua'],
	['linux/modules/llm/backends/ollama.lua', 'linux/ai/engine/backends/ollama.lua'],
	['linux/modules/gestures/swipe.lua', 'linux/modules/gestures/swipe.lua'],
	['linux/tests/unit/test_probe.lua', 'linux/tests/unit/test_probe.lua']
];

/** Scans `text` as the probe file under `map`; returns its rows and new text. */
function scan(text, map = new Map(BASE)) {
	const rows = Plan.scanFile(FILE, text, Plan.referenceContext(map));
	// A refused row stops the step: there is no text to apply then.
	if (rows.some((r) => Plan.REFUSED_KINDS.has(r.kind))) return { rows, out: null };
	return { rows, out: Apply.rewriteText(text, rows, new Map(), FILE) };
}

/** A sweep of package.loaded through `pattern`, as the driver tests write it. */
function sweep(pattern) {
	return (
		'for name in pairs(package.loaded) do\n' +
		`\tif name:match("${pattern}") then package.loaded[name] = nil end\n` +
		'end\n'
	);
}

function run() {
	// The registry family splits: the sweep is refused, never respelled to
	// the one module whose full name the prefix also is.
	{
		const { rows } = scan(sweep('^modules%.keymap%.registry'));
		const refused = rows.filter((r) => r.kind === 'lua-prefix-split');
		assert.equal(refused.length, 1, JSON.stringify(rows));
		assert.equal(refused[0].old, '"^modules%.keymap%.registry"');
		assert.ok(Plan.REFUSED_KINDS.has(refused[0].kind));
	}

	// Every module under the prefix lands under one new prefix holding nothing
	// else: the literal follows.
	{
		const { out } = scan(sweep('^modules%.llm%.'));
		assert.ok(out.includes('name:match("^ai%.engine%.")'), out);
	}

	// A prefix whose modules all stay keeps its literal.
	{
		const text = sweep('^modules%.gestures%.');
		const { rows, out } = scan(text);
		assert.ok(!rows.some((r) => r.kind === 'lua-prefix-split'), JSON.stringify(rows));
		assert.equal(out, text);
	}

	// A broad sweep the step only partly empties is refused.
	{
		const { rows } = scan(sweep('^modules%.'));
		assert.ok(
			rows.some((r) => r.kind === 'lua-prefix-split' && r.old === '"^modules%."'),
			JSON.stringify(rows)
		);
	}

	// The new prefix also receives a module from elsewhere: following would
	// widen the sweep, so the step is refused.
	{
		const map = new Map(BASE);
		map.set('linux/infra/llm_paths.lua', 'linux/ai/engine/paths.lua');
		const { rows } = scan(sweep('^modules%.llm%.'), map);
		assert.ok(
			rows.some((r) => r.kind === 'lua-prefix-split' && r.old === '"^modules%.llm%."'),
			JSON.stringify(rows)
		);
	}

	// A config-key pattern in a file that never touches package.loaded is no
	// sweep: no row of either kind.
	{
		const text = 'local key = path:match("^modules%.keymap%.registry")\n';
		const { rows } = scan(text);
		assert.ok(
			!rows.some((r) => r.kind === 'lua-prefix-split' || r.kind === 'lua-prefix-pattern'),
			JSON.stringify(rows)
		);
	}

	// A module name a test helper builds at run time, helpers.load_with_stubs(
	// "modules.llm." .. name): unlisted, it refuses the step that moves the
	// modules under it, like require("modules.llm." .. name) does.
	{
		const { rows } = scan('local m = helpers.load_with_stubs("modules.llm." .. name)\n');
		assert.ok(
			rows.some((r) => r.kind === 'lua-prefix-split' && r.old === 'modules.llm.'),
			JSON.stringify(rows)
		);
	}

	// A family that moves together while one file is renamed on the way
	// (S12: ui/tooltip/tooltip_llm.lua -> core/ui/ui/tooltip/llm.lua): the
	// sweep follows their common new prefix, which holds nothing else.
	{
		const map = new Map([
			...BASE,
			['linux/ui/tooltip/init.lua', 'linux/core/ui/ui/tooltip/init.lua'],
			['linux/ui/tooltip/tooltip_llm.lua', 'linux/core/ui/ui/tooltip/llm.lua']
		]);
		const { out } = scan(sweep('^ui%.tooltip'), map);
		assert.ok(out && out.includes('name:match("^core%.ui%.ui%.tooltip")'), out);
	}

	// A runtime prefix a listed edit already rewrites at its own step
	// (edits.cjs) is that edit's: an earlier step that moves another module
	// under the same prefix refuses nothing (S08 moved a ui module while the
	// metrics flush bridge test's "ui." .. app .. ".bridge" waits for S30).
	{
		const listed = 'static/ergopti_plus/linux/tests/unit/ui/metrics/test_metrics_flush_bridge.lua';
		const text = 'local B = H.load_module("ui." .. app .. ".bridge")\n';
		const map = new Map([
			['linux/ui/network_status.lua', 'linux/core/network/ui/status.lua'],
			['linux/ui/metrics_apps/bridge.lua', 'linux/ui/metrics_apps/bridge.lua'],
			[
				'linux/tests/unit/ui/metrics/test_metrics_flush_bridge.lua',
				'linux/tests/unit/ui/metrics/test_metrics_flush_bridge.lua'
			]
		]);
		const rows = Plan.scanFile(listed, text, Plan.referenceContext(map));
		assert.ok(!rows.some((r) => r.kind === 'lua-prefix-split'), JSON.stringify(rows));
	}

	console.log('Lua prefix sweeps: OK');
}

run();
