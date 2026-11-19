// tools/audit/parity-census.cjs

/**
 * ==============================================================================
 * MODULE: Platform Parity Census Reconciliation
 * DESCRIPTION:
 * Reconciles a source-area census (tools/audit/source-areas.py output) with the
 * dated parity campaigns under docs/audits/platform-parity/. For every census
 * area, and for every finer unit (the area plus the layer folder below it), it
 * records which campaigns named its files, the pinned source of the latest
 * one, and how far the sources drifted since that pin.
 *
 * Coverage is lexical, not proof of review. A campaign covers a file when one
 * of its Markdown files names it: a path with a source suffix matched on whole
 * path components in the tree at the campaign's pinned commit, or a backticked
 * folder that starts at a driver root (`windows/modules/llm/`). Both follow
 * renames to the census commit. A bare file name matching more than
 * MAX_BARE_MATCHES files is ambiguous and ignored, and so are folders without
 * a driver root, which reports also use to list areas they did not take.
 * DECLARED_SCOPE adds the scope of a report that names no file at all.
 *
 * Drift is a rename-aware diff from the pinned commit to the census commit, so
 * a pure rename counts zero. Behavioural lines leave out the hunks whose every
 * removed/added pair differs only in path-like tokens (paths, includes, dotted
 * module names), which is what a structure move rewrites; a new file counts all
 * its lines. Both numbers choose the next campaign; they judge no module.
 *
 * USAGE:
 *   node tools/audit/parity-census.cjs --census <source-areas.json>
 *        [--previous <older source-areas.json>] [--output <reconciliation.json>]
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { execFileSync, spawn } = require('node:child_process');
const readline = require('node:readline');

const ROOT = path.resolve(__dirname, '..', '..');
const BASE = 'static/ergopti_plus/';
const CAMPAIGNS_DIR = 'docs/audits/platform-parity';
// One name per driver plus _shared: a bare name past that is a common file
// name (init.lua, README) and says nothing about the campaign's scope.
const MAX_BARE_MATCHES = 4;
// Rename detection over the whole tree dominates the run; four keeps a laptop
// responsive and is about four times faster than one at a time.
const PARALLEL_DIFFS = 4;
const SOURCE_SUFFIX =
	'ahk|applescript|c|cpp|cs|css|go|h|hpp|html|js|cjs|lua|m|mm|ps1|py|sh|sql|swift|toml|json|plist|keylayout|rules|service|conf|xml';
const PATH_TOKEN = new RegExp(`[A-Za-z0-9_./{},\\-]*[A-Za-z0-9_}]\\.(?:${SOURCE_SUFFIX})\\b`, 'g');
// A folder may hold a space (`App Cloner.app`) or a `*` wildcard (`windows/ui/*_editor/`).
const FOLDER_TOKEN =
	/`(?:static\/ergopti_plus\/)?((?:windows|macos|linux|_shared)(?:\/[A-Za-z0-9_. *-]+)+)\/?`/g;
// The pinned-source line every report since 2026-11-04 opens with.
const PIN_LINE =
	/(?:Audited (?:source|SHA|revision)|Revision inspected|Reviewed [^\n]*? at)[^`\n]*`([0-9a-f]{7,40})`/;
// Rename-aware patches from the oldest pins reach tens of megabytes.
const MAX_BUFFER = 1024 * 1024 * 1024;
// Scope of reports that name no file, as census-commit paths. Each entry is
// read from the report's own Scope section.
const DECLARED_SCOPE = {
	// « the preview and AI suggestion bubbles and the WPM widget with its tray readout »
	'2026-11-13-tooltips-wpm': [/\/tooltip\//, /\/wpm\//, /wpm_widget/, /wpm_surface/],
	// « the personal information, prompt, paths and personal hotstrings editors »: their shared pages
	'2026-11-12-editors': [
		/^static\/ergopti_plus\/_shared\/ui\/(?:personal_info|prompt|paths|hotstring)_editor\//
	]
};

/** Runs git in the repository and returns stdout as a string. */
function git(args) {
	return execFileSync('git', ['-C', ROOT, ...args], { encoding: 'utf8', maxBuffer: MAX_BUFFER });
}

