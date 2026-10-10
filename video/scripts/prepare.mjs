// video/scripts/prepare.mjs
//
// Prepares everything the Remotion compositions read, from the repository's
// own sources and never from copies:
//   1. video/public/: hard-link mirrors of the static/ folders the driver
//      windows need, so the windows render from the files the drivers ship.
//   2. src/_generated/driver-data.json: the figures the sales page measures
//      (imported from its build-time loader) and the outputs of every
//      hotstring trigger the scenes demonstrate, looked up in the driver's
//      hotstring files. A trigger that no longer exists fails the run.
//
// Run by every npm script that starts the studio or renders.

import {
	existsSync,
	linkSync,
	lstatSync,
	mkdirSync,
	readFileSync,
	readdirSync,
	rmSync,
	unlinkSync,
	writeFileSync
} from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { parse as parseToml } from 'smol-toml';

const VIDEO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const REPO_ROOT = resolve(VIDEO_ROOT, '..');
const STATIC_ROOT = join(REPO_ROOT, 'static');
const HOTSTRINGS_ROOT = join(STATIC_ROOT, 'ergopti_plus/_shared/modules/hotstrings');
const ERGOPTI_EXTENSION_ROOT = join(STATIC_ROOT, 'layouts/registry/ergopti');
const DEMO_SCRIPT_PATH = join(VIDEO_ROOT, 'src/data/demo-script.json');
const OUTPUT_PATH = join(VIDEO_ROOT, 'src/_generated/driver-data.json');
const PUBLIC_ROOT = join(VIDEO_ROOT, 'public');

/** Published path under public/ → mirrored folder. */
const PUBLIC_MIRRORS = {
	'ergopti_plus/_shared': join(STATIC_ROOT, 'ergopti_plus/_shared'),
	demo: join(STATIC_ROOT, 'demo'),
	img: join(STATIC_ROOT, 'img'),
	// Unedited recordings of the installed driver (scripts/record-screen.ps1).
	real: join(VIDEO_ROOT, 'assets/real')
};

// =====================================
// =====================================
// ======= 1/ Public folder mirror =====
// =====================================
// =====================================

/**
 * Rebuild one folder of public/ as a tree of hard links to its source.
 * Hard links cost no disk space, need no privilege on any system, and survive
 * Remotion's bundler, which copies public/ but cannot recreate Windows
 * symlinks. The tree is rebuilt on every run, so an editor that replaces a
 * file (and so breaks its hard link) is picked up at the next run.
 * @param {string} published - Path under public/.
 * @param {string} source - Folder it mirrors.
 */
function mirror(published, source) {
	if (!existsSync(source)) throw new Error(`Missing source folder ${source}`);
	const dest = join(PUBLIC_ROOT, published);
	if (!dest.startsWith(PUBLIC_ROOT)) throw new Error(`Refusing to write outside public/: ${dest}`);
	if (existsSync(dest) || isLink(dest)) {
		// Earlier runs created junctions; remove the link, never its target.
		if (isLink(dest)) unlinkSync(dest);
		else rmSync(dest, { recursive: true });
	}
	const walk = (from, to) => {
		mkdirSync(to, { recursive: true });
		for (const entry of readdirSync(from, { withFileTypes: true })) {
			const src = join(from, entry.name);
			const dst = join(to, entry.name);
			if (entry.isDirectory()) walk(src, dst);
			else if (entry.isFile()) linkSync(src, dst);
		}
	};
	walk(source, dest);
}

/**
 * @param {string} path
 * @returns {boolean}
 */
function isLink(path) {
	try {
		return lstatSync(path).isSymbolicLink();
	} catch {
		return false;
	}
}

// ========================================
// ========================================
// ======= 2/ Facts from the site =========
// ========================================
// ========================================

/**
 * Run the sales page's build-time loader, which reads the driver files
 * relative to the working directory.
 * @returns {Promise<object>}
 */
