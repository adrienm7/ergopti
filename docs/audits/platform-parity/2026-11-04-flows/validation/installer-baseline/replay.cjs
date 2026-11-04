'use strict';
const fs = require('node:fs'),
	path = require('node:path'),
	vm = require('node:vm'),
	cp = require('node:child_process'),
	crypto = require('node:crypto');
const repo = '/workspace/ergopti',
	out = __dirname;
const refs = [
	'213d65af24d2aa4845ba47743c9bab6787b61964',
	'1fa4c28f318258dd1af31920b1a55b8bb4c33de1'
];
const selected = [
	'tools/test/test-owned-runtimes-inventory.cjs',
	'tools/test/lib/spawned-tools.cjs',
	'tools/lib/owned-runtimes.cjs',
	'tools/lib/text-escape.cjs',
	'static/ergopti_plus/_shared/data/owned_runtimes.json',
	'static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/OwnedRuntimeCoreLaunchctl.swift'
];
function git(args) {
	return cp.execFileSync('git', args, { cwd: repo, maxBuffer: 32 * 1024 * 1024 });
}
const receipts = [];
for (const ref of refs) {
	const virtualRoot = '/immutable-git/' + ref,
		entries = new Map(),
		dirs = new Map(),
		cache = new Map(),
		accessed = new Set();
	for (const row of git(['ls-tree', '-rz', '--full-tree', ref])
		.toString()
		.split('\0')
		.filter(Boolean)) {
		const m = /^([0-9]+) (\w+) ([a-f0-9]+)\t([\s\S]+)$/.exec(row);
		if (!m) throw Error(row);
		const name = m[4];
		entries.set(name, { mode: m[1], type: m[2], hash: m[3] });
		const seg = name.split('/');
		for (let i = 0; i < seg.length; i++) {
			const parent = seg.slice(0, i).join('/');
			if (!dirs.has(parent)) dirs.set(parent, new Map());
			dirs.get(parent).set(seg[i], i < seg.length - 1);
		}
	}
	function rel(p) {
		const r = path.relative(virtualRoot, p);
		if (r.startsWith('..') || path.isAbsolute(r)) throw Error('path escapes immutable root ' + p);
		return r;
	}
	function blob(name) {
		const e = entries.get(name);
		if (!e || e.type !== 'blob') throw Error('missing immutable blob ' + name);
		accessed.add(name);
		if (!cache.has(e.hash)) cache.set(e.hash, git(['cat-file', 'blob', e.hash]));
		return cache.get(e.hash);
	}
	const readonlyFS = {
		readFileSync(p, encoding) {
			const b = blob(rel(p));
			return encoding ? b.toString(encoding) : Buffer.from(b);
		},
		readdirSync(p, opts) {
			const d = dirs.get(rel(p));
			if (!d) throw Error('missing immutable directory ' + p);
			return [...d].map(([name, isdir]) =>
				opts?.withFileTypes ? { name, isDirectory: () => isdir, isFile: () => !isdir } : name
			);
		}
	};
	const loaded = new Map(),
		lines = [];
	let exitCode = 0;
	function load(name) {
		if (loaded.has(name)) return loaded.get(name).exports;
		const module = { exports: {} };
		loaded.set(name, module);
		const source = blob(name).toString();
		const filename = virtualRoot + '/' + name;
		const req = (id) => {
			if (id === 'node:fs' || id === 'fs') return readonlyFS;
			if (id.startsWith('.')) {
				let dep = path.posix.normalize(path.posix.join(path.posix.dirname(name), id));
				if (!path.posix.extname(dep)) dep += '.cjs';
				return load(dep);
			}
			return require(id);
		};
		const logger = {
			log: (...x) => lines.push(x.join(' ')),
			error: (...x) => lines.push(x.join(' '))
		};
		const fakeProcess = {
			exit: (n) => {
				exitCode = n;
				throw Object.assign(new Error('TEST_PROCESS_EXIT'), { testExit: true });
			}
		};
		const fn = vm.runInNewContext(
			'(function(require,module,exports,__filename,__dirname,console,process){' + source + '\n})',
			{ structuredClone, Buffer },
			{ filename }
		);
		fn(req, module, module.exports, filename, path.dirname(filename), logger, fakeProcess);
		return module.exports;
	}
	try {
		load('tools/test/test-owned-runtimes-inventory.cjs');
	} catch (e) {
		if (!e.testExit) throw e;
	}
	const Spawned = load('tools/test/lib/spawned-tools.cjs'),
		Registry = load('tools/lib/owned-runtimes.cjs');
	const registry = Registry.load(),
		derived = Spawned.spawnedTools('macos'),
		names = new Set(registry.rows.filter((r) => r.os === 'macos').flatMap((r) => r.programs));
	const missing = [...derived].filter(([name]) => !names.has(name));
	const r = {
		sha: ref,
		node: process.version,
		test_exit: exitCode,
		checks: lines.filter((x) => /^(?:PASS|FAIL) /.test(x)).length,
		failures: lines.filter((x) => /^FAIL /.test(x)).length,
		macos_derived_count: derived.size,
		missing,
		selected_blobs: selected.map((p) => ({
			path: p,
			git_blob: entries.get(p).hash,
			sha256: crypto.createHash('sha256').update(blob(p)).digest('hex')
		})),
		immutable_files_read: accessed.size
	};
	fs.writeFileSync(path.join(out, ref.slice(0, 7) + '-test.log'), lines.join('\n') + '\n');
	receipts.push(r);
	console.log(JSON.stringify(r));
	if (
		exitCode !== 1 ||
		r.checks !== 9 ||
		r.failures !== 1 ||
		missing.length !== 1 ||
		missing[0][0] !== 'installer'
	)
		throw Error('baseline does not match expected failure');
}
fs.writeFileSync(path.join(out, 'receipt.json'), JSON.stringify(receipts, null, 2) + '\n');
