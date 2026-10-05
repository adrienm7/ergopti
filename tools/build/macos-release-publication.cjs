// tools/build/macos-release-publication.cjs

/**
 * Public macOS archive consumers use the producer's canonical bindings. Signing
 * receipts bind actual payload and fragment bytes; they are not CI bundle or
 * native cryptographic verification authority by themselves.
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const { resolveArchives } = require('./macos-release-archives.cjs');
const { shared } = require('../lib/paths.cjs');

const RECEIPT = 'macos-publication.json';
const digest = (bytes) => crypto.createHash('sha256').update(bytes).digest('hex');

/** Load the actual canonical policy without copying its names or order. */
function bindings(defaults) {
	return resolveArchives(
		defaults ?? JSON.parse(fs.readFileSync(shared('modules/updater/defaults.json'), 'utf8'))
	);
}

/** Refuse absent/unsafe payloads; only explicit historical selection admits ENOENT. */
function bytes(filename, allowAbsent = false) {
	let fd;
	try {
		fd = fs.openSync(filename, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW ?? 0));
	} catch (error) {
		if (allowAbsent && error.code === 'ENOENT') return null;
		throw error;
	}
	try {
		const stat = fs.fstatSync(fd);
		if (!stat.isFile() || stat.size <= 0 || fs.lstatSync(filename).isSymbolicLink())
			throw new Error('A public archive input is not a nonempty regular file.');
		return fs.readFileSync(fd);
	} finally {
		fs.closeSync(fd);
	}
}

/** Keep native failure output private; the caller receives only closed refusal. */
function execute(executable, args) {
	return spawnSync(executable, args, { encoding: 'utf8', maxBuffer: 4 * 1024 * 1024 });
}

function command(run, executable, args) {
	const result = run(executable, args);
	if (
		!result ||
		result.error ||
		!Number.isInteger(result.status) ||
		result.status !== 0 ||
		result.signal != null ||
		typeof result.stdout !== 'string'
	)
		throw new Error('Public archive command refused.');
	return result.stdout;
}

function fragment(value, size) {
	if (typeof value !== 'string') throw new Error('Public archive signature fragment refused.');
	const match = /^sparkle:edSignature="([A-Za-z0-9+/]{86}==)" length="([1-9][0-9]*)"\n?$/.exec(
		value
	);
	if (
		!match ||
		Number(match[2]) !== size ||
		Buffer.from(match[1], 'base64').toString('base64') !== match[1]
	)
		throw new Error('Public archive signature fragment refused.');
	return { text: value.replace(/\n$/, ''), signature: match[1] };
}

/** Sign and natively verify every retained declared archive with the explicit key. */
function signArchives(directory, tool, keyFile, options = {}) {
	const policy = bindings(options.defaults),
		run = options.execute ?? execute;
	if (typeof tool !== 'string' || tool === '' || typeof keyFile !== 'string' || keyFile === '')
		throw new Error('An explicit signing tool and key file are required.');
	const records = [],
		owned = [];
	try {
		for (const binding of policy) {
			const target = path.join(directory, binding.name),
				before = bytes(target);
			const result = command(run, tool, ['-f', keyFile, target]);
			const signed = fragment(result, before.length);
			command(run, tool, ['--verify', '-f', keyFile, target, signed.signature]);
			if (!bytes(target).equals(before)) throw new Error('The signed public archive changed.');
			const signatureName = `_${binding.name}.sig`,
				signatureBytes = Buffer.from(signed.text + '\n');
			const signaturePath = path.join(directory, signatureName);
			fs.writeFileSync(signaturePath, signatureBytes, { flag: 'wx', mode: 0o600 });
			owned.push({
				filename: signaturePath,
				stat: fs.lstatSync(signaturePath),
				sha256: digest(signatureBytes)
			});
			records.push({
				...binding,
				size: before.length,
				sha256: digest(before),
				signature_name: signatureName,
				fragment_sha256: digest(signatureBytes)
			});
		}
		const receipt = { schema_version: 1, archives: records };
		fs.writeFileSync(path.join(directory, RECEIPT), JSON.stringify(receipt) + '\n', {
			flag: 'wx',
			mode: 0o600
		});
		return receipt;
	} catch (error) {
		for (const entry of owned) {
			try {
				const current = fs.lstatSync(entry.filename);
				if (
					current.dev === entry.stat.dev &&
					current.ino === entry.stat.ino &&
					digest(bytes(entry.filename)) === entry.sha256
				)
					fs.unlinkSync(entry.filename);
			} catch {
				/* Preserve the primary refusal and any unretired file. */
			}
		}
		throw error;
	}
}

