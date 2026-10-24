// tools/test/test-keystats-timings-single-source.cjs

/**
 * ==============================================================================
 * MODULE: Pinned Timing Copies Single-Source Guard
 * DESCRIPTION:
 * Some Windows timing constants are still declared as AHK literals although the
 * shared timing registry (_shared/modules/timings/constants.toml) holds the same
 * value: a `static` class constant or a top-level `global` that AHK v2
 * initialises before boot loads the registry. This gate pins each such copy to
 * its registry key, so the registry — the documented single source — can never
 * again describe a timing the driver does not use.
 *
 * ROOT CAUSE ENCODED:
 * The first three pairs (CONTEXT_TTL_MS, PARK_CHECK_MS, TOPO_TICK_MS) had
 * silently drifted from the shipped AHK constants (500 vs 1000, 100 vs 250, 500
 * vs 1500). Twenty more registry keys had no reader at all and nothing
 * comparing them with the constant they documented, so tuning them changed
 * nothing and a drift was invisible.
 *
 * FEATURES & RATIONALE:
 * 1. One table, PINS, lists every pinned copy. test-timings-registry-liveness.cjs
 *    reads it: a pin counts as a reader of its key, and a key with neither a
 *    runtime reader nor a pin fails there.
 * 2. Each declaration must exist exactly once in its file. A missing one means
 *    the constant was renamed or moved and the pin silently stopped guarding
 *    it; two of them make the value ambiguous.
 * 3. Second-valued copies (`*_SEC`) are converted, never re-declared in ms here.
 * 4. Negative mutations prove the comparison can fail.
 *
 * NOTE — duplication is still duplication:
 * These copies are not READ from the registry at runtime yet. Wiring a static
 * class constant needs the reassign-at-boot pattern (a sentinel, a loader run
 * after TimingsLoadShared) and a live Windows boot to verify load order. Until a
 * copy is wired, this pin is its single-source guarantee; once wired, its entry
 * is deleted.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const toml = require('smol-toml');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const REGISTRY_PATH = '_shared/modules/timings/constants.toml';
const MS_PER_SEC = 1000;

const KEYSTATS = 'windows/modules/keystats/';

/**
 * Builds one pin. `name` is the declared AHK constant; `unit` is 'sec' when the
 * copy holds seconds (the registry always holds milliseconds).
 * @returns {{section: string, key: string, file: string, name: string, unit: string}}
 */
function pin(section, key, file, name, unit = 'ms') {
	return { section, key, file, name, unit };
}

/** Every AHK literal copy of a registry key. */
const PINS = [
	pin('keystats', 'ingest_tick_ms', KEYSTATS + 'keystats_constants.ahk', 'INGEST_TICK_MS'),
	pin('keystats', 'think_pause_ms', KEYSTATS + 'keystats_constants.ahk', 'THINK_PAUSE_MS'),
	pin(
		'keystats',
		'max_keystroke_delay_ms',
		KEYSTATS + 'keystats_constants.ahk',
		'WPM_MAX_DELAY_MS'
	),
	pin(
		'keystats',
		'midnight_check_tick_ms',
		KEYSTATS + 'keystats_constants.ahk',
		'MIDNIGHT_CHECK_TICK_MS'
	),
	pin(
		'keystats',
		'micro_idle_timeout_ms',
		KEYSTATS + 'keystats_watchers.ahk',
		'MICRO_IDLE_TIMEOUT_MS'
	),
	pin('keystats', 'session_timeout_ms', KEYSTATS + 'keystats_watchers.ahk', 'SESSION_TIMEOUT_MS'),
	pin(
		'keystats',
		'idle_check_interval_ms',
		KEYSTATS + 'keystats_watchers.ahk',
		'IDLE_CHECK_INTERVAL_MS'
	),
	pin('keystats', 'hook_flush_period_ms', KEYSTATS + 'keystats_hook.ahk', 'FLUSH_PERIOD_MS'),
	pin('keystats', 'hook_context_ttl_ms', KEYSTATS + 'keystats_hook.ahk', 'CONTEXT_TTL_MS'),
	pin('keystats', 'topo_tick_ms', KEYSTATS + 'keystats_window_topology.ahk', 'TOPO_TICK_MS'),
	pin('keystats', 'av_state_fast_tick_ms', KEYSTATS + 'keystats_av_state.ahk', 'AVSTATE_TICK_MS'),
	pin('keystats', 'av_state_slow_tick_ms', KEYSTATS + 'keystats_av_state.ahk', 'SLOW_TICK_MS'),
	pin('keystats', 'network_wifi_tick_ms', KEYSTATS + 'keystats_network.ahk', 'NETWORK_TICK_MS'),
	pin('keystats', 'network_reach_tick_ms', KEYSTATS + 'keystats_network.ahk', 'REACH_TICK_MS'),
	pin('keystats', 'network_vpn_tick_ms', KEYSTATS + 'keystats_network.ahk', 'VPN_TICK_MS'),
	pin('keystats', 'sensor_tick_ms', KEYSTATS + 'keystats_sensors.ahk', 'SENSOR_TICK_MS'),
	pin(
		'keystats',
		'mouse_scroll_burst_gap_ms',
		KEYSTATS + 'keystats_mouse.ahk',
		'SCROLL_BURST_GAP_MS'
	),
	pin('keystats', 'mouse_park_check_ms', KEYSTATS + 'keystats_mouse.ahk', 'PARK_CHECK_MS'),
	pin('keystats', 'mouse_park_idle_ms', KEYSTATS + 'keystats_mouse.ahk', 'PARK_IDLE_MS'),
	pin(
		'keystats',
		'roi_halflife_check_ms',
		KEYSTATS + 'keystats_trigger_roi.ahk',
		'HALFLIFE_CHECK_MS'
	),
	pin(
		'keystats',
		'paste_burst_window_ms',
		KEYSTATS + 'keystats_clipboard.ahk',
		'PASTE_BURST_WINDOW_MS'
	),
	pin(
		'keystats',
		'app_category_save_debounce_ms',
		KEYSTATS + 'keystats_app_categories.ahk',
		'DEFERRED_SAVE_RETRY_MS'
	),
	pin('ergonomics', 'block_break_ms', KEYSTATS + 'keystats_ergonomics.ahk', 'BLOCK_BREAK_MS'),
	pin('ergonomics', 'block_warn_ms', KEYSTATS + 'keystats_ergonomics.ahk', 'BLOCK_WARN_MS'),
	pin('ergonomics', 'flow_window_ms', KEYSTATS + 'keystats_ergonomics.ahk', 'FLOW_WINDOW_MS'),
	pin('ergonomics', 'hesitation_ms', KEYSTATS + 'keystats_ergonomics.ahk', 'HESITATION_MS'),
	pin(
		'ergonomics',
		'hesitation_cooldown_ms',
		KEYSTATS + 'keystats_ergonomics.ahk',
		'HESITATION_COOLDOWN_MS'
	),
	pin(
		'tooltip',
		'infinite_ttl_ms',
		'windows/modules/keymap/llm_bridge.ahk',
		'_LLM_INFINITE_TOOLTIP_SEC',
		'sec'
	),
	pin(
		'tooltip',
		'hotstring_min_ttl_ms',
		'windows/modules/keymap/llm_bridge.ahk',
		'_LLM_MIN_TOOLTIP_DURATION_SEC',
		'sec'
	),
	pin(
		'gestures',
		'gesture_auto_configure_delay_ms',
		'windows/modules/gestures/init.ahk',
		'GESTURE_AUTO_CONFIGURE_BOOT_DELAY_MS'
	)
];

