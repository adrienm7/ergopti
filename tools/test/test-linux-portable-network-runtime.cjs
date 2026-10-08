// tools/test/test-linux-portable-network-runtime.cjs

/** Independent package prerequisites and installed native network qualification. */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { bashExecutable } = require('../lib/git-bash.cjs');
const root = path.resolve(__dirname, '../..');
const generator = require('../codegen/codegen-linux-native-runtime.cjs');
const catalogue = JSON.parse(fs.readFileSync(path.join(root, generator.SOURCE), 'utf8'));
const environmentTemplate = 'tools/build/templates/linux-portable-runtime-env.sh';
const source = (name) => fs.readFileSync(path.join(root, name), 'utf8');
// Keep native producer diagnostics private. The original assertion remains
// authoritative; refusal to persist evidence never replaces its exit status.
function persistOwnedStageReceipt(fixture, identity, result) {
	const ownerUID = BigInt(process.getuid());
	const privateMode = (observed, mode) =>
		observed.uid === ownerUID && (observed.mode & 0o777n) === mode;
	let rootDescriptor;
	let receiptDescriptor;
	let refusal = null;
	try {
		rootDescriptor = fs.openSync(
			fixture,
			fs.constants.O_RDONLY | fs.constants.O_DIRECTORY | fs.constants.O_NOFOLLOW
		);
		const rootIdentity = fs.fstatSync(rootDescriptor, { bigint: true });
		if (
			!rootIdentity.isDirectory() ||
			!privateMode(rootIdentity, 0o700n) ||
			rootIdentity.dev !== identity.dev ||
			rootIdentity.ino !== identity.ino
		) {
			throw new Error('owned-root-refused');
		}
		const receiptPath = `/proc/self/fd/${rootDescriptor}/staging-producer.private.json`;
		receiptDescriptor = fs.openSync(
			receiptPath,
			fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW,
			0o600
		);
		const owned = fs.fstatSync(receiptDescriptor, { bigint: true });
		if (!owned.isFile() || owned.nlink !== 1n || !privateMode(owned, 0o600n))
			throw new Error('owned-receipt-refused');
		fs.writeFileSync(
			receiptDescriptor,
			JSON.stringify({
				phase: 'native-stage',
				exit_status: result.status,
				signal: result.signal ?? null,
				error_code: result.error?.code ?? null,
				stdout: result.stdout,
				stderr: result.stderr
			}) + '\n',
			'utf8'
		);
		fs.fsyncSync(receiptDescriptor);
		const published = fs.lstatSync(receiptPath, { bigint: true });
		const current = fs.lstatSync(fixture, { bigint: true });
		if (
			!published.isFile() ||
			!privateMode(published, 0o600n) ||
			published.nlink !== 1n ||
			published.dev !== owned.dev ||
			published.ino !== owned.ino ||
			!current.isDirectory() ||
			!privateMode(current, 0o700n) ||
			current.dev !== identity.dev ||
			current.ino !== identity.ino
		) {
			throw new Error('owned-publication-refused');
		}
	} catch {
		refusal = 'private-receipt-refused';
	} finally {
		for (const descriptor of [receiptDescriptor, rootDescriptor]) {
			if (descriptor === undefined) continue;
			try {
				fs.closeSync(descriptor);
			} catch {
				refusal ??= 'private-receipt-retirement-refused';
			}
		}
	}
	return { ok: refusal === null, reason: refusal };
}

let passed = 0;

// Source inventory is hand maintained from the independent official contracts.
assert.deepEqual(catalogue.network_runtime.portable.gio_modules, [
	'libgiognomeproxy.so',
	'libgiolibproxy.so',
	'libdconfsettings.so'
]);
assert.deepEqual(catalogue.network_runtime.portable.system_ca_files, [
	'/etc/ssl/certs/ca-certificates.crt',
	'/etc/pki/tls/certs/ca-bundle.crt',
	'/usr/share/ssl/certs/ca-bundle.crt',
	'/usr/local/share/certs/ca-root-nss.crt',
	'/etc/ssl/cert.pem'
]);
assert.equal(Object.keys(catalogue.libraries).join(','), 'xkbcommon,xkbcommon_x11,x11,x11_xcb');
passed++;
const allModules = generator
	.flatpakModules(catalogue)
	.split('\n')
	.filter(Boolean)
	.map((line) => {
		assert.ok(line.startsWith('  - {'));
		return JSON.parse(line.slice(4));
	});
