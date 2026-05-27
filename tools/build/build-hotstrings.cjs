// scripts/build-hotstrings.cjs

/**
 * ==============================================================================
 * MODULE: Node.js Hotstrings Compiler
 * DESCRIPTION:
 * Reads the TOML hotstring files under ``static/ergopti_plus/_shared/hotstrings/``
 * and emits one AHK file per category plus a thin ``hotstrings_generated.ahk``
 * entry-point that ``#Include``s all per-category files. This Node.js port
 * replaces ``tools/compile_hotstrings.py`` to unify the pipeline under Node.
 *
 * FEATURES & RATIONALE:
 * 1. Startup cost collapses: the bundled categories (~3 000 entries across five
 *    files) no longer go through a per-line regex parse at every ``.exe`` launch.
 *    The generated .ahk contains direct calls bound by Ahk2Exe into the
 *    executable.
 * 2. Per-category split: each category lives in its own file
 *    (``generated_<category>.ahk``) so diffs and reviews are scoped to the
 *    relevant domain. ``hotstrings_generated.ahk`` becomes a thin entry-point
 *    that ``#Include``s all of them; existing consumers of that file require no
 *    change.
 * 3. The runtime fallback in ``LoadHotstringsSection`` is kept intact so the
 *    user-level ``personal_hotstrings.toml`` (path overridable via the ini)
 *    still loads through the existing parser.
 * 4. ``★`` substitution is preserved: triggers containing the default magic key
 *    character are wrapped in ``StrReplace(trigger, "★", MK)`` so the runtime
 *    ``ScriptInformation["MagicKey"]`` continues to drive the actual key seen
 *    by the hotstring engine.
 * ==============================================================================
 */

"use strict";

const fs   = require("fs");
const path = require("path");
const { parse } = require("smol-toml");




// ====================================
// ====================================
// ======= 1/ Constants =======
// ====================================
// ====================================

// Categories bundled with the repo and therefore compile-time known.
// "personal" is deliberately excluded: its TOML can live outside the repo
// (ScriptInformation["PersonalTomlPath"]) and must keep loading through the
// runtime parser.
const BUNDLED_CATEGORIES = [
	"distancesreduction",
	"sfbsreduction",
	"rolls",
	"autocorrection",
	"magickey",
];

// Literal magic-key marker used inside TOML triggers / outputs. Runtime
// substitution is done with StrReplace(trigger, MAGIC_KEY_MARKER, MK).
const MAGIC_KEY_MARKER = "★"; // ★

const REPO_ROOT       = path.resolve(__dirname, "..");
const TOML_SOURCE_DIR = path.join(REPO_ROOT, "static", "drivers", "_shared", "hotstrings");
const OUTPUT_DIR      = path.join(REPO_ROOT, "static", "drivers", "autohotkey", "lib", "hotstrings");

// UTF-8 BOM prefix — required for AHK v2 source files.
const UTF8_BOM = "﻿";




// ====================================
// ====================================
// ======= 2/ Escaping helpers =======
// ====================================
// ====================================

/**
 * Escape a string for use inside an AHK v2 double-quoted literal.
 * @param {string} s - Raw string value.
 * @returns {string} AHK-escaped string.
 */
function ahkEscape(s) {
	// Backtick is AHK's escape character — must be escaped first
	return s
		.replace(/`/g, "``")
		.replace(/"/g, "`\"")
		.replace(/\n/g, "`n")
		.replace(/\r/g, "`r")
		.replace(/\t/g, "`t")
		.replace(/;/g, "`;");
}

/**
 * Format a truthy/falsy value as an AHK v2 bool literal.
 * @param {unknown} value - Value to convert.
 * @returns {"true"|"false"} AHK bool string.
 */
function ahkBool(value) {
	return value ? "true" : "false";
}

/**
 * Return the AHK expression that yields the runtime trigger string.
 * When the trigger contains the magic-key marker a StrReplace is emitted so
 * the user's current ScriptInformation["MagicKey"] is applied at boot.
 * @param {string} trigger - Raw trigger string.
 * @returns {string} AHK expression.
 */
