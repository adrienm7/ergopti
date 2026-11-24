// tools/lib/app-metadata.cjs

/**
 * ==============================================================================
 * MODULE: Application Metadata
 * DESCRIPTION:
 * The copyright, licence, website, issue tracker, publisher, description and
 * categories every package build writes into the files the operating system
 * shows: the macOS Info.plist (Finder Get Info and Quick Look), the Windows exe
 * version resource (file Properties) and the Linux desktop entries, AppStream
 * metainfo and Debian copyright file (menus and software centres).
 *
 * FEATURES & RATIONALE:
 * 1. One source per value: the copyright holder, the first year and the licence
 *    come from LICENSE, the website from CNAME, the repository from
 *    _shared/updater/data/defaults.json, the product name from identifiers.json
 *    and the rest from _shared/core/text/data/app_metadata.json, so no build
 *    retypes a notice that would then drift from the licence it states.
 * 2. The copyright's end year is the year of the commit being built (Paris
 *    time), never a typed year and never the wall clock: a rebuild of the same
 *    commit gives the same notice.
 * 3. Fail fast: a LICENSE without its MIT holder line, a missing field or a
 *    commit without a date stops the build instead of shipping a blank field.
 *
 * USAGE (shell builds):
 *   node tools/lib/app-metadata.cjs build-year
 *   node tools/lib/app-metadata.cjs field <name> [--year <yyyy>]
 *   node tools/lib/app-metadata.cjs desktop-entry --exec <cmd> --icon <name> [--autostart]
 *   node tools/lib/app-metadata.cjs metainfo --id <id> --desktop-id <file> [--note <text>]
 *   node tools/lib/app-metadata.cjs debian-copyright [--year <yyyy>]
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { shared } = require('./paths.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const SOURCE = shared('core', 'text', 'data', 'app_metadata.json');
const DEFAULTS = shared('updater', 'data', 'defaults.json');
const IDENTIFIERS = shared('core', 'text', 'data', 'identifiers.json');
const TIME_ZONE = 'Europe/Paris';
const STRING_FIELDS = ['publisher', 'summary', 'macos_category', 'metadata_license'];

// ===================================
// ===================================
// ======= 1/ Source reading =========
// ===================================
// ===================================

/** Stops the build with one exact reason. */
function fail(message) {
	throw new Error(`[app-metadata] ${message}`);
}

/**
 * Reads the copyright holder, first year and licence from LICENSE.
 * @param {string} root The repository root.
 * @returns {{holder: string, firstYear: number, license: string, licenseName: string}}
 */
function readLicense(root) {
	const text = fs.readFileSync(path.join(root, 'LICENSE'), 'utf8');
	const kind = /^(MIT) License\s*$/m.exec(text.split('\n')[0]);
	if (!kind) fail('LICENSE must open with "MIT License".');
	const holder = /^Copyright \(c\) (\d{4}) (\S.*\S)\s*$/m.exec(text);
	if (!holder) fail('LICENSE must name its holder as "Copyright (c) <year> <holder>".');
	return {
		holder: holder[2],
		firstYear: Number(holder[1]),
		license: kind[1],
		licenseName: `${kind[1]} License`
	};
}

/**
 * Reads every metadata value the builds write, except the end year.
 * @param {string} [root] The repository root.
 * @returns {Readonly<Record<string, *>>}
 */
function readMetadata(root = ROOT) {
	const data = JSON.parse(fs.readFileSync(SOURCE, 'utf8'));
	for (const field of STRING_FIELDS)
		if (typeof data[field] !== 'string' || data[field].trim() === '')
			fail(`app_metadata.json: "${field}" must be a non-empty string.`);
	for (const field of ['description', 'freedesktop_categories', 'keywords'])
		if (
			!Array.isArray(data[field]) ||
			data[field].length === 0 ||
			!data[field].every((item) => typeof item === 'string' && item.trim() !== '')
		)
			fail(`app_metadata.json: "${field}" must be a non-empty list of strings.`);
	const domain = fs.readFileSync(path.join(root, 'CNAME'), 'utf8').trim();
	if (!/^[a-z0-9.-]+\.[a-z]+$/.test(domain)) fail(`CNAME is not a bare domain: "${domain}".`);
	const { github } = JSON.parse(fs.readFileSync(DEFAULTS, 'utf8'));
	const identifiers = JSON.parse(fs.readFileSync(IDENTIFIERS, 'utf8'));
	const repository = `https://${identifiers.hosts.github}/${github.owner}/${github.repo}`;
	return Object.freeze({
		...readLicense(root),
		productName: identifiers.app.display_name,
		publisher: data.publisher,
		summary: data.summary,
		description: Object.freeze([...data.description]),
		macosCategory: data.macos_category,
		freedesktopCategories: Object.freeze([...data.freedesktop_categories]),
		keywords: Object.freeze([...data.keywords]),
		metadataLicense: data.metadata_license,
		homepage: `https://${domain}`,
		repository,
		issues: `${repository}/issues`,
		releases: `${repository}/releases`
	});
}

