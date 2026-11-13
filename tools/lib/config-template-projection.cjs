// tools/lib/config-template-projection.cjs

/**
 * ==============================================================================
 * MODULE: Shared Config Template And Its Driver Projections
 * DESCRIPTION:
 * The default config.toml of the three drivers is written once, in
 * _shared/_generated/config_template.toml, and each driver's
 * _generated/config_template.toml is the projection of that file onto one
 * driver. This module renders both texts and projects the shared one, so the
 * generator, the packaging that copies a driver template to users and the
 * tests all read the same spelling.
 *
 * FEATURES & RATIONALE:
 * 1. Shared shape: a key line `key = value` inside a table holds for every
 *    driver whose view contains that table; `platform.<driver>.key = value`
 *    holds for that driver only (a driver-only key, or a default the drivers
 *    disagree on). Dotted keys keep a driver-only key at its place among the
 *    shared ones, which per-driver overlay tables could not. `[platform.<driver>]
 *    sections` lists the tables of that driver's view in its order: the order
 *    depends on which features a driver has, so it cannot be one file order.
 * 2. Byte-exact projection: values are copied as the generator spelled them,
 *    never decoded and re-encoded, so a projection carries the same bytes as
 *    the template the generator used to render for each driver.
 * 3. Fail fast: an unknown line, driver or table, or a table no driver lists,
 *    throws instead of producing a partial template.
 * ==============================================================================
 */

'use strict';

/** Driver keys of the features manifest, in the order the shared file lists them. */
const DRIVERS = ['ahk', 'hs', 'linux'];

/** The dotted prefix that marks a driver-only key and names the order tables. */
const PLATFORM_ROOT = 'platform';

// House spacing of both codecs (`toml_codec/codec.lua`, the Windows flat writer):
// five blank lines before a top-level header, three before a nested one.
const TOP_HEADER_SPACING = 5;
const NESTED_HEADER_SPACING = 3;

const BARE_KEY = /^[A-Za-z0-9_-]+$/;
const HEADER_NAME = /^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*$/;

// ===================================
// ===================================
// ======= 1. Text rendering =======
// ===================================
// ===================================

/**
 * @param {string} platform Driver key.
 * @returns {string} The banner of that driver's template.
 */
function driverBanner(platform) {
	return `# _generated/config_template.toml
# AUTO-GENERATED from _shared/settings/data/features/manifest.toml.
# DO NOT EDIT BY HAND — run \`npm run build:manifest\` to refresh.
# This is the default v2 config copied into config/ergopti_plus/${platform}/
# on first boot. After that, the user owns the copy.
`;
}

const SHARED_BANNER = `# _shared/_generated/config_template.toml
# AUTO-GENERATED from _shared/settings/data/features/manifest.toml.
# DO NOT EDIT BY HAND — run \`npm run build:manifest\` to refresh.
# The default v2 config of the three drivers (ahk, hs, linux), written once.
# - \`key = value\` holds for every driver whose view contains the table.
# - \`platform.<driver>.key = value\` holds for that driver only: a key only it
#   has, or a default the drivers disagree on.
# - [platform.<driver>] sections lists the tables of that driver's view, in
#   that driver's order.
# A driver's view is those tables, each with its shared keys and its own
# platform.<driver>. keys (prefix removed), in file order. That view is
# <driver dir>/_generated/config_template.toml, rendered by
# tools/lib/config-template-projection.cjs.
`;

/**
 * Append a header with the house spacing above it.
 * @param {string[]} lines Output lines; the first one is the banner.
 * @param {string} header Table name without brackets.
 */
function pushHeader(lines, header) {
	if (lines.length > 1) {
		const spacing = header.includes('.') ? NESTED_HEADER_SPACING : TOP_HEADER_SPACING;
		// The previous block already ended with one blank line.
		for (let i = 1; i < spacing; i++) lines.push('');
	}
	lines.push(`[${header}]`);
}

