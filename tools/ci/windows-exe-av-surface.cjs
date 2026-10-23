// tools/ci/windows-exe-av-surface.cjs

/**
 * ==============================================================================
 * MODULE: ErgoptiPlus.exe Antivirus Surface Gate
 * DESCRIPTION:
 * Reads the compiled script and the runtime bundle out of a built
 * ErgoptiPlus.exe and checks them against windows-exe-av-surface.json.
 * Corporate proxies and antivirus engines read the same bytes: v1.0.4 was
 * blocked after an inline PowerShell P/Invoke clipboard stage reached the
 * plain-text compiled script. The gate keeps such stages out and stops the
 * remaining PowerShell launch patterns from growing unnoticed.
 *
 * FEATURES & RATIONALE:
 * 1. Real artifact: the PE resource tree is parsed, so the check sees what
 *    Ahk2Exe embedded (comments stripped), not the source tree.
 * 2. Forbidden patterns fail on a single occurrence; ceilings fail when
 *    exceeded and ask for a lower ceiling when the count drops.
 * 3. Reported counts (naming and API wording that is not yet capped) are
 *    printed without gating, so they can be measured on every build.
 * 4. Every count of every pattern family is also returned and can be recorded
 *    as JSON (--record) together with the exe hash, and broken down by bundle
 *    member or by source file (--breakdown, --sources) for report-only
 *    triage. The ceilings in the policy are these counts at the last
 *    measurement, so any growth of the string surface fails the build.
 * ==============================================================================
 */

'use strict';
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const zlib = require('node:zlib');

const POLICY_PATH = path.join(__dirname, 'windows-exe-av-surface.json');
const RT_RCDATA = 10;
const SCRIPT_RESOURCE = 1;
const BUNDLE_RESOURCE = 'BUILD\\STATIC_BUNDLE.ZIP';
const IMAGE_DIRECTORY_RESOURCE = 2;
const IMAGE_DIRECTORY_SECURITY = 4;
// Bundle members scanned as text; binaries are covered by their own builds.
const TEXT_MEMBER =
	/\.(ps1|psm1|ahk|ah2|js|cjs|mjs|html|htm|css|json|toml|tsv|txt|md|lua|vbs|cmd|bat)$/i;

/**
 * Parses the parts of a PE image this gate reads.
 * @param {Buffer} image The executable bytes.
 * @returns {{signed: boolean, resources: Map<string, Buffer>}} Resources keyed
 *   by "type/name" with numeric ids as decimal strings.
 */
function parsePe(image) {
	if (image.length < 0x40 || image.readUInt16LE(0) !== 0x5a4d) throw new Error('Not an MZ image.');
	const pe = image.readUInt32LE(0x3c);
	if (pe + 24 > image.length || image.readUInt32LE(pe) !== 0x00004550)
		throw new Error('Missing PE signature.');
	const sectionCount = image.readUInt16LE(pe + 6);
	const optionalSize = image.readUInt16LE(pe + 20);
	const optional = pe + 24;
	const magic = image.readUInt16LE(optional);
	if (magic !== 0x10b && magic !== 0x20b)
		throw new Error(`Unknown optional header magic ${magic}.`);
	const directories = optional + (magic === 0x20b ? 112 : 96);
	const directory = (index) => ({
		rva: image.readUInt32LE(directories + index * 8),
		size: image.readUInt32LE(directories + index * 8 + 4)
	});
	const sections = [];
	for (let index = 0; index < sectionCount; index += 1) {
		const at = optional + optionalSize + index * 40;
		sections.push({
			va: image.readUInt32LE(at + 12),
			virtualSize: image.readUInt32LE(at + 8),
			rawSize: image.readUInt32LE(at + 16),
			rawPointer: image.readUInt32LE(at + 20)
		});
	}
	const offsetOf = (rva) => {
		for (const section of sections) {
			const span = Math.max(section.virtualSize, section.rawSize);
			if (rva >= section.va && rva < section.va + span)
				return rva - section.va + section.rawPointer;
		}
		throw new Error(`RVA 0x${rva.toString(16)} is outside every section.`);
	};
	const resources = new Map();
	const root = directory(IMAGE_DIRECTORY_RESOURCE);
	if (root.rva !== 0) {
		const base = offsetOf(root.rva);
		const nameOf = (raw) => {
			if ((raw & 0x80000000) === 0) return String(raw);
			const at = base + (raw & 0x7fffffff);
			return image.toString('utf16le', at + 2, at + 2 + image.readUInt16LE(at) * 2);
		};
		const walk = (at, trail, depth) => {
			if (depth > 3) throw new Error('Resource tree is deeper than type/name/language.');
			const count = image.readUInt16LE(at + 12) + image.readUInt16LE(at + 14);
			for (let index = 0; index < count; index += 1) {
				const name = nameOf(image.readUInt32LE(at + 16 + index * 8));
				const target = image.readUInt32LE(at + 20 + index * 8);
				if (target & 0x80000000) {
					walk(base + (target & 0x7fffffff), [...trail, name], depth + 1);
				} else {
					const entry = base + target;
					const start = offsetOf(image.readUInt32LE(entry));
					const key = trail.slice(0, 2).join('/');
					if (resources.has(key)) throw new Error(`Resource ${key} has more than one language.`);
					resources.set(key, image.subarray(start, start + image.readUInt32LE(entry + 4)));
				}
			}
		};
		walk(base, [], 1);
	}
	return { signed: directory(IMAGE_DIRECTORY_SECURITY).size > 0, resources };
}