/** Expands {a,b} braces: `x.{lua,sh}` gives `x.lua` and `x.sh`. */
function expandBraces(token) {
	const match = /\{([^{}]*)\}/.exec(token);
	if (!match) return [token];
	return match[1]
		.split(',')
		.flatMap((part) =>
			expandBraces(token.slice(0, match.index) + part + token.slice(match.index + match[0].length))
		);
}

/** The file and driver-rooted folder tokens a campaign's Markdown names, relative to BASE. */
function campaignTokens(dir) {
	const files = new Set();
	const folders = new Set();
	const walk = (folder) => {
		for (const entry of fs.readdirSync(folder, { withFileTypes: true })) {
			const full = path.join(folder, entry.name);
			if (entry.isDirectory()) walk(full);
			else if (entry.name.endsWith('.md')) {
				const text = fs.readFileSync(full, 'utf8');
				for (const raw of text.match(PATH_TOKEN) || [])
					for (const token of expandBraces(raw)) {
						const clean = token.replace(/^\.?\/+/, '').replace(/^static\/ergopti_plus\//, '');
						if (clean && !clean.includes('{') && !clean.includes(',')) files.add(clean);
					}
				for (const match of text.matchAll(FOLDER_TOKEN))
					if (!new RegExp(`\\.(?:${SOURCE_SUFFIX})$`).test(match[1])) folders.add(match[1]);
			}
		}
	};
	walk(dir);
	return { files, folders };
}

/** The commit a campaign pinned: its report's pin line, else the commit that added the report. */
function campaignPin(dir) {
	const files = fs
		.readdirSync(dir)
		.filter((name) => name.endsWith('.md'))
		.sort((a, b) => (a === 'report.md' ? -1 : b === 'report.md' ? 1 : a.localeCompare(b)));
	for (const name of files) {
		const match = PIN_LINE.exec(fs.readFileSync(path.join(dir, name), 'utf8'));
		if (match)
			return {
				sha: git(['rev-parse', '--verify', `${match[1]}^{commit}`]).trim(),
				source: 'pin line'
			};
	}
	const report = path.relative(ROOT, path.join(dir, files[0])).replace(/\\/g, '/');
	const added = git(['log', '--diff-filter=A', '--format=%H', '--', report])
		.trim()
		.split('\n')
		.pop();
	if (!added) throw new Error(`${dir}: no pinned source and no adding commit`);
	return { sha: added, source: 'commit that added the report' };
}

/** True when a token reads as a path, include or dotted module name. */
function pathLike(token) {
	return /[/\\]/.test(token) || /^[a-z0-9_]+(?:\.[a-z0-9_]+){2,}$/.test(token);
}

/** A removed/added pair that differs only in path-like tokens. */
function pathOnlyPair(before, after) {
	const split = (line) => line.split(/["'`\s()[\],;=]+/).filter(Boolean);
	const a = split(before);
	const b = split(after);
	if (a.length !== b.length) return false;
	return a.every((token, index) => token === b[index] || (pathLike(token) && pathLike(b[index])));
}

/** Strips the a/ or b/ prefix git puts on a patch header path. */
function headerPath(text) {
	return text.replace(/^"|"$/g, '').slice(2);
}

/**
 * Reads a rename-aware `-U0` patch, line by line, into, per file at the census
 * commit: its pin path, changed lines, behavioural lines and whether it is new.
 * The patch streams because the oldest pins produce hundreds of megabytes.
 */
function patchParser() {
	const files = [];
	let file = null;
	let removed = [];
	let added = [];
	let inHunk = false;
	const flush = () => {
		if (file === null || (removed.length === 0 && added.length === 0)) return;
		file.lines += removed.length + added.length;
		const mechanical =
			removed.length === added.length &&
			removed.every((line, index) => pathOnlyPair(line, added[index]));
		if (!mechanical) file.behaviour += removed.length + added.length;
		removed = [];
		added = [];
	};
	const line = (text) => {
		if (text.startsWith('diff --git ')) {
			flush();
			const match = /^diff --git (a\/.+) (b\/.+)$/.exec(text);
			if (!match) throw new Error(`unparsed patch header: ${text}`);
			file = {
				from: headerPath(match[1]),
				to: headerPath(match[2]),
				lines: 0,
				behaviour: 0,
				added: false,
				deleted: false
			};
			files.push(file);
			inHunk = false;
		} else if (!inHunk && text.startsWith('rename from ')) file.from = text.slice(12);
		else if (!inHunk && text.startsWith('rename to ')) file.to = text.slice(10);
		else if (!inHunk && text.startsWith('new file mode')) file.added = true;
		else if (!inHunk && text.startsWith('deleted file mode')) file.deleted = true;
		else if (text.startsWith('@@')) {
			flush();
			inHunk = true;
		} else if (inHunk && text.startsWith('-')) removed.push(text.slice(1));
		else if (inHunk && text.startsWith('+')) added.push(text.slice(1));
	};
	const end = () => {
		flush();
		return files;
	};
	return { line, end };
}

/** Diff between a pin and the census commit: rename map and drift per census path. */
function driftSince(sha, head) {
	const args = [
		'-C',
		ROOT,
		'-c',
		'diff.renameLimit=0',
		'-c',
		'core.quotePath=false',
		'diff',
		'-M',
		'-U0',
		'--no-color',
		'--no-ext-diff',
		sha,
		head,
		'--',
		BASE.slice(0, -1),
		':(glob,exclude)**/tests/**'
	];
	return new Promise((resolve, reject) => {
		const child = spawn('git', args, { stdio: ['ignore', 'pipe', 'pipe'] });
		const parser = patchParser();
		let stderr = '';
		child.stderr.on('data', (chunk) => (stderr += chunk));
		readline.createInterface({ input: child.stdout, crlfDelay: Infinity }).on('line', (text) => {
			try {
				parser.line(text);
			} catch (error) {
				child.kill();
				reject(error);
			}
		});
		child.on('error', reject);
		child.on('close', (code) => {
			if (code !== 0) return reject(new Error(`git diff ${sha} failed (${code}): ${stderr}`));
			const toHead = new Map();
			const byNew = new Map();
			for (const file of parser.end()) {
				toHead.set(file.from, file.deleted ? null : file.to);
				if (!file.deleted) byNew.set(file.to, file);
			}
			resolve({ toHead, byNew });
		});
	});
}

/** Where a pin path lives at the census commit (null when deleted). */
function headPath(drift, oldPath) {
	return drift.toHead.has(oldPath) ? drift.toHead.get(oldPath) : oldPath;
}

/** Line count of every census member, read in one cat-file batch. */
function memberLines(members) {
	const raw = execFileSync('git', ['-C', ROOT, 'cat-file', '--batch'], {
		input: members.map((member) => member.git_blob).join('\n') + '\n',
		maxBuffer: MAX_BUFFER
	});
	const lines = new Map();
	let offset = 0;
	for (const member of members) {
		const headerEnd = raw.indexOf(10, offset);
		const size = Number(raw.toString('latin1', offset, headerEnd).split(' ')[2]);
		const body = raw.subarray(headerEnd + 1, headerEnd + 1 + size);
		let count = 0;
		for (const byte of body) if (byte === 10) count++;
		lines.set(member.path, count + (size > 0 && body[size - 1] !== 10 ? 1 : 0));
		offset = headerEnd + 1 + size + 1;
	}
	return lines;
}

/** The finer unit of a member: its area plus the layer folder below it. */
function unitOf(area, member) {
	const relative = member.path.slice(BASE.length).split('/').slice(1);
	const depth = area.area.split('/').length;
	return relative.length > depth + 1 ? `${area.area}/${relative[depth]}` : area.area;
}

/** Resolves a campaign's file and folder tokens against the tree at its pin. */
function resolveTokens({ files, folders }, tree) {
	const resolved = new Set();
	for (const token of files) {
		const matches = tree.filter((file) => file === token || file.endsWith(`/${token}`));
		if (!token.includes('/') && matches.length > MAX_BARE_MATCHES) continue;
		for (const file of matches) resolved.add(BASE + file);
	}
	for (const folder of folders) {
		const escaped = folder.replace(/[.+?^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '[^/]*');
		const pattern = new RegExp(`^${escaped}/`);
		for (const file of tree) if (pattern.test(file)) resolved.add(BASE + file);
	}
	return resolved;
}

/** Runs async tasks with at most `limit` in flight, keeping input order. */
async function pool(items, limit, task) {
	const results = new Array(items.length);
	let next = 0;
	const worker = async () => {
		while (next < items.length) {
			const index = next++;
			results[index] = await task(items[index]);
		}
	};
	await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
	return results;
}

/** Maps every area of an older census to the census areas its members are in now. */
function mapPrevious(previous, drift, memberIndex) {
	return previous.areas.map((area) => {
		const targets = new Map();
		let gone = 0;
		for (const member of area.members) {
			const hit = memberIndex.get(headPath(drift, member.path));
			if (!hit) gone++;
			else targets.set(hit.area, (targets.get(hit.area) || 0) + 1);
		}
		return {
			key: `${area.os}/${area.area}`,
			members: area.members.length,
			now: [...targets]
				.sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
				.map(([where, count]) => ({ area: where, members: count })),
			left_census: gone
		};
	});
}

/** Groups census members by `keyOf` and summarises coverage and drift per group. */
function summarise(census, keyOf, coverage, lines) {
	const groups = new Map();
	for (const area of census.areas)
		for (const member of area.members) {
			const key = keyOf(area, member);
			if (!groups.has(key)) groups.set(key, []);
			groups.get(key).push(member);
		}
	return [...groups]
		.sort(([a], [b]) => a.localeCompare(b))
		.map(([key, group]) => {
			const byCampaign = new Map();
			for (const member of group)
				for (const hit of coverage.get(member.path) || []) {
					if (!byCampaign.has(hit.campaign)) byCampaign.set(hit.campaign, { ...hit, members: 0 });
					byCampaign.get(hit.campaign).members++;
				}
			const ordered = [...byCampaign.values()].sort((a, b) => a.campaign.localeCompare(b.campaign));
			const latest = ordered[ordered.length - 1];
			const row = {
				key,
				members: group.length,
				code_members: group.filter((member) => member.kind === 'code').length,
				lines: group.reduce((sum, member) => sum + lines.get(member.path), 0),
				campaigns: ordered.map((hit) => ({
					campaign: hit.campaign,
					sha: hit.sha,
					members_named: hit.members
				}))
			};
			if (!latest) return { ...row, status: 'never-campaigned' };
			const drift = { changed_members: 0, new_members: 0, lines: 0, behavioural_lines: 0 };
			for (const member of group) {
				const entry = latest.drift.byNew.get(member.path);
				if (!entry) continue;
				if (entry.added) drift.new_members++;
				if (entry.lines > 0) drift.changed_members++;
				drift.lines += entry.lines;
				drift.behavioural_lines += entry.behaviour;
			}
			return {
				...row,
				latest_campaign: latest.campaign,
				latest_sha: latest.sha,
				drift,
				status: drift.behavioural_lines > 0 ? 'drifted' : 'stable'
			};
		});
}

/** Reads `--census`, `--previous` and `--output`. */
function parseArguments(argv) {
	const options = {};
	for (let i = 0; i < argv.length; i += 2) {
		if (!['--census', '--previous', '--output'].includes(argv[i]) || argv[i + 1] === undefined)
			throw new Error(
				`usage: --census <file> [--previous <file>] [--output <file>] (got ${argv[i]})`
			);
		options[argv[i].slice(2)] = argv[i + 1];
	}
	if (!options.census) throw new Error('--census is required');
	return options;
}

/** Builds the reconciliation and writes it with a one-line summary. */
async function main() {
	const options = parseArguments(process.argv.slice(2));
	const census = JSON.parse(fs.readFileSync(options.census, 'utf8'));
	const head = census.audited_sha;
	const lines = memberLines(census.areas.flatMap((area) => area.members));
	const memberIndex = new Map();
	for (const area of census.areas)
		for (const member of area.members)
			memberIndex.set(member.path, { area: `${area.os}/${area.area}` });

	const own = path.basename(path.dirname(path.resolve(options.census)));
	const campaigns = fs
		.readdirSync(path.join(ROOT, CAMPAIGNS_DIR), { withFileTypes: true })
		.filter(
			(entry) => entry.isDirectory() && /^\d{4}-\d{2}-\d{2}/.test(entry.name) && entry.name !== own
		)
		.map((entry) => entry.name)
		.sort()
		.map((name) => {
			const dir = path.join(ROOT, CAMPAIGNS_DIR, name);
			return { name, dir, pin: campaignPin(dir) };
		});
	const previous = options.previous ? JSON.parse(fs.readFileSync(options.previous, 'utf8')) : null;
	const shas = [
		...new Set([
			...campaigns.map((campaign) => campaign.pin.sha),
			...(previous ? [previous.audited_sha] : [])
		])
	];
	const drifts = new Map(
		await pool(shas, PARALLEL_DIFFS, async (sha) => [sha, await driftSince(sha, head)])
	);

	const coverage = new Map();
	const campaignRows = [];
	for (const campaign of campaigns) {
		const { sha, source } = campaign.pin;
		const tree = git(['ls-tree', '-r', '--name-only', '--full-tree', sha, '--', BASE.slice(0, -1)])
			.split('\n')
			.filter(Boolean)
			.map((file) => file.slice(BASE.length));
		const drift = drifts.get(sha);
		const nowPaths = new Set();
		for (const oldPath of resolveTokens(campaignTokens(campaign.dir), tree)) {
			const now = headPath(drift, oldPath);
			if (now !== null && memberIndex.has(now)) nowPaths.add(now);
		}
		for (const pattern of DECLARED_SCOPE[campaign.name] || [])
			for (const now of memberIndex.keys()) if (pattern.test(now)) nowPaths.add(now);
		for (const now of nowPaths) {
			if (!coverage.has(now)) coverage.set(now, []);
			coverage.get(now).push({ campaign: campaign.name, sha, drift });
		}
		campaignRows.push({
			campaign: campaign.name,
			sha,
			pin_source: source,
			declared_scope: (DECLARED_SCOPE[campaign.name] || []).map(String),
			census_members_named: nowPaths.size
		});
	}

	const document = {
		schema_version: 1,
		meaning:
			'Lexical reconciliation of a source-area census with the dated parity campaigns: a campaign covers a file its Markdown names. Not proof of review. Drift ignores pure renames; behavioural lines leave out path-only hunks.',
		census_sha: head,
		tool: 'tools/audit/parity-census.cjs',
		campaigns: campaignRows,
		areas: summarise(census, (area) => `${area.os}/${area.area}`, coverage, lines),
		units: summarise(
			census,
			(area, member) => `${area.os}/${unitOf(area, member)}`,
			coverage,
			lines
		)
	};
	if (previous) {
		document.previous_sha = previous.audited_sha;
		document.previous_areas = mapPrevious(previous, drifts.get(previous.audited_sha), memberIndex);
	}
	const encoded = JSON.stringify(document, null, '\t') + '\n';
	if (options.output) fs.writeFileSync(options.output, encoded);
	else process.stdout.write(encoded);
	const count = (rows, status) => rows.filter((row) => row.status === status).length;
	process.stderr.write(
		`parity-census: ${document.areas.length} areas (${count(document.areas, 'drifted')} drifted, ` +
			`${count(document.areas, 'never-campaigned')} never campaigned), ${document.units.length} units ` +
			`(${count(document.units, 'drifted')} drifted, ${count(document.units, 'never-campaigned')} never campaigned)\n`
	);
}

main().catch((error) => {
	process.stderr.write(`parity-census: ${error.stack || error}\n`);
	process.exitCode = 1;
});
