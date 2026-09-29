// tools/build/macos-bundle-payload.cjs

/**
 * ==============================================================================
 * MODULE: macOS Bundle Payload
 * DESCRIPTION:
 * Resolves and stages the repository files ErgoptiPlus.app ships under
 * Contents/Resources/static, from the single manifest
 * tools/build/macos-bundle-manifest.json.
 *
 * WHY THIS EXISTS:
 * The app builder used to copy whole trees (rsync of the driver, cp -R of the
 * shared tree, of static/img, and a second copy of the locales, hotstrings and
 * menu manifest at the static root that nothing read). Every file the runtime
 * never opens was download weight for every user and every update. The payload
 * is now one declared set: build_macos_app.sh stages it through this module,
 * and test-macos-bundle-payload.cjs resolves the same set and proves that every
 * path the macOS runtime reads is still inside it.
 *
 * FEATURES & RATIONALE:
 * 1. Tracked bytes only: the inventory is `git ls-files`, so ignored state a
 *    developer checkout accumulates (a .venv, WebView prefetch caches holding
 *    private metrics) can never reach a locally built bundle.
 * 2. Named exclusion groups: each says why the runtime never reads it, and a
 *    pattern or exception that no longer matches any tracked file fails the
 *    resolution, so the manifest cannot keep a stale justification. License
 *    notices of vendored code stay through a group's `except` list.
 * 3. Fail fast: an unknown manifest key, a pattern outside the declared trees,
 *    an `only` file that is not tracked, an existing destination file or a
 *    tree that stages nothing stops the build instead of shipping a gap.
 *
 * USAGE:  node tools/build/macos-bundle-payload.cjs stage <repo-root> <static-root>
 *         Copies the payload into <static-root> (Contents/Resources/static).
 *         node tools/build/macos-bundle-payload.cjs list <repo-root>
 *         Prints one staged target path per line.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

// Repository-relative location of the one payload declaration
const MANIFEST_REL = 'tools/build/macos-bundle-manifest.json';

// Keys each manifest level may carry; anything else is a typo that would be ignored
const MANIFEST_KEYS = new Set(['description', 'trees', 'external', 'exclude']);
const TREE_KEYS = new Set(['source', 'target', 'reason', 'only']);
const EXTERNAL_KEYS = new Set(['target', 'owner', 'reason']);
const EXCLUDE_KEYS = new Set(['group', 'reason', 'patterns', 'except']);

// ===========================================
// ===========================================
// ======= 1/ Manifest validation ============
// ===========================================
// ===========================================

/**
 * Rejects keys a manifest level does not define.
 * @param {object} value Parsed manifest object.
 * @param {Set<string>} allowed Keys this level accepts.
 * @param {string} label Location used in the error message.
 */
function rejectUnknownKeys(value, allowed, label) {
	if (!value || typeof value !== 'object' || Array.isArray(value)) {
		throw new Error(`${label} must be an object`);
	}
	for (const key of Object.keys(value)) {
		if (!allowed.has(key)) throw new Error(`${label} has an unknown key: ${key}`);
	}
}

/**
 * Rejects a path that is absolute, empty, backslashed or climbs out of its root.
 * @param {string} value Candidate relative path.
 * @param {string} label Location used in the error message.
 */
function requireRelativePath(value, label) {
	if (
		typeof value !== 'string' ||
		value === '' ||
		value.includes('\\') ||
		value.startsWith('/') ||
		value.endsWith('/') ||
		value.split('/').some((part) => part === '' || part === '.' || part === '..')
	) {
		throw new Error(`${label} is not a clean relative path: ${JSON.stringify(value)}`);
	}
}

/**
 * Converts a manifest glob into an anchored regular expression. `**` spans
 * directories, `*` and `?` stay inside one path segment.
 * @param {string} pattern Glob relative to the static root.
 * @return {RegExp}
 */