// A required GSS build must carry its own SDK dependency before curl.
const kerberos = allModules.find((module) => module.name === 'network-krb5');
assert.ok(kerberos, 'Flatpak GSS requires a pinned Kerberos build before curl');
assert.equal(allModules.length, 7);
assert.equal(allModules.filter((module) => module.name === 'network-krb5').length, 1);
assert.ok(
	allModules.indexOf(kerberos) < allModules.findIndex((module) => module.name === 'network-curl')
);
assert.equal(kerberos.buildsystem, 'autotools');
assert.equal(kerberos.subdir, 'src');
assert.deepEqual(kerberos.sources, [
	{
		type: 'archive',
		url: 'https://web.mit.edu/kerberos/dist/krb5/1.22/krb5-1.22.2.tar.gz',
		sha256: '3243ffbc8ea4d4ac22ddc7dd2a1dc54c57874c40648b60ff97009763554eaf13',
		'disable-http-decompression': true
	}
]);
assert.ok(kerberos['config-opts'].includes('--libdir=/app/lib'));
assert.ok(kerberos['post-install'].includes('test -f /app/include/gssapi/gssapi.h'));
assert.ok(
	kerberos['post-install'].includes('test "$(pkg-config --variable=prefix mit-krb5-gssapi)" = /app')
);
const flatpakCurl = allModules.find((module) => module.name === 'network-curl');
assert.ok(
	flatpakCurl['config-opts'].includes('-DCMAKE_INSTALL_LIBDIR=lib'),
	'Flatpak curl must resolve its own library through /app/lib'
);
for (const module of allModules.filter((entry) => entry.buildsystem === 'cmake-ninja')) {
	assert.deepEqual(
		module['config-opts'].filter((option) => option.startsWith('-DCMAKE_INSTALL_LIBDIR')),
		['-DCMAKE_INSTALL_LIBDIR=lib'],
		`${module.name} must install libraries in the /app/lib runtime search directory`
	);
}
assert.ok(flatpakCurl['config-opts'].includes('-DCURL_USE_GSSAPI=ON'));
assert.ok(flatpakCurl['config-opts'].includes('-DGSS_ROOT_DIR=/app'));
assert.ok(flatpakCurl['post-install'].some((command) => command.includes('GSS-API( |$)')));
assert.ok(flatpakCurl['post-install'].some((command) => command.includes('SPNEGO( |$)')));
passed++;
// Execute the generated capability command with an explicit recording curl port.
// These parser/exit controls do not claim a native Flatpak curl or Kerberos session.
const featureCommands = flatpakCurl['post-install'].filter((command) =>
	command.includes('--version')
);
assert.equal(featureCommands.length, 1);
for (const [label, output, status, admitted] of [
	['complete features', 'curl fixture\nFeatures: GSS-API SPNEGO SSL', 0, true],
	['missing GSS', 'curl fixture\nFeatures: SPNEGO SSL', 0, false],
	['missing SPNEGO', 'curl fixture\nFeatures: GSS-API SSL', 0, false],
	['protocol names are not features', 'Protocols: GSS-API SPNEGO\nFeatures: SSL', 0, false],
	['foreign GSS suffix', 'Features: GSS-API-foreign SPNEGO', 0, false],
	['foreign SPNEGO suffix', 'Features: GSS-API SPNEGO-foreign', 0, false],
	['failed capability process', 'Features: GSS-API SPNEGO SSL', 1, false]
]) {
	const command =
		'curl() { test "$*" = "--disable --version" || return 91; ' +
		'printf "%s\\n" "$GSS_FIXTURE_OUTPUT"; return "$GSS_FIXTURE_STATUS"; }; ' +
		featureCommands[0].replaceAll('/app/bin/curl', 'curl');
	const result = spawnSync(bashExecutable(), ['-c', command], {
		cwd: root,
		encoding: 'utf8',
		env: { ...process.env, GSS_FIXTURE_OUTPUT: output, GSS_FIXTURE_STATUS: String(status) }
	});
	assert.ifError(result.error);
	assert.equal(result.signal, null, label);
	assert.equal(result.stderr, '', label);
	assert.equal(result.status === 0, admitted, label);
	passed++;
}
for (const mutation of [
	(data) => {
		delete data.network_runtime.portable.flatpak_sources.krb5;
	},
	(data) => {
		data.network_runtime.portable.flatpak_sources.krb5.url = 'https://foreign.invalid/krb5.tar.gz';
	},
	(data) => {
		data.network_runtime.portable.flatpak_sources.krb5.sha256 = 'unverified';
	},
	(data) => {
		data.network_runtime.portable.flatpak_sources.krb5.url =
			'http://web.mit.edu/kerberos/dist/krb5/1.22/krb5-1.22.2.tar.gz';
	}
]) {
	const invalid = structuredClone(catalogue);
	mutation(invalid);
	assert.throws(() => generator.validate(invalid));
	passed++;
}
// Preserve the complete original six-module order, source and option oracles.
const modules = allModules.filter((module) => module.name !== 'network-krb5');
assert.deepEqual(
	modules.map((module) => module.name),
	[
		'network-luv',
		'network-schemas',
		'network-curl',
		'network-duktape',
		'network-libproxy',
		'network-gio-proxy'
	]
);
assert.deepEqual(
	modules.map((module) => module.sources[0].url),
	[
		'https://github.com/luvit/luv.git',
		'https://github.com/GNOME/gsettings-desktop-schemas.git',
		'https://github.com/curl/curl.git',
		'https://github.com/svaarala/duktape/releases/download/v2.7.0/duktape-2.7.0.tar.xz',
		'https://github.com/libproxy/libproxy.git',
		'https://github.com/GNOME/glib-networking.git'
	]
);
assert.ok(modules[0]['config-opts'].includes('-DLUA_BUILD_TYPE=System'));
assert.ok(modules[4]['config-opts'].includes('-Dconfig-xdp=true'));
assert.ok(modules[5]['config-opts'].includes('-Dgnome_proxy=disabled'));
assert.ok(modules[5]['config-opts'].includes('-Dlibproxy=enabled'));
passed++;
for (const mutate of [
	(data) => {
		data.network_runtime.portable.gio_modules.pop();
	},
	(data) => {
		data.network_runtime.portable.system_ca_files = [];
	},
	(data) => {
		data.network_runtime.portable.system_ca_files[0] = '/tmp/../foreign';
	},
	(data) => {
		delete data.network_runtime.portable.flatpak_sources.libproxy;
	},
	(data) => {
		data.network_runtime.portable.flatpak_sources.curl.commit = 'unversioned';
	},
	(data) => {
		data.network_runtime.portable.flatpak_sources.duktape.sha256 = 'unverified';
	},
	(data) => {
		data.network_runtime.portable.flatpak_sources.luv.url = 'http://foreign.invalid/source';
	}
]) {
	const invalid = structuredClone(catalogue);
	mutate(invalid);
	assert.throws(() => generator.validate(invalid));
	passed++;
}
const projected = generator.render(catalogue, source);
const environment = projected[environmentTemplate];
assert.ok(
	environment.includes(
		'export LUA_CPATH="$ERGOPTI_PACKAGE_PREFIX/lib/lua/5.1/?.so${LUA_CPATH:+;$LUA_CPATH};;"'
	)
);
assert.ok(environment.includes('export GIO_MODULE_DIR="$ERGOPTI_PACKAGE_PREFIX/lib/gio/modules"'));
assert.ok(
	environment.includes(
		'export GSETTINGS_SCHEMA_DIR="$ERGOPTI_PACKAGE_PREFIX/share/glib-2.0/schemas"'
	)
);
assert.ok(environment.includes('Recipient system certificate bundle unavailable'));
assert.ok(!environment.includes('--insecure'));
assert.ok(!environment.includes('GSETTINGS_BACKEND=memory'));
passed++;
for (const [name, snippets] of [
	[
		'tools/build/build-linux-appimage.sh',
		[
			'python3 "$SCRIPT_DIR/stage-linux-network-runtime.py"',
			'source "$DRIVER_ROOT/network-runtime-env.sh" "$HERE/usr" "$DRIVER_ROOT"',
			'LUAJIT_BIN="$HERE/usr/bin/luajit"'
		]
	],
	[
		'tools/build/build-linux-flatpak.sh',
		[
			'generator.flatpakModules(data)',
			'source "$DRIVER_ROOT/network-runtime-env.sh" /app "$DRIVER_ROOT"',
			'/app/lib/ergopti/platform/network/runtime_probe.lua /app/lib/ergopti/_shared'
		]
	]
]) {
	for (const snippet of snippets) assert.ok(source(name).includes(snippet), name);
	passed++;
}

