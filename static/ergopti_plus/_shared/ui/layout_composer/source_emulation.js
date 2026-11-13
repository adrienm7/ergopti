// _shared/ui/layout_composer/source_emulation.js

/**
 * ==============================================================================
 * MODULE: Ergopti Layout Source Emulation (web)
 * DESCRIPTION:
 * The web twin of _shared/layouts/engine/composer/source_emulation.lua: performs the
 * emulation table the source compiler writes (compileEmulation), the records no
 * .keylayout holds (custom modifiers and their layers, key-chord mappings,
 * shortcuts sending another key, tap-holds, remaps of system keys), on top of
 * the keylayout the page types with. The site and the composer preview load
 * it; both engines replay the same vectors
 * (_shared/tests/corpus/layouts/source/emulation_vectors.json).
 *
 * FEATURES & RATIONALE:
 * 1. Same decisions as the drivers: TN2056 selection (first matching layer, an
 *    unsided id matches either side), the shared catalogue's typing rule for
 *    tap-holds (the tap before the threshold, the hold from it on), and an
 *    emulated layer typing nothing on a key it does not map.
 * 2. Pure classic script: no DOM, no clock; the caller passes the time and
 *    performs the returned actions in order.
 * 3. Fail fast: a table of another format or version, or naming an undeclared
 *    layer or modifier, throws when compiled, never on a key.
 * ==============================================================================
 */

