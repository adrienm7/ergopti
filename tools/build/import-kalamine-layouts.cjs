// tools/build/import-kalamine-layouts.cjs

/**
 * ==============================================================================
 * MODULE: Kalamine Layout Import
 * DESCRIPTION:
 * Re-encodes the Kalamine layouts of the Ergo-L family into the layout
 * library of the layout analysis
 * (_shared/layouts/data/analysis/layout_library.json): the keymaps of
 * Nuclear-Squid/ergol (WTFPL) and the earlier Ergo-L versions its history
 * keeps, and the Erglace, Ergaie and Colemak French Touch versions their
 * authors' repositories publish. Each file is read at a pinned commit and
 * checked against its SHA-256.
 * USAGE: node tools/build/import-kalamine-layouts.cjs <folder of checkouts>
 *   [--check], the folder holding a full clone of each repository of
 *   REPOSITORIES under its key (`git clone <url> <folder>/<key>`); then
 *   `node tools/lint/format.cjs --write` (the library) and
 *   `node tools/codegen/codegen-layout-analysis-data-js.cjs`. With --check it
 *   writes nothing and fails when the library differs from the files. A
 *   source written as TOML is built to Kalamine JSON with `kalamine build`
 *   (Kalamine 0.40 on the PATH, or the KALAMINE variable), the command the
 *   Ergo-L repository's Makefile builds its own JSON with.
 *
 * FEATURES & RATIONALE:
 * 1. One reader: each JSON goes through the Studio's own reader
 *    (layout_formats.js fromKalamineJson), so the library holds what a user
 *    importing the same file gets. Only the arrangement is kept, never a file
 *    (docs/memory/maintainer-decisions.md, « Layout library »).
 * 2. Kalamine checked first: before it builds a TOML, the run builds the
 *    Ergo-L repository's own erglace_jf.toml and compares the result with the
 *    JSON that repository commits; another Kalamine fails the run instead of
 *    re-encoding other arrangements.
 * 3. Every dead key, chains included: a dead key's rules that Unicode
 *    normalisation gives anyway are left to the codegen (composeAccent); a
 *    rule entering another state (Ergo-L's 1DK typed twice, then e → ë) is
 *    kept with that state's whole table, which no cell composes.
 * 4. One entry per arrangement: a version with the same letters on the same
 *    keys and the same digits as a later one is listed in `not_imported`
 *    (DUPLICATES), the later version holding the arrangement.
 * ==============================================================================
 */

'use strict';

const childProcess = require('node:child_process');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const identifiers = require('../lib/identifiers.cjs');
const { shared } = require('../lib/paths.cjs');
const { loadReaders } = require('./import-kla-layouts.cjs');

const LIBRARY_PATH = shared('layouts', 'data', 'analysis', 'layout_library.json');
const LEVELS = 4;
const GITHUB = `https://${identifiers.hosts.github}`;
const DEAD_TYPED = 'dead:';