// Actual shell environment uses absolute installed paths, including spaces,
// from an unrelated CWD, and preserves an explicit recipient trust override.
if (process.platform === 'linux') {
	const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-package-controls-'));
	fs.chmodSync(scratch, 0o700);
	try {
		const prefix = path.join(scratch, 'installed prefix');
		const driver = path.join(prefix, 'lib/ergopti');
		fs.mkdirSync(driver, { recursive: true });
		for (const name of [
			'bin/luajit',
			'bin/curl',
			'lib/lua/5.1/luv.so',
			'lib/gio/modules/libgiolibproxy.so',
			'share/glib-2.0/schemas/gschemas.compiled'
		]) {
			fs.mkdirSync(path.dirname(path.join(prefix, name)), { recursive: true });
			fs.writeFileSync(path.join(prefix, name), 'owned existence fixture, never executed');
		}
		const script = path.join(scratch, 'environment.sh');
		fs.writeFileSync(script, environment);
		const trust = path.join(scratch, 'recipient trust');
		fs.writeFileSync(trust, 'owned trust override, no TLS request performed\n');
		const observed = spawnSync(
			bashExecutable(),
			[
				'-c',
				'set -euo pipefail; source "$1" "$2" "$3"; printf "%s\\n" "$LUA_CPATH" "$GIO_MODULE_DIR" "$GSETTINGS_SCHEMA_DIR" "$CURL_CA_BUNDLE"',
				'owned-environment',
				script,
				prefix,
				driver
			],
			{
				cwd: '/',
				encoding: 'utf8',
				env: {
					...process.env,
					CURL_CA_BUNDLE: trust,
					LUA_CPATH: path.join(scratch, 'optional native modules/?.so')
				}
			}
		);
		assert.equal(observed.status, 0);
		assert.equal(
			observed.stdout,
			[
				path.join(prefix, 'lib/lua/5.1/?.so') +
					';' +
					path.join(scratch, 'optional native modules/?.so') +
					';;',
				path.join(prefix, 'lib/gio/modules'),
				path.join(prefix, 'share/glib-2.0/schemas'),
				trust,
				''
			].join('\n')
		);
		passed++;
		// Import-only independent filesystem/ELF receipt controls do not execute a
		// GIO factory, curl, ldd or any native package component.
		const helper = path.join(root, 'tools/build/stage-linux-network-runtime.py');
		const controlled = spawnSync(
			'python3',
			[
				'-c',
				`
import contextlib,importlib.util,io,pathlib,sys,types
s=importlib.util.spec_from_file_location('owned_stager',sys.argv[1]);m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
p=pathlib.Path(sys.argv[2]);d=p/'components';d.mkdir();a=d/'a';b=d/'b';a.write_bytes(b'owned A');b.write_bytes(b'owned B');owners={}
m.copy_unique(a,d/'out',owners);m.copy_unique(a,d/'out',owners)
for operation in [lambda:m.copy_unique(b,d/'out',owners),lambda:m.regular_source(d/'absent'),lambda:m.dependency_paths('libmissing.so.0 => not found\\n'),lambda:m.dependency_paths('unrecognized private output\\n')]:
 try:operation()
 except (m.RuntimeRefused,OSError):pass
 else:raise AssertionError('Independent missing/foreign component must refuse')
foreign=d/'foreign';foreign.mkdir();alias=d/'alias';alias.symlink_to(foreign,target_is_directory=True)
try:m.destination_directory(alias/'child')
except m.RuntimeRefused:pass
else:raise AssertionError('Symlink destination must refuse')
assert not (foreign/'child').exists()
assert m.dependency_paths('libowned.so.1 => /owned/libowned.so.1 (0x1234)\\n')==[('libowned.so.1','/owned/libowned.so.1')]
assert m.external_glibc('libc.so.6') and not m.external_glibc('libgio-2.0.so.0')
# Independently insert a foreign leaf at the actual exclusive acquisition.
foreign_file=d/'foreign-data';foreign_file.write_bytes(b'foreign must remain unchanged');real_open=m.os.open;injected=[]
def raced_open(name,flags,*args,**kwargs):
 if name=='race-out' and flags & m.os.O_CREAT:
  m.os.symlink(str(foreign_file),'race-out',dir_fd=kwargs['dir_fd']);injected.append(True)
 return real_open(name,flags,*args,**kwargs)
m.os.open=raced_open
try:m.copy_unique(a,d/'race-out',{})
except m.RuntimeRefused:pass
else:raise AssertionError('Inserted foreign leaf must refuse')
finally:m.os.open=real_open
assert injected==[True] and foreign_file.read_bytes()==b'foreign must remain unchanged'
# Replace the ancestor after its descriptor is pinned. The foreign directory
# receives no write, and the changed publication path must refuse.
owned=d/'owned-parent';owned.mkdir();detached=d/'detached-owned';real_directory=m.directory_fd;replaced=[]
def raced_directory(target,*,create):
 fd=real_directory(target,create=create)
 if pathlib.Path(target)==owned:
  owned.rename(detached);owned.symlink_to(foreign,target_is_directory=True);replaced.append(True)
 return fd
m.directory_fd=raced_directory
try:m.copy_unique(a,owned/'new-component',{})
except m.RuntimeRefused:pass
else:raise AssertionError('Replaced ancestor must refuse publication')
finally:m.directory_fd=real_directory
assert replaced==[True] and not (foreign/'new-component').exists()
assert (detached/'new-component').read_bytes()==b'owned A'
# A failed output close must not replace the independently injected write
# refusal, leak other descriptors, or export its private exception message.
real_open=m.os.open;real_write=m.os.write;real_close=m.os.close;acquired=[];closed=[];cleanup_owner={};diagnostic=io.StringIO()
def tracked_open(name,flags,*args,**kwargs):
 fd=real_open(name,flags,*args,**kwargs)
 if name=='retirement-out':acquired.append(fd)
 return fd
def primary_write(fd,block):
 if fd in acquired:raise m.RuntimeRefused('Independent primary copy refusal.')
 return real_write(fd,block)
def refused_close(fd):
 real_close(fd)
 if fd in acquired:
  closed.append(fd);raise OSError('private-path private-secret cleanup metadata')
m.os.open=tracked_open;m.os.write=primary_write;m.os.close=refused_close
try:
 with contextlib.redirect_stderr(diagnostic):
  try:m.copy_unique(a,d/'retirement-out',cleanup_owner)
  except m.RuntimeRefused as refusal:assert str(refusal)=='Independent primary copy refusal.'
  else:raise AssertionError('Primary copy refusal was lost')
finally:m.os.open=real_open;m.os.write=real_write;m.os.close=real_close
assert len(acquired)==1 and closed==acquired and not cleanup_owner[d/'retirement-out']['complete']
try:m.os.fstat(acquired[0])
except OSError:pass
else:raise AssertionError('Acquired descriptor was not actually closed')
assert diagnostic.getvalue()=='Native packaging descriptor retirement refused; owned inputs retained.\\n'
# The actual stage entry must not normalize/adopt a root replaced after its
# first NOFOLLOW acquisition. Native commands are forbidden in this witness.
root=p/'root-race';root.mkdir();root_detached=p/'root-detached';foreign_root=p/'foreign-root';foreign_root.mkdir();root_injected=[];real_directory=m.directory_fd;real_run=m.run;real_uname=m.os.uname;old_deadline=m._STAGE_DEADLINE
# This is a filesystem-only supported-build entry witness, including on an
# ARM Linux runner; no architecture/FFI/native command is being qualified.
m.os.uname=lambda:types.SimpleNamespace(machine='x86_64')
def replaced_root(target,*,create,use_root=True):
 fd=real_directory(target,create=create,use_root=use_root)
 if pathlib.Path(target)==root and use_root and not root_injected:
  root.rename(root_detached);root.symlink_to(foreign_root,target_is_directory=True);root_injected.append(True)
 return fd
def forbidden_native(*args,**kwargs):raise AssertionError('Native command acquired after root replacement')
m.directory_fd=replaced_root;m.run=forbidden_native
try:m.stage(root,p/'unused-catalogue',p/'unused-template')
except m.RuntimeRefused:pass
else:raise AssertionError('Replaced actual stage root must refuse')
finally:m.directory_fd=real_directory;m.run=real_run;m.os.uname=real_uname;m._STAGE_DEADLINE=old_deadline
assert root_injected==[True] and list(foreign_root.iterdir())==[] and m._DESTINATION_ROOT is None
# The cache writer must receive the retained module directory FD capability.
# Replace its lexical destination during the call; only the detached owned
# directory receives the fixed model cache, and publication must refuse.
writer_root=p/'writer-root';writer_root.mkdir();modules=writer_root/'usr/lib/gio/modules';modules.mkdir(parents=True);detached_modules=writer_root/'usr/lib/gio/detached-modules';foreign_modules=p/'foreign-modules';foreign_modules.mkdir();writer_calls=[];writer_fds=[]
def cache_writer(arguments,*,pass_fds):
 assert arguments[0]=='gio-querymodules' and len(pass_fds)==1
 fd=pass_fds[0];writer_fds.append(fd);assert arguments[1]=='/proc/self/fd/'+str(fd)
 retained=m.os.fstat(fd);expected=modules.stat();assert (retained.st_dev,retained.st_ino)==(expected.st_dev,expected.st_ino)
 modules.rename(detached_modules);modules.symlink_to(foreign_modules,target_is_directory=True);writer_calls.append(True)
 output=m.os.open('giomodule.cache',m.os.O_WRONLY|m.os.O_CREAT|m.os.O_EXCL,0o600,dir_fd=fd)
 try:assert m.os.write(output,b'owned cache model')==len(b'owned cache model')
 finally:m.os.close(output)
 return ''
m.run=cache_writer
try:
 with m.owned_root(writer_root):
  try:m.query_modules(modules)
  except m.RuntimeRefused:pass
  else:raise AssertionError('Replaced native writer destination must refuse publication')
finally:m.run=real_run
assert writer_calls==[True] and list(foreign_modules.iterdir())==[]
assert (detached_modules/'giomodule.cache').read_bytes()==b'owned cache model' and m._DESTINATION_ROOT is None
for fd in writer_fds:
 try:m.os.fstat(fd)
 except OSError:pass
 else:raise AssertionError('Owned writer directory descriptor was not retired')
# Actual directory identity mismatch plus actual close-then-refusal must
# preserve the earlier mismatch and never export private cleanup metadata.
retirement_root=p/'writer-retirement-root';retirement_root.mkdir();target=retirement_root/'module-directory';target.mkdir();original_target=retirement_root/'original-module-directory';observations=[];retired=[];observation_diagnostic=io.StringIO();real_directory=m.directory_fd;real_close=m.os.close
with m.owned_root(retirement_root):
 def observed_directory(path,*,create,use_root=True):
  fd=real_directory(path,create=create,use_root=use_root)
  if pathlib.Path(path)==target:observations.append(fd)
  return fd
 def refused_observation_close(fd):
  real_close(fd)
  if len(observations)==2 and fd==observations[1]:
   retired.append(fd);raise OSError('private path secret native close metadata')
 m.directory_fd=observed_directory;m.os.close=refused_observation_close
 try:
  with contextlib.redirect_stderr(observation_diagnostic):
   try:
    with m.held_directory(target):target.rename(original_target);target.mkdir()
   except m.RuntimeRefused as refusal:assert str(refusal)=='Owned native writer directory changed.'
   else:raise AssertionError('Earlier native writer identity mismatch was lost')
 finally:m.directory_fd=real_directory;m.os.close=real_close
 assert len(observations)==2 and retired==[observations[1]]
 for fd in observations:
  try:m.os.fstat(fd)
  except OSError:pass
  else:raise AssertionError('Acquired writer directory was not actually retired')
 assert observation_diagnostic.getvalue()=='Native writer observation retirement refused; owned inputs retained.\\n'
assert m._DESTINATION_ROOT is None
print('PASS independent portable component controls: 13 passed; 0 skipped.')
`,
				helper,
				scratch
			],
			{ cwd: '/', encoding: 'utf8', env: { ...process.env, PYTHONDONTWRITEBYTECODE: '1' } }
		);
		assert.equal(controlled.status, 0);
		assert.equal(
			controlled.stdout,
			'PASS independent portable component controls: 13 passed; 0 skipped.\n'
		);
		passed++;
	} finally {
		fs.rmSync(scratch, { recursive: true });
	}
}
console.log(
	`Linux portable network packaging controls: ${passed} passed; ${process.platform === 'linux' ? 0 : 2} Linux-only filesystem groups skipped.`
);

