// _shared/ui/hotstrings_config_window/script.js

/**
 * ==============================================================================
 * MODULE: Hotstrings Config Window UI Script
 * DESCRIPTION:
 * Renders the categories / sections tree from the data pushed by Lua, and
 * sends every user mutation back through the `hotstrings_config_bridge`
 * usercontent channel. The page never keeps a divergent local copy of the
 * truth — Lua pushes a fresh state after each action, and we re-render.
 *
 * A group selector (<select>) at the top of the page filters the category
 * list to the active group (Commun / Personnel / one per extension).
 * ==============================================================================
 */

let state = { categories: [], groups: [], presets: [], global_default_delay_ms: 750 };

// The currently selected group key — persisted across Lua-pushed state updates
// so the user's position is not lost after every mutation round-trip.
let activeGroup = null;

// The categories the user folded, by identity. Every mutation makes the host
// push a fresh state and the page draws again: the fold must outlive that.
const foldedCategories = new Set();

// One category's identity across state pushes.
function categoryKey(cat) {
	return [cat.group, cat.name, cat.ext_id || '', cat.personal_path || ''].join('\u0000');
}

// Show or hide a category's sections and turn its caret accordingly.
function applyFold(toggle, sectionsBox, folded) {
	sectionsBox.hidden = folded;
	toggle.classList.toggle('open', !folded);
	toggle.setAttribute('aria-expanded', folded ? 'false' : 'true');
}

// Resolve a translation key via the loaded locale strings (set by i18n.js).
function _t(key) {
	return (window._i18n_strings && window._i18n_strings[key]) || key;
}

// Apply data-i18n-key / data-i18n-title-key inside a freshly cloned template
// fragment (i18n.js cannot reach inside <template> nodes before cloning).
function applyTemplateI18n(node) {
	node.querySelectorAll('[data-i18n-key]').forEach(function (el) {
		el.textContent = _t(el.getAttribute('data-i18n-key'));
	});
	node.querySelectorAll('[data-i18n-title-key]').forEach(function (el) {
		el.title = _t(el.getAttribute('data-i18n-title-key'));
	});
}

// ============================================================
// 1/ Bridge primitives
// ============================================================

const send = makeHostBridge('hotstrings_config_bridge');

function setData(next) {
	if (!next || typeof next !== 'object') return;
	state = next;

	// Preserve the active group across state pushes; fall back to the first group.
	if (state.groups && state.groups.length > 0) {
		const keys = state.groups.map(function (g) {
			return g.key;
		});
		if (!activeGroup || keys.indexOf(activeGroup) === -1) {
			activeGroup = keys[0];
		}
	}

	renderGroupSelector();
	render();
}

function closeWindow() {
	send({ action: 'close' });
}

function resetAll() {
	send({ action: 'reset_all' });
}

function setAllGrey() {
	send({ action: 'set_all_grey' });
}

// ============================================================
// 2/ Group selector
// ============================================================

function renderGroupSelector() {
	const sel = document.getElementById('group-select');
	if (!sel) return;
	sel.innerHTML = '';
	(state.groups || []).forEach(function (g) {
		const o = document.createElement('option');
		o.value = g.key;
		o.textContent = g.label;
		if (g.key === activeGroup) o.selected = true;
		sel.appendChild(o);
	});
}

function onGroupChange() {
	const sel = document.getElementById('group-select');
	if (sel) activeGroup = sel.value;
	render();
}

// ============================================================
// 3/ Rendering
// ============================================================