/** Recheck every exact archive/fragment pair before fresh public output. */
function validatePublication(directory, options = {}) {
	const policy = bindings(options.defaults);
	const rawReceipt = bytes(path.join(directory, RECEIPT)).toString('utf8');
	const receipt = JSON.parse(rawReceipt);
	if (JSON.stringify(receipt) + '\n' !== rawReceipt)
		throw new Error('Public signing receipt encoding refused.');
	if (
		!receipt ||
		Object.keys(receipt).sort().join(',') !== 'archives,schema_version' ||
		receipt.schema_version !== 1 ||
		!Array.isArray(receipt.archives) ||
		receipt.archives.length !== policy.length
	)
		throw new Error('Public signing receipt refused.');
	return policy.map((binding, index) => {
		const record = receipt.archives[index];
		if (
			!record ||
			Object.keys(record).sort().join(',') !==
				'format,fragment_sha256,name,sha256,signature_name,size' ||
			record.name !== binding.name ||
			record.format !== binding.format ||
			record.signature_name !== `_${binding.name}.sig` ||
			!Number.isSafeInteger(record.size) ||
			record.size <= 0 ||
			typeof record.sha256 !== 'string' ||
			!/^[a-f0-9]{64}$/.test(record.sha256) ||
			typeof record.fragment_sha256 !== 'string' ||
			!/^[a-f0-9]{64}$/.test(record.fragment_sha256)
		)
			throw new Error('Public signing receipt binding refused.');
		const payload = bytes(path.join(directory, binding.name));
		const signatureBytes = bytes(path.join(directory, record.signature_name));
		const signature = fragment(signatureBytes.toString('utf8'), payload.length);
		if (
			payload.length !== record.size ||
			digest(payload) !== record.sha256 ||
			digest(signatureBytes) !== record.fragment_sha256
		)
			throw new Error('Public signing receipt bytes changed.');
		return { ...record, fragment: signature.text };
	});
}

/** Only actual absence of a preferred published asset admits the historical one. */
function selectPublished(release, tag, options = {}) {
	if (
		typeof tag !== 'string' ||
		tag === '' ||
		!release ||
		release.isDraft !== false ||
		release.tagName !== tag ||
		!Array.isArray(release.assets) ||
		release.assets.some((asset) => !asset || typeof asset !== 'object')
	)
		throw new Error('Published release inventory refused.');
	for (const binding of bindings(options.defaults)) {
		const matches = release.assets.filter((asset) => asset.name === binding.name);
		if (matches.length === 0) continue;
		if (matches.length !== 1) throw new Error('Published archive inventory is ambiguous.');
		const asset = matches[0];
		if (
			typeof asset.digest !== 'string' ||
			!/^sha256:[a-f0-9]{64}$/.test(asset.digest) ||
			!Number.isSafeInteger(asset.size) ||
			asset.size <= 0
		)
			throw new Error('Published archive integrity receipt refused.');
		return { ...binding, sha256: asset.digest.slice(7), size: asset.size };
	}
	throw new Error('Published release has no declared archive.');
}

/** Hash the actual selected published bytes before the cask receives their name. */
function downloadPublished(repository, tag, directory, options = {}) {
	if (
		typeof repository !== 'string' ||
		!/^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$/.test(repository) ||
		typeof tag !== 'string' ||
		tag === ''
	)
		throw new Error('Published release identity refused.');
	const run = options.execute ?? execute;
	const release = JSON.parse(
		command(run, 'gh', ['api', `repos/${repository}/releases/tags/${encodeURIComponent(tag)}`])
	);
	// Read actual REST fields. Older release-view projections discard digest.
	if (!release || typeof release !== 'object' || Array.isArray(release))
		throw new Error('Published release REST inventory refused.');
	const selected = selectPublished(
		{ isDraft: release.draft, tagName: release.tag_name, assets: release.assets },
		tag,
		options
	);
	fs.mkdirSync(directory);
	command(run, 'gh', [
		'release',
		'download',
		tag,
		'--repo',
		repository,
		'--pattern',
		selected.name,
		'--dir',
		directory
	]);
	const payload = bytes(path.join(directory, selected.name));
	if (payload.length !== selected.size || digest(payload) !== selected.sha256)
		throw new Error('Published archive bytes differ from their receipt.');
	return selected;
}