async function loadSiteFacts() {
	const loader = join(REPO_ROOT, 'src/routes/ergopti-plus/+page.server.js');
	const previous = process.cwd();
	process.chdir(REPO_ROOT);
	try {
		const { load } = await import(pathToFileURL(loader).href);
		return load();
	} finally {
		process.chdir(previous);
	}
}

// =================================================
// =================================================
// ======= 3/ Hotstring outputs from the driver ====
// =================================================
// =================================================

/**
 * Read a TOML file, dropping the BOM some shared files carry.
 * @param {string} path
 * @returns {any}
 */
function readToml(path) {
	return parseToml(readFileSync(path, 'utf-8').replace(/^﻿+/, ''));
}

/**
 * Add every trigger of one hotstring file to the index under a category.
 * @param {Map<string, {output: string, category: string}>} index
 * @param {any} doc
 * @param {string} category
 */
function indexEntries(index, doc, category) {
	for (const [section, tables] of Object.entries(doc)) {
		if (section === '_meta' || !Array.isArray(tables)) continue;
		for (const table of tables) {
			for (const [trigger, entry] of Object.entries(table)) {
				if (entry && typeof entry === 'object' && 'output' in entry && !index.has(trigger)) {
					index.set(trigger, { output: entry.output, category });
				}
			}
		}
	}
}

/**
 * Index the shipped hotstrings the way the sales page groups them: root
 * categories, language packs counted with their root category, and the
 * Ergopti extension files bound to their category by its manifest.
 * @returns {Map<string, {output: string, category: string}>}
 */
function loadHotstringIndex() {
	const index = new Map();
	const menu = readToml(join(HOTSTRINGS_ROOT, '_index.toml'));
	for (const id of menu.menu?.categories_order ?? []) {
		indexEntries(index, readToml(join(HOTSTRINGS_ROOT, `${id}.toml`)), id);
	}
	for (const lang of menu.languages?.order ?? []) {
		for (const id of menu.languages[lang]?.categories_order ?? []) {
			indexEntries(index, readToml(join(HOTSTRINGS_ROOT, lang, `${id}.toml`)), id);
		}
	}
	const bindings =
		readToml(join(ERGOPTI_EXTENSION_ROOT, 'manifest.toml')).extension?.hotstring_bindings ?? {};
	for (const file of readdirSync(join(ERGOPTI_EXTENSION_ROOT, 'hotstrings'))) {
		const stem = file.replace(/\.toml$/, '');
		const binding = bindings[stem];
		if (!binding || file === stem) continue;
		indexEntries(
			index,
			readToml(join(ERGOPTI_EXTENSION_ROOT, 'hotstrings', file)),
			binding.category
		);
	}
	return index;
}

// ==========================
// ==========================
// ======= 4/ Main ==========
// ==========================
// ==========================

for (const [published, source] of Object.entries(PUBLIC_MIRRORS)) mirror(published, source);

const site = await loadSiteFacts();
const colors = Object.fromEntries(site.hotstringCategories.map((c) => [c.id, c.color]));
const index = loadHotstringIndex();
const script = JSON.parse(readFileSync(DEMO_SCRIPT_PATH, 'utf-8'));

const missing = script.hotstrings.filter((trigger) => !index.has(trigger));
if (missing.length > 0) {
	throw new Error(
		`Demo triggers absent from the driver hotstrings: ${missing.join(', ')}. ` +
			'Update src/data/demo-script.json.'
	);
}
const hotstrings = Object.fromEntries(
	script.hotstrings.map((trigger) => {
		const { output, category } = index.get(trigger);
		if (!colors[category]) throw new Error(`No tooltip colour for category ${category}`);
		return [trigger, { output, category, color: colors[category] }];
	})
);

// Counted per driver exactly like the sales page's OS toggle does.
const { isActionOnPlatform } = await import(
	pathToFileURL(join(REPO_ROOT, 'src/routes/ergopti-plus/action-platforms.js')).href
);
// Ids starting with "_" are catalogue placeholders, not actions a user picks.
const allActions = site.actionGroups
	.flatMap((g) => g.sections.flatMap((s) => s.actions))
	.filter((a) => !a.id.startsWith('_'));
