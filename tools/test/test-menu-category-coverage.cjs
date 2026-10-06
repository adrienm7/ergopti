// tools/test/test-menu-category-coverage.cjs

/**
 * ==============================================================================
 * MODULE: Every Declared Menu, Answered By Every Driver That Shows It
 * DESCRIPTION:
 * The per-category answer to "is the menu centralised": for each `*_menu` key in
 * the shared manifest, how many rows each platform projects, and whether the
 * driver names every id it is expected to dispatch.
 *
 * WHAT IT PROVES, category by category — shortcuts, hotstrings, tap-holds,
 * metrics, gestures, layout, IA, debug, updates, apps, Karabiner and the
 * tray root — is that the manifest describes the menu and each driver answers
 * only ids the manifest names. A row a driver draws from nothing would not be
 * declared; a row declared and unanswered renders one item short, permanently.
 *
 * ONE MECHANISM IS NOT A FAILURE, and it is why this file exists rather than a
 * simple "every id appears in every driver": `platforms` restricts a row to the
 * drivers that have the capability, which is what makes "one menu with
 * driver-specific items" expressible at all. A restricted row carries a
 * `reason_key`; test-menu-parity.cjs holds that.
 *
 * A `toggle` is NOT exempt. This gate used to treat it as opt-in per driver, on
 * the premise that an hs.menubar parent can be clicked and so carries the switch
 * itself. It cannot — AppKit never sends the action of an item that opens a
 * submenu — and that premise left Gestures, Shortcuts, Metrics and the Hotstrings
 * master impossible to switch on from the macOS menu bar. A switch shown on a
 * driver is answered like any other row; test-menu-toggle-registered.cjs checks
 * the registration itself.
 *
 * The table is printed on success too: "which categories does each driver draw,
 * and how many rows" is the question this was written to answer, and an
 * unreadable answer is one nobody checks.
 * ==============================================================================
 */

'use strict';
const fs = require('fs');
const path = require('path');
const assert = require('node:assert/strict');
const {
	delegatedMenuSources,
	publishesMenuTemplate
} = require('../lib/menu-shared-delegation.cjs');

const { validateChildTemplates } = require('../lib/menu-row-availability.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const manifest = JSON.parse(
	fs.readFileSync(path.join(SP, '_shared', 'modules', 'menu', 'menu_manifest.json'), 'utf8')
);

const EXT = { ahk: '.ahk', hs: '.lua', linux: '.lua' };
const DIR = { ahk: 'windows', hs: 'macos', linux: 'linux' };

function driverSource(driver) {
	const out = [],
		nativeSources = [];
	(function walk(d) {
		if (!fs.existsSync(d)) return;
		for (const e of fs.readdirSync(d, { withFileTypes: true })) {
			const p = path.join(d, e.name);
			if (e.isDirectory()) {
				if (!['tests', 'vendor', 'node_modules', '_generated'].includes(e.name)) walk(p);
			} else if (p.endsWith(EXT[driver])) {
				const src = fs.readFileSync(p, 'utf8');
				out.push(src);
				nativeSources.push({ rel: p, src });
			}
		}
	})(path.join(SP, DIR[driver]));
	return {
		nativeSources,
		text: out
			.concat(
				delegatedMenuSources(nativeSources, path.join(SP, '_shared', 'lua')).map(
					(source) => source.src
				)
			)
			.join('\n')
	};
}

const src = Object.fromEntries(['ahk', 'hs', 'linux'].map((d) => [d, driverSource(d)]));
const PLATFORMS = ['ahk', 'hs', 'linux'];
const visible = (row, p) => !Array.isArray(row.platforms) || row.platforms.includes(p);

/** Inert provider identities need a reached template, rather than a handler. */
function inertTemplateRow(row) {
	return (
		['label', 'section_header'].includes(row.type) &&
		typeof row.id === 'string' &&
		row.id !== '' &&
		typeof row.i18n === 'string' &&
		row.i18n !== '' &&
		Object.keys(row).every((key) =>
			['type', 'id', 'i18n', 'platforms', 'unavailable'].includes(key)
		)
	);
}

/** Follows canonical includes only from executable native template roots.
 * Lists and groups supply native children, not implicit section-name edges.
 * Validate each reached declaration before it can excuse an inert identity.
 */