/**
 * Lists the members of a ZIP archive with their inflated bytes.
 * @param {Buffer} archive The archive bytes.
 * @returns {Array<{name: string, data: Buffer}>}
 */
function readZip(archive) {
	let end = -1;
	for (let at = archive.length - 22; at >= Math.max(0, archive.length - 65557); at -= 1) {
		if (archive.readUInt32LE(at) === 0x06054b50) {
			end = at;
			break;
		}
	}
	if (end < 0) throw new Error('The bundle has no ZIP end-of-central-directory record.');
	const count = archive.readUInt16LE(end + 10);
	let at = archive.readUInt32LE(end + 16);
	const members = [];
	for (let index = 0; index < count; index += 1) {
		if (archive.readUInt32LE(at) !== 0x02014b50) throw new Error('Corrupt ZIP central directory.');
		const method = archive.readUInt16LE(at + 10);
		const packed = archive.readUInt32LE(at + 20);
		const nameLength = archive.readUInt16LE(at + 28);
		const extraLength = archive.readUInt16LE(at + 30);
		const commentLength = archive.readUInt16LE(at + 32);
		const local = archive.readUInt32LE(at + 42);
		const name = archive.toString('utf8', at + 46, at + 46 + nameLength);
		at += 46 + nameLength + extraLength + commentLength;
		if (name.endsWith('/')) continue;
		const dataAt = local + 30 + archive.readUInt16LE(local + 26) + archive.readUInt16LE(local + 28);
		const raw = archive.subarray(dataAt, dataAt + packed);
		if (method !== 0 && method !== 8)
			throw new Error(`Unsupported ZIP method ${method} for ${name}.`);
		members.push({ name, data: method === 8 ? zlib.inflateRawSync(raw) : Buffer.from(raw) });
	}
	return members;
}

function count(text, pattern) {
	return (text.match(new RegExp(pattern, 'gi')) ?? []).length;
}

/**
 * Lists every pattern of a policy section with its id, in report order.
 * @param {object} section A policy section.
 * @returns {Array<[string, string]>} Pairs of id and pattern.
 */
function sectionPatterns(section) {
	return [
		...Object.entries(section.forbidden ?? {}),
		...Object.entries(section.ceilings ?? {}).map(([id, ceiling]) => [id, ceiling.pattern]),
		...Object.entries(section.reported ?? {})
	];
}

/**
 * Counts every pattern of a policy section in one text.
 * @param {string} text The scanned text.
 * @param {object} section Its policy section.
 * @returns {Object<string, number>} Count per pattern id.
 */
function countSection(text, section) {
	return Object.fromEntries(
		sectionPatterns(section).map(([id, pattern]) => [id, count(text, pattern)])
	);
}