/**
 * The year, in Paris time, of the commit being built: ERGOPTI_BUILD_COMMIT
 * when set (CI passes github.sha, as for the build stamp), else HEAD. The
 * reproducible-builds SOURCE_DATE_EPOCH, when set, is that date already.
 * @param {string} [root] The repository root.
 * @param {NodeJS.ProcessEnv} [env] The environment.
 * @returns {number}
 */
function buildYear(root = ROOT, env = process.env) {
	const commit = env.ERGOPTI_BUILD_COMMIT || 'HEAD';
	const seconds = Number(
		env.SOURCE_DATE_EPOCH !== undefined
			? env.SOURCE_DATE_EPOCH
			: execFileSync('git', ['-C', root, 'show', '-s', '--format=%ct', commit], {
					encoding: 'utf8',
					stdio: ['ignore', 'pipe', 'pipe']
				}).trim()
	);
	if (!Number.isInteger(seconds) || seconds <= 0)
		fail(`the build date of ${commit} is not a positive epoch: "${seconds}".`);
	return Number(
		new Intl.DateTimeFormat('en', { year: 'numeric', timeZone: TIME_ZONE }).format(seconds * 1000)
	);
}

// ===================================
// ===================================
// ======= 2/ Rendered values ========
// ===================================
// ===================================

/**
 * The years a notice covers: the first year alone, or first–end.
 * @param {number} endYear The year of the build.
 * @param {Readonly<Record<string, *>>} [meta] The metadata.
 * @returns {string}
 */
function copyrightYears(endYear, meta = readMetadata()) {
	if (!Number.isInteger(endYear) || endYear < meta.firstYear)
		fail(`the build year ${endYear} precedes the LICENSE year ${meta.firstYear}.`);
	return endYear === meta.firstYear ? `${meta.firstYear}` : `${meta.firstYear}–${endYear}`;
}

/**
 * The copyright notice shown by Finder, file Properties and the packages.
 * @param {number} endYear The year of the build.
 * @param {Readonly<Record<string, *>>} [meta] The metadata.
 * @returns {string} e.g. "Copyright © 2024–2026 Adrien MOYAUX. MIT License."
 */
function copyrightNotice(endYear, meta = readMetadata()) {
	return `Copyright © ${copyrightYears(endYear, meta)} ${meta.holder}. ${meta.licenseName}.`;
}