// Independent command-contract witness: desktop runtime schemas need not ship
// their development .pc file. Only the actual GIO-owned metadata is admitted;
// this spy qualifies query selection and refusals, never native ABI or bytes.
if (process.platform === 'linux') {
	const schemaMetadata = spawnSync(
		'python3',
		[
			'-B',
			'-c',
			`
import importlib.util,json,pathlib,sys,tempfile,types
spec=importlib.util.spec_from_file_location('owned_stager',sys.argv[1]);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class BoundaryReached(Exception):pass
with tempfile.TemporaryDirectory(prefix='ergopti-gio-metadata-') as temporary:
 root=pathlib.Path(temporary);sources=root/'sources';sources.mkdir()
 for name in ['luajit','curl','luv.so','libgiognomeproxy.so','libgiolibproxy.so','libdconfsettings.so','libcrypto.so.3']:(sources/name).write_bytes(b'independent query control only')
 schema=root/'runtime schemas';schema.mkdir();(schema/'gschemas.compiled').write_bytes(b'independent schema acquisition control only')
 catalogue=root/'catalogue.json';catalogue.write_text(json.dumps({'network_runtime':{'portable':{'gio_modules':['libgiognomeproxy.so','libgiolibproxy.so','libdconfsettings.so']}},'archive_digest_runtime':{'soname':'libcrypto.so.3','portable_dlopen_roots':['libcrypto.so.3']}}))
 real_uname=m.os.uname;m.os.uname=lambda:types.SimpleNamespace(machine='x86_64')
 m.shutil.which=lambda name:str(sources/name)
 try:
  for index,value in enumerate([str(schema),'','relative/untrusted-schemas']):
   appdir=root/('package'+str(index));driver=appdir/'usr/lib/ergopti';(driver/'platform/network').mkdir(parents=True);(driver/'platform/network/runtime_probe.lua').write_bytes(b'no execution in query witness')
   queries=[];copies=[];closure=[];crypto_queries=[]
   def controlled_run(arguments,**options):
    if arguments[0]==str(sources/'luajit'):return str(sources/'luv.so')
    # Separate explicit crypto command-contract model; dummy bytes/SONAME output
    # never qualify native OpenSSL ABI, ELF inspection, staging or digest behavior.
    if arguments==['pkg-config','--variable=libdir','libcrypto']:
     crypto_queries.append(arguments);return str(sources)
    if arguments==['readelf','--dynamic','--',str(sources/'libcrypto.so.3')]:
     assert options['env']['LC_ALL']=='C','Explicit SONAME observation must use fixed locale'
     crypto_queries.append(arguments)
     return ' 0x000000000000000e (SONAME) Library soname: [libcrypto.so.3]\\n'
    assert arguments[0]=='pkg-config' and len(arguments)==3,'Unexpected native command or schema factory'
    queries.append(arguments)
    if arguments==['pkg-config','--variable=giomoduledir','gio-2.0']:return str(sources)
    assert arguments==['pkg-config','--variable=schemasdir','gio-2.0'],'Desktop development metadata must not be required'
    return value
   def boundary(*arguments):
    assert [pathlib.Path(item) for item in arguments[0]]==[sources/name for name in ['luajit','curl','luv.so','libgiognomeproxy.so','libgiolibproxy.so','libdconfsettings.so','libcrypto.so.3']],'Explicit crypto source must join the unchanged closure seeds'
    closure.append(True);raise BoundaryReached()
   m.run=controlled_run;m.copy_unique=lambda source,destination,owners:copies.append((pathlib.Path(source),pathlib.Path(destination)));m.copy_elf_closure=boundary
   try:m.stage(str(appdir),str(catalogue),'unused owned template')
   except BoundaryReached:assert index==0
   except m.RuntimeRefused as refusal:
    assert index>0 and str(refusal)=='Native schema location refused.'
   else:raise AssertionError('Query witness must terminate before native ELF or cache commands')
   assert queries==[['pkg-config','--variable=giomoduledir','gio-2.0'],['pkg-config','--variable=schemasdir','gio-2.0']]
   schema_copies=[source for source,destination in copies if destination.name=='gschemas.compiled']
   assert schema_copies==([schema/'gschemas.compiled'] if index==0 else [])
   # Invalid schema values refuse before the newly explicit crypto boundary.
   assert crypto_queries==([['pkg-config','--variable=libdir','libcrypto'],['readelf','--dynamic','--',str(sources/'libcrypto.so.3')]] if index==0 else [])
   crypto_copies=[source for source,destination in copies if destination.name=='libcrypto.so.3']
   assert crypto_copies==([sources/'libcrypto.so.3'] if index==0 else [])
   assert closure==([True] if index==0 else []) and m._DESTINATION_ROOT is None
 finally:m.os.uname=real_uname
with tempfile.TemporaryDirectory(prefix='ergopti-gio-cache-tool-') as temporary:
 root=pathlib.Path(temporary);tool=root/'actual owned executable';tool.write_bytes(b'not executed by metadata control');tool.chmod(0o700)
 nonexecutable=root/'ordinary owned file';nonexecutable.write_bytes(b'not executable')
 for index,value in enumerate([str(tool),'','relative/foreign-tool',str(root/'absent'),str(nonexecutable)]):
  queries=[]
  def tool_metadata(arguments,**options):
   assert arguments==['pkg-config','--variable=gio_querymodules','gio-2.0'],'No writer, replacement native command or foreign metadata query admitted'
   queries.append(arguments);return value
  m.run=tool_metadata
  try:observed=m.gio_querymodules_executable()
  except (m.RuntimeRefused,OSError):assert index>0
  else:assert index==0 and observed==str(tool)
  assert queries==[['pkg-config','--variable=gio_querymodules','gio-2.0']]
print('PASS GIO-owned metadata: 3 schema and 5 cache executable cases; native ABI unqualified.')
`,
			path.join(root, 'tools/build/stage-linux-network-runtime.py')
		],
		{
			cwd: '/',
			encoding: 'utf8',
			env: { ...process.env, PYTHONDONTWRITEBYTECODE: '1' }
		}
	);
	assert.equal(schemaMetadata.status, 0, 'GIO-owned schema metadata selection refused');
	assert.equal(schemaMetadata.stderr, '');
	assert.equal(
		schemaMetadata.stdout,
		'PASS GIO-owned metadata: 3 schema and 5 cache executable cases; native ABI unqualified.\n'
	);
	console.log('GIO-owned schema metadata control: 1 passed; 0 skipped.');
}

