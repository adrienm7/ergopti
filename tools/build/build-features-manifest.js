#!/usr/bin/env node
// scripts/build-features-manifest.js
// Reads the shared features manifest and produces, for each driver, both:
//   1. A native-language manifest module (AHK Map / Lua table) consumed at boot.
//   2. A default config.toml template copied verbatim into the user's config
//      directory on first boot.
//
// Inputs:
//   static/ergopti_plus/_shared/modules/features/manifest.toml
//   static/ergopti_plus/_shared/tap_hold/defaults.toml
//
// Outputs:
//   static/ergopti_plus/windows/_generated/features_manifest.ahk
//   static/ergopti_plus/windows/_generated/config_template.toml
//   static/ergopti_plus/macos/_generated/features_manifest.lua
//   static/ergopti_plus/macos/_generated/config_template.toml
//
// Usage:
//   npm run build:manifest
//   node ./scripts/build-features-manifest.js

import { parse as parseToml } from 'smol-toml';
import { mkdirSync, readFileSync, writeFileSync } from 'fs';
import { dirname, resolve } from 'path';
import { fileURLToPath } from 'url';
import sharedPaths from '../lib/paths.cjs';

const { shared } = sharedPaths;
const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(__dirname, '..', '..');

const MANIFEST_PATH = shared('modules/features/manifest.toml');

const OUT_AHK_DIR = resolve(REPO_ROOT, 'static/ergopti_plus/windows/_generated');
const OUT_HS_DIR = resolve(REPO_ROOT, 'static/ergopti_plus/macos/_generated');
const OUT_LINUX_DIR = resolve(REPO_ROOT, 'static/ergopti_plus/linux/_generated');

// Ultimate fallback default: a feature that declares no 'platforms' at any
// ancestor level inherits this list. When adding a new driver, this list must
// match the platforms enum in _shared/modules/features/manifest.schema.json.
const PLATFORMS = ['ahk', 'hs', 'linux'];

// =================================================
// =================================================
// ======= 1. Manifest parsing + flattening =======
// =================================================
// =================================================

// Pre-process the manifest source so that the nested ``[[features.X.Y.Z]]``
// blocks (which the TOML spec interprets as sub-AoTs of the last parent entry,
// NOT as independent top-level AoTs as we want) are rewritten into a single
// flat ``[[entries]]`` AoT carrying a synthetic ``path_prefix`` field. This
// keeps the source file readable (grouped by section in the original form)
// while sidestepping the AoT-nesting trap.
function preprocessManifestSource(raw) {
	return raw.replace(
		/^\[\[features\.([^\]]+)\]\]\r?$/gm,
		(_match, prefix) => `[[entries]]\npath_prefix = "${prefix}"`
	);
}

function loadManifest() {
	const raw = readFileSync(MANIFEST_PATH, 'utf8');
	const preprocessed = preprocessManifestSource(raw);
	const parsed = parseToml(preprocessed);
	if (!parsed.manifest || !parsed.sections || !parsed.entries) {
		throw new Error(
			'manifest.toml must contain [manifest], [sections], and at least one [[features.*]] block'
		);
	}
	return parsed;
}

// Each parsed entry carries both ``path_prefix`` (the section path, injected
// by the pre-processor) and ``id`` (declared in the source). The flat entry's
// ``path`` is the concatenation; its ``section`` is the prefix.
function flattenFeatures(entries) {
	const result = [];
	for (const entry of entries) {
		if (!entry.id) {
			throw new Error(`feature entry missing "id" at section [${entry.path_prefix}]`);
		}
		if (!entry.path_prefix) {
			throw new Error(`feature entry missing "path_prefix" (preprocessor bug?) id=${entry.id}`);
		}
		// Strip the synthetic field from the rendered entry.
		const { path_prefix, ...rest } = entry;
		result.push({
			...rest,
			section: path_prefix,
			path: `${path_prefix}.${entry.id}`
		});
	}
	return result;
}