function triggerExpr(trigger) {
	const escaped = ahkEscape(trigger);
	if (trigger.includes(MAGIC_KEY_MARKER)) {
		return `StrReplace("${escaped}", "★", _GenMK)`;
	}
	return `"${escaped}"`;
}




// ====================================
// ====================================
// ======= 3/ Entry emission =======
// ====================================
// ====================================

/**
 * Derive the AHK hotstring flags from a TOML entry, replicating the logic in
 * lib/toml_loader.ahk.
 * @param {Record<string, unknown>} entry - Parsed TOML entry object.
 * @returns {string} Flag string (e.g. "*?C").
 */
function computeFlags(entry) {
	let flags = "";
	if (entry["auto_expand"])              flags += "*";
	if (!entry["is_word"])                 flags += "?";
	if (entry["is_case_sensitive_strict"]) flags += "C";
	return flags;
}

/**
 * Emit the lines (options + call) for one TOML hotstring entry into the output
 * array.
 * @param {string[]} out - Accumulator array for output lines.
 * @param {string} trigger - Hotstring trigger string.
 * @param {Record<string, unknown>} entry - Parsed TOML entry object.
 * @param {boolean} isRepeatSection - Whether this section is the magic-key repeatcorrections.
 * @param {string} category - Category name for the registry metadata.
 * @param {string} section - Section name for the registry metadata.
 */
function emitEntry(out, trigger, entry, isRepeatSection, category, section) {
	const output      = entry["output"]              ?? "";
	const flags       = computeFlags(entry);
	// Counter-intuitive flag mapping preserved from the runtime loader:
	//   is_case_sensitive = true  → single-variant CreateHotstring
	//   is_case_sensitive = false → all-variants CreateCaseSensitiveHotstrings
	const isCaseSens  = entry["is_case_sensitive"]   ?? false;
	const finalResult = entry["final_result"]        ?? false;
	// Only mark as a repeat trigger when the trigger itself contains the magic-key
	// marker — plain-text corrections must not be gated by the repeat-specific
	// word-position check.
	const isRepeat    = isRepeatSection && trigger.includes(MAGIC_KEY_MARKER);

	let optionsLine = (
		`\t_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", ` +
		`${ahkBool(finalResult)}, "IsRepeat", ${ahkBool(isRepeat)}` +
		(category ? `, "Category", "${category}"` : "") +
		(section  ? `, "Section", "${section}"`   : "") +
		")"
	);
	out.push(optionsLine);
	out.push(
		'\tif IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {\n' +
		'\t\t_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]\n' +
		"\t}"
	);

	const fn             = isCaseSens ? "CreateHotstring" : "CreateCaseSensitiveHotstrings";
	const outputEscaped  = ahkEscape(String(output));
	out.push(`\t${fn}("${flags}", ${triggerExpr(trigger)}, "${outputEscaped}", _GenOpts)`);
}




// ====================================
// ====================================
// ======= 4/ Banner helpers =======
// ====================================
// ====================================

/**
 * Generate a correctly-aligned major section banner for AHK files.
 * @param {string} title - Section title text.
 * @returns {string} Banner block with 5 blank lines before it.
 */
function makeMajorBanner(title) {
	// Total expected length: prefix(2) + leftEq(7) + 1 + title + 1 + rightEq(7)
	const expectedLen = 2 + 7 + 1 + title.length + 1 + 7;
	const bar         = "; " + "=".repeat(expectedLen - 2);
	const titleLine   = `; ${"=".repeat(7)} ${title} ${"=".repeat(7)}`;
	// 6 newlines = end-of-previous-line \n + 5 blank lines per convention
	return "\n\n\n\n\n\n" + bar + "\n" + bar + "\n" + titleLine + "\n" + bar + "\n" + bar + "\n\n";
}

// Pre-built banners reused in every per-category file
const REGISTRY_BANNER = makeMajorBanner("1/ Generated registry");
const LOADERS_BANNER  = makeMajorBanner("2/ Generated loaders");




// ====================================
// ====================================
// ======= 5/ Section and file emission =======
// ====================================
// ====================================

/**
 * Return the file-path comment and module docstring for a per-category AHK file.
 * @param {string} category - Category name.
 * @returns {string} File header block.
 */