// Real filesystem controls for private evidence, independent of native runtime
// success. Sample private bytes are never logged or uploaded by this harness.
if (process.platform === 'linux') {
	const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-stage-receipt-'));
	fs.chmodSync(directory, 0o700);
	try {
		const result = {
			status: 1,
			signal: null,
			stdout: 'owned private stdout\n',
			stderr: 'owned private stderr\n'
		};
		const successful = path.join(directory, 'owned');
		fs.mkdirSync(successful, { mode: 0o700 });
		assert.equal(
			persistOwnedStageReceipt(successful, fs.lstatSync(successful, { bigint: true }), result).ok,
			true
		);
		const receipt = path.join(successful, 'staging-producer.private.json');
		assert.deepEqual(JSON.parse(fs.readFileSync(receipt, 'utf8')), {
			phase: 'native-stage',
			exit_status: 1,
			signal: null,
			error_code: null,
			stdout: result.stdout,
			stderr: result.stderr
		});
		assert.equal(fs.statSync(receipt).mode & 0o777, 0o600);
		const collided = path.join(directory, 'collision');
		fs.mkdirSync(collided, { mode: 0o700 });
		const foreign = path.join(directory, 'foreign-data');
		fs.writeFileSync(foreign, 'foreign must remain unchanged', { flag: 'wx', mode: 0o600 });
		fs.symlinkSync(foreign, path.join(collided, 'staging-producer.private.json'));
		assert.equal(
			persistOwnedStageReceipt(collided, fs.lstatSync(collided, { bigint: true }), result).ok,
			false
		);
		assert.equal(fs.readFileSync(foreign, 'utf8'), 'foreign must remain unchanged');
		const replaced = path.join(directory, 'replaced');
		const detached = path.join(directory, 'detached');
		const foreignRoot = path.join(directory, 'foreign-root');
		fs.mkdirSync(replaced, { mode: 0o700 });
		fs.mkdirSync(foreignRoot, { mode: 0o700 });
		const identity = fs.lstatSync(replaced, { bigint: true });
		fs.renameSync(replaced, detached);
		fs.symlinkSync(foreignRoot, replaced);
		assert.equal(persistOwnedStageReceipt(replaced, identity, result).ok, false);
		assert.deepEqual(fs.readdirSync(detached), []);
		assert.deepEqual(fs.readdirSync(foreignRoot), []);
		const flushRefused = path.join(directory, 'flush-refused');
		fs.mkdirSync(flushRefused, { mode: 0o700 });
		const realFlush = fs.fsyncSync;
		const realClose = fs.closeSync;
		const retired = [];
		let publication;
		try {
			fs.fsyncSync = () => {
				throw new Error('private flush failure');
			};
			fs.closeSync = (descriptor) => {
				realClose(descriptor);
				retired.push(descriptor);
			};
			publication = persistOwnedStageReceipt(
				flushRefused,
				fs.lstatSync(flushRefused, { bigint: true }),
				result
			);
		} finally {
			fs.fsyncSync = realFlush;
			fs.closeSync = realClose;
		}
		assert.equal(publication.ok, false);
		assert.equal(retired.length, 2);
		for (const descriptor of retired) assert.throws(() => fs.fstatSync(descriptor));
		assert.equal(result.status, 1, 'Diagnostic refusal must preserve original producer status');
		// Exact inode model independently exhibits the numeric rounding collision.
		const highInode = path.join(directory, 'high-inode');
		fs.mkdirSync(highInode, { mode: 0o700 });
		const firstInode = 9007199254740992n;
		const secondInode = 9007199254740993n;
		assert.equal(Number(firstInode), Number(secondInode));
		const realStat = fs.fstatSync;
		const realLstat = fs.lstatSync;
		const observedIdentity = realLstat(highInode, { bigint: true });
		const modeledIdentity = Object.assign(Object.create(observedIdentity), { ino: firstInode });
		let highInodePublication;
		try {
			fs.fstatSync = (descriptor, options) => {
				assert.equal(options.bigint, true);
				const observed = realStat(descriptor, options);
				return observed.isDirectory()
					? Object.assign(Object.create(observed), { ino: firstInode })
					: observed;
			};
			fs.lstatSync = (name, options) => {
				assert.equal(options.bigint, true);
				const observed = realLstat(name, options);
				return name === highInode
					? Object.assign(Object.create(observed), { ino: secondInode })
					: observed;
			};
			highInodePublication = persistOwnedStageReceipt(highInode, modeledIdentity, result);
		} finally {
			fs.fstatSync = realStat;
			fs.lstatSync = realLstat;
		}
		assert.equal(highInodePublication.ok, false, 'Distinct high inodes must refuse publication');
		const publicRoot = path.join(directory, 'nonprivate-root');
		fs.mkdirSync(publicRoot, { mode: 0o700 });
		fs.chmodSync(publicRoot, 0o755);
		assert.equal(
			persistOwnedStageReceipt(publicRoot, fs.lstatSync(publicRoot, { bigint: true }), result).ok,
			false
		);
		assert.deepEqual(fs.readdirSync(publicRoot), []);
		const changedLeaf = path.join(directory, 'changed-leaf-mode');
		fs.mkdirSync(changedLeaf, { mode: 0o700 });
		let changedLeafPublication;
		try {
			fs.fsyncSync = (descriptor) => {
				realFlush(descriptor);
				fs.fchmodSync(descriptor, 0o644);
			};
			changedLeafPublication = persistOwnedStageReceipt(
				changedLeaf,
				fs.lstatSync(changedLeaf, { bigint: true }),
				result
			);
		} finally {
			fs.fsyncSync = realFlush;
		}
		assert.equal(
			changedLeafPublication.ok,
			false,
			'Actual public leaf permissions must refuse publication'
		);
		const foreignOwner = path.join(directory, 'foreign-owner-model');
		fs.mkdirSync(foreignOwner, { mode: 0o700 });
		let ownerPublication;
		try {
			fs.fstatSync = (descriptor, options) => {
				assert.equal(options.bigint, true);
				const observed = realStat(descriptor, options);
				return observed.isDirectory()
					? Object.assign(Object.create(observed), { uid: observed.uid + 1n })
					: observed;
			};
			ownerPublication = persistOwnedStageReceipt(
				foreignOwner,
				realLstat(foreignOwner, { bigint: true }),
				result
			);
		} finally {
			fs.fstatSync = realStat;
		}
		assert.equal(ownerPublication.ok, false, 'Different actual descriptor UID must refuse');
		assert.deepEqual(fs.readdirSync(foreignOwner), []);
		console.log('Private staging receipt controls: 8 passed; 0 skipped.');
	} finally {
		fs.rmSync(directory, { recursive: true });
	}
}

