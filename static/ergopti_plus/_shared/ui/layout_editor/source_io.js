// _shared/ui/layout_editor/source_io.js

/**
 * ==============================================================================
 * MODULE: Layout Editor Source I/O
 * DESCRIPTION:
 * The one place the unified layout editor reads and writes the Ergopti layout
 * source (docs/design/layout-source-format.md). Everything format-specific
 * lives here: TOML decoding and encoding through the vendored smol-toml codec,
 * validation and capability reports through LayoutSource (the format owner,
 * layout_composer/source_model.js), .keylayout import through the composer
 * reader, and the navigation layer file (layers.toml) through LayerModel. The
 * page and the editing model never touch TOML or XML directly, so a change of
 * the format touches this file and its owner only.
 *
 * FEATURES & RATIONALE:
 * 1. Imports stay lossless: an imported .keylayout is kept verbatim by the
 *    format owner. Editing it is an explicit conversion (projectImport) that
 *    reports what the projection cannot hold, never a silent rewrite.
 * 2. The navigation layer is one layer of the source: layers.toml converts in
 *    both directions, per-OS sections becoming platform_keys, so the drivers'
 *    layer file and the source describe the same bindings.
 * 3. Fail fast: every refusal carries a stable code and a source path the page
 *    translates; nothing is dropped or defaulted silently.
 * ==============================================================================
 */