const actionsOn = (tag) => allActions.filter((a) => isActionOnPlatform(a.platform, tag)).length;

// English labels, through the same locale keys the driver menus use.
const SHARED_ROOT = join(STATIC_ROOT, 'ergopti_plus/_shared');
const en = JSON.parse(readFileSync(join(SHARED_ROOT, 'data/locales/en.json'), 'utf-8'));
/**
 * @param {string} key
 * @returns {string}
 */
const t = (key) => {
	if (!(key in en)) throw new Error(`Locale key ${key} missing from en.json`);
	return en[key];
};

/** Drops the picker's "[configurable]" note from a label. */
const bareLabelOf = (label) => label.replace(/\s*\[[^\]]+\]$/, '');

const tapHoldDefaults = readToml(join(SHARED_ROOT, 'tap_hold/defaults.toml')).tap_hold;
const tapHolds = Object.entries(tapHoldDefaults.keys).map(([id, key]) => ({
	id,
	key: t(`tap_hold.group.${id}`),
	tap: t(`sg_actions.${key.tap_action}`),
	hold: key.hold_layer
		? t(`tap_hold.hold.${key.hold_layer}_layer`)
		: t(`tap_hold.hold.${key.hold_modifier}`)
}));

const windowsActions = allActions
	.filter((a) => !a.axis && isActionOnPlatform(a.platform, 'ahk'))
	.map((a) => ({ id: a.id, label: t(`sg_actions.${a.id}`) }));

const gestureSlots = Object.values(
	JSON.parse(readFileSync(join(SHARED_ROOT, 'modules/menu/menu_manifest.json'), 'utf-8'))
		.gesture_slots
).reduce((sum, slots) => sum + slots.length, 0);

// ======= Tap-hold keys every system has, and option labels =======
const tapHoldCatalog = tapHoldDefaults.catalog.keys
	.filter((key) => key.ahk && key.hs && key.linux)
	.map((key) => ({ id: key.id, name: t(key.label_key) }));
// Example options shown as choices, never as what the driver imposes.
const tapHoldOptions = {
	taps: ['enter', 'escape', 'backspace', 'tab', 'copy', 'paste'].map((id) =>
		bareLabelOf(t(`sg_actions.${id}`))
	),
	holds: ['shift', 'nav_layer', 'none'].map((id) => t(`tap_hold.hold.${id}`))
};

// ======= Tray menu, exactly as the manifest lays it out =======
// Top-level titles are hard-coded by each driver's builder; these are the
// keys they use (windows/ui/menu/menu_init.ahk).
const MENU_TITLES = {
	tap_holds: 'menu.tapholds.title',
	shortcuts: 'menu.shortcuts.title',
	gestures: 'menu.gestures.title',
	keyboard_layout: 'menu.layout.title',
	hotstrings: 'menu.hotstrings.title',
	metrics: 'menu.metrics.title',
	llm: 'menu.llm.title',
	agent: 'menu.agent.title',
	about: 'menu.about.title',
	configuration: 'menu.configuration.title',
	language: 'menu.global.language',
	suspend: 'menu.global.suspend',
	debug: 'menu.debug.title'
};
const MENU_SUBMENUS = {
	tap_holds: 'tap_holds_menu',
	shortcuts: 'shortcuts_menu',
	gestures: 'gestures_menu',
	keyboard_layout: 'layout_menu',
	hotstrings: 'hotstrings_menu',
	metrics: 'metrics_menu',
	llm: 'llm_menu',
	agent: 'agent_menu',
	about: 'about_menu',
	configuration: 'configuration_menu',
	language: 'language_menu',
	debug: 'debug_menu'
};
const menuManifest = JSON.parse(
	readFileSync(join(SHARED_ROOT, 'modules/menu/menu_manifest.json'), 'utf-8')
);
const featureTree = readToml(join(SHARED_ROOT, 'modules/features/manifest.toml')).features;
/**
 * The description key of a feature row, found by its manifest path.
 * @param {string} path - e.g. "shortcuts.wrap_text_if_selected".
 * @returns {string}
 */
