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
 * 3. Reported counts (the keylogger wording) are printed without gating,
 *    so the rename can be measured on every build.
 * ==============================================================================
 */

'use strict';
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
	const bundleText = readZip(bundle)
		.filter((member) => TEXT_MEMBER.test(member.name))
		.map((member) => member.data.toString('utf8'))
		.join('\n');
	const scriptResult = checkSection('script', script.toString('utf8'), policy.script);
	const bundleResult = checkSection('bundle', bundleText, policy.bundle);
	return {
		errors: [...scriptResult.errors, ...bundleResult.errors],
		notes: [
			`authenticode: ${signed ? 'present' : 'absent'}`,
			...scriptResult.notes,
			...bundleResult.notes
		]
	};
}

module.exports = { parsePe, readZip, checkSection, validatePolicy, scanExecutable, POLICY_PATH };

if (require.main === module) {
	const args = process.argv.slice(2);
	if (args.length !== 1) {
		process.stderr.write('Usage: node tools/ci/windows-exe-av-surface.cjs <ErgoptiPlus.exe>\n');
		process.exit(2);
	}
	const { errors, notes } = scanExecutable(fs.readFileSync(args[0]));
	for (const note of notes) process.stdout.write(`${note}\n`);
	for (const error of errors) process.stderr.write(`ERROR ${error}\n`);
	process.exit(errors.length === 0 ? 0 : 1);
}