function globToRegExp(pattern) {
	let source = '';
	for (let index = 0; index < pattern.length; index += 1) {
		const character = pattern[index];
		if (character === '*' && pattern[index + 1] === '*') {
			const slashFollows = pattern[index + 2] === '/';
			source += slashFollows ? '(?:.*/)?' : '.*';
			index += slashFollows ? 2 : 1;
		} else if (character === '*') {
			source += '[^/]*';
		} else if (character === '?') {
			source += '[^/]';
		} else {
			source += character.replace(/[.+^${}()|[\]\\]/g, '\\$&');
		}
	}
	return new RegExp(`^${source}$`);
}

/**
 * Parses and validates a payload manifest.
 * @param {string} text Manifest JSON.
 * @return {{trees: object[], external: object[], exclude: object[]}}
 */
function parseManifest(text) {
	const manifest = JSON.parse(text);
	rejectUnknownKeys(manifest, MANIFEST_KEYS, 'manifest');
	for (const key of ['trees', 'external', 'exclude']) {
		if (!Array.isArray(manifest[key]) || manifest[key].length === 0) {
			throw new Error(`manifest.${key} must be a non-empty array`);
		}
	}
	const targets = new Set();
	manifest.trees.forEach((tree, index) => {
		const label = `manifest.trees[${index}]`;
		rejectUnknownKeys(tree, TREE_KEYS, label);
		requireRelativePath(tree.source, `${label}.source`);
		requireRelativePath(tree.target, `${label}.target`);
		if (typeof tree.reason !== 'string' || tree.reason === '') {
			throw new Error(`${label}.reason must explain what the runtime reads there`);
		}
		for (const other of targets) {
			if (
				tree.target === other ||
				tree.target.startsWith(`${other}/`) ||
				other.startsWith(`${tree.target}/`)
			) {
				throw new Error(`${label}.target overlaps another tree: ${tree.target}`);
			}
		}
		targets.add(tree.target);
		if (tree.only !== undefined) {
			if (!Array.isArray(tree.only) || tree.only.length === 0) {
				throw new Error(`${label}.only must be a non-empty array when present`);
			}
			tree.only.forEach((file, fileIndex) =>
				requireRelativePath(file, `${label}.only[${fileIndex}]`)
			);
			if (new Set(tree.only).size !== tree.only.length) {
				throw new Error(`${label}.only lists a file twice`);
			}
		}
	});
	manifest.external.forEach((entry, index) => {
		const label = `manifest.external[${index}]`;
		rejectUnknownKeys(entry, EXTERNAL_KEYS, label);
		requireRelativePath(entry.target, `${label}.target`);
		for (const key of ['owner', 'reason']) {
			if (typeof entry[key] !== 'string' || entry[key] === '') {
				throw new Error(`${label}.${key} must be a non-empty string`);
			}
		}
	});
	const groups = new Set();
	manifest.exclude.forEach((group, index) => {
		const label = `manifest.exclude[${index}]`;
		rejectUnknownKeys(group, EXCLUDE_KEYS, label);
		if (typeof group.group !== 'string' || !/^[a-z][a-z-]*$/.test(group.group)) {
			throw new Error(`${label}.group must be a lowercase kebab-case name`);
		}
		if (groups.has(group.group)) throw new Error(`${label}.group is duplicated: ${group.group}`);
		groups.add(group.group);
		if (typeof group.reason !== 'string' || group.reason === '') {
			throw new Error(`${label}.reason must say why the runtime never reads the group`);
		}
		if (!Array.isArray(group.patterns) || group.patterns.length === 0) {
			throw new Error(`${label}.patterns must be a non-empty array`);
		}
		if (group.except !== undefined && (!Array.isArray(group.except) || group.except.length === 0)) {
			throw new Error(`${label}.except must be a non-empty array when present`);
		}
		const compile = (pattern) => {
			if (typeof pattern !== 'string' || pattern === '' || pattern.startsWith('/')) {
				throw new Error(`${label} has an invalid pattern: ${JSON.stringify(pattern)}`);
			}
			return { pattern, regex: globToRegExp(pattern) };
		};
		group.matchers = group.patterns.map(compile);
		group.exceptMatchers = (group.except || []).map(compile);
	});
	return manifest;
}