function featureDescriptionKey(path) {
	const id = path.split('.').pop();
	const found = [];
	const walk = (node) => {
		if (Array.isArray(node)) node.forEach(walk);
		else if (node && typeof node === 'object') {
			if (node.id === id && node.description_key) found.push(node.description_key);
			Object.values(node).forEach(walk);
		}
	};
	walk(featureTree[path.split('.')[0]]);
	if (found.length === 0) throw new Error(`No feature description for menu path ${path}`);
	return found[0];
}
const onWindows = (row) => !row.platforms || row.platforms.includes('ahk');
// Menu labels follow the webviews' fallback cascade (English, then French) so
// one missing key does not stop the film; every gap is reported.
const fr = JSON.parse(readFileSync(join(SHARED_ROOT, 'data/locales/fr.json'), 'utf-8'));
const missingMenuKeys = new Set();
const driverBuiltLabels = new Set();
const menuLabel = (key) => {
	if (key in en) return en[key];
	if (!(key in fr)) throw new Error(`Menu label ${key} is in neither en.json nor fr.json`);
	missingMenuKeys.add(key);
	return fr[key];
};
/**
 * Every row of a manifest section as Windows shows it, includes expanded.
 * Rows the driver fills at run time keep their place as a placeholder.
 * @param {string} key
 * @returns {Array<{type: string, label: string | null}>}
 */
function menuRows(key) {
	const section = menuManifest[key];
	if (!Array.isArray(section)) throw new Error(`The menu manifest has no section ${key}`);
	return section.filter(onWindows).flatMap((row) => {
		if (row.type === '---') return [{ type: '---', label: null }];
		if (row.type === 'include') return menuRows(row.section);
		if (row.i18n) return [{ type: row.type, label: menuLabel(row.i18n) }];
		if (row.type === 'feature') {
			// Some features (the layout rows) get their label from driver code,
			// not from a locale key: they stay placeholders.
			const key = featureDescriptionKey(row.path);
			if (!(key in en) && !(key in fr)) {
				driverBuiltLabels.add(key);
				return [{ type: 'runtime', label: null }];
			}
			return [{ type: 'feature', label: menuLabel(key) }];
		}
		return [{ type: 'runtime', label: null }];
	});
}
const menu = menuManifest.top_level.filter(onWindows).map((row) => {
	if (row.id === '---') return { id: '---' };
	const titleKey = row.i18n ?? MENU_TITLES[row.id];
	if (!titleKey) throw new Error(`No title for top-level menu row ${row.id}`);
	const submenu = MENU_SUBMENUS[row.id];
	return { id: row.id, label: menuLabel(titleKey), children: submenu ? menuRows(submenu) : [] };
});
if (driverBuiltLabels.size > 0) {
	console.warn(`prepare: menu rows labelled by driver code: ${driverBuiltLabels.size}`);
}
if (missingMenuKeys.size > 0) {
	console.warn(
		`prepare: menu keys missing from en.json (shown in French): ${[...missingMenuKeys].join(', ')}`
	);
}

