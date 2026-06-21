// scripts/gen-architecture-diagram.cjs

/**
 * ==============================================================================
 * MODULE: Architecture Diagram Generator
 * DESCRIPTION:
 * Auto-generates a Mermaid architecture diagram from port specs, domain specs,
 * and adapter file listings. Writes the output to docs/architecture.md.
 *
 * FEATURES & RATIONALE:
 * 1. Source-driven: reads spec file names and adapter listings directly from
 *    the filesystem so the diagram is always in sync with the actual codebase.
 * 2. Three-layer model: Ports (contracts) → Adapters (AHK / HS) → Domain
 *    modules, showing which ports each adapter implements and which domain
 *    modules exist independently.
 * 3. Zero external deps: uses only Node.js built-ins so it runs without
 *    installing anything beyond what the project already has.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { REPO_ROOT, shared } = require('../lib/paths.cjs');

// ==============================================
// ==============================================
// ======= 1/ Constants and Path Helpers =======
// ==============================================
// ==============================================

// Paths derive from the canonical shared-tree resolver (tools/lib/paths.cjs) so a
// future tree rename is a one-token edit there. The reorg moved
// static/drivers/{autohotkey,hammerspoon,_shared/{ports,domain}} to
// static/ergopti_plus/{windows,macos,_shared/core/{ports,domain}}; the old
// hardcoded constants here (plus a ROOT that resolved to tools/ rather than the
// repo root) pointed at nothing, so the diagram silently regenerated empty.
const PORTS_DIR = shared('core', 'ports');
const DOMAIN_DIR = shared('core', 'domain');
const AHK_DIR = path.join(REPO_ROOT, 'static', 'ergopti_plus', 'windows', 'adapters');
const HS_DIR = path.join(REPO_ROOT, 'static', 'ergopti_plus', 'macos', 'adapters');
const OUT_FILE = path.join(REPO_ROOT, 'static', 'ergopti_plus', 'docs', 'architecture.md');

// Prefix used in Mermaid node IDs to avoid reserved-keyword collisions
const PREFIX_PORT = 'P_';
const PREFIX_DOMAIN = 'D_';
const PREFIX_AHK = 'AHK_';
const PREFIX_HS = 'HS_';

// ====================================
// ====================================
// ======= 2/ Filesystem Reads =======
// ====================================
// ====================================

/**
 * Returns the base names (without extension) of all *.spec.js files in a dir.
 * @param {string} dir - Absolute path to the directory.
 * @returns {string[]} Sorted list of module names.
 */
function readSpecNames(dir) {
	if (!fs.existsSync(dir)) return [];
	return fs
		.readdirSync(dir)
		.filter((f) => f.endsWith('.spec.js'))
		.map((f) => f.replace(/\.spec\.js$/, ''))
		.sort();
}

/**
 * Returns the base names (without extension) of all adapter files in a dir.
 * @param {string} dir - Absolute path to the adapters directory.
 * @returns {string[]} Sorted list of adapter names.
 */
function readAdapterNames(dir) {
	if (!fs.existsSync(dir)) return [];
	return fs
		.readdirSync(dir)
		.filter((f) => /\.(ahk|lua)$/.test(f))
		.map((f) => f.replace(/\.(ahk|lua)$/, ''))
		.sort();
}

// ==============================================
// ==============================================
// ======= 3/ Mermaid ID and Label Helpers =======
// ==============================================
// ==============================================

/**
 * Converts a snake_case or camelCase name to a safe Mermaid node identifier.
 * @param {string} prefix - Short prefix string.
 * @param {string} name   - Raw module/file name.
 * @returns {string} A Mermaid-safe node ID.
 */
function nodeId(prefix, name) {
	// Replace non-alphanumeric characters to keep IDs valid
	return prefix + name.replace(/[^a-zA-Z0-9]/g, '_');
}

/**
 * Produces a human-readable display label from a snake_case name.
 * @param {string} name - Raw module/file name.
 * @returns {string} PascalCase or original name for display.
 */
function label(name) {
	// Convert snake_case to TitleCase for readability
	return name
		.split('_')
		.map((w) => w.charAt(0).toUpperCase() + w.slice(1))
		.join('');
}

/**
 * Derives the port name that an adapter is likely implementing by matching
 * adapter base names (snake_case) against port names (PascalCase).
 * @param {string} adapterName - Snake_case adapter file base name.
 * @param {string[]} portNames - List of PascalCase port names.
 * @returns {string|null} Matching port name, or null if none found.
 */
function matchPort(adapterName, portNames) {
	const normalized = adapterName.replace(/_/g, '').toLowerCase();
	return portNames.find((p) => p.replace(/_/g, '').toLowerCase() === normalized) || null;
}

// ============================================
// ============================================
// ======= 4/ Diagram Generation Logic =======
// ============================================
// ============================================

/**
 * Builds the full Mermaid diagram string from the collected data.
 * @param {string[]} ports   - Port spec names (PascalCase).
 * @param {string[]} domain  - Domain spec names (PascalCase).
 * @param {string[]} ahkAdapters - AHK adapter file base names.
 * @param {string[]} hsAdapters  - HS adapter file base names.
 * @returns {string} Complete Mermaid graph definition.
 */
