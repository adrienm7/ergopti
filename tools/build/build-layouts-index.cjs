// tools/build/build-layouts-index.cjs

/**
 * ==============================================================================
 * MODULE: Keyboard-Layout Registry Index Builder
 * DESCRIPTION:
 * Validates every <id>/meta.toml of the layout registry folder and writes the
 * index.json the drivers download: one entry per layout with its checksum,
 * size, licence and the facts a driver needs to install or emulate it.
 *
 * FEATURES & RATIONALE:
 * 1. One layout = one <id>/<id>.keylayout. The .keylayout is the only source
 *    of a layout; nothing derived from it (xkb files, Windows tables) is
 *    stored here, so this index is the complete catalogue.
 * 2. The folder comes from _shared/modules/layouts/defaults.json, the file the
 *    drivers build their download URLs from, so the tool and the drivers
 *    cannot disagree about where the registry lives.
 * 3. Deterministic output: entries sorted by id, fixed key order, tab-indented
 *    JSON with a trailing LF, so the committed file only changes with the data.
 * 4. Fail fast: an unknown meta key, a missing licence file or an asymmetric
 *    variant list stops the build with every error listed.
 *
 * Usage:
 *   node tools/build/build-layouts-index.cjs          write index.json
 *   node tools/build/build-layouts-index.cjs --check  exit 1 when it drifted
 * ==============================================================================
 */

'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { parse: parseToml } = require('smol-toml');
const { REPO_ROOT, shared } = require('../lib/paths.cjs');




// ================================
// ================================
// ======= 1/ Configuration =======
// ================================
// ================================

const LAYOUT_DEFAULTS = JSON.parse(fs.readFileSync(shared('modules', 'layouts', 'defaults.json'), 'utf8'));
const REGISTRY_DIR = path.join(REPO_ROOT, ...LAYOUT_DEFAULTS.registry.folder.split('/'));
const INDEX_PATH = path.join(REGISTRY_DIR, LAYOUT_DEFAULTS.registry.index_file);

// The repository's own licence: layouts under it are covered by the root
// LICENSE, every other licence must ship its text next to the layout.
const REPOSITORY_LICENCE = 'MIT';
const INDEX_SCHEMA_VERSION = 1;
const PLATFORMS = ['linux', 'macos', 'windows'];
const KEYCODE_CONVENTIONS = ['iso', 'ansi'];

const ID_RE = /^[a-z][a-z0-9_]*$/;
const VERSION_RE = /^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/;
const LANGUAGE_RE = /^[a-z]{2,3}(?:-[A-Z]{2})?$/;
const LICENCE_RE = /^[A-Za-z0-9.+-]+$/;
const SHA256_RE = /^[0-9a-f]{64}$/;

const REQUIRED_KEYS = [
	'name',
	'family',
	'version',
	'author',
	'licence',
	'homepage',
	'languages',
	'variants',
	'source_url',
	'platforms',
	'keycode_convention'
];
const OPTIONAL_KEYS = ['licence_file', 'source_sha256', 'xkb', 'extension_source'];
const XKB_KEYS = ['keysym_overrides', 'base_level_only'];
const KEYSYM_RE = /^[A-Za-z0-9_]+$/;




// =============================
// =============================
// ======= 2/ Validation =======
// =============================
// =============================

function isNonEmptyString(value) {
	return typeof value === 'string' && value.trim().length > 0;
}

function isHttpsUrl(value) {
	if (typeof value !== 'string') return false;
	try {
		return new URL(value).protocol === 'https:';
	} catch {
		return false;
	}
}

function validateUniqueList(errors, id, key, value, predicate, allowEmpty) {
	if (!Array.isArray(value)) {
		errors.push(`${id}: ${key} must be an array`);
		return;
	}
	if (!allowEmpty && value.length === 0) errors.push(`${id}: ${key} must not be empty`);
	if (new Set(value).size !== value.length) errors.push(`${id}: ${key} has duplicates`);
	for (const item of value) {
		if (!predicate(item)) errors.push(`${id}: ${key} has an invalid item ${JSON.stringify(item)}`);
	}
}