/**
 * Reads and validates the repository manifest.
 * @param {string} root Repository root.
 * @return {{trees: object[], external: object[], exclude: object[]}}
 */
function loadManifest(root) {
	return parseManifest(fs.readFileSync(path.join(root, MANIFEST_REL), 'utf8'));
}

// ===========================================
// ===========================================
// ======= 2/ Payload resolution =============
// ===========================================
// ===========================================

/**
 * Lists the tracked files below the manifest's tree sources.
 * @param {string} root Repository root.
 * @param {{trees: object[]}} manifest Validated manifest.
 * @return {string[]} Repository-relative POSIX paths.
 */
function trackedFiles(root, manifest) {
	const sources = manifest.trees.map((tree) => tree.source);
	return execFileSync('git', ['-C', root, 'ls-files', '-z', '--', ...sources], {
		encoding: 'utf8',
		maxBuffer: 64 * 1024 * 1024
	})
		.split('\0')
		.filter(Boolean);
}

/**
 * Returns the exclusion group a staged target falls into, if any. A group's
 * `except` patterns keep a file that group would drop (a license notice among
 * the documentation), never one another group drops.
 * @param {{exclude: object[]}} manifest Validated manifest.
 * @param {string} target Path relative to the static root.
 * @return {{group: string, pattern: string}|null}
 */
function exclusionFor(manifest, target) {
	for (const group of manifest.exclude) {
		const matcher = group.matchers.find((candidate) => candidate.regex.test(target));
		if (!matcher) continue;
		if (group.exceptMatchers.some((candidate) => candidate.regex.test(target))) continue;
		return { group: group.group, pattern: matcher.pattern };
	}
	return null;
}

/**
 * Maps tracked repository files to the payload, before and after exclusion.
 * `unfiltered` is what the trees would ship without any exclusion group or
 * `only` list; the guard uses it to tell a missing runtime file from a path
 * that exists nowhere in the repository.
 * @param {{trees: object[], exclude: object[]}} manifest Validated manifest.
 * @param {string[]} tracked Repository-relative tracked paths.
 * @return {{files: {source: string, target: string}[], unfiltered: Set<string>}}
 */
function resolvePayload(manifest, tracked) {
	const files = [];
	const unfiltered = new Set();
	const patternHits = new Map();
	for (const tree of manifest.trees) {
		const prefix = `${tree.source}/`;
		const only = tree.only ? new Set(tree.only) : null;
		const seenOnly = new Set();
		let staged = 0;
		for (const source of tracked) {
			if (!source.startsWith(prefix)) continue;
			const relative = source.slice(prefix.length);
			const target = `${tree.target}/${relative}`;
			unfiltered.add(target);
			if (only && !only.has(relative)) continue;
			if (only) seenOnly.add(relative);
			const excluded = exclusionFor(manifest, target);
			if (excluded) {
				patternHits.set(excluded.pattern, (patternHits.get(excluded.pattern) || 0) + 1);
				if (only)
					throw new Error(
						`${tree.source}: "only" file ${relative} is excluded by ${excluded.group}`
					);
				continue;
			}
			files.push({ source, target });
			staged += 1;
		}
		if (only) {
			for (const relative of only) {
				if (!seenOnly.has(relative))
					throw new Error(`${tree.source}: "only" file is not tracked: ${relative}`);
			}
		}
		if (staged === 0) throw new Error(`${tree.source}: the tree stages no file`);
	}
	for (const group of manifest.exclude) {
		for (const matcher of group.matchers) {
			if (!patternHits.has(matcher.pattern)) {
				throw new Error(
					`exclusion ${group.group}: pattern ${matcher.pattern} matches no tracked file`
				);
			}
		}
		for (const exception of group.exceptMatchers) {
			const kept = files.some(
				(file) =>
					exception.regex.test(file.target) &&
					group.matchers.some((matcher) => matcher.regex.test(file.target))
			);
			if (!kept) {
				throw new Error(
					`exclusion ${group.group}: exception ${exception.pattern} keeps no staged file`
				);
			}
		}
	}
	files.sort((left, right) =>
		left.target < right.target ? -1 : left.target > right.target ? 1 : 0
	);
	return { files, unfiltered };
}