// Each repository: its clone URL and the library source its layouts belong to.
const REPOSITORIES = {
	ergol: { url: `${GITHUB}/Nuclear-Squid/ergol.git`, source: 'ergol_repo' },
	erglace_cmoinard: { url: `${GITHUB}/cmoinard/Erglace.git`, source: 'erglace_cmoinard' },
	erglace_lysquid: { url: `${GITHUB}/Lysquid/Erglace.git`, source: 'erglace_lysquid' },
	ergaie: { url: `${GITHUB}/MacDamien/Ergaie.git`, source: 'ergaie_macdamien' },
	colemak_french_touch: {
		url: 'https://codeberg.org/cedricr/colemak-french-touch.git',
		source: 'colemak_french_touch'
	}
};
// The library sources this import owns, as the Comparer's origin filter names
// them.
const SOURCES = {
	ergol_repo: {
		name: 'Ergo-L repository (keymaps)',
		url: `${GITHUB}/Nuclear-Squid/ergol/tree/03c6c7c8b329d53dcf9c8a5b40a82f75e80b64c1/keymaps`,
		commit: '03c6c7c8b3',
		date: '2026-09-22',
		licence:
			'WTFPL 2 (repository, « Copyright © 2024 Léo Cazenave »); arrangements re-encoded; an earlier version names its commit in its source_path (« commit:path »)'
	},
	erglace_cmoinard: {
		name: 'Erglace (cmoinard)',
		url: `${GITHUB}/cmoinard/Erglace/tree/5ec95161ace6f3757222050c6ef99ce5a8be3fdd`,
		commit: '5ec95161ac',
		date: '2026-05-28',
		licence:
			'no licence published; arrangements re-encoded, its TOML built to Kalamine JSON by Kalamine 0.40'
	},
	erglace_lysquid: {
		name: 'Erglace (Lysquid)',
		url: `${GITHUB}/Lysquid/Erglace/tree/v0.1.0`,
		commit: '285a77409d',
		date: '2024-02-17',
		licence:
			'no licence published; arrangement re-encoded, its TOML built to Kalamine JSON by Kalamine 0.40'
	},
	ergaie_macdamien: {
		name: 'Ergaie (MacDamien)',
		url: `${GITHUB}/MacDamien/Ergaie/tree/4bb64d98eb7b9b5f1478810e03934e14908d77bb/layouts`,
		commit: '4bb64d98eb',
		date: '2024-12-08',
		licence: 'no licence published; arrangement re-encoded'
	},
	colemak_french_touch: {
		name: 'Colemak French Touch (Cédric Rossi)',
		url: 'https://codeberg.org/cedricr/colemak-french-touch/src/commit/e3bfbd43853a1584ec9a24c619e22df8b36a4b33',
		commit: 'e3bfbd4385',
		date: '2024-06-02',
		licence: 'MIT (repository, « Copyright (c) 2024 Cédric Rossi »); arrangement re-encoded'
	}
};
// The Ergo-L repository's current keymaps.
const ERGOL_HEAD = '03c6c7c8b329d53dcf9c8a5b40a82f75e80b64c1';
// Its « v0.7: release candidate » commit, on main, which keeps the earlier
// versions as layouts/ergolv0*.yaml (and their JSON) beside 0_7_0/.
const ERGOL_V07 = '4eaf924e617800e26da709f7026d0b1265103c21';
// Its keymaps of 2025-01-27 (#299), in the ergol-v1.0.1 and v1.0.2 tags.
const ERGOL_2025 = 'e561e4b30545525af1958740a52f159e254c5e3d';
// Its layouts of 2024-11-11 (#268), before the keymaps/ folder.
const ERGOL_2024 = 'e078a83b74a9fd9c704185d4608e179d541d53bb';
const CMOINARD = '5ec95161ace6f3757222050c6ef99ce5a8be3fdd';
const LYSQUID_V010 = '285a77409df8b8e10f90979d81c4a2845c014367';
const ERGAIE = '4bb64d98eb7b9b5f1478810e03934e14908d77bb';
const CFT = 'e3bfbd43853a1584ec9a24c619e22df8b36a4b33';

// The Kalamine check (2.): a TOML and the JSON the Ergo-L repository built
// from it.
const KALAMINE_CHECK = {
	repository: 'ergol',
	commit: ERGOL_HEAD,
	toml: 'keymaps/fr.contrib/erglace_jf.toml',
	json: 'keymaps/fr.contrib/erglace_jf.json'
};