/**
 * Validates one meta.toml record.
 * @param {string} id - Registry id (folder name).
 * @param {object} meta - Parsed meta.toml.
 * @param {(name: string) => boolean} fileExists - Whether a file exists in the layout folder.
 * @returns {string[]} Every problem found; empty when the record is valid.
 */
function validateMeta(id, meta, fileExists) {
	const errors = [];
	if (!ID_RE.test(id)) errors.push(`${id}: the folder name is not a registry id (${ID_RE})`);
	for (const key of Object.keys(meta)) {
		if (!REQUIRED_KEYS.includes(key) && !OPTIONAL_KEYS.includes(key)) errors.push(`${id}: unknown key ${key}`);
	}
	for (const key of REQUIRED_KEYS) {
		if (!(key in meta)) errors.push(`${id}: missing key ${key}`);
	}
	for (const key of ['name', 'author']) {
		if (key in meta && !isNonEmptyString(meta[key])) errors.push(`${id}: ${key} must be a non-empty string`);
	}
	// The family groups a layout with its variants; the drivers compare it with
	// registry.ergopti_family of the shared defaults to tell Ergopti layouts apart.
	if ('family' in meta && !(typeof meta.family === 'string' && ID_RE.test(meta.family))) {
		errors.push(`${id}: family must be a registry id (${ID_RE})`);
	}
	if ('version' in meta && !(typeof meta.version === 'string' && VERSION_RE.test(meta.version))) {
		errors.push(`${id}: version must be semantic (x.y.z)`);
	}
	if ('licence' in meta && !(typeof meta.licence === 'string' && LICENCE_RE.test(meta.licence))) {
		errors.push(`${id}: licence must be an SPDX-style identifier`);
	}
	for (const key of ['homepage', 'source_url']) {
		if (key in meta && !isHttpsUrl(meta[key])) errors.push(`${id}: ${key} must be an https URL`);
	}
	if ('languages' in meta) {
		validateUniqueList(errors, id, 'languages', meta.languages, (v) => typeof v === 'string' && LANGUAGE_RE.test(v), false);
	}
	if ('variants' in meta) {
		validateUniqueList(errors, id, 'variants', meta.variants, (v) => typeof v === 'string' && ID_RE.test(v), true);
	}
	if ('platforms' in meta) {
		validateUniqueList(errors, id, 'platforms', meta.platforms, (v) => PLATFORMS.includes(v), false);
	}
	if ('keycode_convention' in meta && !KEYCODE_CONVENTIONS.includes(meta.keycode_convention)) {
		errors.push(`${id}: keycode_convention must be one of ${KEYCODE_CONVENTIONS.join(', ')}`);
	}
	if ('source_sha256' in meta && !(typeof meta.source_sha256 === 'string' && SHA256_RE.test(meta.source_sha256))) {
		errors.push(`${id}: source_sha256 must be 64 lowercase hex digits`);
	}
	if ('extension_source' in meta && !(typeof meta.extension_source === 'string' && ID_RE.test(meta.extension_source))) {
		errors.push(`${id}: extension_source must identify a registry folder`);
	}
	if ('xkb' in meta) validateXkb(errors, id, meta.xkb);
	if ('licence_file' in meta) {
		if (!isNonEmptyString(meta.licence_file) || !fileExists(meta.licence_file)) {
			errors.push(`${id}: licence_file ${JSON.stringify(meta.licence_file)} does not exist`);
		}
	} else if ('licence' in meta && meta.licence !== REPOSITORY_LICENCE) {
		errors.push(`${id}: a ${meta.licence} layout must ship its licence text (licence_file)`);
	}
	return errors;
}

/**
 * The optional [xkb] table: keysym_overrides is an ordered list of
 * [output text, keysym] pairs the Linux converter uses instead of the keysym
 * it would derive (order is kept: the XCompose file lists them in it), and
 * base_level_only lists outputs a key types on its base level only.
 * @param {string[]} errors - Collector.
 * @param {string} id - Registry id.
 * @param {object} xkb - Parsed [xkb] table.
 */