/**
 * Breaks the counts of a policy section down by file, largest first.
 * @param {Array<{name: string, text: string}>} files The scanned files.
 * @param {object} section Its policy section.
 * @param {number} [top] How many files to keep per pattern id.
 * @returns {Object<string, Array<[string, number]>>} Files with a hit per id.
 */
function breakdownFiles(files, section, top = 8) {
	const result = {};
	for (const [id, pattern] of sectionPatterns(section)) {
		const hits = files
			.map((file) => [file.name, count(file.text, pattern)])
			.filter(([, found]) => found > 0)
			.sort((left, right) => right[1] - left[1] || left[0].localeCompare(right[0]));
		if (hits.length > 0) result[id] = hits.slice(0, top);
	}
	return result;
}

/**
 * Reads the shipped AutoHotkey sources of a Windows driver folder for the
 * script breakdown. The compiled script drops file boundaries, so this is a
 * source-side approximation; the tests folders are skipped.
 * @param {string} directory The windows driver folder.
 * @returns {Array<{name: string, text: string}>}
 */
function readSourceFiles(directory) {
	const files = [];
	const walk = (current) => {
		for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
			const full = path.join(current, entry.name);
			if (entry.isDirectory()) {
				if (entry.name !== 'tests') walk(full);
			} else if (entry.name.toLowerCase().endsWith('.ahk')) {
				files.push({
					name: path.relative(directory, full).split(path.sep).join('/'),
					text: fs.readFileSync(full, 'utf8')
				});
			}
		}
	};
	walk(directory);
	return files;
}

/**
 * Checks one scanned text against a policy section.
 * @param {string} label "script" or "bundle".
 * @param {string} text The scanned text.
 * @param {object} section Its policy section.
 * @returns {{errors: string[], notes: string[]}}
 */
function checkSection(label, text, section) {
	const errors = [];
	const notes = [];
	for (const [id, pattern] of Object.entries(section.forbidden ?? {})) {
		const found = count(text, pattern);
		if (found > 0) errors.push(`${label}: forbidden ${id} (/${pattern}/i) occurs ${found} time(s)`);
	}
	for (const [id, { pattern, max }] of Object.entries(section.ceilings ?? {})) {
		const found = count(text, pattern);
		if (found > max)
			errors.push(`${label}: ${id} (/${pattern}/i) occurs ${found} times, ceiling ${max}`);
		else if (found < max)
			notes.push(`${label}: ${id} dropped to ${found}; lower its ceiling from ${max}`);
		else notes.push(`${label}: ${id} = ${found}`);
	}
	for (const [id, pattern] of Object.entries(section.reported ?? {}))
		notes.push(`${label}: ${id} = ${count(text, pattern)} (reported only)`);
	return { errors, notes };
}

/**
 * Validates the shape of the policy before any count is trusted.
 * @param {object} policy Parsed windows-exe-av-surface.json.
 * @returns {object} The same policy.
 */
function validatePolicy(policy) {
	if (!policy || policy.schema !== 1 || !policy.script || !policy.bundle)
		throw new Error('windows-exe-av-surface.json must declare schema 1, script and bundle.');
	for (const section of [policy.script, policy.bundle]) {
		for (const key of Object.keys(section))
			if (!['forbidden', 'ceilings', 'reported'].includes(key))
				throw new Error(`Unknown policy key ${key}.`);
		for (const pattern of [
			...Object.values(section.forbidden ?? {}),
			...Object.values(section.reported ?? {}),
			...Object.values(section.ceilings ?? {}).map((ceiling) => ceiling.pattern)
		])
			new RegExp(pattern, 'gi');
		for (const ceiling of Object.values(section.ceilings ?? {}))
			if (!Number.isSafeInteger(ceiling.max) || ceiling.max < 0)
				throw new Error('Every ceiling needs a non-negative integer max.');
	}
	return policy;
}

/**
 * Scans a built ErgoptiPlus.exe.
 * @param {Buffer} image The executable bytes.
 * @param {object} [policy] The policy; defaults to the tracked JSON.
 * @returns {{errors: string[], notes: string[]}}
 */