// Each layout: its id, name, version, the file it is read from and that
// file's SHA-256. The library keeps this order.
const LAYOUTS = [
	{
		id: 'bepolar',
		name: 'Bépolar',
		version: '0.7.0',
		repository: 'ergol',
		commit: ERGOL_HEAD,
		path: 'keymaps/fr/bepolar.json',
		sha256: '97f0a662227ba144494c17094e2c287e8d3f64be3586b39dd946f10ec717fee9'
	},
	{
		id: 'colemak_french_touch',
		name: 'Colemak French Touch',
		version: '0.4',
		repository: 'colemak_french_touch',
		commit: CFT,
		path: 'dist/colemkft.json',
		sha256: '26968367704899576e2d8cf2268e1006879b60e3d93d1d3ac742adc74b887eb3'
	},
	{
		id: 'erglace',
		name: 'Erglace',
		version: '0.4.0',
		repository: 'ergol',
		commit: ERGOL_HEAD,
		path: 'keymaps/fr/erglace.json',
		sha256: '85b2e5375e4f3b19770c0e56a4e1e48ed48a5d415f6f83bd6d6e2b7b908f2e27'
	},
	{
		id: 'beopy_1dfh',
		name: 'Béopy 1DFH',
		version: '1.2.1',
		repository: 'ergol',
		commit: ERGOL_HEAD,
		path: 'keymaps/fr.contrib/beopy-l.json',
		sha256: 'b6eb5e7696935467b1965aaf19e7472979a4fe69b94aec2153532586733cd6df'
	},
	{
		id: 'beopy',
		name: 'Béopy',
		version: '1.0.0',
		repository: 'ergol',
		commit: ERGOL_HEAD,
		path: 'keymaps/fr.contrib/beopy.json',
		sha256: 'ae272d9c05a27117d7c93a252aea74983b8b20417130cc63b72b37a22fc5d044'
	},
	{
		id: 'ergaie',
		name: 'Ergaie',
		version: '0.1.9',
		repository: 'ergol',
		commit: ERGOL_HEAD,
		path: 'keymaps/fr.contrib/ergaie.json',
		sha256: 'eb4026164aab0ff63947bad83390b8ada35b4644b40553b16e4919a54a3d821b'
	},
	{
		id: 'erglace_jf',
		name: 'Erglace (JF)',
		version: '0.6.19',
		repository: 'erglace_cmoinard',
		commit: CMOINARD,
		path: 'erglace.toml',
		sha256: '0cd4a59e209eea90c125be4c2bdd6b3bd3037bb562ada9d722616f3a429fd5e1'
	},
	{
		id: 'erglace_nuke',
		name: 'Erglace (Nuke)',
		version: '0.5.0',
		repository: 'ergol',
		commit: ERGOL_HEAD,
		path: 'keymaps/fr.contrib/erglace_nuke.json',
		sha256: '593b22965b78f40c4d08c84d840f61b550d19dabbe172d9b33e8b92a7a314780'
	},
	{
		id: 'kazerty',
		name: 'AZERTY 1DK (Kazerty)',
		version: '1.0',
		repository: 'ergol',
		commit: ERGOL_HEAD,
		path: 'keymaps/fr.contrib/kazerty.json',
		sha256: '31c1a9ad4d66f5b0436ae69a29937f261b8b93f4c0edfdaab430692dff8a5a8a'
	},
	{
		id: 'erglace_jf_0_6_17',
		name: 'Erglace (JF) 0.6.17',
		version: '0.6.17',
		repository: 'ergol',
		commit: ERGOL_HEAD,
		path: 'keymaps/fr.contrib/erglace_jf.json',
		sha256: 'e4aeda4887b3f2c05ac495d7f9fc305ddec49f5ca6c878223d2e5b761a65447f'
	},
	{
		id: 'erglace_jf_0_6_14',
		name: 'Erglace (JF) 0.6.14',
		version: '0.6.14',
		repository: 'erglace_cmoinard',
		commit: CMOINARD,
		path: 'Historique/0.6.14/erglace-0.6.14.toml',
		sha256: 'db3fe494e4c6f2ecec38e40cad2b9a27d7a71d1a31b0293d7b73b37447db3de2'
	},
	{
		id: 'erglace_jf_0_6_13',
		name: 'Erglace (JF) 0.6.13',
		version: '0.6.13',
		repository: 'erglace_cmoinard',
		commit: CMOINARD,
		path: 'Historique/0.6.13/erglace-0.6.13.toml',
		sha256: '9b78f89158989af8dbf5945c3fcd94e824f594c2ac8269ec2eab97651828560d'
	},
	{
		id: 'erglace_0_1',
		name: 'Erglace 0.1',
		version: '0.1.0',
		repository: 'erglace_lysquid',
		commit: LYSQUID_V010,
		path: 'erglace.toml',
		sha256: '81755a311f797b9b85e66ba088928679eb95c8b8bf2812bc91f9c21e8f6e74e2'
	},
	{
		id: 'ergaie_miroir',
		name: 'Ergaie (miroir)',
		version: '0.9.1.7',
		repository: 'ergaie',
		commit: ERGAIE,
		path: 'layouts/ergaie_miroir.json',
		sha256: '147f40618f57402174fff1e6e8d74735faed503c54490335736b3a78b4ff036b'
	},
	{
		id: 'ergol_0_7',
		name: 'Ergo-L 0.7 LTS',
		version: '0.7.0 LTS',
		repository: 'ergol',
		commit: ERGOL_V07,
		path: '0_7_0/ergol.json',
		sha256: '93f39dff6ad031010ee52ad70fbc4bb2d7c8875a31974e2108e2b8c4245b2f23'
	},
	{
		id: 'ergol_0_5',
		name: 'Ergo-L 0.5',
		version: '0.5.0',
		repository: 'ergol',
		commit: ERGOL_V07,
		path: 'layouts/ergolv05.json',
		sha256: '51a339a48462fc616609176598a5fb8dc9ffccb15418105adde0711ba8078d1a'
	},
	{
		// Its header says 0.4.1: the file holds 0.3 and 0.4, the same letters.
		id: 'ergol_0_4',
		name: 'Ergo-L 0.4',
		version: '0.4.1',
		repository: 'ergol',
		commit: ERGOL_V07,
		path: 'layouts/ergolv03_4.json',
		sha256: 'c4ca4d27b4218e827a2b377bfc874a46b8f49085fe1ac63be1fe2804941b42d0'
	},
	{
		// The file's header keeps Kalamine's « 0.7.0 »: its name is the version.
		id: 'ergol_0_2',
		name: 'Ergo-L 0.2',
		version: '0.2',
		repository: 'ergol',
		commit: ERGOL_V07,
		path: 'layouts/ergolv02.json',
		sha256: '9e258eec75286f559e9171436b8a24c4add99d72de2909f15c3514c4956d7fe5'
	},
	{
		id: 'ergol_0_1',
		name: 'Ergo-L 0.1',
		version: '0.1',
		repository: 'ergol',
		commit: ERGOL_V07,
		path: 'layouts/ergolv01.json',
		sha256: '8f1b668d7bcd8651a9cf6bf2edbc2a74ce2395b474fed6175d3e839ed927cafe'
	},
	{
		id: 'optergol',
		name: 'Optergol',
		version: '0.2',
		repository: 'ergol',
		commit: ERGOL_2025,
		path: 'keymaps/fr.contrib/optergol.json',
		sha256: 'cfd86a19132c5d87bd5006ddf29f479f391bb21a62d0c2b81b2c36a49b207135'
	},
	{
		id: 'ergopti_2_1_2_1dk',
		name: 'Ergopti 2.1.2 (1DK)',
		version: '2.1.2',
		repository: 'ergol',
		commit: ERGOL_2025,
		path: 'keymaps/fr.contrib/ergo_1dk.json',
		sha256: 'e3930dcbd42e623311e701f68daf656edbac7f32efa2897f4412870e04df21f8'
	},
	{
		id: 'hypertexte_1dfh',
		name: 'HyperTexte 1DFH',
		version: '1.1.2',
		repository: 'ergol',
		commit: ERGOL_2024,
		path: 'layouts/fr.contrib/hypertexte_1dk.json',
		sha256: 'cde5c499c6f56ef6e247d9ae63d101950fbf25671beb6d2436c86b3e199bbd53'
	}
];
// Versions with the letters and digits of a layout above, which holds them.
const DUPLICATES = [
	{
		repository: 'ergol',
		commit: ERGOL_V07,
		path: 'layouts/ergolv06.json',
		reason: 'Ergo-L 0.6, the same letters and digits as Ergo-L 0.7 LTS',
		same_as: 'ergol_0_7'
	},
	{
		repository: 'ergol',
		commit: ERGOL_HEAD,
		path: 'keymaps/fr/colemak-french-touch.json',
		reason:
			"Colemak French Touch 0.3.1, the Ergo-L repository's copy: the same letters and digits as its author's 0.4",
		same_as: 'colemak_french_touch'
	}
];