function validateXkb(errors, id, xkb) {
	if (typeof xkb !== 'object' || xkb === null || Array.isArray(xkb)) {
		errors.push(`${id}: xkb must be a table`);
		return;
	}
	for (const key of Object.keys(xkb)) {
		if (!XKB_KEYS.includes(key)) errors.push(`${id}: unknown key xkb.${key}`);
	}
	if ('base_level_only' in xkb) {
		validateUniqueList(errors, id, 'xkb.base_level_only', xkb.base_level_only, isNonEmptyString, false);
	}
	const pairs = xkb.keysym_overrides;
	if (pairs === undefined) return;
	if (!Array.isArray(pairs) || pairs.length === 0) {
		errors.push(`${id}: xkb.keysym_overrides must be a non-empty array of [text, keysym] pairs`);
		return;
	}
	const texts = new Set();
	for (const pair of pairs) {
		const valid =
			Array.isArray(pair) &&
			pair.length === 2 &&
			isNonEmptyString(pair[0]) &&
			typeof pair[1] === 'string' &&
			KEYSYM_RE.test(pair[1]);
		if (!valid) {
			errors.push(`${id}: xkb.keysym_overrides has an invalid pair ${JSON.stringify(pair)}`);
			continue;
		}
		if (texts.has(pair[0])) errors.push(`${id}: xkb.keysym_overrides maps ${JSON.stringify(pair[0])} twice`);
		texts.add(pair[0]);
	}
}

/**
 * Cross-record rules: every variant exists, is not the layout itself, lists
 * this layout back and belongs to the same family.
 * @param {Map<string, object>} metas - Registry id → meta record.
 * @returns {string[]} Every problem found.
 */
function validateRegistry(metas) {
	const errors = [];
	for (const [id, meta] of metas) {
		for (const variant of meta.variants || []) {
			if (variant === id) {
				errors.push(`${id}: lists itself as a variant`);
			} else if (!metas.has(variant)) {
				errors.push(`${id}: variant ${variant} is not a registry layout`);
			} else if (!(metas.get(variant).variants || []).includes(id)) {
				errors.push(`${id}: variant ${variant} does not list ${id} back`);
			} else if (metas.get(variant).family !== meta.family) {
				errors.push(`${id}: variant ${variant} belongs to another family`);
			}
		}
	}
	return errors;
}

/**
 * Structural sanity of a .keylayout: served bytes must equal checked-out bytes
 * (no CR, no BOM) and the document must carry the parts every converter reads.
 * @param {string} id - Registry id.
 * @param {Buffer} bytes - File content.
 * @returns {string[]} Every problem found.
 */
function validateKeylayout(id, bytes) {
	const errors = [];
	if (bytes.includes(0x0d)) errors.push(`${id}: the .keylayout contains CR bytes (store it as LF)`);
	if (bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) errors.push(`${id}: the .keylayout starts with a BOM`);
	const text = bytes.toString('utf8');
	for (const tag of ['<keyboard', '<layouts>', '<modifierMap', '<keyMapSet', '<keyMap ']) {
		if (!text.includes(tag)) errors.push(`${id}: the .keylayout has no ${tag} element`);
	}
	if (keyboardName(text) === null) errors.push(`${id}: the <keyboard> element declares no name`);
	return errors;
}

/**
 * The name the <keyboard> element declares: macOS lists, selects and removes
 * the installed layout under it (the KeyboardLayout Name of the input source).
 * @param {string} text - .keylayout content.
 * @returns {string|null} The name, or null when the element declares none.
 */
function keyboardName(text) {
	const match = /<keyboard\b[^>]*\sname\s*=\s*"([^"]+)"/.exec(text);
	return match ? match[1] : null;
}




// ==========================
// ==========================
// ======= 3/ Building =======
// ==========================
// ==========================

