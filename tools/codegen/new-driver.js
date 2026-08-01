// tools/codegen/new-driver.js

/**
 * ==============================================================================
 * MODULE: New-Driver Scaffold Generator
 * DESCRIPTION:
 * CLI generator that creates the skeleton of a new ergopti driver from the
 * shared port and domain specifications. Running this tool produces a complete
 * directory tree under static/ergopti_plus/<name>/ with stub adapters for every
 * port contract, a README, and a checklist of what still needs implementing.
 *
 * FEATURES & RATIONALE:
 * 1. Ports-driven: scans _shared/core/ports/*.spec.js so the list of adapters to
 *    stub is always in sync with the canonical port definitions.
 * 2. Language-aware: --lang lua generates .lua stubs; --lang ahk generates
 *    .ahk stubs. Defaults to lua.
 * 3. Idempotent guard: aborts if the target directory already exists to prevent
 *    accidental overwrites on an in-progress driver.
 * 4. Zero-dependency: uses only Node.js built-ins (fs, path, url) so it runs
 *    without npm install.
 * ==============================================================================
 */

import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

/**
 * Root of the repository. This file lives in tools/codegen/, so the root is TWO
 * levels up — it was one, which resolved to tools/ and made every path below
 * point into a directory that does not exist.
 */
const REPO_ROOT = path.resolve(__dirname, '..', '..');

/**
 * Where all drivers live.
 *
 * `static/drivers/` is the pre-reorg location. A husk of it still exists on some
 * checkouts as two empty, untracked directories, which is why pointing here
 * failed silently rather than loudly: readSpecNames() found no specs, the
 * scaffold emitted ZERO adapters, and the generated adapters/README.md
 * cheerfully announced "Ports to implement (0)".
 */
const DRIVERS_DIR = path.join(REPO_ROOT, 'static', 'ergopti_plus');

/** Spec sources. Both moved under _shared/core/ in the same reorg. */
const PORTS_DIR = path.join(DRIVERS_DIR, '_shared', 'core', 'ports');
const DOMAIN_DIR = path.join(DRIVERS_DIR, '_shared', 'core', 'domain');

/** Sub-directories every driver is expected to contain (canonical mirror layout:
 *  see the driver READMEs and docs/PROJECT_MEMORY.md). */
const DRIVER_SUBDIRS = ['adapters', 'infra', 'modules', 'ui', 'data', '_generated', 'tests'];

/** Supported target languages. */
const SUPPORTED_LANGS = ['lua', 'ahk'];

/** Comment prefix per language. */
const COMMENT_PREFIX = { lua: '---', ahk: ';' };

/** File extension per language. */
const FILE_EXT = { lua: '.lua', ahk: '.ahk' };

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Converts a PascalCase port name (e.g. "FileSystem") to snake_case file name
 * (e.g. "file_system").
 *
 * @param {string} name - PascalCase identifier.
 * @returns {string} Snake-case equivalent.
 */
function toSnakeCase(name) {
	return name.replace(/([A-Z])/g, (m, c, i) => (i === 0 ? c.toLowerCase() : '_' + c.toLowerCase()));
}

/**
 * Reads all *.spec.js filenames from a directory and extracts the port/domain
 * name (the part before ".spec.js").
 *
 * @param {string} dir - Absolute path to the spec directory.
 * @returns {string[]} Sorted list of spec names.
 */
function readSpecNames(dir) {
	if (!fs.existsSync(dir)) return [];
	return fs
		.readdirSync(dir)
		.filter((f) => f.endsWith('.spec.js'))
		.map((f) => f.replace('.spec.js', ''))
		.sort();
}

/**
 * Builds the stub file content for one adapter in the target language.
 *
 * @param {string} driverName - Name of the new driver (e.g. "my-driver").
 * @param {string} portName   - PascalCase port name (e.g. "FileSystem").
 * @param {"lua"|"ahk"} lang  - Target language.
 * @returns {string} Full file content.
 */