// Walk the nested [sections.X.Y...] tables and emit a flat list of section
// metadata entries, each annotated with its full path.
function flattenSections(node, pathParts = []) {
	const result = [];
	if (!node || typeof node !== 'object') return result;

	// Recognise a metadata leaf by the presence of "description_key" — anything
	// else is a nested sub-section table or the top-level "order" array.
	const isMeta =
		Object.prototype.hasOwnProperty.call(node, 'description_key') ||
		Object.prototype.hasOwnProperty.call(node, 'platforms') ||
		Object.prototype.hasOwnProperty.call(node, 'subsections');

	if (isMeta && pathParts.length > 0) {
		result.push({
			path: pathParts.join('.'),
			description_key: node.description_key || '',
			platforms: node.platforms || PLATFORMS,
			subsections: node.subsections || []
		});
	}

	for (const [key, val] of Object.entries(node)) {
		if (
			key === 'order' ||
			key === 'description_key' ||
			key === 'platforms' ||
			key === 'subsections'
		) {
			continue;
		}
		result.push(...flattenSections(val, [...pathParts, key]));
	}
	return result;
}

// Resolve each feature's effective platforms list. If absent on the feature,
// inherit from the nearest ancestor section that declares "platforms".
function resolvePlatforms(features, sections) {
	const sectionByPath = new Map(sections.map((s) => [s.path, s]));
	for (const f of features) {
		if (f.platforms && f.platforms.length > 0) continue;
		// Walk up the section path looking for an explicit platforms list.
		const parts = f.section.split('.');
		while (parts.length > 0) {
			const ancestor = sectionByPath.get(parts.join('.'));
			if (ancestor && ancestor.platforms && ancestor.platforms.length > 0) {
				f.platforms = [...ancestor.platforms];
				break;
			}
			parts.pop();
		}
		if (!f.platforms || f.platforms.length === 0) {
			f.platforms = [...PLATFORMS];
		}
	}
}

// Pick the appropriate default for a given platform.
function resolveDefault(feature, platform) {
	if (feature.default_per_platform && feature.default_per_platform[platform] !== undefined) {
		return feature.default_per_platform[platform];
	}
	if (feature.default !== undefined) {
		return feature.default;
	}
	throw new Error(
		`feature ${feature.path} has neither default nor default_per_platform.${platform}`
	);
}

function validate(features) {
	for (const f of features) {
		const hasDefault = f.default !== undefined;
		const hasDefaultPerPlatform = f.default_per_platform !== undefined;
		if (hasDefault === hasDefaultPerPlatform) {
			throw new Error(
				`feature ${f.path} must declare exactly one of default / default_per_platform`
			);
		}
		if (f.type === 'enum' && (!f.enum_values || f.enum_values.length === 0)) {
			throw new Error(`feature ${f.path} has type=enum but no enum_values`);
		}
		if (!/^[a-z][a-z0-9_]*$/.test(f.id)) {
			throw new Error(`feature ${f.path} has invalid id "${f.id}" (must match ^[a-z][a-z0-9_]*$)`);
		}
	}
}

// ========================================
// ========================================
// ======= 2. AHK manifest rendering =======
// ========================================
// ========================================