function render() {
	const main = document.getElementById('content');
	main.innerHTML = '';

	const tplCat = document.getElementById('tpl-category').content;
	const tplSec = document.getElementById('tpl-section').content;

	// Filter categories to the active group only
	const visible = (state.categories || []).filter(function (cat) {
		return cat.group === activeGroup;
	});

	for (const cat of visible) {
		const node = document.importNode(tplCat, true);
		applyTemplateI18n(node);
		const card = node.querySelector('.cat');

		card.querySelector('.cat-title').textContent = cat.title;

		// The caret and the title both fold the category's sections.
		const toggle = card.querySelector('[data-role=toggle]');
		const title = card.querySelector('.cat-title');
		const sectionsBox = card.querySelector('.sections');
		const key = categoryKey(cat);
		const fold = () => {
			if (foldedCategories.has(key)) foldedCategories.delete(key);
			else foldedCategories.add(key);
			applyFold(toggle, sectionsBox, foldedCategories.has(key));
		};
		applyFold(toggle, sectionsBox, foldedCategories.has(key));
		toggle.addEventListener('click', fold);
		title.addEventListener('click', fold);

		// File-level (category) controls
		bindDelay(card.querySelector('.field-delay'), cat, null);
		bindColor(card.querySelector('.field-color'), cat, null);
		bindPriority(card.querySelector('.field-priority'), cat, null);
		bindTooltip(card.querySelector('.field-tooltip'), cat, null);
		applyMetadataAvailability(card, cat);

		// Sections
		for (const sec of cat.sections) {
			const secNode = document.importNode(tplSec, true);
			applyTemplateI18n(secNode);
			secNode.querySelector('.sec-title').textContent = sec.title || sec.name;
			bindDelay(secNode.querySelector('.field-delay'), cat, sec);
			bindColor(secNode.querySelector('.field-color'), cat, sec);
			bindPriority(secNode.querySelector('.field-priority'), cat, sec);
			bindTooltip(secNode.querySelector('.field-tooltip'), cat, sec);
			applyMetadataAvailability(secNode, sec);
			sectionsBox.appendChild(secNode);
		}
		if (cat.readonly === true) {
			for (const control of card.querySelectorAll('input, select, button')) control.disabled = true;
		}

		main.appendChild(node);
	}
}

// ============================================================
// 4/ Field bindings
// ============================================================

function applyMetadataAvailability(node, target) {
	const unavailable = target.readonly_metadata || {};
	for (const [key, selector] of [
		['delay', 'delay'],
		['color', 'color'],
		['priority', 'priority'],
		['show_tooltip', 'tooltip']
	]) {
		if (unavailable[key] !== true) continue;
		const field = node.querySelector('.field-' + selector);
		if (!field) continue;
		field.title = target.readonly_metadata_reason || '';
		for (const control of field.querySelectorAll('input, select, button')) control.disabled = true;
	}
}

function bindDelay(field, cat, sec) {
	const ms = sec ? sec.delay_ms : cat.delay_ms;
	const overridden = sec ? sec.delay_overridden : cat.delay_overridden;
	// When the TOML default is 0, fall back to the global default as the hint
	// so the user understands what value will actually be applied.
	const defaultMs =
		(sec ? sec.delay_default_ms : cat.delay_default_ms) || state.global_default_delay_ms || 750;
	const input = field.querySelector('input');
	const reset = field.querySelector('.reset');

	input.value = ms || defaultMs;
	input.placeholder = defaultMs;
	field.classList.toggle('overridden', !!overridden);

	input.addEventListener('change', () => {
		const v = parseInt(input.value, 10);
		if (Number.isFinite(v) && v >= 0) {
			send({
				action: 'set_delay',
				category: cat.name,
				group: cat.group,
				section: sec ? sec.name : '',
				personal_path: cat.personal_path || '',
				ext_id: cat.ext_id || '',
				ms: v
			});
		}
	});

	reset.addEventListener('click', () => {
		send({
			action: 'clear_delay',
			category: cat.name,
			group: cat.group,
			section: sec ? sec.name : '',
			personal_path: cat.personal_path || '',
			ext_id: cat.ext_id || ''
		});
	});
}

