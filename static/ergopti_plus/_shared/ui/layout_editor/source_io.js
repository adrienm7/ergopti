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
 *    format owner. Editing it is an explicit conversion (convertImport) that
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

	/** The compiler's key tables (generated from their owners: _generated/key_tables.js). */
	function tables() {
		return LAYOUT_SOURCE_TABLES;
	}

	/** A target the page cannot produce, with the compiler's refusal. */
	function refusedRow(target, artifact, error) {
		const code = error && typeof error.code === 'string' ? error.code : 'compile_refused';
		const detail =
			error && typeof error.path === 'string' ? error.path : String(error && error.message);
		return { target, status: 'unavailable', artifact, reason: code, blockers: [detail] };
	}

	/**
	 * Per-target support: the format owner's report, with the compiler's own
	 * macOS and driver rows for a structured source, as tools/lib/layout-source-report.cjs
	 * builds them. The Linux XKB and Windows KLC rows stay the format owner's
	 * until a download runs their converters (xkbArchive, klcFile).
	 */
	function capabilities(doc) {
		const report = LayoutSource.capabilities(doc);
		if (isPreserved(doc)) return report;
		const set = (row) => {
			report[report.findIndex((entry) => entry.target === row.target)] = row;
		};
		try {
			set(LayoutSourceCompiler.exportMacos(doc, tables()).report);
		} catch (error) {
			set(refusedRow('macos', 'bundle', error));
		}
		for (const [target, platform] of [
			['driver_macos', 'macos'],
			['driver_linux', 'linux']
		]) {
			try {
				const compiled = LayoutSourceCompiler.targetKeylayout(doc, tables(), platform);
				set({
					target,
					status: compiled.omitted.length ? 'partial' : 'emulated',
					artifact: 'emulation',
					reason: 'compiled_keylayout_installed_by_composer_host',
					blockers: [],
					omitted: compiled.omitted
				});
			} catch (error) {
				set(refusedRow(target, 'emulation', error));
			}
		}
		return report;
	}

	/**
	 * One .keylayout of a macOS variant: the preserved XML when it is that
	 * variant, else the compilation of the structured source.
	 * @param {object} doc
	 * @param {'iso'|'ansi'} variant
	 * @returns {{filename: string, text: string}}
	 */
	function keylayoutFile(doc, variant) {
		if (isPreserved(doc)) {
			if (doc.imported_keylayout.convention !== variant)
				throw new SourceIOError('source_export_unavailable', 'physical.base');
			return { filename: `${doc.layout.id}.keylayout`, text: exportKeylayout(doc) };
		}
		const [file] = LayoutSourceCompiler.exportMacos(doc, tables(), variant).files;
		return { filename: file.path, text: file.text };
	}

	/**
	 * The macOS bundle (ISO and ANSI .keylayout, plists, UTF-16 strings) of a
	 * structured source as one stored ZIP archive the browser downloads.
	 * @param {object} doc
	 * @returns {{filename: string, bytes: Uint8Array}}
	 */
	function macosBundleArchive(doc) {
		if (isPreserved(doc))
			throw new SourceIOError('source_export_unavailable', 'imported_keylayout');
		const { files } = LayoutSourceCompiler.exportMacos(doc, tables(), 'bundle');
		const root = files[0].path.split('/')[0];
		return { filename: `${root}.zip`, bytes: LayoutZipWriter.pack(files) };
	}

	/**
	 * Runs a target export step, its refusal turned into this module's error.
	 * @param {function(): *} step
	 */
	function targetStep(step) {
		try {
			return step();
		} catch (error) {
			if (error && error.name === 'TargetExportError')
				throw new SourceIOError('target_export_refused', error.message);
			throw error;
		}
	}

	/**
	 * The Linux XKB files of a source as one stored ZIP archive, written by the
	 * shared target export and the shared Lua converter the repository tool
	 * runs (`export-xkb`), so the files are byte for byte the tool's.
	 * @param {object} doc
	 * @param {{lua: {call: function}, keysyms: object, template: string, types: string}} assets
	 *   A LayoutLuaRunner and key_sym.json, xkb_symbols.txt, xkb_types.txt.
	 * @returns {{filename: string, bytes: Uint8Array, files: {path: string, text: string}[], report: object}}
	 */
	function xkbArchive(doc, assets) {
		const target = targetStep(() => LayoutTargetCompiler.target(doc, tables(), 'linux'));
		const request = targetStep(() =>
			LayoutTargetExport.xkbRequest(doc, target, {
				keycodes: tables().macKeycodes,
				keysyms: assets.keysyms,
				template: assets.template,
				types: assets.types
			})
		);
		const output = assets.lua.call('xkb', request.input);
		const { report, files } = targetStep(() =>
			LayoutTargetExport.xkbFiles(target, request, output)
		);
		const root = `${request.id}_xkb`;
		return {
			filename: `${root}.zip`,
			bytes: LayoutZipWriter.pack(
				files.map((file) => ({ path: `${root}/${file.path}`, text: file.text, encoding: 'utf8' }))
			),
			files,
			report
		};
	}

	/**
	 * The Windows .klc of a source in MSKLC bytes (UTF-16LE, BOM, CRLF), written
	 * by the shared target export with the repository tool's KLC generator
	 * (`export-klc`), so the bytes are the tool's.
	 * @param {object} doc
	 * @param {{lua: {call: function}, generator: object}} assets
	 *   A LayoutLuaRunner and LayoutKlcGenerator.
	 * @returns {{filename: string, bytes: Uint8Array, report: object}}
	 */
	function klcFile(doc, assets) {
		const target = targetStep(() => LayoutTargetCompiler.target(doc, tables(), 'windows'));
		const metadata = targetStep(() => LayoutTargetExport.klcMetadata(doc));
		// A structured source compiles straight to the canonical form; a preserved
		// import's XML is read by the shared Lua reader.
		let canonical = target.canonical;
		if (!canonical) {
			const read = assets.lua.call('read', { xml: target.text });
			if (!read.ok) throw new SourceIOError('target_export_refused', read.reason);
			canonical = read.canonical;
		}
		const exported = targetStep(() =>
			LayoutTargetExport.klcExport(
				doc,
				target,
				canonical,
				{ keycodes: tables().macKeycodes, physicalKeys: tables().physicalKeys },
				assets.generator
			)
		);
		return {
			filename: `${metadata.dll_name}.klc`,
			bytes: LayoutTargetExport.encodeKlc(exported.klc),
			report: exported.report
		};
	}

	/**
	 * The macOS download the export drop-down chooses (`exports.macos.format`,
	 * `bundle` by default): the bundle as one ZIP, or the single .keylayout of
	 * ISO or ANSI, zipped only when an icon file travels beside it. A preserved
	 * import downloads unchanged, as its own variant only.
	 * @param {object} doc
	 * @param {'bundle'|'iso'|'ansi'} [format] - Defaults to the source's choice.
	 * @returns {{filename: string, mime: string, text?: string, bytes?: Uint8Array}}
	 */
	function macosDownload(doc, format) {
		if (isPreserved(doc)) {
			const variant = format || doc.imported_keylayout.convention;
			if (variant === 'bundle')
				throw new SourceIOError('source_export_unavailable', 'imported_keylayout');
			const file = keylayoutFile(doc, variant);
			return { filename: file.filename, mime: 'application/xml', text: file.text };
		}
		const { files } = LayoutSourceCompiler.exportMacos(doc, tables(), format);
		if (files.length === 1 && files[0].encoding === 'utf8')
			return { filename: files[0].path, mime: 'application/xml', text: files[0].text };
		const root = files[0].path.split('/')[0].replace(/\.keylayout$/, '');
		return { filename: `${root}.zip`, mime: 'application/zip', bytes: LayoutZipWriter.pack(files) };
	}

	/** Base64 of bytes, for the host message that carries the DLL images. */
	function base64(bytes) {
		const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
		let out = '';
		for (let i = 0; i < bytes.length; i += 3) {
			const n = (bytes[i] << 16) | ((bytes[i + 1] || 0) << 8) | (bytes[i + 2] || 0);
			out += alphabet[(n >> 18) & 63] + alphabet[(n >> 12) & 63];
			out += i + 1 < bytes.length ? alphabet[(n >> 6) & 63] : '=';
			out += i + 2 < bytes.length ? alphabet[n & 63] : '=';
		}
		return out;
	}

	/**
	 * The four Windows keyboard layout DLL images of a structured source (x86,
	 * wow64, x64, arm64), written in the page by the repository tool's own
	 * compiler-free writer (_generated/kbd_dll_writer.js, from tools/lib/kbd-dll),
	 * with what the Windows tables cannot hold.
	 * @param {object} doc
	 * @returns {{dllName: string, dlls: Object<string, Uint8Array>, omitted: {path: string, reason: string}[]}}
	 */
	function windowsDlls(doc) {
		if (isPreserved(doc)) throw new SourceIOError('source_preserved', 'imported_keylayout');
		if (typeof LayoutKbdDll === 'undefined')
			throw new SourceIOError('kbd_dll_writer_missing', '_generated/kbd_dll_writer.js');
		let converted;
		try {
			converted = LayoutKbdDll.fromSource(doc, { physicalKeys: tables().physicalKeys });
		} catch (error) {
			if (!error || typeof error.code !== 'string') throw error;
			throw new SourceIOError(error.code, error.path || 'exports.windows');
		}
		return {
			dllName: converted.model.dll_name,
			dlls: LayoutKbdDll.writeDlls(converted.model),
			omitted: converted.omitted
		};
	}

	/**
	 * The Windows DLL download: one stored ZIP with <dll>/<arch>/<dll>.dll for the
	 * four images and <dll>/omitted.json listing what the tables leave out.
	 * @param {object} doc
	 * @returns {{filename: string, bytes: Uint8Array}}
	 */
	function windowsDllArchive(doc) {
		const built = windowsDlls(doc);
		const files = Object.entries(built.dlls).map(([arch, bytes]) => ({
			path: `${built.dllName}/${arch}/${built.dllName}.dll`,
			bytes
		}));
		files.push({
			path: `${built.dllName}/omitted.json`,
			text: `${JSON.stringify(built.omitted, null, 2)}\n`,
			encoding: 'utf8'
		});
		return { filename: `${built.dllName}-dll.zip`, bytes: LayoutZipWriter.pack(files) };
	}

	// The native images a host installs beside the .keylayout, by platform: the
	// Windows host registers the DLLs (the .keylayout serves its emulation).
	const NATIVE_IMAGES = Object.freeze({
		windows: (doc) => {
			const built = windowsDlls(doc);
			return {
				dll_name: built.dllName,
				dlls: Object.fromEntries(
					Object.entries(built.dlls).map(([arch, bytes]) => [arch, base64(bytes)])
				)
			};
		}
	});

	/**
	 * What the ErgoptiPlus composer host installs: the TOML, the .keylayout
	 * compiled for the host's OS and, for a structured source, the emulation
	 * table of that OS (composer_save with `source` and `emulation`,
	 * composer.lua), which the driver performs for what the .keylayout cannot
	 * hold (custom modifiers, tap-holds, shortcuts). A preserved import has none.
	 * @param {object} doc
	 * On Windows it also carries the four DLL images (base64 per architecture,
	 * `dll_name`), which the host registers through its elevated helper.
	 * @param {'macos'|'linux'|'windows'} platform
	 * @returns {{source: string, keylayout: string, emulation?: string, dll_name?: string,
	 *   dlls?: Object<string, string>}}
	 */
	function installPayload(doc, platform) {
		const compiled = LayoutSourceCompiler.targetKeylayout(doc, tables(), platform);
		const payload = { source: serialize(doc), keylayout: compiled.text };
		if (!isPreserved(doc)) payload.emulation = JSON.stringify(emulationTable(doc, platform));
		const images = NATIVE_IMAGES[platform];
		if (images) Object.assign(payload, images(doc));
		return payload;
	}

	/**
	 * The emulation table of a structured source for one OS: what the drivers
	 * and the page preview perform on top of the compiled .keylayout.
	 * @param {object} doc
	 * @param {'macos'|'linux'|'windows'} platform
	 * @returns {object}
	 */
	function emulationTable(doc, platform) {
		return LayoutSourceCompiler.compileEmulation(doc, tables(), { platform });
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
	 * Converts a preserved import into structured records through the shared
	 * compiler's importer, which compiles back to the same behaviour and refuses
	 * what the records cannot hold. Only the original bytes are lost.
	 * @param {object} doc - A preserved document.
	 * @returns {{doc: object, lost: string[]}}
	 */
	function convertImport(doc) {
		if (!isPreserved(doc)) throw new SourceIOError('source_not_imported', 'imported_keylayout');
		const { text, convention } = doc.imported_keylayout;
		const structured = LayoutSourceCompiler.importStructured(
			text,
			doc.layout.id,
			convention,
			tables()
		);
		return { doc: structured, lost: ['keylayout_original_xml'] };
	}

	/**
	 * Converts a preserved import the importer refuses, approximately, through
	 * the composer reader: five character levels, dead keys with chaining and
	 * terminators. The page offers it only after that refusal, with this list.
	 * @param {object} doc - A preserved document.
	 * @returns {{doc: object, lost: string[]}} The editable source and what the
	 *   projection cannot hold (stable codes the page translates).
	 */
	/**
	 * The keys of one composer level and the dead keys they reach, from a
	 * composer source (a parsed .keylayout or a built-in reference). Dead-key
	 * ids are prefixed so several sources never collide.
	 * @param {object} parsed - LayoutComposer.parseSource / referenceSource output.
	 * @param {string[]} levels - Composer levels (base, shift, altgr, shift_altgr, command).
	 * @param {string} prefix - Dead-key id prefix.
	 * @returns {{keys: object[], deadKeys: object[]}} keys[i] is the table of levels[i].
	 */
	function composerLevels(parsed, levels, prefix) {
		const stateIds = new Map();
		const deadId = (state) => {
			if (!stateIds.has(state))
				stateIds.set(state, `${prefix}${identifierFrom(state, 's')}_${stateIds.size + 1}`);
			return stateIds.get(state);
		};
		const keys = levels.map((level) => {
			const table = {};
			for (const [code, cells] of Object.entries(parsed.cells)) {
				const cell = cells[level];
				if (!cell) continue;
				if (own(cell, 'text')) table[code] = { text: cell.text };
				else table[code] = { dead_key: deadId(parsed.actions[cell.dead.action].none.next) };
			}
			return table;
		});
		// Chained states reached only through another dead key still need a record.
		const queue = [...stateIds.keys()];
		for (let index = 0; index < queue.length; index++)
			for (const rule of Object.values(parsed.compositions[queue[index]] || {}))
				if (rule.next && !stateIds.has(rule.next)) {
					deadId(rule.next);
					queue.push(rule.next);
				}
		const deadKeys = [];
		for (const [state, id] of stateIds) {
			const rules = Object.entries(parsed.compositions[state] || {}).map(([input, rule]) =>
				rule.next ? { input, next: deadId(rule.next) } : { input, text: rule.output }
			);
			deadKeys.push({ id, name: state, terminator: parsed.terminators[state] || '', rules });
		}
		return { keys, deadKeys };
	}

	/** The five character levels of a composer source as source layers and dead keys. */
	function projectedLayers(parsed) {
		const converted = composerLevels(
			parsed,
			PROJECTED_LAYERS.map((level) => level.composer),
			DEAD_KEY_PREFIX
		);
		const layers = PROJECTED_LAYERS.map((level, index) => ({
			id: level.id,
			required: level.required.slice(),
			optional: [],
			keys: converted.keys[index]
		}));
		return { layers, deadKeys: converted.deadKeys };
	}

	function approximateImport(doc) {
		if (!isPreserved(doc)) throw new SourceIOError('source_not_imported', 'imported_keylayout');
		const { text, convention } = doc.imported_keylayout;
		const parsed = LayoutComposer.parseSource(
			doc.layout.id,
			text,
			convention,
			LAYOUT_COMPOSER_DATA
		);
		const converted = projectedLayers(parsed);
		const layers = converted.layers;
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
		if (converted.deadKeys.length) editable.dead_keys = converted.deadKeys;
		for (const field of ['modifiers', 'keys', 'remap', 'shortcuts', 'windows', 'exports'])
			if (own(doc, field)) editable[field] = copy(doc[field]);
		LayoutSource.validate(editable);
		return { doc: editable, lost };
	}

	/**
	 * A new editable source that starts as another layout: a registry layout
	 * through the generator's exact importer, else (the importer refuses it, or
	 * a built-in reference with no .keylayout) its five character levels.
	 * @param {{id: string, name: string, parsed: object, text?: string, convention?: string}} entry
	 *   One of fillSources.
	 * @param {string} id - The new layout's identifier.
	 * @param {string} name - Its displayed name.
	 * @returns {{doc: object, lost: string[]}} What the copy could not hold (stable codes).
	 */
	function startFrom(entry, id, name) {
		if (typeof entry.text === 'string') {
			try {
				const exact = convertImport(importKeylayout(entry.text, id, entry.convention)).doc;
				exact.layout = Object.assign({}, exact.layout, { id, name });
				return { doc: LayoutSource.validate(exact), lost: [] };
			} catch (error) {
				if (!(error instanceof LayoutSource.SourceError)) throw error;
			}
		}
		const doc = create(id, name);
		const converted = projectedLayers(entry.parsed);
		doc.layers = converted.layers;
		if (converted.deadKeys.length) doc.dead_keys = converted.deadKeys;
		const lost = typeof entry.text === 'string' ? ['keylayout_sided_modifiers'] : [];
		if (entry.convention === 'ansi') lost.push('keylayout_ansi_projected_iso');
		if (entry.parsed.ambiguous && entry.parsed.ambiguous.size > 0)
			lost.push('keylayout_ambiguous_compositions');
		return { doc: LayoutSource.validate(doc), lost };
	}

	/**
	 * The layouts a layer can be filled from: the built-in references (QWERTY,
	 * AZERTY) and the registry layouts a host supplies as {id, name, convention, text}.
	 * @param {object[]} supplied
	 * @returns {{id: string, name: string, parsed: object}[]} Unreadable ones are left out.
	 */
	function fillSources(supplied) {
		const sources = Object.entries(LAYOUT_COMPOSER_REFERENCE).map(([id, reference]) => ({
			id,
			name: reference.name,
			parsed: LayoutComposer.referenceSource(id, reference)
		}));
		for (const entry of supplied || []) {
			try {
				sources.push({
					id: entry.id,
					name: entry.name,
					text: entry.text,
					convention: entry.convention,
					parsed: LayoutComposer.parseSource(
						entry.id,
						entry.text,
						entry.convention,
						LAYOUT_COMPOSER_DATA
					)
				});
			} catch (error) {
				if (!(error instanceof LayoutComposer.ComposerError)) throw error;
			}
		}
		return sources;
	}

	/**
	 * The composer's job inside the editor: replaces one layer's keys with one
	 * level of another layout, and brings that level's dead keys along.
	 * @param {object} doc - An editable source.
	 * @param {{id: string, parsed: object}} source - From fillSources.
	 * @param {string} level - base, shift, altgr, shift_altgr or command.
	 * @param {string} layerId - The layer to fill.
	 */
	function fillLayer(doc, source, level, layerId) {
		if (isPreserved(doc)) throw new SourceIOError('source_preserved', 'imported_keylayout');
		const prefix = `${identifierFrom(source.id, 'l')}_${level}_`;
		const filled = composerLevels(source.parsed, [level], prefix);
		const next = copy(doc);
		const layer = (next.layers || []).find((entry) => entry.id === layerId);
		if (!layer) throw new SourceIOError('layer_unknown', `layers.${layerId}`);
		layer.keys = filled.keys[0];
		const ids = new Set(filled.deadKeys.map((entry) => entry.id));
		next.dead_keys = (next.dead_keys || [])
			.filter((entry) => !ids.has(entry.id))
			.concat(filled.deadKeys);
		if (next.dead_keys.length === 0) delete next.dead_keys;
		return LayoutSource.validate(next);
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
		convertImport,
		approximateImport,
		fillSources,
		startFrom,
		windowsDlls,
		windowsDllArchive,
		fillLayer,
		keylayoutFile,
		macosBundleArchive,
		macosDownload,
		xkbArchive,
		klcFile,
		installPayload,
		emulationTable,
		withNavLayer,
		navLayerFile
	};
})();
