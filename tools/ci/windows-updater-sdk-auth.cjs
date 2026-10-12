// tools/ci/windows-updater-sdk-auth.cjs
// Authenticate pinned SDK artifact bytes without executing the interpreter.
'use strict';
const path = require('node:path');
const crypto = require('node:crypto');
const zlib = require('node:zlib');
const assert = require('node:assert/strict');
const { readSourceFile } = require('./windows-updater-original-source.cjs');
const root = path.resolve(__dirname, '../..');
const contractPath = path.join(
	root,
	'static/ergopti_plus/_shared/modules/updater/windows_release_toolchain.json'
);
const maximum = 134217728;
const memberName = 'AutoHotkey64.exe';
const sha = (bytes) => crypto.createHash('sha256').update(bytes).digest('hex');
const demand = (ok, message) => {
	if (!ok) throw new Error(message);
};
function bounded(bytes, offset, length, message) {
	demand(
		Number.isSafeInteger(offset) &&
			offset >= 0 &&
			Number.isSafeInteger(length) &&
			length >= 0 &&
			offset <= bytes.length - length,
		message
	);
}
function memberBytes(archive) {
	const ends = [];
	for (
		let position = Math.max(0, archive.length - 65557);
		position <= archive.length - 22;
		position++
	) {
		if (
			archive.readUInt32LE(position) === 0x06054b50 &&
			position + 22 + archive.readUInt16LE(position + 20) === archive.length
		)
			ends.push(position);
	}
	demand(ends.length === 1, 'SDK ZIP terminal directory refused.');
	const end = ends[0];
	demand(
		archive.readUInt16LE(end + 4) === 0 && archive.readUInt16LE(end + 6) === 0,
		'SDK ZIP split disk refused.'
	);
	const count = archive.readUInt16LE(end + 10);
	demand(
		count > 0 && count < 65535 && count === archive.readUInt16LE(end + 8),
		'SDK ZIP entry count refused.'
	);
	const directorySize = archive.readUInt32LE(end + 12),
		directory = archive.readUInt32LE(end + 16);
	bounded(archive, directory, directorySize, 'SDK ZIP directory bounds refused.');
	demand(directory + directorySize === end, 'SDK ZIP directory closure refused.');
	const entries = [];
	let cursor = directory;
	for (let index = 0; index < count; index++) {
		bounded(archive, cursor, 46, 'SDK ZIP central header refused.');
		demand(archive.readUInt32LE(cursor) === 0x02014b50, 'SDK ZIP central signature refused.');
		const flags = archive.readUInt16LE(cursor + 8),
			method = archive.readUInt16LE(cursor + 10);
		const nameLength = archive.readUInt16LE(cursor + 28),
			extraLength = archive.readUInt16LE(cursor + 30),
			commentLength = archive.readUInt16LE(cursor + 32);
		const length = 46 + nameLength + extraLength + commentLength;
		bounded(archive, cursor, length, 'SDK ZIP central entry bounds refused.');
		demand(cursor + length <= end && nameLength > 0, 'SDK ZIP central entry refused.');
		demand(
			(flags & ~0x080e) === 0 && (method === 0 || method === 8),
			'SDK ZIP encryption or method refused.'
		);
		demand(archive.readUInt16LE(cursor + 34) === 0, 'SDK ZIP member disk refused.');
		const name = archive.subarray(cursor + 46, cursor + 46 + nameLength);
		const text = name.toString('utf8');
		demand(!text.includes('\0') && Buffer.from(text).equals(name), 'SDK ZIP member name refused.');
		const components = text
			.replaceAll('\\', '/')
			.split('/')
			.filter((part) => part !== '' && part !== '.');
		const windowsBase = (components.at(-1) || '')
			.split(':')[0]
			.replace(/[ .]+$/, '')
			.toLowerCase();
		demand(
			windowsBase !== memberName.toLowerCase() || text === memberName,
			'SDK ZIP interpreter alias refused.'
		);
		for (let extra = cursor + 46 + nameLength; extra < cursor + 46 + nameLength + extraLength; ) {
			bounded(archive, extra, 4, 'SDK ZIP extra header refused.');
			const tag = archive.readUInt16LE(extra),
				size = archive.readUInt16LE(extra + 2);
			demand(
				tag !== 1 && extra + 4 + size <= cursor + 46 + nameLength + extraLength,
				'SDK ZIP extra or ZIP64 refused.'
			);
			extra += 4 + size;
		}
		const compressed = archive.readUInt32LE(cursor + 20),
			size = archive.readUInt32LE(cursor + 24),
			local = archive.readUInt32LE(cursor + 42);
		demand(
			compressed !== 0xffffffff && size !== 0xffffffff && local !== 0xffffffff,
			'SDK ZIP64 refused.'
		);
		entries.push({
			name,
			text,
			flags,
			method,
			compressed,
			size,
			local,
			crc: archive.readUInt32LE(cursor + 16),
			external: archive.readUInt32LE(cursor + 38)
		});
		cursor += length;
	}
	demand(cursor === end, 'SDK ZIP central census refused.');
	const ranges = [];
	for (const entry of entries) {
		bounded(archive, entry.local, 30, 'SDK ZIP local header bounds refused.');
		demand(archive.readUInt32LE(entry.local) === 0x04034b50, 'SDK ZIP local signature refused.');
		demand(
			archive.readUInt16LE(entry.local + 6) === entry.flags &&
				archive.readUInt16LE(entry.local + 8) === entry.method,
			'SDK ZIP local contract differs.'
		);
		const names = archive.readUInt16LE(entry.local + 26),
			extras = archive.readUInt16LE(entry.local + 28);
		const data = entry.local + 30 + names + extras;
		bounded(
			archive,
			entry.local,
			30 + names + extras + entry.compressed,
			'SDK ZIP member bounds refused.'
		);
		demand(
			archive.subarray(entry.local + 30, entry.local + 30 + names).equals(entry.name),
			'SDK ZIP local member differs.'
		);
		for (let extra = entry.local + 30 + names; extra < data; ) {
			bounded(archive, extra, 4, 'SDK ZIP local extra header refused.');
			const tag = archive.readUInt16LE(extra),
				size = archive.readUInt16LE(extra + 2);
			demand(tag !== 1 && extra + 4 + size <= data, 'SDK ZIP local extra or ZIP64 refused.');
			extra += 4 + size;
		}
		let finish = data + entry.compressed;
		if (entry.flags & 8) {
			for (const [offset, expected] of [
				[14, entry.crc],
				[18, entry.compressed],
				[22, entry.size]
			])
				demand(
					[0, expected].includes(archive.readUInt32LE(entry.local + offset)),
					'SDK ZIP local descriptor fields refused.'
				);
			bounded(archive, finish, 12, 'SDK ZIP descriptor bounds refused.');
			if (archive.readUInt32LE(finish) === 0x08074b50) {
				finish += 4;
				bounded(archive, finish, 12, 'SDK ZIP signed descriptor bounds refused.');
			}
			demand(
				archive.readUInt32LE(finish) === entry.crc &&
					archive.readUInt32LE(finish + 4) === entry.compressed &&
					archive.readUInt32LE(finish + 8) === entry.size,
				'SDK ZIP descriptor differs.'
			);
			finish += 12;
		} else
			demand(
				archive.readUInt32LE(entry.local + 14) === entry.crc &&
					archive.readUInt32LE(entry.local + 18) === entry.compressed &&
					archive.readUInt32LE(entry.local + 22) === entry.size,
				'SDK ZIP local sizes differ.'
			);
		demand(finish <= directory, 'SDK ZIP member overlaps directory.');
		entry.data = data;
		ranges.push([entry.local, finish]);
	}
	ranges.sort((left, right) => left[0] - right[0]);
	for (let index = 1; index < ranges.length; index++)
		demand(ranges[index - 1][1] <= ranges[index][0], 'SDK ZIP member overlap refused.');
	const selected = entries.filter((entry) => entry.text === memberName);
	demand(selected.length === 1, 'SDK ZIP requires one exact interpreter member.');
	const entry = selected[0];
	const unixType = (entry.external >>> 16) & 0xf000;
	demand(
		entry.size > 0 &&
			entry.size <= maximum &&
			(entry.external & 0x10) === 0 &&
			(unixType === 0 || unixType === 0x8000),
		'SDK ZIP interpreter size or file type refused.'
	);
	const payload = archive.subarray(entry.data, entry.data + entry.compressed);
	if (entry.method === 0)
		demand(payload.length === entry.size, 'SDK ZIP stored size differs before allocation.');
	const decoded =
		entry.method === 0
			? Buffer.from(payload)
			: zlib.inflateRawSync(payload, { maxOutputLength: entry.size, info: true });
	const bytes = entry.method === 0 ? decoded : decoded.buffer;
	if (entry.method === 8)
		demand(
			decoded.engine.bytesWritten === payload.length,
			'SDK ZIP compressed stream closure refused.'
		);
	demand(
		bytes.length === entry.size && zlib.crc32(bytes) === entry.crc,
		'SDK ZIP interpreter bytes or CRC differ.'
	);
	return bytes;
}
function peIdentity(bytes) {
	bounded(bytes, 0, 64, 'SDK DOS header truncated.');
	demand(bytes.readUInt16LE(0) === 0x5a4d, 'SDK DOS signature refused.');
	const pe = bytes.readUInt32LE(0x3c);
	demand(pe >= 64, 'SDK PE offset refused.');
	bounded(bytes, pe, 26, 'SDK PE header truncated.');
	demand(
		bytes.readUInt32LE(pe) === 0x4550 && bytes.readUInt16LE(pe + 4) === 0x8664,
		'SDK x64 PE signature or machine refused.'
	);
	const optionalSize = bytes.readUInt16LE(pe + 20),
		characteristics = bytes.readUInt16LE(pe + 22);
	demand(
		optionalSize >= 112 && (characteristics & 0x2002) === 2,
		'SDK executable PE contract refused.'
	);
	bounded(bytes, pe + 24, optionalSize, 'SDK PE optional header bounds refused.');
	demand(bytes.readUInt16LE(pe + 24) === 0x20b, 'SDK PE32+ identity refused.');
	const sections = bytes.readUInt16LE(pe + 6);
	demand(sections > 0 && sections <= 96, 'SDK PE section count refused.');
	bounded(bytes, pe + 24 + optionalSize, sections * 40, 'SDK PE section table bounds refused.');
	return {
		machine: 0x8664,
		optional_magic: 0x20b,
		executable_header_flag: true,
		dll_header_flag: false,
		architecture: 'amd64',
		headers_only: true,
		loader_validated: false
	};
}
function receiveSdk(imagePath, reportedFileVersion) {
	const archivePath = process.env.ERGOPTI_WINDOWS_AHK_ARCHIVE;
	demand(
		typeof archivePath === 'string' && path.isAbsolute(archivePath) && path.isAbsolute(imagePath),
		'Explicit absolute pinned SDK archive/image paths required.'
	);
	demand(
		typeof reportedFileVersion === 'string' && reportedFileVersion.trim() !== '',
		'Reported SDK metadata required.'
	);
	const contract = readSourceFile(contractPath);
	const runtime = JSON.parse(contract.bytes.toString('utf8')).runtime;
	demand(
		runtime &&
			typeof runtime.version === 'string' &&
			/^\d+\.\d+\.\d+$/.test(runtime.version) &&
			typeof runtime.asset === 'string' &&
			runtime.asset === `AutoHotkey_${runtime.version}.zip` &&
			typeof runtime.sha256 === 'string' &&
			/^[0-9a-f]{64}$/.test(runtime.sha256),
		'Canonical SDK runtime contract refused.'
	);
	const archive = readSourceFile(archivePath, maximum);
	demand(archive.sha256 === runtime.sha256, 'Pinned SDK archive digest refused before parsing.');
	const image = readSourceFile(imagePath, maximum),
		member = memberBytes(archive.bytes);
	demand(member.equals(image.bytes), 'Pinned SDK member differs from acquired interpreter.');
	return {
		scope: 'source-only-sdk-archive-binding',
		native_executed: false,
		runtime_version: runtime.version,
		asset: runtime.asset,
		contract: { path: contractPath, sha256: contract.sha256, identity: contract.identity },
		archive: { path: archivePath, sha256: archive.sha256, identity: archive.identity },
		image: { path: imagePath, sha256: image.sha256, identity: image.identity },
		member: { name: memberName, sha256: sha(member), bytes: member.length },
		pe: peIdentity(image.bytes),
		reported_file_version: reportedFileVersion,
		reported_file_version_qualified: false
	};
}
function requireSameSdk(before, after) {
	assert.deepEqual(after, before, 'Pinned SDK receipt changed.');
}
module.exports = { receiveSdk, requireSameSdk };