/** Escapes text for an XML element. */
function xml(text) {
	return text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

/**
 * A freedesktop desktop entry; every Linux package writes this one.
 * @param {{exec: string, icon: string, autostart?: boolean}} options
 * @param {Readonly<Record<string, *>>} [meta] The metadata.
 * @returns {string}
 */
function desktopEntry({ exec, icon, autostart = false }, meta = readMetadata()) {
	if (!exec || !icon) fail('a desktop entry needs --exec and --icon.');
	return [
		'[Desktop Entry]',
		'Type=Application',
		'Name=Ergopti',
		`Comment=${meta.summary}`,
		`Exec=${exec}`,
		`Icon=${icon}`,
		'Terminal=false',
		`Categories=${meta.freedesktopCategories.join(';')};`,
		`Keywords=${meta.keywords.join(';')};`,
		...(autostart ? ['X-GNOME-Autostart-enabled=true'] : []),
		''
	].join('\n');
}

/**
 * The AppStream metainfo a software centre reads.
 * @param {{id: string, desktopId: string, note?: string}} options
 * @param {Readonly<Record<string, *>>} [meta] The metadata.
 * @returns {string}
 */
function appstreamMetainfo({ id, desktopId, note }, meta = readMetadata()) {
	if (!id || !desktopId) fail('a metainfo needs --id and --desktop-id.');
	const paragraphs = [...meta.description, ...(note ? [note] : [])];
	return [
		'<?xml version="1.0" encoding="UTF-8"?>',
		'<component type="desktop-application">',
		`  <id>${xml(id)}</id>`,
		'  <name>Ergopti</name>',
		`  <summary>${xml(meta.summary)}</summary>`,
		`  <metadata_license>${xml(meta.metadataLicense)}</metadata_license>`,
		`  <project_license>${xml(meta.license)}</project_license>`,
		`  <developer id="${xml(new URL(meta.homepage).hostname.split('.').reverse().join('.'))}">`,
		`    <name>${xml(meta.holder)}</name>`,
		'  </developer>',
		`  <developer_name>${xml(meta.holder)}</developer_name>`,
		`  <url type="homepage">${xml(meta.homepage)}</url>`,
		`  <url type="bugtracker">${xml(meta.issues)}</url>`,
		`  <url type="vcs-browser">${xml(meta.repository)}</url>`,
		`  <url type="help">${xml(meta.homepage)}</url>`,
		// No contact address is published: the issue tracker is the contact.
		`  <url type="contact">${xml(meta.issues)}</url>`,
		`  <launchable type="desktop-id">${xml(desktopId)}</launchable>`,
		'  <categories>',
		...meta.freedesktopCategories.map((category) => `    <category>${xml(category)}</category>`),
		'  </categories>',
		'  <keywords>',
		...meta.keywords.map((keyword) => `    <keyword>${xml(keyword)}</keyword>`),
		'  </keywords>',
		'  <content_rating type="oars-1.1"/>',
		'  <description>',
		...paragraphs.map((paragraph) => `    <p>${xml(paragraph)}</p>`),
		'  </description>',
		'</component>',
		''
	].join('\n');
}

/**
 * The machine-readable Debian copyright file (DEP-5).
 * @param {number} endYear The year of the build.
 * @param {Readonly<Record<string, *>>} [meta] The metadata.
 * @returns {string}
 */
function debianCopyright(endYear, meta = readMetadata()) {
	const license = fs
		.readFileSync(path.join(ROOT, 'LICENSE'), 'utf8')
		.replace(/\r\n/g, '\n')
		.split('\n')
		.slice(1)
		.join('\n')
		.trim()
		.split('\n')
		.map((line) => (line.trim() === '' ? ' .' : ` ${line}`))
		.join('\n');
	return [
		'Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/',
		'Upstream-Name: ergopti',
		`Upstream-Contact: ${meta.issues}`,
		`Source: ${meta.repository}`,
		'',
		'Files: *',
		`Copyright: ${copyrightYears(endYear, meta)} ${meta.holder}`,
		`License: ${meta.license}`,
		license,
		''
	].join('\n');
}

/**
 * One named value for a shell build.
 * @param {string} name The field.
 * @param {number} endYear The year of the build.
 * @param {Readonly<Record<string, *>>} [meta] The metadata.
 * @returns {string}
 */
function field(name, endYear, meta = readMetadata()) {
	if (name === 'copyright') return copyrightNotice(endYear, meta);
	if (name === 'copyright-years') return copyrightYears(endYear, meta);
	const key = name.replace(/-([a-z])/g, (_, letter) => letter.toUpperCase());
	const value = meta[key];
	if (typeof value !== 'string' && typeof value !== 'number') fail(`unknown field "${name}".`);
	return String(value);
}

module.exports = {
	readMetadata,
	buildYear,
	copyrightYears,
	copyrightNotice,
	desktopEntry,
	appstreamMetainfo,
	debianCopyright,
	field
};

// ===================================
// ===================================
// ======= 3/ Command line ===========
// ===================================
// ===================================

/** Parses --name value and bare --flag options. */
function parseOptions(args) {
	const options = {};
	for (let index = 0; index < args.length; index += 1) {
		const match = /^--([a-z-]+)$/.exec(args[index]);
		if (!match) fail(`unexpected argument "${args[index]}".`);
		if (match[1] === 'autostart') options.autostart = true;
		else {
			if (index + 1 >= args.length) fail(`--${match[1]} needs a value.`);
			options[match[1]] = args[(index += 1)];
		}
	}
	return options;
}

if (require.main === module) {
	try {
		const [command, ...rest] = process.argv.slice(2);
		const positional = command === 'field' ? rest.shift() : undefined;
		const options = parseOptions(rest);
		const year = () => (options.year ? Number(options.year) : buildYear());
		let output;
		if (command === 'build-year') output = `${buildYear()}\n`;
		else if (command === 'field') output = `${field(positional, year())}\n`;
		else if (command === 'desktop-entry') output = desktopEntry(options);
		else if (command === 'metainfo')
			output = appstreamMetainfo({
				id: options.id,
				desktopId: options['desktop-id'],
				note: options.note
			});
		else if (command === 'debian-copyright') output = debianCopyright(year());
		else fail('usage: app-metadata.cjs build-year|field|desktop-entry|metainfo|debian-copyright');
		process.stdout.write(output);
	} catch (error) {
		process.stderr.write(`${error.message}\n`);
		process.exit(1);
	}
}