// ======= Wrap-selection symbols (shared catalogue) =======
const wrapCatalogue = JSON.parse(
	readFileSync(join(SHARED_ROOT, 'modules/wrap_symbols/wrap_symbols.json'), 'utf-8')
);
const wrapSymbols = {
	label: t('shortcuts.label_wrap_text'),
	groups: wrapCatalogue.groups.map((g) => ({ label: t(g.i18n), pairs: g.pairs }))
};
// ======= Best-of abbreviations (the site's showcase list) =======
// Outputs come from the driver files; an entry the driver no longer ships is
// left out and reported, since the list belongs to the site.
const bestOfTriggers = Object.keys(
	parseToml(readFileSync(join(REPO_ROOT, 'src/routes/utilisation/magic_sample.toml'), 'utf-8'))
);
const bestOfMissing = bestOfTriggers.filter((trigger) => !index.has(trigger));
if (bestOfMissing.length > 0) {
	console.warn(`prepare: best-of triggers absent from the driver: ${bestOfMissing.join(', ')}`);
}
const bestOf = bestOfTriggers
	.filter((trigger) => index.has(trigger))
	.map((trigger) => {
		const { output, category } = index.get(trigger);
		const keys = [...trigger].length;
		return { trigger, output, color: colors[category], ratio: [...output].length / keys };
	})
	.sort((a, b) => b.ratio - a.ratio);

// ======= Navigation layer (recommended bindings) =======
const actionLabel = (id) => {
	if (id.startsWith('keystroke:')) return id.slice('keystroke:'.length);
	for (const key of [`sg_actions.${id}`, `layer_actions.${id}`]) if (key in en) return en[key];
	throw new Error(`No English label for navigation action ${id}`);
};
const navLayer = Object.entries(
	readToml(join(SHARED_ROOT, 'keymap/layers.recommended.toml')).layers.nav.all
).map(([code, action]) => ({ code, action, label: actionLabel(action) }));

// ======= Recommended Win+letter shortcuts and their macOS twins =======
// [[features.shortcuts]] is an array of tables; its keyboard/keys arrays hang
// off whichever element precedes them, so collect them across elements.
const shortcutTables = readToml(join(SHARED_ROOT, 'modules/features/manifest.toml')).features
	.shortcuts;
const shortcutRows = (field) => shortcutTables.flatMap((table) => table[field] ?? []);
const macKeys = new Set(shortcutRows('keys').map((k) => k.id));
const shortcuts = shortcutRows('keyboard')
	.filter((slot) => /^win_[a-z]$/.test(slot.id) && slot.recommended && slot.recommended !== 'none')
	.map((slot) => {
		const letter = slot.id.slice(-1);
		return {
			action: slot.recommended,
			label: t(`sg_actions.${slot.recommended}`),
			windows: `Win + ${letter.toUpperCase()}`,
			// The same letter can run another action on macOS: keep its own label.
			macos: macKeys.has(`ctrl_${letter}`)
				? { keys: `Ctrl + ${letter.toUpperCase()}`, label: t(`shortcuts.label_ctrl_${letter}`) }
				: null
		};
	});

const data = {
	facts: {
		hotstringTotal: site.hotstringTotal,
		hotstringCategories: site.hotstringCategories.map(({ id, count, color }) => ({
			id,
			count,
			color
		})),
		aiModels: site.aiTotalModels,
		aiModelProviders: site.aiTotalProviders,
		apiProviders: site.apiProviders.length,
		locales: site.localesCount,
		actions: { windows: actionsOn('ahk'), macos: actionsOn('hs') },
		gestureSlots,
		llm: site.llmDefaults
	},
	webviews: site.webviews,
	tapHolds,
	windowsActions,
	tapHoldCatalog,
	tapHoldOptions,
	menu,
	wrapSymbols,
	bestOf,
	navLayer,
	shortcuts,
	// The native tooltip's spec (colours, radius, padding, LLM line colours),
	// so the drawn tooltips match the driver's.
	tooltip: readToml(join(STATIC_ROOT, 'ergopti_plus/_shared/modules/tooltip/constants.toml')),
	hotstrings
};

mkdirSync(dirname(OUTPUT_PATH), { recursive: true });
writeFileSync(OUTPUT_PATH, `${JSON.stringify(data, null, '\t')}\n`);
console.log(
	`prepare: ${Object.keys(hotstrings).length} triggers resolved, ${data.facts.hotstringTotal} hotstrings, ` +
		`${data.facts.aiModels} models, ${data.facts.actions.windows}/${data.facts.actions.macos} actions (Windows/macOS), ${data.facts.locales} locales`
);