/**
 * @param {string} platform Driver key.
 * @param {{header: string, rows: [string, string][]}[]} sections The driver's
 *   tables in order, each with its `[key, value literal]` rows.
 * @returns {string} The driver's config template.
 */
function renderDriverTemplate(platform, sections) {
	if (!DRIVERS.includes(platform)) throw new Error(`unknown driver ${platform}`);
	const lines = [driverBanner(platform)];
	for (const { header, rows } of sections) {
		pushHeader(lines, header);
		for (const [key, literal] of rows) lines.push(`${key} = ${literal}`);
		lines.push('');
	}
	return lines.join('\n');
}

function compareRank(a, b) {
	for (let i = 0; i < Math.max(a.length, b.length); i++) {
		const d = (a[i] ?? -1) - (b[i] ?? -1);
		if (d !== 0) return d;
	}
	return 0;
}

/**
 * Merge the three driver views into the shared template.
 * @param {Record<string, {header: string, rank: number[],
 *   rows: {key: string, literal: string, rank: number[]}[]}[]>} views Each
 *   driver's tables in its order; `rank` places a table or a key in the
 *   manifest's authored order, and is the same for one key on every driver.
 * @returns {string} The shared template.
 */
function renderSharedTemplate(views) {
	const tables = new Map();
	for (const platform of DRIVERS) {
		const view = views[platform];
		if (!Array.isArray(view)) throw new Error(`no config template view for ${platform}`);
		for (const section of view) {
			if (!HEADER_NAME.test(section.header) || section.header.split('.')[0] === PLATFORM_ROOT) {
				throw new Error(`config template table [${section.header}] cannot be projected`);
			}
			if (!tables.has(section.header)) {
				tables.set(section.header, { rank: section.rank, drivers: [], keys: new Map() });
			}
			const table = tables.get(section.header);
			if (compareRank(section.rank, table.rank) < 0) table.rank = section.rank;
			table.drivers.push(platform);
			for (const row of section.rows) {
				if (!BARE_KEY.test(row.key)) {
					throw new Error(`config template key ${section.header}.${row.key} is not a bare key`);
				}
				if (!table.keys.has(row.key)) table.keys.set(row.key, { rank: row.rank, values: {} });
				const key = table.keys.get(row.key);
				if (compareRank(row.rank, key.rank) !== 0) {
					throw new Error(`config template key ${section.header}.${row.key} has two places`);
				}
				key.values[platform] = row.literal;
			}
		}
	}

	const lines = [SHARED_BANNER];
	const ordered = [...tables.entries()].sort(
		(a, b) => compareRank(a[1].rank, b[1].rank) || (a[0] < b[0] ? -1 : 1)
	);
	for (const [header, table] of ordered) {
		pushHeader(lines, header);
		const keys = [...table.keys.entries()].sort((a, b) => compareRank(a[1].rank, b[1].rank));
		for (const [key, { values }] of keys) {
			const literals = table.drivers.map((platform) => values[platform]);
			if (literals.every((literal) => literal !== undefined && literal === literals[0])) {
				lines.push(`${key} = ${literals[0]}`);
				continue;
			}
			for (const platform of table.drivers) {
				if (values[platform] !== undefined) {
					lines.push(`${PLATFORM_ROOT}.${platform}.${key} = ${values[platform]}`);
				}
			}
		}
		lines.push('');
	}
	for (const platform of DRIVERS) {
		pushHeader(lines, `${PLATFORM_ROOT}.${platform}`);
		lines.push('sections = [');
		for (const section of views[platform]) lines.push(`\t"${section.header}",`);
		lines.push(']');
		lines.push('');
	}
	return lines.join('\n');
}

// ==================================
// ==================================
// ======= 2. Projection =======
// ==================================
// ==================================

/**
 * Read the shared template into its tables and driver orders.
 * @param {string} text The shared template.
 * @returns {{tables: Map<string, {driver: string|null, key: string, literal: string}[]>,
 *   orders: Record<string, string[]>}}
 */
