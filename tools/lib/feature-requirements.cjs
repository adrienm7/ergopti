// tools/lib/feature-requirements.cjs

/**
 * ==============================================================================
 * MODULE: Feature Requirements Derivation
 * DESCRIPTION:
 * Reads what every feature of _shared/modules/features/manifest.toml declares
 * it needs per OS (`requires = { macos = [...], linux = [...], windows = [...] }`)
 * and derives, from the drivers' real inputs, what each feature actually
 * reaches. The closed vocabulary and the per-OS detection rules live in
 * _shared/modules/features/requirements.toml; the macOS Karabiner mapping lives
 * in macos/platform/remap/generator.lua, beside the state fields it maps.
 *
 * FEATURES & RATIONALE:
 * 1. No free text: a requirement is derived from code, never from prose. The
 *    macOS Karabiner use is the union of the generator state fields each
 *    feature feeds (every `state.<field>` the generator reads must be mapped)
 *    and of the modules that reach Karabiner through the injected remap facade
 *    (`_karabiner`, `platform.remap.ke_variables`). Every other requirement is
 *    a source signature (a grab ioctl, a spawned program, an owner module
 *    name) whose every hit is classified as an owner of named features or as
 *    plumbing with a stated reason.
 * 2. Both directions: a feature that reaches a requirement without declaring
 *    it, and a declared requirement nothing reaches, are both errors, each
 *    reported with the owner files that prove the use or the selector that
 *    would have to exist.
 * 3. Injectable sources: derive() takes every input as data, so the gate's
 *    self-test can mutate one input and prove each direction can fail.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { parse: parseToml } = require('smol-toml');

const ROOT = path.resolve(__dirname, '..', '..');
const PLUS = path.join(ROOT, 'static/ergopti_plus');
const MANIFEST_PATH = path.join(PLUS, '_shared/modules/features/manifest.toml');
const VOCABULARY_PATH = path.join(PLUS, '_shared/modules/features/requirements.toml');
const GENERATOR_PATH = path.join(PLUS, 'macos/platform/remap/generator.lua');
const TABLE_PATH = path.join(ROOT, 'docs/design/feature-requirements.md');

// The manifest names drivers by platform id; `requires` names them by OS, as
// a reader of the table does. This is the one place the two meet.
const OS_OF_PLATFORM = Object.freeze({ hs: 'macos', linux: 'linux', ahk: 'windows' });
const OS_ORDER = Object.freeze(['macos', 'linux', 'windows']);
// A feature that declares no platforms at any level is on every driver, as in
// tools/build/build-features-manifest.js.
const ALL_PLATFORMS = Object.freeze(['ahk', 'hs', 'linux']);

const STATE_TABLE = 'REQUIREMENT_STATE_FEATURES';
const FACADE_TABLE = 'REQUIREMENT_FACADE_FEATURES';
const ID_PATTERN = /^[a-z][a-z0-9_]*$/;

// ==================================
// ==================================
// ======= 1/ Source loading =======
// ==================================
// ==================================

/**
 * Rewrites nested `[[features.a.b]]` blocks into one flat array, the same
 * preprocessing tools/build/build-features-manifest.js applies, so nested
 * arrays of tables do not attach to the previous entry.
 * @param {string} raw Manifest source.
 * @returns {object} Parsed manifest.
 */
function parseManifest(raw) {
	const flat = raw.replace(
		/^\[\[features\.([^\]]+)\]\]\r?$/gm,
		(_match, prefix) => `[[entries]]\npath_prefix = "${prefix}"`
	);
	return parseToml(flat);
}

/**
 * Resolves a feature's platforms from the nearest declaring ancestor section.
 * @param {object} sections Parsed `[sections]` tree.
 * @param {string} prefix Feature section path.
 * @returns {string[]|null}
 */
function sectionPlatforms(sections, prefix) {
	let node = sections;
	let found = null;
	for (const part of prefix.split('.')) {
		node = node && typeof node === 'object' ? node[part] : undefined;
		if (node && Array.isArray(node.platforms) && node.platforms.length > 0) found = node.platforms;
	}
	return found;
}