function reachedInertTemplateRows(nativeSources, extension, definitions, platform) {
	const reached = new Set();
	if (EXT[platform] !== extension) return reached;
	for (const [root, declaration] of Object.entries(definitions)) {
		if (
			!Array.isArray(declaration) ||
			!nativeSources.some(
				(native) => native.src.includes(root) && publishesMenuTemplate(native.src, extension, root)
			)
		)
			continue;
		const graph = Object.create(null);
		const collecting = new Set();
		function declarations(key) {
			if (collecting.has(key)) throw new Error('cyclic child-template include');
			if (Object.hasOwn(graph, key)) return;
			const rows = definitions[key];
			if (!Array.isArray(rows) || rows.length === 0) throw new Error('missing child template');
			collecting.add(key);
			graph[key] = rows;
			for (const row of rows) {
				if (!row || typeof row !== 'object' || Array.isArray(row)) throw new Error('invalid row');
				if (
					row.platforms !== undefined &&
					(!Array.isArray(row.platforms) ||
						row.platforms.length === 0 ||
						new Set(row.platforms).size !== row.platforms.length ||
						!row.platforms.every((value) => PLATFORMS.includes(value)))
				)
					throw new Error('invalid platform projection');
				if (row.type === 'include') declarations(row.section);
			}
			collecting.delete(key);
		}
		try {
			declarations(root);
			validateChildTemplates(graph);
		} catch {
			// A malformed reached route cannot supply publication evidence.
			continue;
		}
		function visit(key, rowId) {
			for (const row of graph[key]) {
				if ((rowId !== undefined && row.id !== rowId) || !visible(row, platform)) continue;
				if (row.type === 'include') visit(row.section, row.row_id);
				else if (inertTemplateRow(row)) reached.add(row);
			}
		}
		visit(root);
	}
	return reached;
}

// Independently authored controls keep commands and behavior-bearing labels in
// the handler census, and refuse decorative source as evidence of publication.
{
	const row = { type: 'label', id: 'fixture_label', i18n: 'fixture.caption' };
	assert.equal(inertTemplateRow(row), true);
	assert.equal(inertTemplateRow({ ...row, type: 'section_header' }), true);
	for (const change of [
		{ type: 'command' },
		{ command: 'run' },
		{ callback: 'run' },
		{ caption_getter: 'caption' },
		{ id: '' },
		{ i18n: '' }
	]) {
		assert.equal(inertTemplateRow({ ...row, ...change }), false);
	}
	for (const [extension, call, prefix] of [
		['.lua', 'ManifestMenu.template_rows("fixture")', '-- '],
		['.ahk', 'MenuRenderer_TemplateRows("fixture")', '; ']
	]) {
		assert.equal(publishesMenuTemplate(call, extension, 'fixture'), true);
		for (const source of [
			prefix + call,
			JSON.stringify(call),
			'function ' + call,
			call.replace('fixture', 'other'),
			call.replace('("fixture")', '("fixture" .. "tail")'),
			'Foreign.' + call
		]) {
			assert.equal(publishesMenuTemplate(source, extension, 'fixture'), false);
		}
	}
}