function ahkEscapeString(s) {
	// AHK v2 uses backtick as the escape char; backslash is literal.
	return String(s)
		.replace(/`/g, '``')
		.replace(/"/g, '`"')
		.replace(/\r/g, '`r')
		.replace(/\n/g, '`n')
		.replace(/\t/g, '`t');
}

function ahkLiteral(value) {
	if (value === null || value === undefined) return '""';
	if (typeof value === 'boolean') return value ? 'true' : 'false';
	if (typeof value === 'number') return String(value);
	if (typeof value === 'string') return `"${ahkEscapeString(value)}"`;
	if (Array.isArray(value)) {
		return '[' + value.map(ahkLiteral).join(', ') + ']';
	}
	if (typeof value === 'object') {
		const entries = Object.entries(value)
			.map(([k, v]) => `${ahkLiteral(k)}, ${ahkLiteral(v)}`)
			.join(', ');
		return `Map(${entries})`;
	}
	throw new Error(`cannot represent ${typeof value} in AHK literal`);
}

function renderAhkManifest(manifest, sections, features) {
	const lines = [];
	lines.push('; _generated/features_manifest.ahk');
	lines.push('; AUTO-GENERATED from _shared/modules/features/manifest.toml.');
	lines.push('; DO NOT EDIT BY HAND — run `npm run build:manifest` to refresh.');
	lines.push('');
	lines.push('global FEATURES_MANIFEST := Map(');
	lines.push(`    "version", ${ahkLiteral(manifest.manifest.version)},`);

	const topOrder = (manifest.sections && manifest.sections.order) || [];
	lines.push(`    "section_order", ${ahkLiteral(topOrder)},`);

	lines.push('    "sections", Map(');
	const sectionLines = sections.map((s) => {
		const meta = {
			description_key: s.description_key,
			platforms: s.platforms,
			subsections: s.subsections
		};
		return `        ${ahkLiteral(s.path)}, ${ahkLiteral(meta)}`;
	});
	lines.push(sectionLines.join(',\n'));
	lines.push('    ),');

	lines.push('    "features", [');
	const platformFeatures = features.filter((f) => f.platforms.includes('ahk'));
	const featLines = platformFeatures.map((f) => {
		const entry = {
			path: f.path,
			id: f.id,
			section: f.section,
			default: resolveDefault(f, 'ahk'),
			type: f.type || '',
			description_key: f.description_key || '',
			platforms: f.platforms
		};
		if (f.enum_values) entry.enum_values = f.enum_values;
		return `        ${ahkLiteral(entry)}`;
	});
	lines.push(featLines.join(',\n'));
	lines.push('    ]');
	lines.push(')');
	lines.push('');
	return lines.join('\n');
}

// ========================================
// ========================================
// ======= 3. Lua manifest rendering =======
// ========================================
// ========================================

function luaEscapeString(s) {
	return String(s)
		.replace(/\\/g, '\\\\')
		.replace(/"/g, '\\"')
		.replace(/\r/g, '\\r')
		.replace(/\n/g, '\\n')
		.replace(/\t/g, '\\t');
}

// Renders a JS value as an inline Lua literal (objects and arrays stay on one
// line). loadfile parses inline tables identically to multi-line ones, so this
// only affects the committed file's size/readability, never the resolved data.
function luaLiteral(value) {
	if (value === null || value === undefined) return 'nil';
	if (typeof value === 'boolean') return value ? 'true' : 'false';
	if (typeof value === 'number') return String(value);
	if (typeof value === 'string') return `"${luaEscapeString(value)}"`;
	if (Array.isArray(value)) {
		return `{ ${value.map((v) => luaLiteral(v)).join(', ')} }`;
	}
	if (typeof value === 'object') {
		const entries = Object.entries(value).map(([k, v]) => {
			const keyLit = /^[a-zA-Z_][a-zA-Z0-9_]*$/.test(k) ? k : `["${luaEscapeString(k)}"]`;
			return `${keyLit} = ${luaLiteral(v)}`;
		});
		return `{ ${entries.join(', ')} }`;
	}
	throw new Error(`cannot represent ${typeof value} in Lua literal`);
}

function renderLuaManifest(manifest, sections, features, platform) {
	const lines = [];
	lines.push('--- _generated/features_manifest.lua');
	lines.push('--- AUTO-GENERATED from _shared/modules/features/manifest.toml.');
	lines.push('--- DO NOT EDIT BY HAND — run `npm run build:manifest` to refresh.');
	lines.push('---');
	lines.push('--- NOTE (F-LOW-15): description_key is emitted here for structural');
	lines.push('--- parity with the AHK twin (features_manifest.ahk) and because');
	lines.push('--- test-manifest-parity.cjs cross-checks it between the two generated');
	lines.push('--- files — but no Lua module on macOS reads entry.description_key today');
	lines.push('--- (confirmed via a repo-wide grep; lib/manifest_reader.lua\'s own');
	lines.push('--- docstring documents it as exposing only what macOS modules actually');
	lines.push('--- consume). The AHK driver genuinely resolves every description_key via');
	lines.push('--- its menu builder. Removing the field from this side alone would break');
	lines.push('--- the shared parity-test regex parsers, which require it to even match a');
	lines.push('--- section/feature block — left as-is rather than touching that shared path.');
	lines.push('');
	lines.push('local M = {}');
	lines.push('');
	lines.push(`M.version = ${luaLiteral(manifest.manifest.version)}`);
	lines.push('');
	const topOrder = (manifest.sections && manifest.sections.order) || [];
	lines.push(`M.section_order = ${luaLiteral(topOrder)}`);
	lines.push('');
	lines.push('M.sections = {');
	for (const s of sections) {
		const meta = {
			description_key: s.description_key,
			platforms: s.platforms,
			subsections: s.subsections
		};
		const keyLit = `["${luaEscapeString(s.path)}"]`;
		lines.push(`\t${keyLit} = ${luaLiteral(meta)},`);
	}
	lines.push('}');
	lines.push('');
	lines.push('M.features = {');
	const platformFeatures = features.filter((f) => f.platforms.includes(platform));
	for (const f of platformFeatures) {
		const entry = {
			path: f.path,
			id: f.id,
			section: f.section,
			default: resolveDefault(f, platform),
			type: f.type || '',
			description_key: f.description_key || '',
			platforms: f.platforms
		};
		if (f.enum_values) entry.enum_values = f.enum_values;
		// Emit each feature compactly: opening brace, all fields on one line, then
		// the closing brace. ~3 lines/feature instead of ~9, while keeping the
		// entry's opening "{" on its own line so the regex manifest parsers
		// (parseLuaFeatures, depth-based) still walk each block correctly.
		const fields = Object.entries(entry)
			.map(([k, v]) => `${k} = ${luaLiteral(v)}`)
			.join(', ');
		lines.push('\t{');
		lines.push(`\t\t${fields},`);
		lines.push('\t},');
	}
	lines.push('}');
	lines.push('');
	lines.push('return M');
	lines.push('');
	return lines.join('\n');
}

// ======================================================
// ======================================================
// ======= 4. config.toml template rendering =======
// ======================================================
// ======================================================

function tomlValueLiteral(value) {
	if (typeof value === 'boolean') return value ? 'true' : 'false';
	if (typeof value === 'number') {
		if (Number.isInteger(value)) return String(value);
		return value.toString();
	}
	if (typeof value === 'string') {
		const escaped = value
			.replace(/\\/g, '\\\\')
			.replace(/"/g, '\\"')
			.replace(/\n/g, '\\n')
			.replace(/\t/g, '\\t');
		return `"${escaped}"`;
	}
	if (Array.isArray(value)) {
		return '[' + value.map(tomlValueLiteral).join(', ') + ']';
	}
	if (value && typeof value === 'object') {
		const entries = Object.entries(value)
			.map(([k, v]) => `${k} = ${tomlValueLiteral(v)}`)
			.join(', ');
		return `{ ${entries} }`;
	}
	throw new Error(`cannot represent value in TOML literal: ${typeof value}`);
}

// Group features by section path, then emit each section as a TOML block.
// Features whose default is a table become their own sub-section
// [section.id]. Features whose default is a primitive become a flat key
// inside [section].
function renderConfigTemplate(manifest, sections, features, platform) {
	const banner = `# _generated/config_template.toml
# AUTO-GENERATED from _shared/modules/features/manifest.toml.
# DO NOT EDIT BY HAND — run \`npm run build:manifest\` to refresh.
# This is the default v2 config copied into config/ergopti_plus/${platform}/
# on first boot. After that, the user owns the copy.
`;

	const platformFeatures = features.filter((f) => f.platforms.includes(platform));

	// Index features by section for stable emission order.
	const bySection = new Map();
	for (const f of platformFeatures) {
		if (!bySection.has(f.section)) bySection.set(f.section, []);
		bySection.get(f.section).push(f);
	}

	const lines = [banner];

	// Iterate sections in flatten order so the rendered TOML reflects the
	// manifest's authored order. We render sections that have at least one
	// feature for this platform; pure-metadata sections (no features) are
	// skipped.
	for (const sectionPath of Array.from(bySection.keys())) {
		const entries = bySection.get(sectionPath);

		// First pass: primitive defaults → flat keys under [section].
		const flatEntries = entries.filter((e) => {
			const def = resolveDefault(e, platform);
			return typeof def !== 'object' || def === null || Array.isArray(def);
		});
		const tableEntries = entries.filter((e) => {
			const def = resolveDefault(e, platform);
			return typeof def === 'object' && def !== null && !Array.isArray(def);
		});

		if (flatEntries.length > 0) {
			lines.push(`[${sectionPath}]`);
			for (const e of flatEntries) {
				lines.push(`${e.id} = ${tomlValueLiteral(resolveDefault(e, platform))}`);
			}
			lines.push('');
		}

		for (const e of tableEntries) {
			lines.push(`[${sectionPath}.${e.id}]`);
			const def = resolveDefault(e, platform);
			for (const [k, v] of Object.entries(def)) {
				lines.push(`${k} = ${tomlValueLiteral(v)}`);
			}
			lines.push('');
		}
	}

	return lines.join('\n');
}

// ========================================
// ========================================
// ======= 5. Driver dispatch + IO =======
// ========================================
// ========================================

function ensureDir(p) {
	mkdirSync(p, { recursive: true });
}

function writeOutput(absPath, content) {
	ensureDir(dirname(absPath));
	// AHK source retains UTF-8 BOM and follows the repository-wide LF convention.
	const payload = absPath.endsWith('.ahk')
		? '﻿' + content.replace(/\r\n?/g, '\n')
		: content;
	writeFileSync(absPath, payload, 'utf8');
	console.log(`Wrote ${absPath} (${content.length} chars)`);
}

function main() {
	console.log('Loading manifest…');
	const manifest = loadManifest();

	const sections = flattenSections(manifest.sections);
	const features = flattenFeatures(manifest.entries);
	resolvePlatforms(features, sections);
	validate(features);
	console.log(`Parsed ${sections.length} section(s), ${features.length} feature(s).`);

	// AHK outputs
	writeOutput(
		resolve(OUT_AHK_DIR, 'features_manifest.ahk'),
		renderAhkManifest(manifest, sections, features)
	);
	writeOutput(
		resolve(OUT_AHK_DIR, 'config_template.toml'),
		renderConfigTemplate(manifest, sections, features, 'ahk')
	);
	// HS outputs
	writeOutput(
		resolve(OUT_HS_DIR, 'features_manifest.lua'),
		renderLuaManifest(manifest, sections, features, 'hs')
	);
	writeOutput(
		resolve(OUT_HS_DIR, 'config_template.toml'),
		renderConfigTemplate(manifest, sections, features, 'hs')
	);
	// Linux outputs. The driver went without a features manifest for a long
	// time, which is why its keylogger had none of the privacy toggles the
	// other two read from the shared source — it had nowhere to read them from.
	writeOutput(
		resolve(OUT_LINUX_DIR, 'features_manifest.lua'),
		renderLuaManifest(manifest, sections, features, 'linux')
	);
	writeOutput(
		resolve(OUT_LINUX_DIR, 'config_template.toml'),
		renderConfigTemplate(manifest, sections, features, 'linux')
	);
	console.log('Done.');
}

main();