// ==========================
// ======= 1/ Reading =======
// ==========================

/**
 * A file of a checkout at a commit.
 * @param {string} folder - The folder of checkouts.
 * @param {string} repository - The REPOSITORIES key.
 * @param {string} commit - The full commit id.
 * @param {string} file - The path in the repository.
 * @returns {Buffer} The file's bytes.
 * @throws {Error} When the checkout lacks the commit or the file.
 */
function gitShow(folder, repository, commit, file) {
	const dir = path.join(folder, repository);
	if (!fs.existsSync(path.join(dir, '.git')))
		throw new Error(`${dir}: no clone of ${REPOSITORIES[repository].url}`);
	return childProcess.execFileSync('git', ['-C', dir, 'show', `${commit}:${file}`], {
		maxBuffer: 1 << 26
	});
}

/**
 * The SHA-256 of some bytes, in hexadecimal.
 * @param {Buffer} bytes - The bytes.
 * @returns {string} The digest.
 */
function sha256(bytes) {
	return crypto.createHash('sha256').update(bytes).digest('hex');
}

/**
 * Builds a Kalamine TOML into its JSON with `kalamine build`.
 * @param {Buffer} toml - The TOML's bytes.
 * @param {string} name - The file's base name (Kalamine reads the extension).
 * @returns {object} The parsed JSON.
 */
