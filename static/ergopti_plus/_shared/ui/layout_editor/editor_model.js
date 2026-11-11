// _shared/ui/layout_editor/editor_model.js

/**
 * ==============================================================================
 * MODULE: Layout Editor Model
 * DESCRIPTION:
 * The pure editing half of the unified layout editor. Every edit takes a
 * source document and returns a new validated one, so the page keeps an undo
 * history of plain snapshots and never holds a half-applied change. It also
 * selects the layer a set of held modifiers reaches and simulates typing for
 * the live preview, dead keys and chains included. It touches no DOM and no
 * file: TOML and XML stay in source_io.js, which validates through the format
 * owner (layout_composer/source_model.js).
 *
 * FEATURES & RATIONALE:
 * 1. An edit that would make the source invalid throws with the format's
 *    stable code; the previous document stays the current one.
 * 2. Removing a layer, a modifier or a dead key that something still uses is
 *    refused with the referring path, never cascaded silently.
 * 3. The preview follows the format's contract only (layer selection by
 *    required/optional modifiers, rules, terminators); it does not claim what
 *    a given OS does natively — the export report says that.
 * ==============================================================================
 */

// A classic script's top-level var is a global of the page (and of a vm context).
var LayoutEditorModel = (function () {
	'use strict';

	// ============================
	// ======= 1/ Constants =======
	// ============================

	const HISTORY_LIMIT = 200;
	const PLATFORMS = ['windows', 'macos', 'linux'];
	const MAPPING_KINDS = ['text', 'dead_key', 'action', 'key', 'disabled'];
	const CAPS_MODES = ['unaffected', 'shift', 'separate'];

	const own = (value, key) => Object.prototype.hasOwnProperty.call(value, key);
	const copy = (value) => JSON.parse(JSON.stringify(value));

	/** A refused edit: a stable code and the path that refuses it. */
	class EditError extends Error {
		constructor(code, path) {
			super(`${code}: ${path}`);
			this.name = 'EditError';
			this.code = code;
			this.path = path;
		}
	}

	/** Validates the edited copy, or throws the format's refusal. */
	function commit(next) {
		const checked = LayoutSourceIO.check(next);
		if (!checked.ok) throw new EditError(checked.error.code, checked.error.path);
		return next;
	}

	/** Refuses edits of a preserved import: its XML owns the mappings. */
	function editable(doc) {
		if (LayoutSourceIO.isPreserved(doc))
			throw new EditError('source_preserved', 'imported_keylayout');
		return copy(doc);
	}

	function layerIndex(doc, layerId) {
		const index = (doc.layers || []).findIndex((layer) => layer.id === layerId);
		if (index < 0) throw new EditError('layer_unknown', `layers.${layerId}`);
		return index;
	}

	// ==========================
	// ======= 2/ Layers ========
	// ==========================

	/** The layers in declaration order. */
	function layers(doc) {
		return (doc.layers || []).map((layer) => ({
			id: layer.id,
			required: layer.required.slice(),
			optional: layer.optional.slice()
		}));
	}

	/**
	 * What a key does on a layer: the platform override when one is given and
	 * present, else the shared mapping.
	 * @returns {{mapping: object, scope: string}|null}
	 */
	function mappingAt(doc, layerId, code, platform) {
		const layer = doc.layers[layerIndex(doc, layerId)];
		const overrides = platform && layer.platform_keys && layer.platform_keys[platform];
		if (overrides && own(overrides, code)) return { mapping: overrides[code], scope: platform };
		if (own(layer.keys, code)) return { mapping: layer.keys[code], scope: 'all' };
		return null;
	}

	/**
	 * Sets or clears what a key does on a layer.
	 * @param {object|null} mapping - A format mapping, or null to clear.
	 * @param {string|null} platform - Null for every OS, else one OS.
	 */
	function setMapping(doc, layerId, code, mapping, platform) {
		const next = editable(doc);
		const layer = next.layers[layerIndex(next, layerId)];
		if (platform && !PLATFORMS.includes(platform))
			throw new EditError('platform_unknown', String(platform));
		let target = layer.keys;
		if (platform) {
			layer.platform_keys = layer.platform_keys || {};
			layer.platform_keys[platform] = layer.platform_keys[platform] || {};
			target = layer.platform_keys[platform];
		}
		if (mapping === null) delete target[code];
		else target[code] = copy(mapping);
		if (platform && Object.keys(target).length === 0) delete layer.platform_keys[platform];
		if (layer.platform_keys && Object.keys(layer.platform_keys).length === 0)
			delete layer.platform_keys;
		return commit(next);
	}

	/** Adds a layer reached by holding its required modifiers. */
	function addLayer(doc, id, required, optional) {
		const next = editable(doc);
		next.layers = next.layers || [];
		next.layers.push({ id, required: required.slice(), optional: optional.slice(), keys: {} });
		return commit(next);
	}

	/** Every path naming a layer, a modifier or a dead key, for refusals. */
	function references(doc, kind, id) {
		const found = [];
		(doc.layers || []).forEach((layer, index) => {
			if (kind === 'modifier' && [...layer.required, ...layer.optional].includes(id))
				found.push(`layers[${index}]`);
			const tables = [layer.keys, ...Object.values(layer.platform_keys || {})];
			for (const table of tables)
				for (const [code, mapping] of Object.entries(table)) {
					if (kind === 'dead_key' && mapping.dead_key === id)
						found.push(`layers.${layer.id}.${code}`);
					if (kind === 'modifier' && (mapping.modifiers || []).includes(id))
						found.push(`layers.${layer.id}.${code}`);
				}
		});
		for (const [code, entry] of Object.entries(doc.keys || {}))
			if (kind === 'layer' && (entry.caps_layer === id || entry.caps_shift_layer === id))
				found.push(`keys.${code}`);
		(doc.tap_holds || []).forEach((entry, index) => {
			if (kind === 'layer' && entry.hold_layer === id) found.push(`tap_holds[${index}]`);
			if (kind === 'modifier' && entry.hold_modifier === id) found.push(`tap_holds[${index}]`);
		});
		(doc.shortcuts || []).forEach((entry, index) => {
			if (kind === 'modifier' && [...entry.modifiers, ...entry.send_modifiers].includes(id))
				found.push(`shortcuts[${index}]`);
		});
		(doc.dead_keys || []).forEach((entry, index) => {
			if (kind === 'dead_key' && entry.id !== id && entry.rules.some((rule) => rule.next === id))
				found.push(`dead_keys[${index}]`);
		});
		return found;
	}

	/** Removes a layer nothing refers to; the base layer stays. */
	function removeLayer(doc, id) {
		if (id === 'base') throw new EditError('layer_base_required', 'layers.base');
		const used = references(doc, 'layer', id);
		if (used.length) throw new EditError('layer_in_use', used[0]);
		const next = editable(doc);
		next.layers.splice(layerIndex(next, id), 1);
		return commit(next);
	}

	// ============================================
	// ======= 3/ Modifiers and dead keys =========
	// ============================================

	/** Adds or replaces a user-defined modifier (Kana, Roya, Loya...). */
	function setModifier(doc, id, mode, keys) {
		const next = editable(doc);
		next.modifiers = (next.modifiers || []).filter((entry) => entry.id !== id);
		next.modifiers.push({ id, mode, keys: keys.slice() });
		return commit(next);
	}

	function removeModifier(doc, id) {
		const used = references(doc, 'modifier', id);
		if (used.length) throw new EditError('modifier_in_use', used[0]);
		const next = editable(doc);
		next.modifiers = (next.modifiers || []).filter((entry) => entry.id !== id);
		if (next.modifiers.length === 0) delete next.modifiers;
		return commit(next);
	}

	/** Adds a dead key, or changes its name and terminator, keeping its rules. */
	function setDeadKey(doc, id, name, terminator) {
		const next = editable(doc);
		next.dead_keys = next.dead_keys || [];
		const existing = next.dead_keys.find((entry) => entry.id === id);
		const entry = existing || { id, terminator: '', rules: [] };
		entry.terminator = terminator;
		if (name) entry.name = name;
		else delete entry.name;
		if (!existing) next.dead_keys.push(entry);
		return commit(next);
	}

	/**
	 * Sets one composition of a dead key.
	 * @param {{text?: string, next?: string}|null} result - Null removes it.
	 */
	function setDeadRule(doc, id, input, result) {
		const next = editable(doc);
		const entry = (next.dead_keys || []).find((candidate) => candidate.id === id);
		if (!entry) throw new EditError('dead_key_unknown', `dead_keys.${id}`);
		entry.rules = entry.rules.filter((rule) => rule.input !== input);
		if (result !== null) entry.rules.push(Object.assign({ input }, copy(result)));
		return commit(next);
	}

	function removeDeadKey(doc, id) {
		const used = references(doc, 'dead_key', id);
		if (used.length) throw new EditError('dead_key_in_use', used[0]);
		const next = editable(doc);
		next.dead_keys = next.dead_keys.filter((entry) => entry.id !== id);
		if (next.dead_keys.length === 0) delete next.dead_keys;
		return commit(next);
	}

	// ==============================================
	// ======= 4/ Keys, remap, shortcuts, holds =====
	// ==============================================

	/** Sets a key's properties (name, Caps Lock mode...), or clears them with null. */
	function setKeyProperties(doc, code, properties) {
		const next = editable(doc);
		next.keys = next.keys || {};
		if (properties === null || Object.keys(properties).length === 0) delete next.keys[code];
		else next.keys[code] = copy(properties);
		if (Object.keys(next.keys).length === 0) delete next.keys;
		return commit(next);
	}

	/** Makes a physical key act as another one ('' disables it), or clears it. */
	function setRemap(doc, code, target) {
		const next = editable(doc);
		next.remap = next.remap || {};
		if (target === null) delete next.remap[code];
		else next.remap[code] = target;
		if (Object.keys(next.remap).length === 0) delete next.remap;
		return commit(next);
	}

	const chordId = (key, modifiers) => `${key}:${modifiers.slice().sort().join(',')}`;

	/** Adds or replaces a shortcut that sends another chord than the typed text. */
	function setShortcut(doc, shortcut) {
		const next = editable(doc);
		const id = chordId(shortcut.key, shortcut.modifiers);
		next.shortcuts = (next.shortcuts || []).filter((e) => chordId(e.key, e.modifiers) !== id);
		next.shortcuts.push(copy(shortcut));
		return commit(next);
	}

	function removeShortcut(doc, key, modifiers) {
		const next = editable(doc);
		const id = chordId(key, modifiers);
		next.shortcuts = (next.shortcuts || []).filter((e) => chordId(e.key, e.modifiers) !== id);
		if (next.shortcuts.length === 0) delete next.shortcuts;
		return commit(next);
	}

	/** Adds or replaces a key's tap-hold (tap mapping, hold layer or modifier). */
	function setTapHold(doc, entry) {
		const next = editable(doc);
		next.tap_holds = (next.tap_holds || []).filter((e) => e.key !== entry.key);
		next.tap_holds.push(copy(entry));
		return commit(next);
	}

	function removeTapHold(doc, key) {
		const next = editable(doc);
		next.tap_holds = (next.tap_holds || []).filter((e) => e.key !== key);
		if (next.tap_holds.length === 0) delete next.tap_holds;
		return commit(next);
	}

	/** Changes the layout metadata (name, description, author). */
	function setLayout(doc, fields) {
		const next = copy(doc);
		for (const [field, value] of Object.entries(fields)) {
			if (value === '' && field !== 'name') delete next.layout[field];
			else next.layout[field] = value;
		}
		return commit(next);
	}

	/** Changes one target's export settings, or clears them with null. */
	function setExport(doc, target, settings) {
		const next = copy(doc);
		next.exports = next.exports || {};
		if (settings === null) delete next.exports[target];
		else next.exports[target] = copy(settings);
		if (Object.keys(next.exports).length === 0) delete next.exports;
		return commit(next);
	}

	/**
	 * Moves or copies what a key does on a layer to another key, KbdEdit's drag
	 * and drop: a move swaps the two keys, a copy leaves the source as it was.
	 * @param {boolean} keep - True copies, false swaps.
	 */
	function transferMapping(doc, layerId, from, to, platform, keep) {
		if (from === to) return doc;
		const source = mappingAt(doc, layerId, from, platform);
		const target = mappingAt(doc, layerId, to, platform);
		const pick = (found) => (found && found.scope === (platform || 'all') ? found.mapping : null);
		let next = setMapping(doc, layerId, to, pick(source), platform);
		if (!keep) next = setMapping(next, layerId, from, pick(target), platform);
		return next;
	}

	/**
	 * The layer holding the other case of a layer: the same selector with Shift
	 * added or removed, or null when the source has none.
	 */
	function caseLayer(doc, layerId) {
		const layer = doc.layers[layerIndex(doc, layerId)];
		const shifted = layer.required.includes('shift');
		const wanted = shifted
			? layer.required.filter((token) => token !== 'shift')
			: layer.required.concat('shift');
		const same = (a, b) => a.length === b.length && a.every((token) => b.includes(token));
		const partner = doc.layers.find(
			(entry) =>
				entry.id !== layerId &&
				same(entry.required, wanted) &&
				same(
					entry.optional.filter((t) => t !== 'shift'),
					layer.optional.filter((t) => t !== 'shift')
				)
		);
		return partner ? { id: partner.id, upper: !shifted } : null;
	}

	/**
	 * KbdEdit's automatic case mapping: sets a mapping and, when it types one
	 * letter with a one-letter other case, fills that case on the case layer.
	 * A non-empty partner cell is kept unless `overwrite` is set.
	 * @returns {object} The edited document.
	 */
	function setMappingWithCase(doc, layerId, code, mapping, platform, overwrite) {
		let next = setMapping(doc, layerId, code, mapping, platform);
		const text = mapping && typeof mapping.text === 'string' ? mapping.text : null;
		const partner = text && [...text].length === 1 ? caseLayer(next, layerId) : null;
		if (!partner) return next;
		const other = partner.upper ? text.toUpperCase() : text.toLowerCase();
		if (other === text || [...other].length !== 1) return next;
		const existing = mappingAt(next, partner.id, code, platform);
		if (existing && existing.scope === (platform || 'all') && !overwrite) return next;
		next = setMapping(next, partner.id, code, { text: other }, platform);
		return next;
	}

	/**
	 * KbdEdit's « move all keys »: every shared mapping of a layer goes to
	 * another layer, replacing its cells; `keep` copies instead of moving.
	 */
	function transferLayer(doc, from, to, keep) {
		if (from === to) return doc;
		const next = editable(doc);
		const source = next.layers[layerIndex(next, from)];
		const target = next.layers[layerIndex(next, to)];
		Object.assign(target.keys, copy(source.keys));
		if (!keep) source.keys = {};
		return commit(next);
	}

	/** Replaces the Windows layout flags (KLLF and similar identifiers). */
	function setWindowsFlags(doc, flags) {
		const next = editable(doc);
		next.windows = next.windows || {};
		if (flags.length) next.windows.flags = flags.slice();
		else delete next.windows.flags;
		if (Object.keys(next.windows).length === 0) delete next.windows;
		return commit(next);
	}

	const nlsId = (entry) => `${entry.key}:${entry.modifiers.slice().sort().join(',')}`;

	/** Adds or replaces a Windows NLS special function on a key chord. */
	function setNls(doc, entry) {
		const next = editable(doc);
		next.windows = next.windows || {};
		next.windows.nls = (next.windows.nls || []).filter((e) => nlsId(e) !== nlsId(entry));
		next.windows.nls.push(copy(entry));
		return commit(next);
	}

	function removeNls(doc, key, modifiers) {
		const next = editable(doc);
		const id = nlsId({ key, modifiers });
		next.windows.nls = (next.windows.nls || []).filter((e) => nlsId(e) !== id);
		if (next.windows.nls.length === 0) delete next.windows.nls;
		if (Object.keys(next.windows).length === 0) delete next.windows;
		return commit(next);
	}

	// =============================
	// ======= 5/ Preview ==========
	// =============================

	/** The either-side modifier a sided one belongs to (shift_left -> shift). */
	const family = (id) => id.replace(/_(left|right)$/, '');

	/** Whether one selector (required, optional) accepts the held modifiers. */
	function accepts(selector, held) {
		const allowed = [...selector.required, ...selector.optional];
		const satisfied = (id) => held.some((h) => h === id || family(h) === id);
		const permitted = (h) => allowed.some((id) => id === h || id === family(h));
		return selector.required.every(satisfied) && held.every(permitted);
	}

	/**
	 * The layer a set of held modifiers reaches: a selector (the layer's own or
	 * one of its alternatives) whose required modifiers are all held, with
	 * nothing held outside required and optional; the most specific wins. Held
	 * modifiers may be sided (shift_left) or either-side (shift).
	 * @param {string[]} held - Modifier ids.
	 * @returns {string|null}
	 */
	function layerFor(doc, held) {
		let best = null;
		let bestSize = -1;
		for (const layer of doc.layers || [])
			for (const selector of [layer, ...(layer.alternatives || [])])
				if (accepts(selector, held) && selector.required.length > bestSize) {
					best = layer;
					bestSize = selector.required.length;
				}
		return best ? best.id : null;
	}

	/**
	 * Types a sequence of key presses through the source.
	 * @param {{code: string, held: string[]}[]} presses
	 * @param {string|null} platform - The OS whose overrides apply.
	 * @returns {{text: string, pending: string|null}} The typed text and the dead
	 *   key still waiting for its next key.
	 */
	function simulate(doc, presses, platform) {
		const deadKeys = new Map((doc.dead_keys || []).map((entry) => [entry.id, entry]));
		let text = '';
		let pending = null;
		for (const press of presses) {
			const layerId = layerFor(doc, press.held);
			const found = layerId ? mappingAt(doc, layerId, press.code, platform) : null;
			if (!found) continue;
			const mapping = found.mapping;
			if (own(mapping, 'dead_key')) {
				// Chains go through a rule's `next`; another dead key ends the pending one.
				if (pending) text += pending.terminator;
				pending = deadKeys.get(mapping.dead_key);
				continue;
			}
			if (!own(mapping, 'text')) {
				if (pending) text += pending.terminator;
				pending = null;
				continue;
			}
			if (pending) {
				const rule = pending.rules.find((candidate) => candidate.input === mapping.text);
				if (rule && own(rule, 'next')) {
					if (own(rule, 'text')) text += rule.text;
					pending = deadKeys.get(rule.next);
					continue;
				}
				text += rule ? rule.text : pending.terminator + mapping.text;
				pending = null;
				continue;
			}
			text += mapping.text;
		}
		return { text, pending: pending ? pending.id : null };
	}

	/** The kind of a mapping (text, dead_key, action, key or disabled). */
	function kindOf(mapping) {
		return MAPPING_KINDS.find((kind) => own(mapping, kind));
	}

	// =============================
	// ======= 6/ History ==========
	// =============================

	/** Undo and redo over document snapshots. */
	function createHistory(doc) {
		const past = [];
		const future = [];
		let present = doc;
		return {
			current: () => present,
			push(next) {
				past.push(present);
				if (past.length > HISTORY_LIMIT) past.shift();
				future.length = 0;
				present = next;
				return present;
			},
			reset(next) {
				past.length = 0;
				future.length = 0;
				present = next;
				return present;
			},
			canUndo: () => past.length > 0,
			canRedo: () => future.length > 0,
			undo() {
				if (past.length) {
					future.push(present);
					present = past.pop();
				}
				return present;
			},
			redo() {
				if (future.length) {
					past.push(present);
					present = future.pop();
				}
				return present;
			}
		};
	}

	return {
		EditError,
		PLATFORMS,
		MAPPING_KINDS,
		CAPS_MODES,
		layers,
		mappingAt,
		setMapping,
		addLayer,
		removeLayer,
		references,
		setModifier,
		removeModifier,
		setDeadKey,
		setDeadRule,
		removeDeadKey,
		setKeyProperties,
		setRemap,
		setShortcut,
		removeShortcut,
		setTapHold,
		removeTapHold,
		setLayout,
		setExport,
		transferMapping,
		caseLayer,
		setMappingWithCase,
		transferLayer,
		setWindowsFlags,
		setNls,
		removeNls,
		layerFor,
		simulate,
		kindOf,
		createHistory
	};
})();