/**
 * Inventories the existing extension format inside one layout folder.
 * The digest identifies immutable content; installing it never stores activation.
 * @param {string} folder - Layout folder.
 * @param {string} id - Registry layout id.
 * @param {object} meta - Layout metadata, including an optional licence file.
 * @returns {object} Extension metadata and verified file descriptors.
 */
function buildExtension(folder, id, meta) {
	const sourceId = meta.extension_source || id;
	if (!ID_RE.test(sourceId)) throw new Error(`${id}: invalid extension source`);
	const sourceFolder = path.join(path.dirname(folder), sourceId);
	const manifestPath = path.join(sourceFolder, 'manifest.toml');
	const manifest = parseToml(fs.readFileSync(manifestPath, 'utf8'));
	const extension = manifest.extension;
	if (!extension || extension.id !== sourceId ||
		!isNonEmptyString(extension.name) || !VERSION_RE.test(extension.version || '')) {
		throw new Error(`${id}: manifest.toml requires an extension id, name and semantic version`);
	}
	const description = extension.description || {};
	if (typeof description !== 'object' || Array.isArray(description) ||
		Object.values(description).some((text) => typeof text !== 'string')) {
		throw new Error(`${id}: invalid extension descriptions in manifest.toml`);
	}
	const relativePaths = ['manifest.toml', `${id}.keylayout`];
	if (meta.licence_file) {
		if (!/^[A-Za-z0-9_-]+(?:\.txt)?$/.test(meta.licence_file)) {
			throw new Error(`${id}: extension licence_file must be a plain text filename`);
		}
		relativePaths.push(meta.licence_file);
	}
	for (const category of ['hotstrings', 'shortcuts']) {
		const directory = path.join(sourceFolder, category);
		if (!fs.existsSync(directory)) continue;
		if (!fs.lstatSync(directory).isDirectory() || fs.lstatSync(directory).isSymbolicLink()) {
			throw new Error(`${id}: ${category} must be a real extension directory`);
		}
		for (const item of fs.readdirSync(directory, { withFileTypes: true })) {
			const supported = category === 'hotstrings'
				? /^[a-z][a-z0-9_-]*\.toml$/.test(item.name)
				: /^menu\.(ahk|lua)$/.test(item.name);
			if (!item.isFile() || !supported) throw new Error(`${id}: unsupported extension file ${category}/${item.name}`);
			relativePaths.push(`${category}/${item.name}`);
		}
	}
	const files = relativePaths.sort().map((relative) => {
		const ownFile = relative === `${id}.keylayout` || relative === meta.licence_file;
		const filename = path.join(ownFile ? folder : sourceFolder, ...relative.split('/'));
		if (!fs.lstatSync(filename).isFile() || fs.lstatSync(filename).isSymbolicLink()) {
			throw new Error(`${id}: extension files must be regular files: ${relative}`);
		}
		const bytes = fs.readFileSync(filename);
		return { path: relative, file: `${ownFile ? id : sourceId}/${relative}`, size: bytes.length,
			sha256: crypto.createHash('sha256').update(bytes).digest('hex') };
	});
	if (files.reduce((sum, file) => sum + file.size, 0) > LAYOUT_DEFAULTS.registry.max_file_bytes) {
		throw new Error(`${id}: extension exceeds the registry download bound`);
	}
	return { id: extension.id, name: extension.name, version: extension.version, description,
		sha256: crypto.createHash('sha256').update(JSON.stringify(files)).digest('hex'), files };
}

/**
 * Reads, validates and indexes the registry folder.
 * @param {string} registryDir - Absolute registry folder.
 * @returns {{index: object, text: string}} The index and its serialised form.
 */