function kalamineBuild(toml, name) {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kalamine-'));
	try {
		const source = path.join(dir, name);
		const out = path.join(dir, 'layout.json');
		fs.writeFileSync(source, toml);
		childProcess.execFileSync(process.env.KALAMINE || 'kalamine', ['build', source, '--out', out], {
			stdio: ['ignore', 'ignore', 'inherit']
		});
		return JSON.parse(fs.readFileSync(out, 'utf8'));
	} finally {
		fs.rmSync(dir, { recursive: true, force: true });
	}
}

/**
 * Checks that this Kalamine builds the Ergo-L repository's own JSON.
 * @param {string} folder - The folder of checkouts.
 * @throws {Error} When the build differs from the committed JSON.
 */
function checkKalamine(folder) {
	const { repository, commit, toml, json } = KALAMINE_CHECK;
	const built = kalamineBuild(gitShow(folder, repository, commit, toml), path.basename(toml));
	const committed = JSON.parse(gitShow(folder, repository, commit, json).toString('utf8'));
	for (const field of ['keymap', 'deadkeys', 'altgr'])
		if (JSON.stringify(built[field]) !== JSON.stringify(committed[field]))
			throw new Error(
				`kalamine build ${toml} differs from the Ergo-L repository's ${json} (${field}): use Kalamine 0.40`
			);
}

/**
 * The Kalamine JSON of one layout, its source checked against its SHA-256.
 * @param {string} folder - The folder of checkouts.
 * @param {object} spec - A LAYOUTS entry.
 * @returns {object} The parsed JSON.
 * @throws {Error} On another digest.
 */