// Literal kernel-stat fixtures are independent of the changed parser. They
// model census completeness/refusal only; native ownership needs actual tests.
if (process.platform === 'linux') {
	const censusControls = spawnSync(
		'python3',
		[
			'-B',
			'-c',
			`
import importlib.util,io,sys
spec=importlib.util.spec_from_file_location('owned_stager',sys.argv[1]);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
rows={
410:b'410 (owned parent) S 1 410 410 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 101\\n',
731:b'731 (owned worker ) unusual) S 410 731 731 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 201\\n',
732:b'732 (owned zombie) Z 410 731 731 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 202\\n',
733:b'733 (other parent) S 42 731 731 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 203\\n'
}
class View:
 entries=['733','732','self','410','731'];records=rows.copy();self_record=rows[410];self_sequence=None;status=b'NSpid:\t410\\n';status_sequence=None
view=View()
class ControlledPath:
 def __init__(self,value):self.value=str(value);self.name=self.value.rsplit('/',1)[-1]
 def iterdir(self):
  assert self.value=='/proc','No argv/environment or unrelated native source'
  if isinstance(view.entries,BaseException):raise view.entries
  return iter(ControlledPath('/proc/'+name) for name in view.entries)
 def read_bytes(self):
  if self.value=='/proc/self/stat':
   value=view.self_sequence.pop(0) if view.self_sequence is not None else view.self_record
   if isinstance(value,BaseException):raise value
   return value
  parts=self.value.split('/');assert len(parts)==4 and parts[1]=='proc' and parts[3]=='stat'
  value=view.records.get(int(parts[2]),FileNotFoundError())
  if isinstance(value,BaseException):raise value
  return value
 def open(self,mode):
  assert self.value=='/proc/self/status' and mode=='rb'
  value=view.status_sequence.pop(0) if view.status_sequence is not None else view.status
  if isinstance(value,BaseException):raise value
  return io.BytesIO(value)
real_path=m.Path;real_pid=m.os.getpid;m.Path=ControlledPath;m.os.getpid=lambda:410
passed=0
try:
 assert m.process_fact(731)=={'state':'S','parent':410,'group':731,'session':731,'birth':201};passed+=1
 assert m.direct_children()==[731,732];passed+=1
 assert m.process_fact(732)['parent']==410 and m.process_fact(732)['state']=='Z';passed+=1
 assert m.group_live_members(731)==[733,731];passed+=1
 view.entries=['410','999','731'];assert m.direct_children()==[731];passed+=1
 def refuses(entries,records):
  view.entries=entries;view.records=records
  try:m.process_census()
  except m.RuntimeRefused:pass
  else:raise AssertionError('Missing/incomplete/denied kernel census must refuse')
 refuses(FileNotFoundError(),rows);passed+=1
 refuses(['731','732'],rows);passed+=1
 refuses(['410','733'],{**rows,733:PermissionError(13,'private refusal')});passed+=1
 refuses(['410','731'],{**rows,731:b'731 (owned worker) S 410 731\\n'});passed+=1
 refuses(['410','731'],{**rows,731:b'731 (owned worker) S -1 731 731 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 201\\n'});passed+=1
 refuses(['410','731'],{**rows,731:b'734 (wrong PID) S 410 731 731 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 201\\n'});passed+=1
 refuses(['410','731','731'],rows);passed+=1
 refuses(['410','731'],{**rows,410:FileNotFoundError()});passed+=1
 refuses(['410','0'],rows);passed+=1
 view.entries=['410','734'];view.records={**rows,734:b'734 (exiting foreign) X 0 -1 -1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 204\\n'}
 assert m.process_fact(734)=={'state':'X','parent':0,'group':-1,'session':-1,'birth':204}
 assert m.direct_children()==[] and m.group_live_members(-1)==[];passed+=1
 assert passed==15
 # Complementary actual-self/PID-view fixtures do not derive identity from
 # the numeric owner row. Every disagreement must refuse a completed census.
 namespace_passed=0
 def owner_refuses(record=rows[410],status=b'NSpid:\t410\\n',self_sequence=None,status_sequence=None,numeric_owner=rows[410]):
  view.entries=['410','731'];view.records={**rows,410:numeric_owner};view.self_record=record;view.status=status;view.self_sequence=self_sequence;view.status_sequence=status_sequence
  try:m.process_census()
  except m.RuntimeRefused:pass
  else:raise AssertionError('Actual self/PID-view disagreement must refuse')
 owner_refuses(numeric_owner=b'410 (foreign numeric owner) S 1 410 410 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 999\\n');namespace_passed+=1
 owner_refuses(record=b'411 (different self) S 1 411 411 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 101\\n');namespace_passed+=1
 changed_self=b'410 (changed self birth) S 1 410 410 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 102\\n'
 owner_refuses(self_sequence=[rows[410],changed_self]);namespace_passed+=1
 owner_refuses(status=b'NSpid:\t917\t410\\n');namespace_passed+=1
 owner_refuses(status=b'NSpid:\t410\t410\\n');namespace_passed+=1
 owner_refuses(status=b'Pid:\t410\\n');namespace_passed+=1
 owner_refuses(status=b'NSpid:\t410\\nNSpid:\t410\\n');namespace_passed+=1
 owner_refuses(status=PermissionError(13,'private self-status refusal'));namespace_passed+=1
 owner_refuses(status=b'x'*65537);namespace_passed+=1
 owner_refuses(record=FileNotFoundError());namespace_passed+=1
 owner_refuses(status_sequence=[b'NSpid:\t410\\n',b'NSpid:\t917\t410\\n']);namespace_passed+=1
 owner_refuses(status=b'NSpid:unrecognized\t410\\n');namespace_passed+=1
 assert namespace_passed==12
finally:m.Path=real_path;m.os.getpid=real_pid
print('PASS PPID census literal controls: 15 passed; 0 skipped; native authority unqualified.')
print('PASS PPID owner/view controls: 12 passed; 0 skipped; native authority unqualified.')
`,
			path.join(root, 'tools/build/stage-linux-network-runtime.py')
		],
		{ cwd: '/', encoding: 'utf8', env: { ...process.env, PYTHONDONTWRITEBYTECODE: '1' } }
	);
	assert.equal(censusControls.status, 0, 'Independent PPID census controls refused');
	assert.equal(censusControls.stderr, '');
	assert.equal(
		censusControls.stdout,
		'PASS PPID census literal controls: 15 passed; 0 skipped; native authority unqualified.\n' +
			'PASS PPID owner/view controls: 12 passed; 0 skipped; native authority unqualified.\n'
	);
	console.log('PPID census literal controls: 15 passed; 0 skipped.');
	console.log('PPID owner/view controls: 12 passed; 0 skipped.');
}