function buildIndex(registryDir) {
	const ids = fs
		.readdirSync(registryDir, { withFileTypes: true })
		.filter((entry) => entry.isDirectory())
		.map((entry) => entry.name)
		.sort();
	const metas = new Map();
	const errors = [];
	const files = new Map();
	const extensions = new Map();
	for (const id of ids) {
		const folder = path.join(registryDir, id);
		const metaPath = path.join(folder, 'meta.toml');
		const layoutPath = path.join(folder, `${id}.keylayout`);
		if (!fs.existsSync(metaPath)) {
			errors.push(`${id}: meta.toml is missing`);
			continue;
		}
		if (!fs.existsSync(layoutPath)) {
			errors.push(`${id}: ${id}.keylayout is missing`);
			continue;
		}
		let meta;
		try {
			meta = parseToml(fs.readFileSync(metaPath, 'utf8'));
		} catch (err) {
			errors.push(`${id}: meta.toml does not parse: ${err.message}`);
			continue;
		}
		errors.push(...validateMeta(id, meta, (name) => fs.existsSync(path.join(folder, name))));
		const bytes = fs.readFileSync(layoutPath);
		errors.push(...validateKeylayout(id, bytes));
		metas.set(id, meta);
		files.set(id, bytes);
		try {
			extensions.set(id, buildExtension(folder, id, meta));
		} catch (err) {
			errors.push(`${id}: ${err.message}`);
		}
	}
	errors.push(...validateRegistry(metas));
	if (ids.length === 0) errors.push('the registry folder holds no layout');
	if (errors.length > 0) {
		throw new Error(`Invalid layout registry:\n  ${errors.join('\n  ')}`);
	}

	const layouts = ids.map((id) => {
		const meta = metas.get(id);
		const bytes = files.get(id);
		const entry = {
			id,
			name: meta.name,
			family: meta.family,
			keyboard_name: keyboardName(bytes.toString('utf8')),
			version: meta.version,
			file: `${id}/${id}.keylayout`,
			sha256: crypto.createHash('sha256').update(bytes).digest('hex'),
			size: bytes.length,
			licence: meta.licence,
			homepage: meta.homepage,
			author: meta.author,
			languages: [...meta.languages],
			variants: [...meta.variants].sort(),
			platforms: [...meta.platforms].sort(),
			keycode_convention: meta.keycode_convention,
			source_url: meta.source_url,
			extension: extensions.get(id)
		};
		if (meta.source_sha256) entry.source_sha256 = meta.source_sha256;
		if (meta.licence_file) entry.licence_file = meta.licence_file;
		if (meta.xkb) {
			entry.xkb = {};
			if (meta.xkb.keysym_overrides) entry.xkb.keysym_overrides = meta.xkb.keysym_overrides.map((pair) => [...pair]);
			if (meta.xkb.base_level_only) entry.xkb.base_level_only = [...meta.xkb.base_level_only];
		}
		return entry;
	});
	const index = {
		_comment:
			'Generated by tools/build/build-layouts-index.cjs from the <id>/meta.toml files of this folder. Do not edit: run npm run build:layouts-index.',
		schema_version: INDEX_SCHEMA_VERSION,
		layouts
	};
	return { index, text: `${JSON.stringify(index, null, '\t')}\n` };
}




// ======================
// ======================
// ======= 4/ CLI =======
// ======================
// ======================

function main() {
	const checkOnly = process.argv.includes('--check');
	const { text } = buildIndex(REGISTRY_DIR);
	const relative = path.relative(REPO_ROOT, INDEX_PATH).replace(/\\/g, '/');
	if (checkOnly) {
		const current = fs.existsSync(INDEX_PATH) ? fs.readFileSync(INDEX_PATH, 'utf8') : '';
		if (current !== text) {
			console.error(`${relative} is out of date: run npm run build:layouts-index`);
			process.exit(1);
		}
		console.log(`${relative} is up to date.`);
		return;
	}
	fs.writeFileSync(INDEX_PATH, text);
	console.log(`Wrote ${relative}.`);
}

if (require.main === module) main();

module.exports = {
	REGISTRY_DIR,
	INDEX_PATH,
	ID_RE,
	buildIndex,
	validateMeta,
	validateRegistry,
	validateKeylayout,
	keyboardName
};