// A classic script's top-level var is a global of the page (and of a vm context).
var LayoutSourceIO = (function () {
	'use strict';

	// ============================
	// ======= 1/ Constants =======
	// ============================

	// The composer reader's levels and the modifiers each one holds (macOS
	// semantics: Option is the AltGr level, Command the shortcuts level).
	const PROJECTED_LAYERS = [
		{ id: 'base', composer: 'base', required: [] },
		{ id: 'shift', composer: 'shift', required: ['shift'] },
		{ id: 'altgr', composer: 'altgr', required: ['alt'] },
		{ id: 'shift_altgr', composer: 'shift_altgr', required: ['shift', 'alt'] },
		{ id: 'command', composer: 'command', required: ['meta'] }
	];
	// layers.toml modifier tokens and the source's built-in names.
	const NAV_MODIFIERS = { ctrl: 'control', alt: 'alt', shift: 'shift', meta: 'meta', fn: 'fn' };
	const NAV_LAYER = 'nav';
	const NAV_MODIFIER = 'nav';
	const FN_MODIFIER = { id: 'fn', mode: 'held', keys: ['Fn'] };
	const REPEAT_ACTION = /^repeat_count_([0-9]+)$/;
	const DEAD_KEY_PREFIX = 'dead_';

	const own = (value, key) => Object.prototype.hasOwnProperty.call(value, key);
	const copy = (value) => JSON.parse(JSON.stringify(value));

	/** A refusal of this module, with a stable code and the place it concerns. */
	class SourceIOError extends Error {
		constructor(code, path) {
			super(`${code}: ${path}`);
			this.name = 'SourceIOError';
			this.code = code;
			this.path = path;
		}
	}

	// ========================
	// ======= 2/ Codec =======
	// ========================

	/** The TOML codec the vendored smol-toml file exported into the page. */
	function codec() {
		const loaded = typeof exports === 'object' && exports !== null ? exports : null;
		if (!loaded || typeof loaded.parse !== 'function' || typeof loaded.stringify !== 'function')
			throw new SourceIOError('toml_codec_missing', 'vendor/smol-toml.js');
		return loaded;
	}

	/** A refusal as plain data the page can translate. */
	function failure(error) {
		if (error && typeof error.code === 'string' && typeof error.path === 'string')
			return { code: error.code, path: error.path };
		if (error instanceof codec().TomlError)
			return { code: 'toml_syntax', path: error.message.split('\n')[0] };
		throw error;
	}

	/**
	 * Reads a source document.
	 * @param {string} text - TOML text.
	 * @returns {{ok: true, doc: object}|{ok: false, error: {code: string, path: string}}}
	 */
	function parse(text) {
		try {
			return { ok: true, doc: LayoutSource.read(text, codec()) };
		} catch (error) {
			return { ok: false, error: failure(error) };
		}
	}

	/**
	 * Writes a validated document as TOML; an invalid document throws.
	 * @param {object} doc
	 * @returns {string}
	 */
	function serialize(doc) {
		const text = LayoutSource.write(doc, codec());
		return text.endsWith('\n') ? text : text + '\n';
	}

	/**
	 * Validates a document without changing it.
	 * @returns {{ok: true}|{ok: false, error: {code: string, path: string}}}
	 */
	function check(doc) {
		try {
			LayoutSource.validate(doc);
			return { ok: true };
		} catch (error) {
			return { ok: false, error: failure(error) };
		}
	}

	// ==================================
	// ======= 3/ Documents ============
	// ==================================

	/**
	 * A new editable source with an empty base layer.
	 * @param {string} id - Source identifier ([a-z][a-z0-9_]*).
	 * @param {string} name - Display name.
	 */
	function create(id, name) {
		return LayoutSource.validate({
			format: LayoutSource.FORMAT,
			version: LayoutSource.VERSION,
			layout: { id, name },
			physical: { base: 'iso' },
			layers: [{ id: 'base', required: [], optional: [], keys: {} }]
		});
	}

	/** Whether the document keeps an imported .keylayout verbatim. */
	function isPreserved(doc) {
		return own(doc, 'imported_keylayout');
	}

	/** Imports a .keylayout losslessly; the XML stays the mapping owner. */
	function importKeylayout(xml, id, convention) {
		return LayoutSource.importKeylayout(xml, id, convention);
	}

	/** The preserved .keylayout, refused once the source holds edits it cannot compile. */
	function exportKeylayout(doc) {
		return LayoutSource.exportKeylayout(doc);
	}

	/** Per-target support of the format owner's exporters. */
	function capabilities(doc) {
		return LayoutSource.capabilities(doc);
	}

	/** An identifier the format accepts, derived from free text. */
	function identifierFrom(text, fallback) {
		const slug = String(text)
			.normalize('NFD')
			.replace(/[̀-ͯ]/g, '')
			.toLowerCase()
			.replace(/[^a-z0-9]+/g, '_')
			.replace(/^_+|_+$/g, '');
		const id = /^[a-z]/.test(slug) ? slug : `${fallback}_${slug}`.replace(/_+$/, '');
		return id;
	}

	/**
	 * Converts a preserved import into an editable source through the composer
	 * reader: five character levels, dead keys with chaining and terminators.
	 * The original XML is dropped from the result, so the caller asks first.
	 * @param {object} doc - A preserved document.
	 * @returns {{doc: object, lost: string[]}} The editable source and what the
	 *   projection cannot hold (stable codes the page translates).
	 */
	function projectImport(doc) {
		if (!isPreserved(doc)) throw new SourceIOError('source_not_imported', 'imported_keylayout');
		const { text, convention } = doc.imported_keylayout;
		const parsed = LayoutComposer.parseSource(
			doc.layout.id,
			text,
			convention,
			LAYOUT_COMPOSER_DATA
		);
		const stateIds = new Map();
		const deadId = (state) => {
			if (!stateIds.has(state))
				stateIds.set(state, `${DEAD_KEY_PREFIX}${identifierFrom(state, 's')}_${stateIds.size + 1}`);
			return stateIds.get(state);
		};
		const layers = PROJECTED_LAYERS.map((level) => {
			const keys = {};
			for (const [code, cells] of Object.entries(parsed.cells)) {
				const cell = cells[level.composer];
				if (!cell) continue;
				if (own(cell, 'text')) keys[code] = { text: cell.text };
				else {
					const neutral = parsed.actions[cell.dead.action].none;
					keys[code] = { dead_key: deadId(neutral.next) };
				}
			}
			return { id: level.id, required: level.required.slice(), optional: [], keys };
		});
		// Chained states reached only through another dead key still need a record.
		for (const rules of Object.values(parsed.compositions))
			for (const rule of Object.values(rules)) if (rule.next) deadId(rule.next);
		const deadKeys = [];
		for (const [state, id] of stateIds) {
			const rules = Object.entries(parsed.compositions[state] || {}).map(([input, rule]) =>
				rule.next ? { input, next: deadId(rule.next) } : { input, text: rule.output }
			);
			deadKeys.push({ id, name: state, terminator: parsed.terminators[state] || '', rules });
		}
		const lost = ['keylayout_original_xml', 'keylayout_sided_modifiers'];
		if (convention === 'ansi') lost.push('keylayout_ansi_projected_iso');
		if (parsed.ambiguous.size > 0) lost.push('keylayout_ambiguous_compositions');
		const editable = {
			format: doc.format,
			version: doc.version,
			layout: copy(doc.layout),
			physical: { base: 'iso' },
			layers
		};
		if (deadKeys.length) editable.dead_keys = deadKeys;
		for (const field of ['modifiers', 'keys', 'remap', 'shortcuts', 'windows', 'exports'])
			if (own(doc, field)) editable[field] = copy(doc[field]);
		LayoutSource.validate(editable);
		return { doc: editable, lost };
	}

	// =======================================
	// ======= 4/ Navigation layer file =======
	// =======================================

	/** One layers.toml binding as a source mapping, for one OS; used collects its modifiers. */
	function navMapping(value, os, data, used) {
		const parsed = LayerModel.parseBinding(value, data);
		if (parsed.type === 'action') return { action: parsed.id };
		if (parsed.type === 'repeat_count') return { action: `repeat_count_${parsed.count}` };
		if (parsed.type === 'keystroke') {
			if (parsed.chords.length !== 1) throw new SourceIOError('nav_binding_sequence', value);
			const chord = parsed.chords[0];
			const modifiers = chord.mods.map((mod) =>
				mod === 'primary' ? NAV_MODIFIERS[data.primary_modifier[os]] : NAV_MODIFIERS[mod]
			);
			for (const modifier of modifiers) used.add(modifier);
			return modifiers.length ? { key: chord.key, modifiers } : { key: chord.key };
		}
		throw new SourceIOError('nav_binding_invalid', String(value));
	}

	/** Whether a binding resolves differently per OS (its `primary` modifier). */
	function navIsPlatformDependent(value, data) {
		const parsed = LayerModel.parseBinding(value, data);
		return parsed.type === 'keystroke' && parsed.chords.some((c) => c.mods.includes('primary'));
	}

	/**
	 * Puts the navigation layer of a layers.toml into a source as its `nav`
	 * layer, entered by holding one of holdKeys.
	 * @param {object} doc - An editable source (not a preserved import).
	 * @param {string|null} text - layers.toml content.
	 * @param {string[]} holdKeys - Physical keys whose hold enters the layer.
	 * @param {object} data - LAYER_EDITOR_DATA.
	 * @returns {object} A new validated document.
	 */
	function withNavLayer(doc, text, holdKeys, data) {
		if (isPreserved(doc)) throw new SourceIOError('source_preserved', 'imported_keylayout');
		if (!Array.isArray(holdKeys) || holdKeys.length === 0)
			throw new SourceIOError('nav_hold_key_missing', 'modifiers.nav.keys');
		const read = LayerModel.readLayerFile(text, data);
		if (read.problem) throw new SourceIOError('nav_file_invalid', read.problem);
		const sections = read.doc.layers[data.layer] || {};
		const keys = {};
		const platformKeys = {};
		const used = new Set();
		for (const [section, bindings] of Object.entries(sections)) {
			if (section !== LayerModel.SECTION_ALL && !data.platforms.includes(section))
				throw new SourceIOError('nav_section_unknown', `layers.${data.layer}.${section}`);
			for (const [code, value] of Object.entries(bindings)) {
				if (section !== LayerModel.SECTION_ALL) {
					platformKeys[section] = platformKeys[section] || {};
					platformKeys[section][code] = navMapping(value, section, data, used);
				} else if (navIsPlatformDependent(value, data)) {
					for (const os of data.platforms) {
						platformKeys[os] = platformKeys[os] || {};
						if (!own(sections[os] || {}, code))
							platformKeys[os][code] = navMapping(value, os, data, used);
					}
				} else keys[code] = navMapping(value, data.platforms[0], data, used);
			}
		}
		const next = copy(doc);
		next.modifiers = (next.modifiers || []).filter((m) => m.id !== NAV_MODIFIER);
		next.modifiers.push({ id: NAV_MODIFIER, mode: 'held', keys: holdKeys.slice() });
		if (used.has(FN_MODIFIER.id) && !next.modifiers.some((m) => m.id === FN_MODIFIER.id))
			next.modifiers.push(copy(FN_MODIFIER));
		const layer = { id: NAV_LAYER, required: [NAV_MODIFIER], optional: [], keys };
		if (Object.keys(platformKeys).length) layer.platform_keys = platformKeys;
		next.layers = (next.layers || []).filter((l) => l.id !== NAV_LAYER);
		next.layers.push(layer);
		return LayoutSource.validate(next);
	}

	/** One source mapping as a layers.toml binding, or a refusal. */
	function navBinding(mapping, data) {
		if (own(mapping, 'action')) {
			const repeat = REPEAT_ACTION.exec(mapping.action);
			if (repeat) return `repeat_count:${Number(repeat[1])}`;
			if (!own(data.actions, mapping.action))
				throw new SourceIOError('nav_action_unknown', mapping.action);
			return mapping.action;
		}
		if (own(mapping, 'key')) {
			const tokens = (mapping.modifiers || []).map((mod) => {
				const token = Object.keys(NAV_MODIFIERS).find((t) => NAV_MODIFIERS[t] === mod);
				if (!token) throw new SourceIOError('nav_modifier_unsupported', mod);
				return token;
			});
			tokens.sort((a, b) => data.modifier_order.indexOf(a) - data.modifier_order.indexOf(b));
			return `keystroke:${tokens.concat([mapping.key]).join('+')}`;
		}
		throw new SourceIOError('nav_mapping_unsupported', JSON.stringify(mapping));
	}

	/**
	 * Writes the source's `nav` layer as the drivers' layers.toml.
	 * @param {object} doc
	 * @param {object} data - LAYER_EDITOR_DATA.
	 * @returns {string}
	 */
	function navLayerFile(doc, data) {
		const layer = (doc.layers || []).find((l) => l.id === NAV_LAYER);
		const sections = {};
		if (layer) {
			const all = {};
			for (const [code, mapping] of Object.entries(layer.keys))
				all[code] = navBinding(mapping, data);
			if (Object.keys(all).length) sections[LayerModel.SECTION_ALL] = all;
			for (const [os, bindings] of Object.entries(layer.platform_keys || {})) {
				const out = {};
				for (const [code, mapping] of Object.entries(bindings))
					out[code] = navBinding(mapping, data);
				if (Object.keys(out).length) sections[os] = out;
			}
		}
		const layers = Object.keys(sections).length ? { [data.layer]: sections } : {};
		return LayerModel.serialize({ layers }, data);
	}

	return {
		SourceIOError,
		NAV_LAYER,
		parse,
		serialize,
		check,
		create,
		isPreserved,
		importKeylayout,
		exportKeylayout,
		capabilities,
		identifierFrom,
		projectImport,
		withNavLayer,
		navLayerFile
	};
})();