/**
 * Flattens the manifest into features carrying their OS list and declaration.
 * @param {string} raw Manifest source.
 * @returns {Array<{path: string, section: string, oses: string[], requires: object|undefined}>}
 */
function loadFeatures(raw) {
	const parsed = parseManifest(raw);
	if (!Array.isArray(parsed.entries)) throw new Error('manifest.toml has no [[features.*]] entry');
	return parsed.entries.map((entry) => {
		const platforms =
			(Array.isArray(entry.platforms) && entry.platforms.length > 0 && entry.platforms) ||
			sectionPlatforms(parsed.sections || {}, entry.path_prefix) ||
			ALL_PLATFORMS;
		const oses = OS_ORDER.filter((os) =>
			platforms.some((platform) => OS_OF_PLATFORM[platform] === os)
		);
		return {
			path: `${entry.path_prefix}.${entry.id}`,
			section: entry.path_prefix,
			oses,
			requires: entry.requires
		};
	});
}

/**
 * Lists a driver's scanned source files, relative to its root, sorted.
 * @param {object} driver `[drivers.<os>]` table.
 * @returns {string[]}
 */
function listDriverFiles(driver) {
	const root = path.join(PLUS, driver.root);
	const out = [];
	const walk = (dir) => {
		for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
			const abs = path.join(dir, entry.name);
			const rel = path.relative(root, abs).split(path.sep).join('/');
			if (entry.isDirectory()) {
				if (!driver.skip.some((skip) => `${rel}/`.startsWith(skip))) walk(abs);
			} else if (driver.extensions.some((ext) => entry.name.endsWith(ext))) {
				out.push(rel);
			}
		}
	};
	walk(root);
	return out.sort();
}

/**
 * Reads every input derive() needs from the working tree.
 * @returns {object} Sources for derive().
 */
function loadSources() {
	const vocabulary = parseToml(fs.readFileSync(VOCABULARY_PATH, 'utf8'));
	const files = {};
	for (const [os, driver] of Object.entries(vocabulary.drivers || {})) {
		files[os] = {};
		for (const rel of listDriverFiles(driver)) {
			files[os][rel] = fs.readFileSync(path.join(PLUS, driver.root, rel), 'utf8');
		}
	}
	return {
		features: loadFeatures(fs.readFileSync(MANIFEST_PATH, 'utf8')),
		vocabulary,
		generator: fs.readFileSync(GENERATOR_PATH, 'utf8'),
		files
	};
}

// =====================================
// ======= 2/ Comment stripping =======
// =====================================

/**
 * Removes comments while keeping string literals, so a signature that only
 * appears in a comment (the history of a replaced `xdotool key`) is no use.
 * @param {string} src Source text.
 * @param {string} ext File extension.
 * @returns {string}
 */