if (process.argv.includes('--native')) {
	assert.equal(process.platform, 'linux', 'Native package qualification requires Linux');
	const appdir = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-native-appdir-'));
	fs.chmodSync(appdir, 0o700);
	const appdirIdentity = fs.lstatSync(appdir, { bigint: true });
	const driver = path.join(appdir, 'usr/lib/ergopti');
	fs.mkdirSync(driver, { recursive: true });
	fs.cpSync(path.join(root, 'static/ergopti_plus/linux'), driver, { recursive: true });
	fs.cpSync(path.join(root, 'static/ergopti_plus/_shared'), path.join(driver, '_shared'), {
		recursive: true
	});
	const staged = spawnSync(
		'python3',
		[
			path.join(root, 'tools/build/stage-linux-network-runtime.py'),
			'--appdir',
			appdir,
			'--catalogue',
			path.join(root, generator.SOURCE),
			'--template',
			path.join(root, environmentTemplate)
		],
		{ cwd: '/', encoding: 'utf8' }
	);
	const producerReceipt = persistOwnedStageReceipt(appdir, appdirIdentity, staged);
	if (!producerReceipt.ok) {
		console.error('Native staging private receipt refused; owned fixture retained.');
	}
	// Refusal preserves the owned package for diagnosis. No successful receipt
	// is inferred from host ABI tests, static source guards or staging alone.
	assert.equal(staged.status, 0, 'Actual AppDir runtime staging refused; owned fixture retained');
	assert.equal(producerReceipt.ok, true, 'Native staging private receipt publication refused');
	assert.equal(
		staged.stdout,
		'PASS AppImage staged native network runtime: ABI/backend/schema admitted; PAC/session unqualified.\n'
	);
	const nativeProbe = () =>
		spawnSync(
			'python3',
			[
				path.join(root, 'tools/build/stage-linux-network-runtime.py'),
				'--appdir',
				appdir,
				'--catalogue',
				path.join(root, generator.SOURCE),
				'--template',
				path.join(root, environmentTemplate),
				'--probe-only'
			],
			{ cwd: '/', encoding: 'utf8' }
		);
	assert.equal(nativeProbe().status, 0);
	for (const component of [
		'usr/lib/lua/5.1/luv.so',
		'usr/lib/gio/modules/libgiolibproxy.so',
		'usr/share/glib-2.0/schemas/gschemas.compiled'
	]) {
		const original = path.join(appdir, component);
		fs.renameSync(original, original + '.owned-disabled');
		const refused = nativeProbe();
		assert.equal(refused.status, 1, 'Missing installed component must refuse without abort');
		assert.equal(refused.stdout, '');
		assert.equal(refused.stderr, 'Native network packaging refused.\n');
		fs.renameSync(original + '.owned-disabled', original);
		assert.equal(nativeProbe().status, 0);
	}
	// The actual command owner must retire both an ordinary command and a
	// timeout's setsid-escaped descendant. These are real kernel controls;
	// their private PID/birth marker never becomes public test output.
	const commandOwnership = spawnSync(
		'python3',
		[
			'-B',
			'-c',
			`
import importlib.util,json,pathlib,sys,time
spec=importlib.util.spec_from_file_location('owned_stager',sys.argv[1]);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
baseline=m.subreaper()
assert m.run([sys.executable,'-c',"print('OWNED_CAPTURE_ACK')"],budget_seconds=2)=='OWNED_CAPTURE_ACK\\n'
assert m.direct_children()==[] and m.subreaper()==baseline
marker=pathlib.Path(sys.argv[2])/'escaped-child.json'
child_program="""import json,os,pathlib,sys,time
child=os.fork()
if child==0:
 os.setsid()
 raw=pathlib.Path('/proc/self/stat').read_bytes().rpartition(b') ')[2].split()
 pathlib.Path(sys.argv[1]).write_text(json.dumps({'pid':os.getpid(),'birth':int(raw[19])}))
 time.sleep(60)
else:
 while not pathlib.Path(sys.argv[1]).exists():time.sleep(0.01)
 print('OWNED_ESCAPE_ACQUIRED',flush=True)
 time.sleep(60)
"""
started=time.monotonic()
try:m.run([sys.executable,'-c',child_program,str(marker)],budget_seconds=0.5)
except m.RuntimeRefused as refusal:
 assert str(refusal)=='Native packaging command deadline or cancellation refused.'
else:raise AssertionError('Owned command deadline was not preserved')
assert marker.is_file(), 'Escape control must actually acquire its descendant'
identity=json.loads(marker.read_text())
try:current=m.process_fact(identity['pid'])
except FileNotFoundError:pass
else:assert current['birth']!=identity['birth'], 'Original owned descendant still exists'
assert m.direct_children()==[] and m.subreaper()==baseline
assert time.monotonic()-started<5, 'Successful command retirement must be bounded'
print('PASS actual Linux command ownership: 2 native groups; 0 skipped.')
`,
			path.join(root, 'tools/build/stage-linux-network-runtime.py'),
			appdir
		],
		{ cwd: '/', encoding: 'utf8' }
	);
	assert.equal(
		commandOwnership.status,
		0,
		'Actual command ownership refused; owned fixture retained'
	);
	assert.equal(
		commandOwnership.stdout,
		'PASS actual Linux command ownership: 2 native groups; 0 skipped.\n'
	);

	fs.rmSync(appdir, { recursive: true });
	console.log(
		'PASS actual staged AppDir network runtime: 7 native groups; real AppImage/Flatpak delivery unqualified.'
	);
}