var LayoutSourceEmulation = (function () {
	'use strict';

	// ============================
	// ======= 1/ Constants =======
	// ============================

	const FORMAT = 'ergopti-layout-emulation';
	const VERSION = 1;
	// The built-in modifiers a driver reports, in the order key actions name them.
	const REPORTED = ['shift', 'control', 'alt', 'alt_right', 'meta', 'caps_lock'];
	// The built-in modifiers that have a left and a right key.
	const SIDED = new Set(['shift', 'control', 'alt', 'meta']);

	const fail = (message) => {
		throw new Error(message);
	};

	// ============================
	// ======= 2/ Matching ========
	// ============================

	/** The modifier family of an id; a custom id is its own family. */
	function family(id) {
		const match = /^(.*?)_(left|right)$/.exec(id);
		return match && SIDED.has(match[1]) ? match[1] : id;
	}

	/** Whether a selector modifier id stands for a held one. */
	function covers(spec, held) {
		if (spec === held) return true;
		if (family(spec) !== family(held)) return false;
		return family(spec) === spec || family(held) === held;
	}

	/**
	 * Whether a selector matches the held modifier ids exactly (TN2056).
	 * @param {{required: string[], optional: string[]}} selector
	 * @param {string[]} pressed
	 */
	function selectorMatches(selector, pressed) {
		if (!selector.required.every((required) => pressed.some((id) => covers(required, id))))
			return false;
		return pressed.every(
			(id) =>
				selector.required.some((spec) => covers(spec, id)) ||
				selector.optional.some((spec) => covers(spec, id))
		);
	}

	// ==============================
	// ======= 3/ Compilation =======
	// ==============================

	/** Check one mapping of the table and copy it. */
	function mappingOf(value, where) {
		if (value === null || typeof value !== 'object')
			fail(`The emulation table holds a malformed mapping at ${where}.`);
		if (typeof value.text === 'string') return { text: value.text };
		if (typeof value.key === 'string')
			return { key: value.key, modifiers: (value.modifiers || []).slice() };
		if (value.disabled === true) return { disabled: true };
		return fail(`The emulation table holds a malformed mapping at ${where}.`);
	}

	/**
	 * Compile a decoded emulation table into the lookups the key path walks.
	 * @param {object} table - compileEmulation's table.
	 */
	function compile(table) {
		if (!table || table.format !== FORMAT || table.version !== VERSION)
			fail(`The layout emulation table is not an ${FORMAT} version ${VERSION} table.`);
		const model = {
			layout: table.layout,
			modifierKeys: new Map(),
			custom: new Map(),
			layers: [],
			layerById: new Map(),
			shortcuts: [],
			tapHolds: new Map(),
			remaps: new Map()
		};
		for (const modifier of table.modifiers || []) {
			if (typeof modifier.id !== 'string' || !['held', 'locked'].includes(modifier.mode))
				fail('The emulation table holds a malformed custom modifier.');
			model.custom.set(modifier.id, modifier.mode);
			for (const key of modifier.keys || []) {
				if (model.modifierKeys.has(key)) fail(`Two custom modifiers share the key ${key}.`);
				model.modifierKeys.set(key, { id: modifier.id, mode: modifier.mode });
			}
		}
		// Kana is a built-in no driver reports: the targets compile its layers to
		// their native Option/AltGr level, so a selector naming it never matches here.
		const known = (id) =>
			REPORTED.includes(id) || id === 'kana' || model.custom.has(id) || SIDED.has(family(id));
		const ids = (list, where) => {
			if (!Array.isArray(list)) fail(`The emulation table holds no modifier list at ${where}.`);
			for (const id of list)
				if (typeof id !== 'string' || !known(id))
					fail(`The emulation table names the unknown modifier '${id}' at ${where}.`);
			return list.slice();
		};
		(table.layers || []).forEach((layer, index) => {
			if (typeof layer.id !== 'string' || !Array.isArray(layer.selectors) || !layer.keys)
				fail('The emulation table holds a malformed layer.');
			const compiled = {
				id: layer.id,
				native: layer.native === true,
				selectable: layer.selectable !== false,
				selectors: layer.selectors.map((selector, position) => {
					const where = `layers[${index}].selectors[${position}]`;
					return {
						required: ids(selector.required, where),
						optional: ids(selector.optional, where)
					};
				}),
				keys: new Map(
					Object.entries(layer.keys).map(([code, value]) => [
						code,
						mappingOf(value, `layers.${layer.id}.${code}`)
					])
				)
			};
			model.layers.push(compiled);
			model.layerById.set(layer.id, compiled);
		});
		(table.shortcuts || []).forEach((shortcut, index) => {
			const where = `shortcuts[${index}]`;
			if (typeof shortcut.key !== 'string' || typeof shortcut.send_key !== 'string')
				fail(`The emulation table holds a malformed shortcut at ${where}.`);
			model.shortcuts.push({
				key: shortcut.key,
				modifiers: ids(shortcut.modifiers, where),
				sendKey: shortcut.send_key,
				sendModifiers: ids(shortcut.send_modifiers, where)
			});
		});
		(table.tap_holds || []).forEach((entry, index) => {
			const where = `tap_holds[${index}]`;
			if (
				typeof entry.key !== 'string' ||
				!Number.isSafeInteger(entry.threshold_ms) ||
				entry.threshold_ms <= 0
			)
				fail(`The emulation table holds a malformed tap-hold at ${where}.`);
			if ((entry.hold_layer === undefined) === (entry.hold_modifier === undefined))
				fail(`A tap-hold of the emulation table needs one hold at ${where}.`);
			if (entry.hold_layer !== undefined && !model.layerById.has(entry.hold_layer))
				fail(`A tap-hold holds the unknown layer '${entry.hold_layer}'.`);
			if (entry.hold_modifier !== undefined && !known(entry.hold_modifier))
				fail(`A tap-hold holds the unknown modifier '${entry.hold_modifier}'.`);
			if (model.tapHolds.has(entry.key) || model.modifierKeys.has(entry.key))
				fail(`The key ${entry.key} has two roles in the emulation table.`);
			model.tapHolds.set(entry.key, {
				key: entry.key,
				tap: mappingOf(entry.tap, `${where}.tap`),
				holdLayer: entry.hold_layer,
				holdModifier: entry.hold_modifier,
				threshold: entry.threshold_ms
			});
		});
		for (const remap of table.remaps || []) {
			if (typeof remap.key !== 'string' || typeof remap.to !== 'string')
				fail('The emulation table holds a malformed remap.');
			model.remaps.set(remap.key, remap.to);
		}
		return model;
	}

	// ==========================
	// ======= 4/ Session =======
	// ==========================

	/** Start performing a compiled table. */
	function newSession(model) {
		if (!model || !Array.isArray(model.layers)) fail('A session needs a compiled table.');
		return { model, active: new Set(), heldKeys: new Map(), pending: null, hold: null };
	}

	/** The held modifier ids: the driver's built-ins, then the active customs, sorted. */
	function pressedIds(session, held) {
		const set = new Set(held || []);
		return REPORTED.filter((id) => set.has(id)).concat([...session.active].sort());
	}

	/** The built-in modifiers a key action keeps from the hand (Caps Lock is a lock). */
	function heldModifiers(held) {
		const set = new Set(held || []);
		return REPORTED.filter((id) => id !== 'caps_lock' && set.has(id));
	}

	/** Append the actions of one mapping. */
	function perform(mapping, actions) {
		if (mapping.text !== undefined) actions.push({ type: 'text', text: mapping.text });
		else if (mapping.key !== undefined)
			actions.push({ type: 'key', key: mapping.key, modifiers: mapping.modifiers.slice() });
	}

	function startHold(session, actions) {
		const entry = session.pending.entry;
		session.hold = { entry, code: session.pending.code };
		session.pending = null;
		if (entry.holdModifier === undefined) return;
		if (session.model.custom.has(entry.holdModifier)) session.active.add(entry.holdModifier);
		else actions.push({ type: 'modifier', id: entry.holdModifier, down: true });
	}

	function endHold(session, actions) {
		const entry = session.hold.entry;
		session.hold = null;
		if (entry.holdModifier === undefined) return;
		if (session.model.custom.has(entry.holdModifier)) session.active.delete(entry.holdModifier);
		else actions.push({ type: 'modifier', id: entry.holdModifier, down: false });
	}

	/** Settle a pending tap-hold before another key: the tap, or the hold from its threshold. */
	function settle(session, now, actions) {
		const pending = session.pending;
		if (!pending) return;
		if (now - pending.at < pending.entry.threshold) {
			session.pending = null;
			perform(pending.entry.tap, actions);
		} else startHold(session, actions);
	}

	function selectedLayer(session, pressed) {
		if (session.hold && session.hold.entry.holdLayer !== undefined)
			return session.model.layerById.get(session.hold.entry.holdLayer);
		return (
			session.model.layers.find(
				(layer) =>
					layer.selectable && layer.selectors.some((selector) => selectorMatches(selector, pressed))
			) || null
		);
	}

	function shortcutFor(session, code, pressed) {
		return (
			session.model.shortcuts.find((shortcut) => {
				if (shortcut.key !== code) return false;
				const namesCaps = shortcut.modifiers.includes('caps_lock');
				const chord = pressed.filter((id) => id !== 'caps_lock' || namesCaps);
				return selectorMatches({ required: shortcut.modifiers, optional: [] }, chord);
			}) || null
		);
	}

	/**
	 * Decide one physical key press (a repeat of a held one included).
	 * @param {object} session
	 * @param {string} code - KeyboardEvent.code.
	 * @param {string[]} held - Built-in modifier ids held, caps_lock when on.
	 * @param {number} now - Milliseconds of the press.
	 * @returns {{consumed: boolean, actions: object[]}}
	 */
	function press(session, code, held, now) {
		const model = session.model;
		const actions = [];
		if (session.heldKeys.has(code)) return { consumed: true, actions };
		const modifier = model.modifierKeys.get(code);
		const tapHold = model.tapHolds.get(code);
		if (modifier) {
			session.heldKeys.set(code, 'modifier');
			if (modifier.mode === 'locked' && session.active.has(modifier.id))
				session.active.delete(modifier.id);
			else session.active.add(modifier.id);
			return { consumed: true, actions };
		}
		settle(session, now, actions);
		if (tapHold) {
			session.heldKeys.set(code, 'tap_hold');
			session.pending = { entry: tapHold, code, at: now };
			return { consumed: true, actions };
		}
		const pressed = pressedIds(session, held);
		const shortcut = shortcutFor(session, code, pressed);
		if (shortcut) {
			actions.push({
				type: 'key',
				key: shortcut.sendKey,
				modifiers: shortcut.sendModifiers.slice()
			});
			return { consumed: true, actions };
		}
		if (model.remaps.has(code)) {
			const to = model.remaps.get(code);
			if (to !== '') actions.push({ type: 'key', key: to, modifiers: heldModifiers(held) });
			return { consumed: true, actions };
		}
		const layer = selectedLayer(session, pressed);
		if (!layer) return { consumed: false, actions };
		if (layer.keys.has(code)) {
			perform(layer.keys.get(code), actions);
			return { consumed: true, actions };
		}
		// A hold reaching a native layer: no modifier selects it on the OS, so the
		// key goes out with the modifiers of the layer's first selector.
		if (layer.native && session.hold && session.hold.entry.holdLayer === layer.id) {
			const sent = new Set(heldModifiers(held).concat(layer.selectors[0].required));
			const modifiers = REPORTED.filter((id) => sent.has(id)).concat(
				[...sent].filter((id) => !REPORTED.includes(id))
			);
			actions.push({ type: 'key', key: code, modifiers });
			return { consumed: true, actions };
		}
		// An emulated layer has no keyMap for the OS to fall back on.
		return { consumed: !layer.native, actions };
	}

	/**
	 * Decide one physical key release.
	 * @returns {{consumed: boolean, actions: object[]}}
	 */
	function release(session, code, now) {
		const actions = [];
		const role = session.heldKeys.get(code);
		if (role === undefined) return { consumed: false, actions };
		session.heldKeys.delete(code);
		if (role === 'modifier') {
			const modifier = session.model.modifierKeys.get(code);
			if (modifier.mode === 'held') session.active.delete(modifier.id);
			return { consumed: true, actions };
		}
		if (session.pending && session.pending.code === code) {
			const pending = session.pending;
			session.pending = null;
			if (now - pending.at < pending.entry.threshold) perform(pending.entry.tap, actions);
			return { consumed: true, actions };
		}
		if (session.hold && session.hold.code === code) endHold(session, actions);
		return { consumed: true, actions };
	}

	/** Start the hold of a pending tap-hold whose threshold has passed. */
	function tick(session, now) {
		const actions = [];
		const pending = session.pending;
		if (pending && now - pending.at >= pending.entry.threshold) startHold(session, actions);
		return actions;
	}

	/** Drop every pending and held state, releasing a held built-in modifier. */
	function reset(session) {
		const actions = [];
		if (session.hold) endHold(session, actions);
		session.pending = null;
		session.hold = null;
		session.heldKeys = new Map();
		session.active = new Set();
		return actions;
	}

	return {
		FORMAT,
		VERSION,
		REPORTED,
		selectorMatches,
		compile,
		newSession,
		press,
		release,
		tick,
		reset
	};
})();
