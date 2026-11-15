// _shared/ui/layout_composer/target_export.js

/**
 * ==============================================================================
 * MODULE: Ergopti Layout Source Target Export
 * DESCRIPTION:
 * The one owner of the Linux XKB and Windows KLC exports of a layout source:
 * what each export admits or refuses, the converter request it builds, the
 * files it writes and the per-target report. The repository tool
 * (tools/lib/layout-source-xkb.cjs, layout-source-klc.cjs) and the layout
 * editor page load this same script; only the Lua step differs in how it
 * runs (the `lua` process for the tool, fengari in the page) and both run the
 * shared Lua adapter _shared/layouts/engine/composer/source_export.lua.
 * A structured source reaches both writers as the canonical form
 * target_compiler.js compiles it to; a preserved import as its own XML.
 *
 * FEATURES & RATIONALE:
 * 1. Pure classic script: no file, process or DOM access; the caller passes
 *    the target (LayoutTargetCompiler.target), the Lua results, the tables
 *    and the KLC generator (tools/codegen/lib/windows-keyboard-layout.cjs).
 * 2. Fail fast: a construct an export cannot carry throws a TargetExportError
 *    with a stable reason and its details before any file exists.
 * 3. Same bytes everywhere: the files are returned as text (KLC also as the
 *    MSKLC bytes, UTF-16LE with a byte order mark and CRLF line ends).
 * ==============================================================================
 */