// This separate actual-kernel control adds no original native-7 credit. Its
// worker and every descendant are supervised by the unchanged production run.
if (process.argv.includes('--native') || process.argv.includes('--census-native')) {
	assert.equal(process.platform, 'linux', 'Actual PPID census requires Linux');
	const nativeCensus = spawnSync(
		'python3',
		[
			'-B',
			'-c',
			`
import importlib.util,os,sys
spec=importlib.util.spec_from_file_location('owned_stager',sys.argv[1]);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
control="""
import importlib.util,os,signal,subprocess,sys,time
spec=importlib.util.spec_from_file_location('controlled_stager',sys.argv[1]);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
assert m.direct_children()==[]
child=subprocess.Popen([sys.executable,'-B','-c','import time;time.sleep(60)'])
# There is no competing reaper in this single-threaded worker. An unreaped
# child cannot lose its reserved PID even if it exits between observation and
# signal. waitid proves kernel ownership before every destructive action.
assert m.direct_children()==[child.pid]
fact=m.process_fact(child.pid);assert fact['parent']==os.getpid()
try:m.run([sys.executable,'-B','-c',"print('UNADMITTED_CHILD')"])
except m.RuntimeRefused as refusal:assert str(refusal)=='Exclusive native command ownership unavailable.'
else:raise AssertionError('Existing direct child must prevent a new command')
assert m.direct_children()==[child.pid]
assert m.observe_child(child.pid) is None
assert m.process_fact(child.pid)['birth']==fact['birth']
os.kill(child.pid,signal.SIGTERM)
deadline=time.monotonic()+2
while True:
 observed=m.observe_child(child.pid)
 if observed is not None:break
 assert time.monotonic()<deadline,'Owned terminal observation must be bounded'
 time.sleep(0.01)
assert observed.si_pid==child.pid and observed.si_code==os.CLD_KILLED and observed.si_status==signal.SIGTERM
assert m.direct_children()==[child.pid]
assert m.process_fact(child.pid)['birth']==fact['birth'] and m.process_fact(child.pid)['state']=='Z'
reaped,status=os.waitpid(child.pid,0);assert reaped==child.pid
child.returncode=os.waitstatus_to_exitcode(status)
assert m.direct_children()==[]
print('PASS actual PPID exclusive-child and WNOWAIT reservation: 2 passed; 0 skipped.')
"""
baseline=m.subreaper()
assert m.run([sys.executable,'-B','-c',control,sys.argv[1]],budget_seconds=5)=='PASS actual PPID exclusive-child and WNOWAIT reservation: 2 passed; 0 skipped.\\n'
assert m.direct_children()==[] and m.subreaper()==baseline
print('PASS actual PPID exclusive-child and WNOWAIT reservation: 2 passed; 0 skipped.')
`,
			path.join(root, 'tools/build/stage-linux-network-runtime.py')
		],
		{ cwd: '/', encoding: 'utf8', env: { ...process.env, PYTHONDONTWRITEBYTECODE: '1' } }
	);
	assert.equal(nativeCensus.status, 0, 'Actual PPID census/kernel ownership refused');
	assert.equal(nativeCensus.stderr, '');
	assert.equal(
		nativeCensus.stdout,
		'PASS actual PPID exclusive-child and WNOWAIT reservation: 2 passed; 0 skipped.\n'
	);
	console.log('Actual PPID census controls: 2 passed; 0 skipped; native-7 credit unchanged.');
}