/** Emit a feed from one bound signing receipt, retaining the explicit legacy ZIP ABI. */
function generateAppcast(env, options = {}) {
	for (const key of [
		'ERGOPTI_VERSION',
		'ERGOPTI_BUILD',
		'ERGOPTI_CHANNEL',
		'GH_OWNER',
		'GH_REPO',
		'OUTPUT_PATH'
	])
		if (typeof env[key] !== 'string' || env[key] === '')
			throw new Error('Required appcast input is absent.');
	let selected;
	if (env.ARCHIVE_DIR !== undefined) {
		if (typeof env.ARCHIVE_DIR !== 'string' || env.ARCHIVE_DIR === '')
			throw new Error('Appcast archive directory refused.');
		selected = validatePublication(env.ARCHIVE_DIR, options)[0];
	} else {
		// Existing maintainer/fixture calls explicitly name historical ZIP. This
		// branch cannot turn an unbound preferred archive into a fresh feed.
		const legacy = bindings(options.defaults).find((binding) => binding.format === 'zip');
		if (
			!legacy ||
			typeof env.ZIP_PATH !== 'string' ||
			path.basename(env.ZIP_PATH) !== legacy.name ||
			typeof env.SPARKLE_SIG_FILE !== 'string'
		)
			throw new Error('Explicit historical appcast input refused.');
		const payload = bytes(env.ZIP_PATH);
		selected = {
			...legacy,
			size: payload.length,
			fragment: fragment(bytes(env.SPARKLE_SIG_FILE).toString('utf8'), payload.length).text
		};
	}
	const escape = (value) =>
		value
			.replaceAll('&', '&amp;')
			.replaceAll('"', '&quot;')
			.replaceAll('<', '&lt;')
			.replaceAll('>', '&gt;');
	const url = `https://github.com/${env.GH_OWNER}/${env.GH_REPO}/releases/download/v${env.ERGOPTI_VERSION}/${selected.name}`;
	// Publication follows the explicit release source revision, not the clock.
	const revision = env.GITHUB_SHA ?? 'HEAD';
	if (
		typeof revision !== 'string' ||
		(env.GITHUB_SHA !== undefined && !/^[a-f0-9]{40}$/.test(revision))
	)
		throw new Error('Appcast source revision refused.');
	const published =
		options.pubDate ??
		command(options.execute ?? execute, 'git', [
			'-C',
			path.resolve(__dirname, '..', '..'),
			'show',
			'-s',
			'--format=%cD',
			revision
		]).trim();
	if (
		typeof published !== 'string' ||
		published === '' ||
		/[\r\n]/.test(published) ||
		!Number.isFinite(Date.parse(published))
	)
		throw new Error('Appcast publication date refused.');
	const xml = `<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0"
     xmlns:sparkle="http://www.andymattes.com/xml/namespaces/sparkle/1.0"
     xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Ergopti</title>
    <link>https://github.com/${escape(env.GH_OWNER)}/${escape(env.GH_REPO)}</link>
    <item>
      <title>Ergopti ${escape(env.ERGOPTI_VERSION)}</title>
      <pubDate>${escape(published)}</pubDate>
      <sparkle:version>${escape(env.ERGOPTI_BUILD)}</sparkle:version>
      <sparkle:shortVersionString>${escape(env.ERGOPTI_VERSION)}</sparkle:shortVersionString>
      <enclosure
        url="${escape(url)}"
        ${selected.fragment}
        type="application/octet-stream"
      />
    </item>
  </channel>
</rss>
`;
	fs.writeFileSync(env.OUTPUT_PATH, xml);
	return { name: selected.name, format: selected.format, size: selected.size };
}

if (require.main === module) {
	try {
		const [operation, ...args] = process.argv.slice(2);
		let result;
		if (operation === 'sign' && args.length === 3) result = signArchives(...args);
		else if (operation === 'validate' && args.length === 1) result = validatePublication(args[0]);
		else if (operation === 'preferred' && args.length === 1)
			result = validatePublication(args[0])[0];
		else if (operation === 'appcast' && args.length === 0) result = generateAppcast(process.env);
		else if (operation === 'download' && args.length === 3) result = downloadPublished(...args);
		else throw new Error('Invalid public archive command.');
		process.stdout.write(JSON.stringify(result) + '\n');
	} catch {
		console.error('Public macOS archive operation refused.');
		process.exitCode = 1;
	}
}

module.exports = {
	RECEIPT,
	bindings,
	bytes,
	fragment,
	signArchives,
	validatePublication,
	selectPublished,
	downloadPublished,
	generateAppcast
};