function buildAdapterStub(driverName, portName, lang) {
	const c = COMMENT_PREFIX[lang];
	const ext = FILE_EXT[lang];
	const snakeName = toSnakeCase(portName);
	const filePath = `static/ergopti_plus/${driverName}/adapters/${snakeName}${ext}`;
	const specRef = `static/ergopti_plus/_shared/core/ports/${portName}.spec.js`;

	if (lang === 'lua') {
		return [
			`--- ${filePath}`,
			``,
			`--- ==============================================================================`,
			`--- MODULE: ${portName} Adapter (${driverName})`,
			`--- DESCRIPTION:`,
			`--- ${driverName} implementation of the ${portName} port contract defined in`,
			`--- ${specRef}.`,
			`---`,
			`--- TODO: Replace every stub below with a real implementation that satisfies`,
			`--- the contract described in the spec file referenced above.`,
			`--- ==============================================================================`,
			``,
			`local M = {}`,
			``,
			``,
			``,
			``,
			``,
			`-- ============================================================`,
			`-- ============================================================`,
			`-- ======= 1/ ${portName} Port Implementation =======`,
			`-- ============================================================`,
			`-- ============================================================`,
			``,
			`--- TODO: implement ${portName} contract`,
			`--- See: ${specRef}`,
			``,
			``,
			``,
			``,
			`return M`,
			``
		].join('\n');
	}

	// AHK
	return [
		`; ${filePath}`,
		``,
		`; ==============================================================================`,
		`; MODULE: ${portName} Adapter (${driverName})`,
		`; DESCRIPTION:`,
		`; ${driverName} implementation of the ${portName} port contract defined in`,
		`; ${specRef}.`,
		`;`,
		`; TODO: Replace every stub below with a real implementation that satisfies`,
		`; the contract described in the spec file referenced above.`,
		`; ==============================================================================`,
		``,
		``,
		``,
		``,
		``,
		`; ============================================================`,
		`; ============================================================`,
		`; ======= 1/ ${portName} Port Implementation =======`,
		`; ============================================================`,
		`; ============================================================`,
		``,
		`; TODO: implement ${portName} contract`,
		`; See: ${specRef}`,
		``
	].join('\n');
}

/**
 * Builds the top-level README.md for the new driver.
 *
 * @param {string} driverName - Name of the new driver.
 * @param {string[]} ports    - List of port names to implement.
 * @param {string[]} domains  - List of domain spec names.
 * @param {"lua"|"ahk"} lang  - Target language.
 * @returns {string} Markdown content.
 */
function buildDriverReadme(driverName, ports, domains, lang) {
	const portList = ports.map((p) => `- \`${p}\``).join('\n');
	const domainList = domains.map((d) => `- \`${d}\``).join('\n');

	return [
		`# ${driverName} Driver`,
		``,
		`> Generated by \`scripts/new-driver.js\`. Replace this README with real documentation.`,
		``,
		`## Overview`,
		``,
		`This driver implements the ergopti hexagonal architecture for \`${driverName}\`.`,
		`The language target is **${lang}**.`,
		``,
		`## Directory structure`,
		``,
		`\`\`\``,
		`${driverName}/`,
		`  adapters/    One file per port contract (see _shared/core/ports/)`,
		`  modules/     Internal domain-specific modules`,
		`  tests/       Unit and integration tests`,
		`  lib/         Utilities shared across this driver`,
		`\`\`\``,
		``,
		`## Ports to implement (${ports.length})`,
		``,
		portList,
		``,
		`## Domain specs (${domains.length})`,
		``,
		domainList,
		``,
		`## Getting started`,
		``,
		`1. Open \`adapters/\` and implement every TODO stub.`,
		`2. Run the shared port compliance test:`,
		`   \`npm run test:port-compliance\``,
		`3. Add driver-specific tests under \`tests/\`.`,
		`4. Update this README with runtime requirements and setup instructions.`,
		``
	].join('\n');
}

/**
 * Builds the adapters/README.md listing all ports to implement.
 *
 * @param {string} driverName - Name of the new driver.
 * @param {string[]} ports    - List of port names.
 * @param {"lua"|"ahk"} lang  - Target language.
 * @returns {string} Markdown content.
 */