function buildDiagram(ports, domain, ahkAdapters, hsAdapters) {
	const lines = ['graph TD'];

	// --- Ports subgraph ---
	lines.push('');
	lines.push('    subgraph Ports["Ports — shared contracts"]');
	for (const p of ports) {
		lines.push(`        ${nodeId(PREFIX_PORT, p)}["${p}"]`);
	}
	lines.push('    end');

	// --- AHK adapters subgraph with edges from ports ---
	lines.push('');
	lines.push('    subgraph AHK_Adapters["AHK Adapters — windows/adapters/"]');
	for (const a of ahkAdapters) {
		const lbl = label(a) + '.ahk';
		lines.push(`        ${nodeId(PREFIX_AHK, a)}["${lbl}"]`);
	}
	lines.push('    end');

	// --- HS adapters subgraph with edges from ports ---
	lines.push('');
	lines.push('    subgraph HS_Adapters["HS Adapters — macos/adapters/"]');
	for (const a of hsAdapters) {
		const lbl = label(a) + '.lua';
		lines.push(`        ${nodeId(PREFIX_HS, a)}["${lbl}"]`);
	}
	lines.push('    end');

	// --- Domain subgraph ---
	lines.push('');
	lines.push('    subgraph Domain["Domain — shared business logic"]');
	for (const d of domain) {
		lines.push(`        ${nodeId(PREFIX_DOMAIN, d)}["${d}"]`);
	}
	lines.push('    end');

	// --- Port → AHK adapter edges ---
	lines.push('');
	lines.push('    %% Port implementations: AHK');
	for (const a of ahkAdapters) {
		const p = matchPort(a, ports);
		if (p) {
			lines.push(`    ${nodeId(PREFIX_PORT, p)} -->|implements| ${nodeId(PREFIX_AHK, a)}`);
		}
	}

	// --- Port → HS adapter edges ---
	lines.push('');
	lines.push('    %% Port implementations: Hammerspoon');
	for (const a of hsAdapters) {
		const p = matchPort(a, ports);
		if (p) {
			lines.push(`    ${nodeId(PREFIX_PORT, p)} -->|implements| ${nodeId(PREFIX_HS, a)}`);
		}
	}

	// --- Domain dependency hints (Expander → Registry, HotstringMatcher → Registry) ---
	lines.push('');
	lines.push('    %% Key domain relationships');
	const knownEdges = [
		['Expander', 'Registry'],
		['HotstringMatcher', 'Registry'],
		['Expander', 'Terminators'],
		['HotstringMatcher', 'Terminators']
	];
	for (const [src, dst] of knownEdges) {
		if (domain.includes(src) && domain.includes(dst)) {
			lines.push(`    ${nodeId(PREFIX_DOMAIN, src)} -->|uses| ${nodeId(PREFIX_DOMAIN, dst)}`);
		}
	}

	return lines.join('\n');
}

/**
 * Wraps the Mermaid diagram in a Markdown document with a header and timestamp.
 * @param {string} mermaid - The raw Mermaid diagram text.
 * @returns {string} Full Markdown file content.
 */
function wrapMarkdown(mermaid) {
	const ts = new Date().toISOString().slice(0, 10);
	return [
		'<!-- static/ergopti_plus/docs/architecture.md -->',
		'<!-- AUTO-GENERATED — do not edit by hand. Run: npm run gen:diagram -->',
		'',
		'# Architecture Overview',
		'',
		`> Generated on ${ts} from port specs, domain specs, and adapter file listings.`,
		'',
		'The diagram below shows the three-layer hexagonal architecture:',
		'**Ports** (shared contracts) → **Adapters** (driver-specific implementations) → **Domain** (pure business logic).',
		'',
		'```mermaid',
		mermaid,
		'```',
		''
	].join('\n');
}

// ==============================
// ==============================
// ======= 5/ Entry Point =======
// ==============================
// ==============================

function main() {
	console.log('[gen:diagram] Reading specs and adapter listings…');

	const ports = readSpecNames(PORTS_DIR);
	const domain = readSpecNames(DOMAIN_DIR);
	const ahkAdapters = readAdapterNames(AHK_DIR);
	const hsAdapters = readAdapterNames(HS_DIR);

	console.log(`[gen:diagram]   Ports   : ${ports.length}`);
	console.log(`[gen:diagram]   Domain  : ${domain.length}`);
	console.log(`[gen:diagram]   AHK     : ${ahkAdapters.length}`);
	console.log(`[gen:diagram]   HS      : ${hsAdapters.length}`);

	const mermaid = buildDiagram(ports, domain, ahkAdapters, hsAdapters);
	const markdown = wrapMarkdown(mermaid);

	fs.mkdirSync(path.dirname(OUT_FILE), { recursive: true });
	fs.writeFileSync(OUT_FILE, markdown, 'utf8');

	console.log(`[gen:diagram] Written → ${OUT_FILE}`);
}

// Only run when invoked directly (``node …/gen-architecture-diagram.cjs``); when
// required by the regression test the read helpers and path constants are used
// without the file-writing side effect.
if (require.main === module) {
	main();
}

module.exports = {
	PORTS_DIR,
	DOMAIN_DIR,
	AHK_DIR,
	HS_DIR,
	OUT_FILE,
	readSpecNames,
	readAdapterNames,
	buildDiagram,
	wrapMarkdown,
	main
};