var LayoutTargetExport = (function () {
	'use strict';

	// The source schema has no release-version field. New editable MSKLC artifacts
	// start at this explicit version; it is unrelated to the TOML schema version.
	const KLC_ARTIFACT_VERSION = '1.0.0';
	const CONTROLS = /[\u0000-\u001f\u007f-\u009f]/u;
	// kbd.h reserves these WCHAR values for absent/dead/ligature table entries.
	const RESERVED_WCHAR = /[-]/u;
	const asList = (value) => (Array.isArray(value) ? value : []);

	/** A refusal with a stable reason; `details` names what was refused. */
	class TargetExportError extends Error {
		constructor(reason, details) {
			super(reason);
			this.name = 'TargetExportError';
			if (details !== undefined) this.details = details;
		}
	}

	function refuse(reason, details) {
		throw new TargetExportError(reason, details);
	}

	// ============================
	// ======= 1/ Linux XKB =======
	// ============================

	/**
	 * The XKB converter request of a source, its metadata checked.
	 * @param {object} document - A validated source.
	 * @param {{text?: string, canonical?: object, convention: string, plan?: object}} target
	 *   LayoutTargetCompiler.target(document, tables, 'linux').
	 * @param {{keycodes: object, keysyms: object, template: string, types: string}} assets
	 *   mac_keycodes.json, key_sym.json, xkb_symbols.txt and xkb_types.txt.
	 * @returns {{id: string, description: string, input: object}}
	 */
	function xkbRequest(document, target, assets) {
		const metadata = (document.exports && document.exports.linux) || {};
		const id = metadata.name !== undefined ? metadata.name : document.layout.id;
		const description =
			metadata.description !== undefined ? metadata.description : document.layout.name;
		if (!/^[a-z][a-z0-9_]*$/.test(id)) refuse('exports.linux.name must be a source identifier');
		// The converter interpolates this into an XKB quoted string.
		if (/["\\\u0000-\u001f\u007f-\u009f]/u.test(description))
			refuse('exports.linux.description contains an unsupported XKB string character');
		const level5 = target.plan && target.plan.level5;
		return {
			id,
			description,
			input: Object.assign(
				target.canonical ? { canonical: target.canonical } : { xml: target.text },
				level5
					? { level5: { keys: level5.keys.map((key) => ({ xkb: key.xkb, keysym: key.keysym })) } }
					: {},
				{
					convention: target.convention,
					layout_id: id,
					display_name: description,
					keycodes: assets.keycodes,
					keysyms: assets.keysyms.keysyms,
					locale_extended_prefixes: assets.keysyms.locale_extended_prefixes,
					template: assets.template,
					types: assets.types
				}
			)
		};
	}

	/**
	 * The XKB files and report from the Lua conversion result.
	 * @param {{omitted: object[], plan?: object}} target - xkbRequest's target.
	 * @param {{id: string, description: string}} request - xkbRequest's result.
	 * @param {object} output - source_export.lua `xkb` result; its `types` is the
	 *   types file the symbols need, written beside them.
	 * @returns {{report: object, files: {path: string, text: string}[]}}
	 */
	function xkbFiles(target, request, output) {
		if (!output.ok) refuse(output.reason, output);
		const level5 = (target.plan && target.plan.level5) || null;
		const report = Object.assign(
			{
				target: 'linux',
				status: 'partial',
				artifact: 'xkb',
				reason: level5 ? 'eleven_level_character_projection' : 'seven_level_character_projection',
				blockers: [],
				omitted: target.omitted,
				name: request.id,
				description: request.description,
				level5
			},
			output.projection,
			{
				system_key_codes: output.system_key_codes,
				limitations: [
					'Only the character-key table is generated; listed system/keypad codes keep their installed behavior.',
					'Option, right Alt and Kana map to AltGr; Linux Alt, Control and Super use the Command shortcut level.',
					...(level5
						? [
								`${level5.modifier} holds the fifth level: ${level5.keys.map((key) => key.key).join(', ')} type ${level5.keys[0].keysym} and no longer act as their own modifier.`
							]
						: []),
					'Listed empty cells emit NoSymbol and may inherit XKB symbols; source key disabling is not compiled.',
					'Listed unbound character actions use the converter Unicode keysym fallback, without a physical source action binding.',
					'XCompose requires client support and the exported Compose file; native macOS dead-key fallback and cancellation are not certified.',
					'Registry-specific keysym hints, driver features and installation are outside this source export.'
				]
			}
		);
		return {
			report,
			files: [
				{ path: `${request.id}.xkb`, text: output.symbols },
				{ path: `${request.id}.XCompose`, text: output.compose },
				{ path: 'xkb_types.txt', text: output.types },
				{ path: 'export.json', text: `${JSON.stringify(report, null, 2)}\n` }
			]
		};
	}

	// ============================
	// ======= 2/ Windows KLC =====
	// ============================

	/** Metadata goes into quoted KLC/C-family fields of the established generator. */
	function quoted(value, field) {
		if (typeof value !== 'string' || /["\\\u0000-\u001f\u007f-\u009f]/u.test(value))
			refuse(`${field}: unsupported quoted metadata`);
		return value;
	}

	/**
	 * The KLC metadata of a source, checked before anything is read.
	 * @param {object} document - A validated source.
	 * @returns {{dll_name: string, layout_id: string, locale: string, name: string, author: string, description: string}}
	 */
	function klcMetadata(document) {
		const metadata = document.exports && document.exports.windows;
		if (!metadata || !metadata.locale || !metadata.layout_id || !metadata.dll_name)
			refuse('exports.windows requires locale, layout_id and dll_name');
		if (!/^[a-z][a-z0-9]{0,7}$/.test(metadata.dll_name))
			refuse('exports.windows.dll_name must contain 1 to 8 lowercase letters/digits');
		// KLC carries a language LCID, not an installer's custom A0nn keyboard-layout ID.
		if (!/^0000[0-9a-fA-F]{4}$/.test(metadata.layout_id) || metadata.layout_id === '00000000')
			refuse(
				'exports.windows.layout_id must be a nonzero language LCID (0000xxxx); custom KLIDs require an installer'
			);
		const locale = quoted(metadata.locale, 'exports.windows.locale');
		try {
			new Intl.Locale(locale);
		} catch {
			refuse('exports.windows.locale must be a language tag');
		}
		const name = quoted(document.layout.name, 'layout.name');
		return {
			dll_name: metadata.dll_name,
			layout_id: metadata.layout_id,
			locale,
			name,
			author: quoted(
				document.layout.author !== undefined ? document.layout.author : '',
				'layout.author'
			),
			description: quoted(
				document.layout.description !== undefined ? document.layout.description : name,
				'layout.description'
			)
		};
	}

	/**
	 * Create native character files without installing or reserving a Windows KLID.
	 * @param {object} document - A validated source.
	 * @param {{convention: string, omitted: object[], plan?: object}} imported
	 *   LayoutTargetCompiler.target(document, tables, 'windows').
	 * @param {object} canonical - The target's canonical form, or for a preserved
	 *   import source_export.lua `read` result's canonical reading.
	 * @param {{keycodes: object, physicalKeys: object}} tables - mac_keycodes.json, physical_keys.json.
	 * @param {object} Windows - The KLC generator module.
	 * @returns {{report: object, klc: string, files: {path: string, text: string}[]}}
	 */
	function klcExport(document, imported, canonical, tables, Windows) {
		const metadata = klcMetadata(document);
		const { locale, name, author, description } = metadata;
		const modifierBits = (imported.plan && imported.plan.modifier_bits) || [];
		const keycodes = tables.keycodes;
		const physicalKeys = tables.physicalKeys;
		const physical = keycodes.keys.map((key) => ({
			code: key.code,
			mac: typeof key.mac === 'object' ? key.mac[imported.convention] : key.mac
		}));
		const placed = new Set(physical.map((key) => key.mac));
		const untouched = new Map();
		for (const set of asList(canonical.key_map_sets))
			for (const map of asList(set.key_maps))
				for (const key of asList(map.keys)) {
					if (placed.has(key.code)) {
						if (key.output && CONTROLS.test(key.output))
							refuse('control_output_on_character_key', { code: key.code });
						if (key.output && RESERVED_WCHAR.test(key.output))
							refuse('reserved_windows_character', { code: key.code });
					} else {
						const printable =
							typeof key.output === 'string' && key.output !== '' && !CONTROLS.test(key.output);
						if ((key.action || printable) && !(key.code >= 65 && key.code <= 92))
							refuse('unplaced_character_key', { code: key.code });
						if (!untouched.has(key.code)) untouched.set(key.code, []);
						untouched
							.get(key.code)
							.push(
								Object.assign(
									{ set: set.id, map: map.index },
									key.action ? { action: key.action } : { output: key.output }
								)
							);
					}
				}
		for (const action of asList(canonical.actions)) {
			if (CONTROLS.test(action.id)) refuse('control_action_identifier');
			if (!asList(action.whens).some((when) => when.state === 'none'))
				refuse('action_without_neutral_transition', { action: action.id });
			for (const when of asList(action.whens)) {
				if (CONTROLS.test(when.state) || (when.next && CONTROLS.test(when.next)))
					refuse('control_state_identifier');
				if (when.output && CONTROLS.test(when.output))
					refuse('control_output_in_action', { action: action.id });
				if (when.output && RESERVED_WCHAR.test(when.output))
					refuse('reserved_windows_character', { action: action.id });
			}
		}
		for (const terminator of asList(canonical.terminators)) {
			if (CONTROLS.test(terminator.state) || CONTROLS.test(terminator.output))
				refuse('control_terminator');
			if (RESERVED_WCHAR.test(terminator.output))
				refuse('reserved_windows_character', { state: terminator.state });
		}
		const context = {
			meta: {
				name,
				author,
				version: KLC_ARTIFACT_VERSION,
				licence: '',
				keycode_convention: imported.convention
			},
			spec: {
				dll_name: metadata.dll_name,
				language_id: metadata.layout_id.slice(4).toUpperCase(),
				locale_name: locale,
				language_name: new Intl.DisplayNames(['en'], { type: 'language' }).of(locale),
				layout_text: name,
				layout_description: description
			},
			keycodes,
			physicalKeys,
			sourceRel: `layout-source:${document.layout.id}`,
			modifierBits
		};
		let generated;
		try {
			generated = Windows.generate(canonical, context);
		} catch (error) {
			// The generator states what it cannot write (CAPLOKALTGR, columns) in its message.
			refuse(error.message);
		}
		if (!generated.model.keys.length) refuse('no_exportable_character_keys');
		if (generated.model.omitted.length)
			refuse('unrepresentable_dead_transitions', generated.model.omitted);
		const deadStates = new Set(generated.model.deadKeys.map((dead) => dead.state));
		for (const action of asList(canonical.actions))
			for (const when of asList(action.whens))
				if (when.state !== 'none' && !deadStates.has(when.state))
					refuse('unrepresented_dead_state', { action: action.id, state: when.state });
		const bound = new Set(
			generated.model.keys.flatMap((key) => Object.values(key.cells).map((cell) => cell.action))
		);
		const unbound = asList(canonical.actions).filter(
			(action) =>
				!bound.has(action.id) && asList(action.whens).some((when) => when.state !== 'none')
		);
		if (unbound.length)
			refuse(
				'unbound_stateful_actions',
				unbound.map((action) => action.id)
			);
		const layout = Windows.indexLayout(canonical);
		const emittedKeys = new Set(generated.model.keys.map((key) => key.code));
		for (const key of physical)
			if (!emittedKeys.has(key.code))
				for (const pressed of [['caps'], ['shift', 'caps']]) {
					const cell = Windows.resolveCell(layout, Windows.keyMapIndex(layout, pressed), key.mac);
					if (cell.kind !== 'none')
						refuse('unrepresented_caps_character_key', {
							key: key.code,
							modifiers: pressed,
							source: cell
						});
				}
		const unsupported = [];
		const modifiers = ['shift', 'caps', 'option', 'control', 'command'];
		for (let mask = 0; mask < 32; mask++) {
			if (!(mask & 24)) continue;
			const pressed = modifiers.filter((_, bit) => mask & (1 << bit));
			const index = Windows.keyMapIndex(layout, pressed);
			unsupported.push({
				modifiers: pressed,
				source_map_index: index,
				source_cells: physical
					.map((key) =>
						Object.assign(
							{ key: key.code, code: key.mac },
							Windows.resolveCell(layout, index, key.mac)
						)
					)
					.filter((cell) => cell.kind !== 'none')
			});
		}
		const report = {
			target: 'windows',
			status: 'partial',
			artifact: 'klc',
			reason: 'msklc_character_columns',
			blockers: [],
			omitted: imported.omitted,
			name: metadata.dll_name,
			locale,
			language_lcid: metadata.layout_id.toLowerCase(),
			artifact_version: KLC_ARTIFACT_VERSION,
			columns: generated.model.columns.map((column) => ({
				shift_state: column.klc,
				source_modifiers: column.mac
			})),
			modifier_bits: modifierBits,
			uncompiled_modifiers: unsupported,
			system_keys: [...untouched]
				.sort(([a], [b]) => a - b)
				.map(([code, source_mappings]) => ({ code, source_mappings })),
			character_keys: generated.model.keys.length,
			virtual_keys: generated.model.keys.map((key) => ({
				key: key.code,
				scan_code: key.scanCode,
				virtual_key: key.vk
			})),
			dead_keys: generated.model.deadKeys.length,
			ligatures: generated.model.ligatures.length,
			limitations: [
				'Ctrl and Shift+Ctrl cells are left empty for Windows control-key behavior; source Command mappings are not compiled. Listed combinations retain their source cells for review.',
				'Virtual keys follow the existing generator allocation; source shortcuts are not inferred from the displayed character.',
				...modifierBits.map(
					(bit) =>
						`${bit.modifier} holds the ${bit.bit} bit: ${bit.key} types VK_${bit.vk} and no longer acts as its own key.`
				),
				'Listed system/keypad mappings are not compiled; the KLC generator emits the standard decimal point.',
				'KLC uses a language LCID, not a reserved keyboard-layout ID; locale/LCID association and native Windows loading are not certified.',
				'No DLL or installer is produced. The new KLC artifact starts at version 1.0; the source schema has no release-version field.'
			]
		};
		return {
			report,
			klc: generated.klc,
			files: [
				{ path: `${metadata.dll_name}.klc`, text: generated.klc },
				{ path: 'export.json', text: `${JSON.stringify(report, null, 2)}\n` }
			]
		};
	}

	/**
	 * The MSKLC bytes of a .klc text: UTF-16LE with a byte order mark and CRLF,
	 * byte for byte what the generator's Node encodeKlc writes.
	 * @param {string} text - LF text.
	 * @returns {Uint8Array}
	 */
	function encodeKlc(text) {
		const body = text.replace(/\n/g, '\r\n');
		const bytes = new Uint8Array(2 + body.length * 2);
		bytes[0] = 0xff;
		bytes[1] = 0xfe;
		for (let index = 0; index < body.length; index++) {
			const unit = body.charCodeAt(index);
			bytes[2 + index * 2] = unit & 0xff;
			bytes[3 + index * 2] = unit >> 8;
		}
		return bytes;
	}

	return { TargetExportError, xkbRequest, xkbFiles, klcMetadata, klcExport, encodeKlc };
})();