function parseSharedTemplate(text) {
	const tables = new Map();
	const orders = {};
	let current = null;
	let listing = null;
	const lines = text.split('\n');
	lines.forEach((line, index) => {
		const where = `config template line ${index + 1}`;
		if (listing !== null) {
			if (line === ']') {
				listing = null;
				return;
			}
			const match = /^\t"([^"\\]+)",$/.exec(line);
			if (!match) throw new Error(`${where}: expected a quoted table name, got ${line}`);
			listing.push(match[1]);
			return;
		}
		if (line === '' || line.startsWith('#')) return;
		const header = /^\[([^\]]+)\]$/.exec(line);
		if (header) {
			current = header[1];
			const order = new RegExp(`^${PLATFORM_ROOT}\\.(.+)$`).exec(current);
			if (order) {
				if (!DRIVERS.includes(order[1])) throw new Error(`${where}: unknown driver ${order[1]}`);
				if (orders[order[1]]) throw new Error(`${where}: [${current}] appears twice`);
			} else if (tables.has(current)) {
				throw new Error(`${where}: [${current}] appears twice`);
			} else {
				tables.set(current, []);
			}
			return;
		}
		if (current === null) throw new Error(`${where}: key outside a table`);
		const order = new RegExp(`^${PLATFORM_ROOT}\\.(.+)$`).exec(current);
		if (order) {
			if (line !== 'sections = [') throw new Error(`${where}: expected sections = [, got ${line}`);
			listing = [];
			orders[order[1]] = listing;
			return;
		}
		const separator = line.indexOf(' = ');
		if (separator <= 0) throw new Error(`${where}: expected key = value, got ${line}`);
		const name = line.slice(0, separator);
		const literal = line.slice(separator + 3);
		const scoped = new RegExp(`^${PLATFORM_ROOT}\\.([^.]+)\\.(.+)$`).exec(name);
		if (scoped && !DRIVERS.includes(scoped[1])) {
			throw new Error(`${where}: unknown driver ${scoped[1]}`);
		}
		const row = scoped
			? { driver: scoped[1], key: scoped[2], literal }
			: { driver: null, key: name, literal };
		if (!BARE_KEY.test(row.key)) throw new Error(`${where}: ${row.key} is not a bare key`);
		tables.get(current).push(row);
	});
	if (listing !== null) throw new Error('config template: unterminated sections list');
	for (const platform of DRIVERS) {
		if (!orders[platform])
			throw new Error(`config template: no [${PLATFORM_ROOT}.${platform}] sections`);
	}
	const listed = new Set(Object.values(orders).flat());
	for (const header of tables.keys()) {
		if (!listed.has(header)) throw new Error(`config template: no driver lists [${header}]`);
	}
	return { tables, orders };
}

/**
 * @param {string} text The shared template.
 * @param {string} platform Driver key.
 * @returns {{header: string, rows: [string, string][]}[]} That driver's tables.
 */
function projectSections(text, platform) {
	if (!DRIVERS.includes(platform)) throw new Error(`unknown driver ${platform}`);
	const { tables, orders } = parseSharedTemplate(text);
	return orders[platform].map((header) => {
		if (!tables.has(header))
			throw new Error(`config template: ${platform} lists missing [${header}]`);
		const rows = tables
			.get(header)
			.filter((row) => row.driver === null || row.driver === platform)
			.map((row) => [row.key, row.literal]);
		return { header, rows };
	});
}

/**
 * @param {string} text The shared template.
 * @param {string} platform Driver key.
 * @returns {string} That driver's config template.
 */
function projectDriverTemplate(text, platform) {
	return renderDriverTemplate(platform, projectSections(text, platform));
}

module.exports = {
	DRIVERS,
	PLATFORM_ROOT,
	parseSharedTemplate,
	projectDriverTemplate,
	projectSections,
	renderDriverTemplate,
	renderSharedTemplate
};