function buildAdaptersReadme(driverName, ports, lang) {
	const ext = FILE_EXT[lang];
	const rows = ports
		.map((p) => {
			const file = toSnakeCase(p) + ext;
			return `| \`${file}\` | \`${p}\` | \`_shared/core/ports/${p}.spec.js\` | ❌ TODO |`;
		})
		.join('\n');

	return [
		`# ${driverName} — Adapters`,
		``,
		`Each file in this directory implements one port contract from`,
		`\`static/ergopti_plus/_shared/core/ports/\`.`,
		``,
		`| File | Port | Spec | Status |`,
		`|------|------|------|--------|`,
		rows,
		``,
		`Replace the ❌ TODO status cells as you implement each adapter.`,
		``
	].join('\n');
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

/**
 * Entry point — parses CLI args, validates inputs, and generates the scaffold.
 */
function main() {
	const args = process.argv.slice(2);

	// Parse --lang flag
	let lang = 'lua';
	const langIdx = args.indexOf('--lang');
	if (langIdx !== -1) {
		lang = args[langIdx + 1];
		args.splice(langIdx, 2);
	}

	const driverName = args[0];

	// Validate arguments
	if (!driverName) {
		console.error('Usage: node scripts/new-driver.js <driver-name> [--lang lua|ahk]');
		process.exit(1);
	}

	if (!/^[a-z][a-z0-9-]*$/.test(driverName)) {
		console.error(
			`Error: driver name "${driverName}" must be lowercase letters, digits, and hyphens only.`
		);
		process.exit(1);
	}

	if (!SUPPORTED_LANGS.includes(lang)) {
		console.error(
			`Error: unsupported language "${lang}". Supported: ${SUPPORTED_LANGS.join(', ')}`
		);
		process.exit(1);
	}

	const targetDir = path.join(DRIVERS_DIR, driverName);

	if (fs.existsSync(targetDir)) {
		console.error(`Error: directory already exists: ${targetDir}`);
		console.error('Remove it first or choose a different driver name.');
		process.exit(1);
	}

	// Collect specs
	const ports = readSpecNames(PORTS_DIR);
	const domains = readSpecNames(DOMAIN_DIR);

	// A scaffold with no adapters is not a scaffold — it is an empty directory
	// tree and a README claiming there is nothing to implement. That is what this
	// tool produced for as long as its paths were stale, and nothing about the
	// output said so. Refuse instead.
	if (ports.length === 0) {
		console.error(`Error: no port specs found in ${PORTS_DIR}`);
		console.error('Refusing to scaffold a driver with zero adapters — fix the spec path first.');
		process.exit(1);
	}

	console.log(`\nGenerating driver scaffold: ${driverName} (lang=${lang})`);
	console.log(`Ports found:  ${ports.length}`);
	console.log(`Domain specs: ${domains.length}\n`);

	// Create subdirectories
	for (const sub of DRIVER_SUBDIRS) {
		fs.mkdirSync(path.join(targetDir, sub), { recursive: true });
		console.log(`  Created  ${driverName}/${sub}/`);
	}

	// Generate adapter stubs
	const ext = FILE_EXT[lang];
	for (const port of ports) {
		const snakeName = toSnakeCase(port);
		const adapterPath = path.join(targetDir, 'adapters', snakeName + ext);
		fs.writeFileSync(adapterPath, buildAdapterStub(driverName, port, lang), 'utf8');
		console.log(`  Created  ${driverName}/adapters/${snakeName}${ext}  (${port})`);
	}

	// Generate READMEs
	fs.writeFileSync(
		path.join(targetDir, 'README.md'),
		buildDriverReadme(driverName, ports, domains, lang),
		'utf8'
	);
	console.log(`  Created  ${driverName}/README.md`);

	fs.writeFileSync(
		path.join(targetDir, 'adapters', 'README.md'),
		buildAdaptersReadme(driverName, ports, lang),
		'utf8'
	);
	console.log(`  Created  ${driverName}/adapters/README.md`);

	// Print checklist
	console.log(`
Done. Next steps:
─────────────────────────────────────────────────────────────────
  [ ] Implement each adapter stub in static/ergopti_plus/${driverName}/adapters/
      (${ports.length} files — one per port contract in _shared/core/ports/)

  [ ] Satisfy the domain specs listed in static/ergopti_plus/_shared/core/domain/
      (${domains.length} specs: ${domains.join(', ')})

  [ ] Add driver entry-point under static/ergopti_plus/${driverName}/
      (e.g. a main .${lang === 'lua' ? 'lua' : 'ahk'} file equivalent to linux/ergopti_hotstrings.lua)

  [ ] Add tests under static/ergopti_plus/${driverName}/tests/

  [ ] Run: npm run test:port-compliance
      to verify every adapter satisfies its contract

  [ ] Update static/ergopti_plus/${driverName}/README.md with real documentation

  [ ] Update static/ergopti_plus/${driverName}/adapters/README.md status column
─────────────────────────────────────────────────────────────────`);
}

main();