function stripComments(src, ext) {
	if (ext === '.lua') return stripLuaComments(src);
	if (ext === '.ahk') return stripLineComments(src, ';', /\/\*[\s\S]*?\*\//g);
	if (ext === '.ps1') return stripLineComments(src, '#', /<#[\s\S]*?#>/g);
	throw new Error(`no comment syntax known for ${ext}`);
}

/**
 * Strips Lua `--` and `--[[ ]]` comments outside string literals.
 * @param {string} src Lua source.
 * @returns {string}
 */
function stripLuaComments(src) {
	let out = '';
	let i = 0;
	while (i < src.length) {
		const ch = src[i];
		if (ch === '"' || ch === "'") {
			let j = i + 1;
			while (j < src.length && src[j] !== ch && src[j] !== '\n') j += src[j] === '\\' ? 2 : 1;
			out += src.slice(i, j + 1);
			i = j + 1;
		} else if (ch === '[' && /^\[=*\[/.test(src.slice(i, i + 8))) {
			const level = src.slice(i).match(/^\[(=*)\[/)[1];
			const close = src.indexOf(`]${level}]`, i);
			const end = close < 0 ? src.length : close + level.length + 2;
			out += src.slice(i, end);
			i = end;
		} else if (ch === '-' && src[i + 1] === '-') {
			const block = src.slice(i + 2).match(/^\[(=*)\[/);
			if (block) {
				const close = src.indexOf(`]${block[1]}]`, i);
				i = close < 0 ? src.length : close + block[1].length + 2;
			} else {
				const nl = src.indexOf('\n', i);
				i = nl < 0 ? src.length : nl;
			}
		} else {
			out += ch;
			i += 1;
		}
	}
	return out;
}

/**
 * Strips line comments that start a line or follow whitespace, and blocks.
 * @param {string} src Source text.
 * @param {string} marker Line comment marker.
 * @param {RegExp} block Block comment pattern.
 * @returns {string}
 */
function stripLineComments(src, marker, block) {
	const escaped = marker.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
	const line = new RegExp(`(^|[ \\t])${escaped}.*$`, 'gm');
	return src.replace(block, '').replace(line, '$1');
}

// ==========================================
// ======= 3/ Lua table literal reader =======
// ==========================================

/**
 * Reads the table constructor assigned to `M.<name>` in a Lua source: string
 * values, `name =` and `["key"] =` keys, nested tables. Anything else (a
 * variable, a call) is refused, so the mapping stays data.
 * @param {string} src Lua source.
 * @param {string} name Table name after `M.`.
 * @returns {object|Array}
 */
function readLuaTable(src, name) {
	const code = stripLuaComments(src);
	const anchor = code.match(new RegExp(`^M\\.${name}\\s*=\\s*\\{`, 'm'));
	if (!anchor) throw new Error(`generator.lua defines no M.${name} table`);
	let i = anchor.index + anchor[0].length - 1;
	const skip = () => {
		while (i < code.length && /\s/.test(code[i])) i += 1;
	};
	const readString = () => {
		const quote = code[i];
		let j = i + 1;
		let value = '';
		while (code[j] !== quote) {
			if (j >= code.length || code[j] === '\n') throw new Error(`M.${name}: unterminated string`);
			if (code[j] === '\\') {
				value += code[j + 1];
				j += 2;
			} else {
				value += code[j];
				j += 1;
			}
		}
		i = j + 1;
		return value;
	};
	const readValue = () => {
		skip();
		if (code[i] === '"' || code[i] === "'") return readString();
		if (code[i] === '{') return readTable();
		throw new Error(
			`M.${name}: only strings and tables are allowed, found "${code.slice(i, i + 20)}"`
		);
	};
	const readTable = () => {
		i += 1;
		const list = [];
		const map = {};
		for (;;) {
			skip();
			if (code[i] === '}') {
				i += 1;
				break;
			}
			let key = null;
			const ident = code.slice(i).match(/^([A-Za-z_][A-Za-z0-9_]*)\s*=(?!=)/);
			if (ident) {
				key = ident[1];
				i += ident[0].length;
			} else if (code[i] === '[') {
				i += 1;
				skip();
				key = readString();
				skip();
				if (code[i] !== ']') throw new Error(`M.${name}: expected ] after a key`);
				i += 1;
				skip();
				if (code[i] !== '=') throw new Error(`M.${name}: expected = after [${key}]`);
				i += 1;
			}
			const value = readValue();
			if (key === null) list.push(value);
			else if (Object.prototype.hasOwnProperty.call(map, key)) {
				throw new Error(`M.${name}: duplicate key ${key}`);
			} else map[key] = value;
			skip();
			if (code[i] === ',' || code[i] === ';') i += 1;
		}
		if (list.length > 0 && Object.keys(map).length > 0) {
			throw new Error(`M.${name}: a table mixes list items and keys`);
		}
		return Object.keys(map).length > 0 ? map : list;
	};
	return readTable();
}

// =============================
// ======= 4/ Selectors =======
// =============================

/**
 * Expands one owner's selectors into feature paths available on an OS.
 * `a.b` is one feature, `a.b.*` the features directly in section a.b,
 * `a.b.**` every feature under a.b, and a leading `!` removes a selection.
 * Each selector must select something, so a stale one fails.
 * @param {string[]} selectors Owner selectors.
 * @param {Array} features Features available on the OS.
 * @param {string} where Owner description for errors.
 * @param {string[]} errors Error sink.
 * @returns {Set<string>}
 */
function expandSelectors(selectors, features, where, errors) {
	const selected = new Set();
	if (!Array.isArray(selectors) || selectors.length === 0) {
		errors.push(`${where}: an owner must name at least one feature selector`);
		return selected;
	}
	for (const raw of selectors) {
		const negative = raw.startsWith('!');
		const selector = negative ? raw.slice(1) : raw;
		let matches;
		if (selector.endsWith('.**')) {
			const base = selector.slice(0, -3);
			matches = features.filter((f) => f.section === base || f.section.startsWith(`${base}.`));
		} else if (selector.endsWith('.*')) {
			const base = selector.slice(0, -2);
			matches = features.filter((f) => f.section === base);
		} else {
			matches = features.filter((f) => f.path === selector);
		}
		const paths = matches.map((f) => f.path);
		const effective = negative ? paths.filter((p) => selected.has(p)) : paths;
		if (effective.length === 0) {
			errors.push(`${where}: selector "${raw}" selects no feature available on this OS`);
		}
		for (const p of paths) {
			if (negative) selected.delete(p);
			else selected.add(p);
		}
	}
	return selected;
}

// ===============================
// ======= 5/ Derivation =======
// ===============================

/**
 * Records that `feature` reaches `requirement` on `os` because of `evidence`.
 * @param {Map} derived os -> feature -> requirement -> evidence[].
 */
function addUse(derived, os, feature, requirement, evidence) {
	if (!derived.has(os)) derived.set(os, new Map());
	const byFeature = derived.get(os);
	if (!byFeature.has(feature)) byFeature.set(feature, new Map());
	const byRequirement = byFeature.get(feature);
	if (!byRequirement.has(requirement)) byRequirement.set(requirement, []);
	byRequirement.get(requirement).push(evidence);
}

/**
 * Classifies one hit file against the owners and plumbing of a detection.
 * @returns {{kind: string, key: string}|null}
 */
function classify(file, owners, plumbing, where, errors) {
	const keys = [
		...Object.keys(owners).map((key) => ({ kind: 'owner', key })),
		...Object.keys(plumbing).map((key) => ({ kind: 'plumbing', key }))
	].filter((entry) => file.startsWith(entry.key));
	if (keys.length === 0) {
		errors.push(
			`${where}: ${file} reaches the requirement but is neither an owner nor plumbing — ` +
				'name the features it serves, or why it serves none'
		);
		return null;
	}
	if (keys.length > 1) {
		errors.push(`${where}: ${file} matches several entries (${keys.map((k) => k.key).join(', ')})`);
		return null;
	}
	return keys[0];
}

/**
 * Finds the files of a driver matching a detection's signature.
 * @param {object} detection `[detection.<os>.<id>]` table.
 * @param {object} driverFiles rel -> source.
 * @param {string} where Error prefix.
 * @param {string[]} errors Error sink.
 * @returns {string[]}
 */
function signatureHits(detection, driverFiles, where, errors) {
	const content = (detection.content || []).map((p) => new RegExp(p));
	const fileName = detection.file_name ? new RegExp(detection.file_name) : null;
	if (content.length === 0 && !fileName) {
		errors.push(`${where}: a detection needs content patterns or a file_name pattern`);
		return [];
	}
	const hits = [];
	for (const [rel, src] of Object.entries(driverFiles)) {
		if (fileName && fileName.test(path.posix.basename(rel))) {
			hits.push(rel);
			continue;
		}
		if (content.length === 0) continue;
		const code = stripComments(src, path.posix.extname(rel));
		if (content.some((re) => re.test(code))) hits.push(rel);
	}
	return hits.sort();
}

/**
 * Derives the Karabiner use of macOS features from the generator itself.
 * @returns {void}
 */
function deriveKarabiner(sources, detection, osFeatures, derived, errors) {
	const where = 'macos/karabiner';
	const generatorCode = stripLuaComments(sources.generator);
	const read = new Set(
		[...generatorCode.matchAll(/\bstate\.([a-z_][a-z0-9_]*)/g)].map((m) => m[1])
	);
	let stateMap;
	let facadeMap;
	try {
		stateMap = readLuaTable(sources.generator, STATE_TABLE);
		facadeMap = readLuaTable(sources.generator, FACADE_TABLE);
	} catch (err) {
		errors.push(`${where}: ${err.message}`);
		return;
	}
	for (const field of [...read].sort()) {
		if (!Object.prototype.hasOwnProperty.call(stateMap, field)) {
			errors.push(
				`${where}: the generator reads state.${field} but M.${STATE_TABLE} does not map it ` +
					'to the features it feeds (or give the reason it feeds none)'
			);
		}
	}
	for (const [field, value] of Object.entries(stateMap)) {
		const entry = `${where} M.${STATE_TABLE}.${field}`;
		if (!read.has(field)) errors.push(`${entry}: the generator never reads state.${field}`);
		if (!Array.isArray(value)) {
			if (typeof value.why !== 'string' || value.why.length === 0) {
				errors.push(`${entry}: a field that feeds no feature states { why = "..." }`);
			}
			continue;
		}
		for (const feature of expandSelectors(value, osFeatures, entry, errors)) {
			addUse(derived, 'macos', feature, 'karabiner', `generator state.${field}`);
		}
	}
	const hits = signatureHits(detection, sources.files.macos || {}, where, errors);
	for (const file of hits) {
		if (!Object.prototype.hasOwnProperty.call(facadeMap, file)) {
			errors.push(
				`${where}: ${file} calls the remap facade (_karabiner / ke_variables) but ` +
					`M.${FACADE_TABLE} does not list it`
			);
		}
	}
	for (const [file, value] of Object.entries(facadeMap)) {
		const entry = `${where} M.${FACADE_TABLE}["${file}"]`;
		if (!hits.includes(file)) errors.push(`${entry}: the file does not call the remap facade`);
		if (!Array.isArray(value)) {
			if (typeof value.why !== 'string' || value.why.length === 0) {
				errors.push(`${entry}: a caller that serves no feature states { why = "..." }`);
			}
			continue;
		}
		for (const feature of expandSelectors(value, osFeatures, entry, errors)) {
			addUse(derived, 'macos', feature, 'karabiner', `facade ${file}`);
		}
	}
}

/**
 * Derives one signature-based requirement on one OS.
 * @returns {void}
 */
function deriveSignature(os, id, detection, sources, osFeatures, derived, errors) {
	const where = `${os}/${id}`;
	const owners = detection.owners || {};
	const plumbing = detection.plumbing || {};
	const hits = signatureHits(detection, sources.files[os] || {}, where, errors);
	const used = new Set();
	for (const file of hits) {
		const entry = classify(file, owners, plumbing, where, errors);
		if (!entry) continue;
		used.add(`${entry.kind}:${entry.key}`);
		if (entry.kind !== 'owner') continue;
		const features = expandSelectors(
			owners[entry.key],
			osFeatures,
			`${where} owner ${entry.key}`,
			errors
		);
		for (const feature of features) addUse(derived, os, feature, id, file);
	}
	for (const [kind, table] of [
		['owner', owners],
		['plumbing', plumbing]
	]) {
		for (const [key, value] of Object.entries(table)) {
			if (!used.has(`${kind}:${key}`)) {
				errors.push(`${where}: ${kind} "${key}" matches no file reaching the requirement`);
			}
			if (kind === 'plumbing' && (typeof value !== 'string' || value.length === 0)) {
				errors.push(`${where}: plumbing "${key}" must state its reason`);
			}
		}
	}
}

/**
 * Validates the vocabulary and returns the requirement ids per OS.
 * @returns {Map<string, string[]>}
 */
function vocabularyByOs(vocabulary, errors) {
	const ids = Object.keys(vocabulary.requirements || {});
	if (ids.length === 0) errors.push('requirements.toml declares no [requirements.<id>]');
	for (const id of ids) {
		const req = vocabulary.requirements[id];
		if (!ID_PATTERN.test(id)) errors.push(`requirement id "${id}" is not lower snake case`);
		for (const field of ['kind', 'summary']) {
			if (typeof req[field] !== 'string' || req[field].length === 0) {
				errors.push(`requirement ${id} has no ${field}`);
			}
		}
	}
	const byOs = new Map();
	for (const os of OS_ORDER) {
		const detections = (vocabulary.detection || {})[os] || {};
		for (const id of Object.keys(detections)) {
			if (!ids.includes(id)) errors.push(`[detection.${os}.${id}] names no [requirements.${id}]`);
		}
		byOs.set(
			os,
			ids.filter((id) => Object.prototype.hasOwnProperty.call(detections, id))
		);
		if (!vocabulary.drivers || !vocabulary.drivers[os])
			errors.push(`requirements.toml has no [drivers.${os}]`);
	}
	for (const id of ids) {
		if (!OS_ORDER.some((os) => byOs.get(os).includes(id))) {
			errors.push(`requirement ${id} has no [detection.<os>.${id}]: no OS can derive it`);
		}
	}
	return byOs;
}

/**
 * Derives every feature's requirements and compares them with the manifest.
 * @param {object} sources From loadSources(), possibly mutated by a test.
 * @returns {{errors: string[], derived: Map, byOs: Map, features: Array}}
 */
function derive(sources) {
	const errors = [];
	const byOs = vocabularyByOs(sources.vocabulary, errors);
	const derived = new Map();
	for (const os of OS_ORDER) {
		const osFeatures = sources.features.filter((f) => f.oses.includes(os));
		for (const id of byOs.get(os)) {
			const detection = sources.vocabulary.detection[os][id];
			if (detection.source === 'karabiner_generator') {
				if (os !== 'macos') errors.push(`${os}/${id}: the Karabiner generator is macOS only`);
				else deriveKarabiner(sources, detection, osFeatures, derived, errors);
			} else if (detection.source !== undefined) {
				errors.push(`${os}/${id}: unknown source "${detection.source}"`);
			} else {
				deriveSignature(os, id, detection, sources, osFeatures, derived, errors);
			}
		}
	}
	compare(sources.features, byOs, derived, errors);
	return { errors, derived, byOs, features: sources.features };
}

/**
 * Compares the declarations with the derivation, in both directions.
 * @returns {void}
 */
function compare(features, byOs, derived, errors) {
	for (const feature of features) {
		const declared = feature.requires;
		if (
			declared === undefined ||
			declared === null ||
			typeof declared !== 'object' ||
			Array.isArray(declared)
		) {
			errors.push(
				`${feature.path}: declares no requires = { ${feature.oses.map((os) => `${os} = [...]`).join(', ')} }`
			);
			continue;
		}
		for (const os of Object.keys(declared)) {
			if (!feature.oses.includes(os)) {
				errors.push(
					`${feature.path}: requires.${os} is declared but the feature is not available on ${os} ` +
						'(its platforms and reason_key say so)'
				);
			}
		}
		for (const os of feature.oses) {
			const list = declared[os];
			if (!Array.isArray(list)) {
				errors.push(
					`${feature.path}: requires.${os} is missing (an empty list means nothing external)`
				);
				continue;
			}
			const allowed = byOs.get(os);
			const sorted = [...list].sort();
			if (list.join('|') !== sorted.join('|') || new Set(list).size !== list.length) {
				errors.push(`${feature.path}: requires.${os} must be sorted and without duplicates`);
			}
			for (const id of list) {
				if (!allowed.includes(id)) {
					errors.push(
						`${feature.path}: requires.${os} names "${id}", outside the ${os} vocabulary (${allowed.join(', ')})`
					);
				}
			}
			const uses = (derived.get(os) && derived.get(os).get(feature.path)) || new Map();
			for (const [id, evidence] of uses) {
				if (!list.includes(id)) {
					errors.push(
						`${feature.path}: reaches ${id} on ${os} without declaring it — ` +
							`evidence: ${[...new Set(evidence)].join('; ')}`
					);
				}
			}
			for (const id of list) {
				if (allowed.includes(id) && !uses.has(id)) {
					errors.push(
						`${feature.path}: declares ${id} on ${os} but nothing derived reaches it — ` +
							`add an owner selector in requirements.toml${id === 'karabiner' ? ' or generator.lua' : ''}, or drop it`
					);
				}
			}
		}
	}
}

/**
 * The derived requirements of one feature on one OS, sorted.
 * @returns {string[]}
 */
function derivedList(derived, os, featurePath) {
	const uses = derived.get(os) && derived.get(os).get(featurePath);
	return uses ? [...uses.keys()].sort() : [];
}

// =================================
// ======= 6/ Table rendering =======
// =================================

/**
 * Formats rows as a Markdown table with padded columns, the layout Prettier
 * gives one, so the generated file stays stable under the repository format.
 * @param {string[]} header Column titles.
 * @param {string[][]} rows Cells.
 * @returns {string[]}
 */
function markdownTable(header, rows) {
	const widths = header.map((title, col) =>
		Math.max(3, title.length, ...rows.map((row) => row[col].length))
	);
	const line = (cells) => `| ${cells.map((c, col) => c.padEnd(widths[col])).join(' | ')} |`;
	return [line(header), line(widths.map((w) => '-'.repeat(w))), ...rows.map(line)];
}

/**
 * Renders docs/design/feature-requirements.md from the declarations.
 * @param {object} sources From loadSources().
 * @returns {string}
 */
function renderTable(sources) {
	const { vocabulary, features } = sources;
	const ids = Object.keys(vocabulary.requirements);
	const cell = (feature, os) => {
		if (!feature.oses.includes(os)) return 'n/a';
		const list = (feature.requires && feature.requires[os]) || [];
		return list.length === 0 ? '—' : list.map((id) => `\`${id}\``).join(', ');
	};
	const vocabularyRows = ids.map((id) => {
		const req = vocabulary.requirements[id];
		const oses = OS_ORDER.filter((os) => ((vocabulary.detection || {})[os] || {})[id]);
		return [`\`${id}\``, req.kind, oses.join(', '), req.summary];
	});
	const featureRows = features.map((feature) => [
		`\`${feature.path}\``,
		...OS_ORDER.map((os) => cell(feature, os))
	]);
	return [
		'<!-- docs/design/feature-requirements.md -->',
		'<!-- Generated by tools/codegen/codegen-feature-requirements.cjs; do not edit. -->',
		'',
		'# Feature requirements per OS',
		'',
		'What each feature of `_shared/modules/features/manifest.toml` needs outside',
		'the driver itself, per OS. The declarations are the `requires` field of each',
		'feature; `tools/test/test-feature-requirements.cjs` derives the same table from',
		'the drivers (the macOS Karabiner generator state fields and remap facade',
		'callers, and the source signatures of `requirements.toml`) and fails when the',
		'two disagree in either direction.',
		'',
		'`—` means nothing external; `n/a` means the feature is not on that OS (its',
		'`platforms` and `reason_key` say why).',
		'',
		'## Vocabulary',
		'',
		...markdownTable(['Requirement', 'Kind', 'OS', 'What it is'], vocabularyRows),
		'',
		'## Features',
		'',
		...markdownTable(['Feature', 'macOS', 'Linux', 'Windows'], featureRows),
		''
	].join('\n');
}

module.exports = {
	OS_ORDER,
	TABLE_PATH,
	derive,
	derivedList,
	expandSelectors,
	loadFeatures,
	loadSources,
	readLuaTable,
	renderTable,
	stripComments
};
