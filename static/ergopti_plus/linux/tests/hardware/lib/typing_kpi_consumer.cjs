// tests/hardware/lib/typing_kpi_consumer.cjs

/** Execute the real typing state and data owners with a bounded DOM adapter. */
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

/**
 * Creates an isolated dashboard consumer without replacing its selection logic.
 * @param {string} root Repository root.
 * @param {object} manifest Native or explicitly modeled manifest.
 * @returns {object} Rendering and snapshot capabilities for this owned context.
 */
function createTypingConsumer(root, manifest) {
	// Read the canonical policy enum without importing macOS fallback key names
	// into this explicitly modeled Linux host/DOM adapter.
	const state = vm.createContext({ window: {}, KEYCODE_DATA: [] });
	vm.runInContext(
		fs.readFileSync(
			path.join(root, 'static/ergopti_plus/_shared/ui/metrics_typing/state.js'),
			'utf8'
		),
		state,
		{ filename: 'state.js' }
	);
	const elements = new Map();
	const element = (id) => {
		if (!elements.has(id)) elements.set(id, { value: '', style: {}, innerHTML: '' });
		return elements.get(id);
	};
	element('date_start').value = '2026-10-03';
	element('date_end').value = '2026-10-03';
	const context = vm.createContext({
		window: { metrics_manifest: manifest },
		APP_SELECTION_MODE: vm.runInContext('APP_SELECTION_MODE', state),
		INFO_SVG: vm.runInContext('INFO_SVG', state),
		app_state: {
			manifest_dates_sorted: ['2026-10-03'],
			selected_apps: new Set(),
			today_live_data: null
		},
		document: { getElementById: element },
		get_local_date_string: () => new Date().toISOString().slice(0, 10),
		format_number: String,
		escape_html: String,
		render_apps_table: () => {},
		_t: (key) => key,
		KEYCODE_NAMES: { 29: 'Left Ctrl' }
	});
	// The complete data owner brings its real helper closure, never policy stubs.
	vm.runInContext(
		fs.readFileSync(
			path.join(root, 'static/ergopti_plus/_shared/ui/metrics_typing/data.js'),
			'utf8'
		),
		context,
		{ filename: 'data.js' }
	);
	return {
		renderEditor() {
			vm.runInContext(
				"app_state.selected_apps = new Set(['editor']); app_state.app_selection_mode = APP_SELECTION_MODE.SUBSET; render_apps_kpi();",
				context
			);
		},
		renderNone() {
			vm.runInContext(
				'app_state.selected_apps = new Set(); app_state.app_selection_mode = APP_SELECTION_MODE.NONE; render_apps_kpi();',
				context
			);
		},
		element
	};
}

module.exports = { createTypingConsumer };