function scanExecutable(image, policy = JSON.parse(fs.readFileSync(POLICY_PATH, 'utf8'))) {
	validatePolicy(policy);
	const { signed, resources } = parsePe(image);
	const script = resources.get(`${RT_RCDATA}/${SCRIPT_RESOURCE}`);
	const bundle = resources.get(`${RT_RCDATA}/${BUNDLE_RESOURCE}`);
	if (!script) throw new Error('The exe has no compiled script resource (RCDATA 1).');
	if (!bundle) throw new Error(`The exe has no ${BUNDLE_RESOURCE} resource.`);
	const members = readZip(bundle)
		.filter((member) => TEXT_MEMBER.test(member.name))
		.map((member) => ({ name: member.name, text: member.data.toString('utf8') }));
	const bundleText = members.map((member) => member.text).join('\n');
	const scriptText = script.toString('utf8');
	const scriptResult = checkSection('script', scriptText, policy.script);
	const bundleResult = checkSection('bundle', bundleText, policy.bundle);
	return {
		counts: {
			script: countSection(scriptText, policy.script),
			bundle: countSection(bundleText, policy.bundle)
		},
		bundleBreakdown: breakdownFiles(members, policy.bundle),
		signed,
		errors: [...scriptResult.errors, ...bundleResult.errors],
		notes: [
			`authenticode: ${signed ? 'present' : 'absent'}`,
			...scriptResult.notes,
			...bundleResult.notes
		]
	};
}

module.exports = {
	parsePe,
	readZip,
	checkSection,
	countSection,
	breakdownFiles,
	readSourceFiles,
	validatePolicy,
	scanExecutable,
	POLICY_PATH
};

/**
 * Formats a per-file breakdown for the console.
 * @param {string} label "bundle" or "sources".
 * @param {Object<string, Array<[string, number]>>} breakdown Files per id.
 * @returns {string[]} Output lines.
 */
function formatBreakdown(label, breakdown) {
	return Object.entries(breakdown).flatMap(([id, files]) => [
		`${label} breakdown ${id}:`,
		...files.map(([name, found]) => `  ${String(found).padStart(5)}  ${name}`)
	]);
}

if (require.main === module) {
	const args = process.argv.slice(2);
	const option = (name) => {
		const at = args.indexOf(name);
		if (at < 0) return undefined;
		const [, value] = args.splice(at, 2);
		if (value === undefined) throw new Error(`${name} needs a value.`);
		return value;
	};
	const recordPath = option('--record');
	const sourcesPath = option('--sources');
	const breakdown = args.includes('--breakdown');
	const positional = args.filter((arg) => arg !== '--breakdown');
	if (positional.length !== 1) {
		process.stderr.write(
			'Usage: node tools/ci/windows-exe-av-surface.cjs [--breakdown] [--sources <windows dir>] ' +
				'[--record <counts.json>] <ErgoptiPlus.exe>\n'
		);
		process.exit(2);
	}
	const image = fs.readFileSync(positional[0]);
	const result = scanExecutable(image);
	for (const note of result.notes) process.stdout.write(`${note}\n`);
	if (breakdown) {
		for (const line of formatBreakdown('bundle', result.bundleBreakdown))
			process.stdout.write(`${line}\n`);
		if (sourcesPath) {
			const policy = JSON.parse(fs.readFileSync(POLICY_PATH, 'utf8'));
			const files = readSourceFiles(sourcesPath);
			for (const line of formatBreakdown('sources', breakdownFiles(files, policy.script)))
				process.stdout.write(`${line}\n`);
		}
	}
	if (recordPath) {
		const record = {
			schema: 1,
			sha256: crypto.createHash('sha256').update(image).digest('hex'),
			bytes: image.length,
			authenticode: result.signed,
			script: result.counts.script,
			bundle: result.counts.bundle
		};
		fs.writeFileSync(recordPath, `${JSON.stringify(record, null, '\t')}\n`);
	}
	for (const error of result.errors) process.stderr.write(`ERROR ${error}\n`);
	process.exit(result.errors.length === 0 ? 0 : 1);
}