/**
 * Compares every pin with the registry.
 * @param {Object} registry Parsed timing registry ([section][key] = number).
 * @param {(rel: string) => string} readSource Returns a driver file's text.
 * @param {Object[]} pins The pin table.
 * @returns {string[]} One message per broken pin.
 */
function pinErrors(registry, readSource, pins) {
	const errors = [];
	for (const p of pins) {
		const expected = registry[p.section] && registry[p.section][p.key];
		if (typeof expected !== 'number') {
			errors.push(
				`[${p.section}].${p.key} is not in ${REGISTRY_PATH}, but ${p.file} ${p.name} ` +
					'is pinned to it. Fix the pin, or restore the key.'
			);
			continue;
		}
		const src = readSource(p.file);
		const decl = new RegExp(
			'^[ \\t]*(?:static|global)[ \\t]+' + p.name + '[ \\t]*:=[ \\t]*(\\d+(?:\\.\\d+)?)\\b',
			'gm'
		);
		const found = [...src.matchAll(decl)];
		if (found.length !== 1) {
			errors.push(
				`${p.file}: expected exactly one literal declaration of ${p.name}, found ` +
					`${found.length}. A renamed or moved constant leaves its pin guarding nothing.`
			);
			continue;
		}
		const raw = Number(found[0][1]);
		const asMs = p.unit === 'sec' ? raw * MS_PER_SEC : raw;
		if (Math.abs(asMs - expected) > 1e-9) {
			const line = src.slice(0, found[0].index).split('\n').length;
			errors.push(
				`${p.file}:${line}: ${p.name} = ${raw}${p.unit === 'sec' ? ' s' : ' ms'} but ` +
					`[${p.section}].${p.key} = ${expected} ms. Fix: make them equal — the AHK ` +
					'literal is what Windows ships, the registry is what every other reader and ' +
					'every maintainer trusts.'
			);
		}
	}
	return errors;
}

/** Runs the gate on the real tree, then proves it can fail. */
function main() {
	const registry = toml.parse(fs.readFileSync(path.join(SP, REGISTRY_PATH), 'utf8'));
	const readSource = (rel) => fs.readFileSync(path.join(SP, rel), 'utf8');
	const errors = pinErrors(registry, readSource, PINS);

	const first = PINS[0];
	const drifted = structuredClone(registry);
	drifted[first.section][first.key] += 1;
	const secPin = PINS.find((p) => p.unit === 'sec');
	const mutations = [
		['registry value drifted from its pin', drifted, readSource, first],
		['pinned constant removed from its file', registry, () => 'class Empty {\n}\n', first],
		[
			'pinned constant declared twice',
			registry,
			(rel) =>
				readSource(rel) +
				`\nclass Copy {\n    static ${first.name} := ${registry[first.section][first.key]}\n}\n`,
			first
		],
		[
			'a seconds copy holding milliseconds',
			registry,
			(rel) =>
				readSource(rel).replace(
					new RegExp('(' + secPin.name + '[ \\t]*:=[ \\t]*)\\d+(?:\\.\\d+)?'),
					(all, head) => head + String(registry[secPin.section][secPin.key])
				),
			secPin
		]
	];
	for (const [name, reg, reader, target] of mutations) {
		if (pinErrors(reg, reader, [target]).length === 0)
			errors.push(`negative mutation was not rejected: ${name}`);
	}

	if (errors.length > 0) {
		console.error('\x1b[31m[ERROR] Pinned timing copies are not single-sourced:\x1b[0m');
		for (const e of errors) console.error('    ' + e);
		process.exit(1);
	}

	console.log(
		`\x1b[32m[OK] ${PINS.length} pinned AHK timing copies match the shared timing registry.\x1b[0m`
	);
}

if (require.main === module) main();

module.exports = { PINS, pinErrors };
