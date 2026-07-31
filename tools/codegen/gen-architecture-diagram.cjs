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
 * 2. Three-layer model: Ports (contracts) → Adapters (one subgraph per
 *    discovered driver) → Domain
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
const OUT_FILE = path.join(REPO_ROOT, 'static', 'ergopti_plus', 'docs', 'architecture.md');
const DRIVERS_ROOT = path.join(REPO_ROOT, 'static', 'ergopti_plus');

// Prefix used in Mermaid node IDs to avoid reserved-keyword collisions
const PREFIX_PORT = 'P_';
const PREFIX_DOMAIN = 'D_';

/**
 * Every driver, discovered by its adapters/ tree.
 *
 * The two directories used to be hardcoded, which is why a document titled
 * "the three-layer hexagonal architecture" contained zero occurrences of the
 * word "linux" while linux/adapters/ held 22 of them. A diagram is read as the
 * map of the system; one that omits a third of it is worse than none, because
 * nobody re-checks a picture.
 * @returns {{name: string, dir: string, prefix: string, title: string}[]}
 */
function discoverDrivers() {
	// Display names for the drivers that exist; the directory name is only the
	// fallback, so a new driver renders sensibly without an edit here.
	const TITLES = {
		windows: 'Windows (AutoHotkey)',
		macos: 'macOS (Hammerspoon)',
		linux: 'Linux (Lua)'
	};
	return fs
		.readdirSync(DRIVERS_ROOT, { withFileTypes: true })
		.filter((e) => e.isDirectory() && fs.existsSync(path.join(DRIVERS_ROOT, e.name, 'adapters')))
		.map((e) => ({
			name: e.name,
			dir: path.join(DRIVERS_ROOT, e.name, 'adapters'),
			prefix: e.name.toUpperCase().replace(/[^A-Z0-9]/g, '') + '_',
			title: TITLES[e.name] || e.name.charAt(0).toUpperCase() + e.name.slice(1)
		}))
		.sort((a, b) => a.name.localeCompare(b.name));
}

const DRIVERS = discoverDrivers();

// Kept for any external caller; both now derive from the discovered list
// rather than from their own literals.
const AHK_DIR = (DRIVERS.find((d) => d.name === 'windows') || {}).dir;
const HS_DIR = (DRIVERS.find((d) => d.name === 'macos') || {}).dir;

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
	if (!dir || !fs.existsSync(dir)) return [];
	return fs
		.readdirSync(dir)
		.filter((f) => /\.(ahk|lua)$/.test(f))
		.map((f) => f.replace(/\.(ahk|lua)$/, ''))
		.sort();
}

/**
 * Returns the adapter file extension a driver uses, read from disk rather than
 * assumed, so a driver written in a third language needs no edit here.
 * @param {string} dir - Absolute path to the adapters directory.
 * @returns {string} Extension with the dot (e.g. ".lua"), or "" if unknown.
 */
function adapterExtension(dir) {
	if (!dir || !fs.existsSync(dir)) return '';
	const f = fs.readdirSync(dir).find((n) => /\.(ahk|lua)$/.test(n));
	return f ? f.slice(f.lastIndexOf('.')) : '';
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
 * @param {{driver: object, adapters: string[], ext: string}[]} driverData
 *   One entry per discovered driver, in the order they should be drawn.
 * @returns {string} Complete Mermaid graph definition.
 */
function buildDiagram(ports, domain, driverData) {
	const lines = ['graph TD'];

	// --- Ports subgraph ---
	lines.push('');
	lines.push('    subgraph Ports["Ports — shared contracts"]');
	for (const p of ports) {
		lines.push(`        ${nodeId(PREFIX_PORT, p)}["${p}"]`);
	}
	lines.push('    end');

	// --- One adapters subgraph per driver ---
	for (const { driver, adapters, ext } of driverData) {
		lines.push('');
		lines.push(`    subgraph ${driver.prefix}Adapters["${driver.title} Adapters — ${driver.name}/adapters/"]`);
		for (const a of adapters) {
			lines.push(`        ${nodeId(driver.prefix, a)}["${label(a)}${ext}"]`);
		}
		lines.push('    end');
	}

	// --- Domain subgraph ---
	lines.push('');
	lines.push('    subgraph Domain["Domain — shared business logic"]');
	for (const d of domain) {
		lines.push(`        ${nodeId(PREFIX_DOMAIN, d)}["${d}"]`);
	}
	lines.push('    end');

	// --- Port → adapter edges, per driver ---
	for (const { driver, adapters } of driverData) {
		lines.push('');
		lines.push(`    %% Port implementations: ${driver.title}`);
		for (const a of adapters) {
			const p = matchPort(a, ports);
			if (p) {
				lines.push(`    ${nodeId(PREFIX_PORT, p)} -->|implements| ${nodeId(driver.prefix, a)}`);
			}
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

/**
 * Reads every discovered driver's adapter listing once, so the diagram and the
 * regression test see exactly the same data.
 * @returns {{driver: object, adapters: string[], ext: string}[]}
 */
function collectDriverData() {
	return DRIVERS.map((driver) => ({
		driver,
		adapters: readAdapterNames(driver.dir),
		ext: adapterExtension(driver.dir)
	}));
}

function main() {
	console.log('[gen:diagram] Reading specs and adapter listings…');

	const ports = readSpecNames(PORTS_DIR);
	const domain = readSpecNames(DOMAIN_DIR);
	const driverData = collectDriverData();

	console.log(`[gen:diagram]   Ports   : ${ports.length}`);
	console.log(`[gen:diagram]   Domain  : ${domain.length}`);
	for (const { driver, adapters } of driverData) {
		console.log(`[gen:diagram]   ${driver.name.padEnd(8)}: ${adapters.length}`);
	}

	const mermaid = buildDiagram(ports, domain, driverData);
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
	DRIVERS,
	OUT_FILE,
	readSpecNames,
	readAdapterNames,
	adapterExtension,
	collectDriverData,
	buildDiagram,
	wrapMarkdown,
	main
};