function categoryFileHeader(category) {
	return (
		`; static/ergopti_plus/windows/lib/hotstrings/generated_${category}.ahk\n` +
		"\n" +
		"; ==============================================================================\n" +
		`; MODULE: Generated Hotstrings — ${category}\n` +
		"; DESCRIPTION:\n" +
		"; AUTO-GENERATED FILE — DO NOT EDIT BY HAND.\n" +
		"; Regenerate with ``node scripts/build-hotstrings.cjs`` from the repo root\n" +
		"; whenever the bundled TOML files under ``static/ergopti_plus/_shared/hotstrings/`` change.\n" +
		";\n" +
		"; Contains the ``_GenLoad_*`` loader functions and the partial\n" +
		`; \`\`_GENERATED_HOTSTRINGS\`\` map entries for the \`\`${category}\`\` category.\n` +
		"; Included automatically by ``hotstrings_generated.ahk``.\n" +
		"; ==============================================================================\n"
	);
}

const ENTRY_POINT_HEADER =
	"; static/ergopti_plus/windows/lib/hotstrings/hotstrings_generated.ahk\n" +
	"\n" +
	"; ==============================================================================\n" +
	"; MODULE: Generated Hotstrings Registrar — Entry Point\n" +
	"; DESCRIPTION:\n" +
	"; AUTO-GENERATED FILE — DO NOT EDIT BY HAND.\n" +
	"; Regenerate with ``node scripts/build-hotstrings.cjs`` from the repo root\n" +
	"; whenever the bundled TOML files under ``static/ergopti_plus/_shared/hotstrings/`` change.\n" +
	";\n" +
	"; This file is a thin entry-point that ``#Include``s one generated file per\n" +
	"; category. Consumers that already ``#Include`` this file require no change.\n" +
	"; ``LoadHotstringsSection`` consults ``_GENERATED_HOTSTRINGS`` first and only\n" +
	"; falls back to the TOML parser for the ``personal`` category and for sections\n" +
	"; this file does not cover (e.g. a freshly-added TOML file that has not yet\n" +
	"; been recompiled).\n" +
	"; ==============================================================================\n" +
	"\n" +
	"\n";

/**
 * Emit one generated loader function and return its AHK name for the registry.
 * @param {string[]} out - Accumulator array for output lines.
 * @param {string} category - Category name.
 * @param {string} section - Section name.
 * @param {Array<Record<string, unknown>>} entries - Array of TOML entry objects.
 * @returns {string} The generated AHK function name.
 */
function emitSection(out, category, section, entries) {
	const fnName = `_GenLoad_${category}_${section}`;
	out.push(`${fnName}(FeatureConfig, ExtraOptions := unset) {`);
	out.push("\tglobal ScriptInformation");
	// Prefix every local with _Gen so #Warn LocalSameAsGlobal does not flag
	// a clash with same-named top-level assignments elsewhere in the driver
	out.push(
		'\t_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ' +
		"? FeatureConfig.TimeActivationSeconds : 0"
	);
	out.push('\t_GenMK := ScriptInformation["MagicKey"]');

	const isRepeatSection = (category === "magickey" && section === "repeatcorrections");
	for (const entryDict of entries) {
		for (const [trigger, data] of Object.entries(entryDict)) {
			emitEntry(out, trigger, data, isRepeatSection, category, section);
		}
	}
	out.push("}");
	out.push("");
	return fnName;
}

/**
 * Compile every section block of one category TOML file.
 * @param {string} category - Category name matching the TOML file stem.
 * @returns {{ content: string, registry: Array<[string, string]> }} Compiled AHK content and registry tuples.
 */