// ===========================================
// ===========================================
// ======= 3/ Staging ========================
// ===========================================
// ===========================================

/**
 * Creates a directory chain, refusing a symbolic link or a non-directory on it.
 * The walk stops at a directory already in `known`, which stage() seeds with
 * the resolved destination root.
 * @param {string} directory Absolute directory path.
 * @param {Set<string>} known Directories already verified.
 */
function ensureDirectory(directory, known) {
	if (known.has(directory)) return;
	const parent = path.dirname(directory);
	if (parent !== directory) ensureDirectory(parent, known);
	if (!fs.existsSync(directory)) fs.mkdirSync(directory);
	const stat = fs.lstatSync(directory);
	if (!stat.isDirectory() || stat.isSymbolicLink()) {
		throw new Error(`Unsafe payload directory: ${directory}`);
	}
	known.add(directory);
}

/**
 * Copies the resolved payload into a static root, preserving modes and
 * modification times so the bundle's executables stay executable.
 * @param {string} root Repository root.
 * @param {string} staticRoot Destination (Contents/Resources/static).
 * @return {number} Number of files copied.
 */
function stage(root, staticRoot) {
	const repository = fs.realpathSync(root);
	const manifest = loadManifest(repository);
	const { files } = resolvePayload(manifest, trackedFiles(repository, manifest));
	// The caller chooses where the static root lives, and its ancestors may be
	// symbolic links the stager does not own (macOS /var and /tmp point into
	// /private). Resolving the root once keeps them out of the symlink refusal,
	// which then applies only to the directories staged below it.
	fs.mkdirSync(staticRoot, { recursive: true });
	const destination = fs.realpathSync(staticRoot);
	if (!fs.statSync(destination).isDirectory()) {
		throw new Error(`Payload destination is not a directory: ${staticRoot}`);
	}
	const known = new Set([destination]);
	for (const file of files) {
		const from = path.join(repository, ...file.source.split('/'));
		const to = path.join(destination, ...file.target.split('/'));
		const stat = fs.lstatSync(from);
		if (!stat.isFile()) throw new Error(`Payload source is not a regular file: ${file.source}`);
		ensureDirectory(path.dirname(to), known);
		fs.copyFileSync(from, to, fs.constants.COPYFILE_EXCL);
		fs.chmodSync(to, stat.mode & 0o7777);
		fs.utimesSync(to, stat.atime, stat.mtime);
	}
	return files.length;
}

// ===========================================
// ===========================================
// ======= 4/ Command line ===================
// ===========================================
// ===========================================

if (require.main === module) {
	const [command, rootArgument, staticRootArgument, ...rest] = process.argv.slice(2);
	if (command === 'stage' && rootArgument && staticRootArgument && rest.length === 0) {
		const count = stage(rootArgument, staticRootArgument);
		console.error(`[macos-bundle-payload] staged ${count} files into ${staticRootArgument}`);
	} else if (command === 'list' && rootArgument && staticRootArgument === undefined) {
		const manifest = loadManifest(rootArgument);
		const { files } = resolvePayload(manifest, trackedFiles(rootArgument, manifest));
		process.stdout.write(files.map((file) => `${file.target}\n`).join(''));
	} else {
		console.error(
			'Usage: macos-bundle-payload.cjs stage <repo-root> <static-root> | list <repo-root>'
		);
		process.exit(2);
	}
}

module.exports = {
	MANIFEST_REL,
	globToRegExp,
	parseManifest,
	loadManifest,
	trackedFiles,
	exclusionFor,
	resolvePayload,
	stage
};