// Collision priority (0-100, higher wins a same-trigger collision). The input
// shows the effective value and the placeholder shows the source/TOML default,
// so an empty field means "inherit the default". Mirrors bindDelay.
function bindPriority(field, cat, sec) {
	if (!field) return;
	const value = sec ? sec.priority : cat.priority;
	const overridden = sec ? sec.priority_overridden : cat.priority_overridden;
	const def = sec ? sec.priority_default : cat.priority_default;
	const input = field.querySelector('input');
	const reset = field.querySelector('.reset');

	input.value = typeof value === 'number' ? value : '';
	if (typeof def === 'number') input.placeholder = def;
	field.classList.toggle('overridden', !!overridden);

	input.addEventListener('change', () => {
		const v = parseInt(input.value, 10);
		if (Number.isFinite(v) && v >= 0 && v <= 100) {
			send({
				action: 'set_priority',
				category: cat.name,
				group: cat.group,
				section: sec ? sec.name : '',
				personal_path: cat.personal_path || '',
				ext_id: cat.ext_id || '',
				priority: v
			});
		}
	});

	reset.addEventListener('click', () => {
		send({
			action: 'clear_priority',
			category: cat.name,
			group: cat.group,
			section: sec ? sec.name : '',
			personal_path: cat.personal_path || '',
			ext_id: cat.ext_id || ''
		});
	});
}

function bindColor(field, cat, sec) {
	const color = sec ? sec.color : cat.color;
	const overridden = sec ? sec.color_overridden : cat.color_overridden;
	const select = field.querySelector('select');
	const swatch = field.querySelector('.swatch');
	const reset = field.querySelector('.reset');

	// Build the dropdown: presets + a current-value entry when the active
	// hex is not part of the preset list, so the user always sees the
	// current selection clearly.
	select.innerHTML = '';
	const opts = state.presets.slice();
	const lower = (color || '').toLowerCase();
	const known = opts.find((p) => (p.hex || '').toLowerCase() === lower);
	if (color && !known) {
		opts.unshift({ label: color, hex: color });
	}
	for (const p of opts) {
		const o = document.createElement('option');
		o.value = p.hex;
		o.textContent = p.label;
		if ((p.hex || '').toLowerCase() === lower) o.selected = true;
		select.appendChild(o);
	}
	swatch.style.background = color || 'transparent';
	field.classList.toggle('overridden', !!overridden);

	select.addEventListener('change', () => {
		const hex = select.value;
		if (hex) {
			send({
				action: 'set_color',
				category: cat.name,
				group: cat.group,
				section: sec ? sec.name : '',
				personal_path: cat.personal_path || '',
				ext_id: cat.ext_id || '',
				hex
			});
		}
	});

	reset.addEventListener('click', () => {
		send({
			action: 'clear_color',
			category: cat.name,
			group: cat.group,
			section: sec ? sec.name : '',
			personal_path: cat.personal_path || '',
			ext_id: cat.ext_id || ''
		});
	});
}

function bindTooltip(field, cat, sec) {
	if (!field) return;
	const showTooltip = sec ? sec.show_tooltip : cat.show_tooltip;
	const overridden = sec ? sec.show_tooltip_overridden : cat.show_tooltip_overridden;
	const chk = field.querySelector('.chk-tooltip');
	const reset = field.querySelector('.reset');

	chk.checked = showTooltip !== false;
	field.classList.toggle('overridden', !!overridden);
	reset.disabled = !overridden;

	chk.addEventListener('change', () => {
		send({
			action: 'set_tooltip',
			category: cat.name,
			group: cat.group,
			section: sec ? sec.name : '',
			personal_path: cat.personal_path || '',
			ext_id: cat.ext_id || '',
			show_tooltip: chk.checked
		});
	});

	reset.addEventListener('click', () => {
		send({
			action: 'clear_tooltip',
			category: cat.name,
			group: cat.group,
			section: sec ? sec.name : '',
			personal_path: cat.personal_path || '',
			ext_id: cat.ext_id || ''
		});
	});
}

// ============================================================
// 6/ The contract with the host
// ============================================================

// The host pushes data by calling `window.setData(...)`, guarded with
// `if(window.setData)`. Publishing it explicitly rather than relying on a
// top-level function declaration being globalised: the guard means a page that
// does not expose it turns every push into a silent no-op, and an implicit
// global is a fragile thing to hang that on across two files in two languages.
//
// The Linux hardware harness found this window unreachable that way while the
// editor — which has always assigned `window.initData` explicitly — worked.
window.setData = setData;