function compileCategory(category) {
	const tomlPath = path.join(TOML_SOURCE_DIR, `${category}.toml`);
	if (!fs.existsSync(tomlPath)) {
		process.stderr.write(`[build-hotstrings] skip (missing): ${tomlPath}\n`);
		return { content: "", registry: [] };
	}

	const raw  = fs.readFileSync(tomlPath, "utf8");
	const data = parse(raw);

	/** @type {Array<[string, string]>} */
	const registry      = [];
	/** @type {string[]} */
	const functionsOut  = [];

	for (const [key, value] of Object.entries(data)) {
		// _meta and _meta.sections are consumed by the runtime metadata loader
		// (ApplyTomlMetadataToFeatures), not by the hotstring registrar
		if (key.startsWith("_"))      continue;
		if (!Array.isArray(value))    continue;

		const section = key.toLowerCase();
		const fnName  = emitSection(functionsOut, category, section, value);
		registry.push([`${category}.${section}`, fnName]);
	}

	// Build the per-category partial registry map
	const registryLines = [`global _GENERATED_HOTSTRINGS_${category.toUpperCase()} := Map(`];
	for (const [k, fn] of registry) {
		registryLines.push(`\t"${k}", ${fn},`);
	}
	registryLines.push(")");

	const content =
		categoryFileHeader(category) +
		REGISTRY_BANNER +
		registryLines.join("\n") +
		LOADERS_BANNER +
		functionsOut.join("\n") +
		"\n";

	return { content, registry };
}

/**
 * Compile all categories and build the entry-point file.
 * @returns {{ perCategory: Record<string, string>, entryPoint: string }} Maps filename to AHK source.
 */
function build() {
	/** @type {Record<string, string>} */
	const perCategory         = {};
	/** @type {Array<[string, string]>} */
	const allRegistry         = [];
	/** @type {string[]} */
	const includedCategories  = [];

	for (const category of BUNDLED_CATEGORIES) {
		const { content, registry } = compileCategory(category);
		if (!content) continue;
		perCategory[`generated_${category}.ahk`] = content;
		allRegistry.push(...registry);
		includedCategories.push(category);
	}

	// Thin entry-point: #Include each per-category file then merge partial maps
	const includeLines = includedCategories
		.map((cat) => `#Include generated_${cat}.ahk`)
		.join("\n");

	const mergeBanner = makeMajorBanner("1/ Merge per-category maps into _GENERATED_HOTSTRINGS");
	const mergeLines  = ["global _GENERATED_HOTSTRINGS := Map()"];
	for (const category of includedCategories) {
		mergeLines.push(
			`for _k, _v in _GENERATED_HOTSTRINGS_${category.toUpperCase()}` +
			`\n\t_GENERATED_HOTSTRINGS[_k] := _v`
		);
	}

	const entryPoint =
		ENTRY_POINT_HEADER +
		includeLines +
		mergeBanner +
		mergeLines.join("\n") +
		"\n";

	return { perCategory, entryPoint };
}




// ====================================
// ====================================
// ======= 6/ Main =======
// ====================================
// ====================================

/**
 * Entry-point: compile hotstrings and write all generated AHK files with
 * UTF-8 BOM + CRLF line endings as required by AHK v2.
 */
function main() {
	/**
	 * Convert LF line endings to CRLF and prepend UTF-8 BOM.
	 * @param {string} content - Raw string with LF endings.
	 * @returns {Buffer} Buffer ready to write to disk.
	 */
	function toAhkBuffer(content) {
		const crlf = content.replace(/\r\n/g, "\n").replace(/\n/g, "\r\n");
		return Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), Buffer.from(crlf, "utf8")]);
	}

	const { perCategory, entryPoint } = build();

	let totalBytes = 0;
	for (const [filename, content] of Object.entries(perCategory)) {
		const outPath = path.join(OUTPUT_DIR, filename);
		const buf     = toAhkBuffer(content);
		fs.writeFileSync(outPath, buf);
		totalBytes += buf.length;
		process.stdout.write(`[build-hotstrings] wrote ${outPath} (${buf.length.toLocaleString()} bytes)\n`);
	}

	const entryPath = path.join(OUTPUT_DIR, "hotstrings_generated.ahk");
	const entryBuf  = toAhkBuffer(entryPoint);
	fs.writeFileSync(entryPath, entryBuf);
	process.stdout.write(
		`[build-hotstrings] wrote ${entryPath} (${entryBuf.length.toLocaleString()} bytes)` +
		` — entry-point #Including ${Object.keys(perCategory).length} category file(s)` +
		` (${totalBytes.toLocaleString()} bytes of hotstring code)\n`
	);
}

main();