function readSource(folder, spec) {
	const bytes = gitShow(folder, spec.repository, spec.commit, spec.path);
	const digest = sha256(bytes);
	if (digest !== spec.sha256)
		throw new Error(`${spec.id}: ${spec.path} has the SHA-256 ${digest}, not ${spec.sha256}`);
	if (spec.path.endsWith('.json')) return JSON.parse(bytes.toString('utf8'));
	return kalamineBuild(bytes, path.basename(spec.path));
}

// ==========================
// ======= 2/ Entries =======
// ==========================

/**
 * A library entry from a Kalamine JSON, through the Studio's reader: the four
 * levels of every measured key, and the dead keys' rules that the codegen
 * does not compose (3.).
 * @param {object} json - The parsed Kalamine JSON.
 * @param {object} spec - {id, name, version, language, source, source_path}.
 * @param {object} F - LAYOUT_FORMATS.
 * @param {string[]} codes - The measured codes.
 * @returns {object} The entry.
 * @throws {Error} On a character the reader could not place.
 */
function entryFrom(json, spec, F, codes) {
	const { layout, unmapped } = F.fromKalamineJson(json);
	const lost = unmapped.filter((entry) => entry.what !== 'dead_key_rules');
	if (lost.length > 0) throw new Error(`${spec.id}: unmapped ${JSON.stringify(lost)}`);
	const rows = {};
	for (const code of codes) if (layout.rows[code]) rows[code] = layout.rows[code].slice(0, LEVELS);
	for (const code of Object.keys(layout.rows))
		if (!rows[code] && layout.rows[code].some((cell) => cell !== null))
			throw new Error(`${spec.id}: ${code} is not a measured key`);
	// The states of the cells; the codegen composes their standard accents.
	const onKey = new Set();
	for (const row of Object.values(rows))
		for (const cell of row) if (cell && typeof cell === 'object') onKey.add(cell.dead);
	// The states the rules reach from the cells' (1DK twice → diaeresis).
	const reached = new Set(onKey);
	for (let grew = true; grew; ) {
		grew = false;
		for (const state of Array.from(reached))
			for (const output of Object.values(layout.dead[state] || {}))
				if (output && typeof output === 'object' && !reached.has(output.dead)) {
					reached.add(output.dead);
					grew = true;
				}
	}
	const deadRules = {};
	for (const state of reached) {
		const composed = onKey.has(state) ? F.composeAccent({ rows, dead: {} }, state, state) : {};
		const rules = {};
		for (const [typed, output] of Object.entries(layout.dead[state] || {})) {
			// A dead key typed in a state is one of a cell, or it types nothing.
			if (typed.startsWith(DEAD_TYPED) && !onKey.has(typed.slice(DEAD_TYPED.length))) continue;
			if (typeof output === 'string' && composed[typed] === output) continue;
			rules[typed] = output;
		}
		if (Object.keys(rules).length > 0) deadRules[state] = rules;
	}
	// A state entered by a rule needs rules of its own.
	for (const rules of Object.values(deadRules))
		for (const [typed, output] of Object.entries(rules))
			if (output && typeof output === 'object' && !deadRules[output.dead]) delete rules[typed];
	const entry = {
		id: spec.id,
		name: spec.name,
		language: spec.language,
		source: spec.source,
		source_path: spec.source_path,
		fingering: 'standard',
		rows,
		version: spec.version
	};
	if (Object.keys(deadRules).length > 0) entry.dead_rules = sortedRules(deadRules);
	return entry;
}

/**
 * The dead-key rules in a stable order: states and typed keys by code point.
 * @param {object} rules - state → typed → output.
 * @returns {object} The same rules, sorted.
 */
function sortedRules(rules) {
	const byKey = (a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0);
	return Object.fromEntries(
		Object.entries(rules)
			.sort(byKey)
			.map(([state, table]) => [state, Object.fromEntries(Object.entries(table).sort(byKey))])
	);
}

/**
 * The library path of a layout's file: the path alone at the source's
 * pinned commit, else « commit:path ».
 * @param {object} spec - A LAYOUTS or DUPLICATES entry.
 * @returns {string} The source path.
 */