// Transitive publication is declaration-specific and rooted in native code.
// A list/group identity does not mean that a similarly named section is reached.
{
	const label = { type: 'label', id: 'nested_heading', i18n: 'fixture.caption' };
	const paused = {
		type: 'label',
		id: 'paused_heading',
		i18n: 'fixture.paused',
		platforms: ['hs'],
		unavailable: 'hide'
	};
	const command = { type: 'command', id: 'clicked_control', i18n: 'fixture.run' };
	const definitions = {
		frame: [
			{ type: 'include', section: 'bridge' },
			{ type: 'list', id: 'native_list' },
			{ type: 'group', id: 'native_group', i18n: 'fixture.group' }
		],
		bridge: [{ type: 'include', section: 'leaf', present_when: 'heading_present' }],
		leaf: [label, paused, command],
		native_list: [{ ...label, id: 'unreached_list_heading' }],
		native_group: [{ ...label, id: 'unreached_group_heading' }],
		orphan: [{ ...label, id: 'orphan_heading' }]
	};
	for (const [extension, call, comment] of [
		['.lua', 'ManifestMenu.template_rows("frame", {}, {}, {})', '-- '],
		['.ahk', 'MenuRenderer_TemplateRows("frame", Map(), Map(), Map())', '; ']
	]) {
		const platform = extension === '.ahk' ? 'ahk' : 'hs';
		const nativeDefinitions = {
			...definitions,
			leaf: [label, { ...paused, platforms: [platform] }, command]
		};
		const nativePaused = nativeDefinitions.leaf[1];
		const natives = [{ rel: 'actual-native-owner' + extension, src: call }];
		const reached = reachedInertTemplateRows(natives, extension, nativeDefinitions, platform);
		assert.equal(reached.has(label), true);
		assert.equal(reached.has(nativePaused), true);
		assert.equal(reached.has(command), false);
		assert.equal(reached.size, 2);
		for (const other of PLATFORMS.filter((value) => value !== platform)) {
			assert.equal(
				reachedInertTemplateRows(natives, extension, nativeDefinitions, other).has(nativePaused),
				false
			);
		}
		assert.equal(
			reachedInertTemplateRows(natives, '.foreign', nativeDefinitions, platform).size,
			0
		);

		for (const source of [
			comment + call,
			JSON.stringify(call),
			'function ' + call,
			'Foreign.' + call,
			call.replace('frame', 'foreign'),
			call.replace('"frame"', '"frame" .. suffix')
		]) {
			assert.equal(
				reachedInertTemplateRows(
					[{ rel: 'native' + extension, src: source }],
					extension,
					nativeDefinitions,
					platform
				).size,
				0
			);
		}
		// Text outside the caller-owned native inventory is not a publication root.
		assert.equal(reachedInertTemplateRows([], extension, nativeDefinitions, platform).size, 0);
		for (const change of [
			{ leaf: undefined },
			{ leaf: [] },
			{ bridge: [{ type: 'include', section: 'frame' }] },
			{ bridge: [{ type: 'include', section: 'missing' }] },
			{ bridge: [{ type: 'include', section: 'leaf', command: 'run' }] },
			{ bridge: [{ type: 'include', section: 'leaf', present_when: true }] },
			{ bridge: [{ type: 'include', section: 'leaf', row_id: 'missing' }] },
			{ leaf: [{ ...label, command: 'run' }] },
			{ leaf: [{ ...label, callback: 'run' }] },
			{ leaf: [{ ...label, disabled: 'true' }] },
			{ leaf: [{ ...label, disabled: true }] },
			{ leaf: [{ ...label, platforms: ['foreign'] }] },
			{ leaf: [{ ...label, platforms: ['hs', 'hs'] }] }
		]) {
			assert.equal(
				reachedInertTemplateRows(natives, extension, { ...nativeDefinitions, ...change }, platform)
					.size,
				0
			);
		}
		// Exact selection never credits the unselected identity or a clicked row.
		const selected = {
			...nativeDefinitions,
			bridge: [{ type: 'include', section: 'leaf', row_id: label.id }]
		};
		const selectedRows = reachedInertTemplateRows(natives, extension, selected, platform);
		assert.equal(selectedRows.has(label), true);
		assert.equal(selectedRows.has(nativePaused), false);
		assert.equal(selectedRows.size, 1);
		assert.equal(
			reachedInertTemplateRows(
				natives,
				extension,
				{ ...selected, leaf: [label, { ...label }] },
				platform
			).size,
			0
		);
		assert.equal(
			reachedInertTemplateRows(
				natives,
				extension,
				{ ...selected, bridge: [{ type: 'include', section: 'leaf', row_id: command.id }] },
				platform
			).size,
			0
		);
		assert.equal(
			reachedInertTemplateRows(
				natives,
				extension,
				{
					...definitions,
					bridge: [{ type: 'include', section: 'leaf', on_refusal: 'omit_presentation' }]
				},
				platform
			).size,
			0
		);
	}
}

const reachedInert = Object.fromEntries(
	PLATFORMS.map((platform) => [
		platform,
		reachedInertTemplateRows(src[platform].nativeSources, EXT[platform], manifest, platform)
	])
);

const rows = [];
for (const [key, list] of Object.entries(manifest)) {
	if (!Array.isArray(list)) continue;
	const cell = {};
	for (const p of PLATFORMS) {
		const shown = list.filter((r) => visible(r, p));
		// Rows that need the driver to name something: an id it dispatches on.
		const needing = shown.filter((r) => typeof r.id === 'string' && r.id !== '---');
		const missing = needing.filter((r) => !src[p].text.includes(r.id) && !reachedInert[p].has(r));
		cell[p] = { shown: shown.length, missing: missing.map((r) => r.id) };
	}
	rows.push({ key, cell });
}

const pad = (s, n) => String(s).padEnd(n);
console.log(pad('menu', 30) + pad('windows', 12) + pad('macos', 12) + 'linux');
console.log('-'.repeat(66));
let unanswered = 0;
for (const { key, cell } of rows.sort((a, b) => a.key.localeCompare(b.key))) {
	const fmt = (c) =>
		c.shown === 0 ? '—' : c.missing.length ? `${c.shown} (${c.missing.length}!)` : `${c.shown}`;
	console.log(pad(key, 30) + pad(fmt(cell.ahk), 12) + pad(fmt(cell.hs), 12) + fmt(cell.linux));
	for (const p of PLATFORMS) unanswered += cell[p].missing.length;
}
console.log('-'.repeat(66));
console.log(
	`${rows.length} menus declared; ${unanswered} declared id(s) not named by the driver that shows them`
);
if (unanswered > 0) {
	console.error('[31m[FAIL] a declared menu row is not answered by a driver that shows it:[0m');
	for (const { key, cell } of rows) {
		for (const p of PLATFORMS) {
			if (cell[p].missing.length) {
				console.error(
					`    - ${p} ${key}: ${cell[p].missing.join(', ')} — declared for this platform and named ` +
						'nowhere in its source. The renderer logs one warning and skips the row, so the menu is ' +
						'one item short, permanently.'
				);
			}
		}
	}
	process.exit(1);
}
console.log(
	`[32m[OK] ${rows.length} menus declared in _shared; every id shown on a driver is answered by it.[0m`
);