function sourcePath(spec) {
	const source = SOURCES[REPOSITORIES[spec.repository].source];
	return spec.commit.startsWith(source.commit)
		? spec.path
		: `${spec.commit.slice(0, 10)}:${spec.path}`;
}

/**
 * The library with this import's entries: each kept at its earlier place,
 * a new one appended, so a run changes only what its files change.
 * @param {object} library - layout_library.json.
 * @param {object[]} entries - This import's layouts.
 * @param {object[]} notImported - This import's not_imported entries.
 * @returns {object} The new library.
 */
function merge(library, entries, notImported) {
	const owned = new Set(Object.keys(SOURCES));
	const byId = new Map(entries.map((entry) => [entry.id, entry]));
	const layouts = [];
	for (const entry of library.layouts) {
		if (!owned.has(entry.source)) layouts.push(entry);
		else if (byId.has(entry.id)) {
			layouts.push(byId.get(entry.id));
			byId.delete(entry.id);
		}
	}
	// The other files left out (the Ergo-L repository's copies of layouts
	// another collection holds) are not this import's.
	const byPath = new Map(notImported.map((entry) => [entry.source_path, entry]));
	const skipped = [];
	for (const entry of library.not_imported) {
		if (!owned.has(entry.source) || !byPath.has(entry.source_path)) skipped.push(entry);
		else {
			skipped.push(byPath.get(entry.source_path));
			byPath.delete(entry.source_path);
		}
	}
	return {
		...library,
		sources: { ...library.sources, ...SOURCES },
		layouts: layouts.concat(Array.from(byId.values())),
		not_imported: skipped.concat(Array.from(byPath.values()))
	};
}

/**
 * Reads every layout and returns the library with them, unwritten.
 * @param {string} folder - The folder of checkouts.
 * @returns {object} The new library.
 */
function importInto(folder) {
	const { F, E } = loadReaders();
	const codes = E.typingCodes();
	if (LAYOUTS.some((spec) => !spec.path.endsWith('.json'))) checkKalamine(folder);
	const entries = LAYOUTS.map((spec) =>
		entryFrom(
			readSource(folder, spec),
			{
				...spec,
				language: 'fr',
				source: REPOSITORIES[spec.repository].source,
				source_path: sourcePath(spec)
			},
			F,
			codes
		)
	);
	const notImported = DUPLICATES.map((spec) => ({
		source: REPOSITORIES[spec.repository].source,
		source_path: sourcePath(spec),
		reason: spec.reason,
		same_as: spec.same_as
	}));
	const library = JSON.parse(fs.readFileSync(LIBRARY_PATH, 'utf8'));
	return merge(library, entries, notImported);
}

/**
 * Writes the library, or with --check compares it.
 * @param {string[]} argv - The command line arguments.
 */
function main(argv) {
	const folder = argv.find((arg) => !arg.startsWith('--'));
	if (!folder || !fs.existsSync(folder))
		throw new Error(
			'usage: node tools/build/import-kalamine-layouts.cjs <folder of checkouts> [--check]'
		);
	const library = importInto(folder);
	const text = `${JSON.stringify(library, null, '\t')}\n`;
	if (argv.includes('--check')) {
		const current = JSON.parse(fs.readFileSync(LIBRARY_PATH, 'utf8'));
		if (JSON.stringify(current) !== JSON.stringify(library))
			throw new Error('layout_library.json differs from the Kalamine sources: run the import');
		console.log(`import-kalamine-layouts --check — ${LAYOUTS.length} layouts match their files`);
		return;
	}
	fs.writeFileSync(LIBRARY_PATH, text);
	console.log(`import-kalamine-layouts — ${LAYOUTS.length} layouts written`);
}

if (require.main === module) main(process.argv.slice(2));

module.exports = { entryFrom, importInto, LAYOUTS, SOURCES };
