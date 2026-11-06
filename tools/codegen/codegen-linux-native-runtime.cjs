// tools/codegen/codegen-linux-native-runtime.cjs

/** Projects the Linux runtime catalogue into native package and FFI consumers. */
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const ROOT = path.resolve(__dirname, '../..');
const SOURCE = 'static/ergopti_plus/_shared/data/linux_native_runtime.json';
const IDENTIFIERS = 'static/ergopti_plus/_shared/data/identifiers.json';
const LUA_OUTPUT = 'static/ergopti_plus/linux/_generated/native_runtime.lua';
const MANAGERS = ['apt', 'dnf', 'zypper', 'pacman', 'xbps', 'apk'];
const KEYS = ['xkbcommon', 'xkbcommon_x11', 'x11', 'x11_xcb'];
const NETWORK_KEYS = ['gio', 'gobject', 'glib'];
// FFI libraries a feature loads when present (the Wayland clipboard owner).
const OPTIONAL_KEYS = ['wayland_client'];
const LUV_CMAKE_OPTIONS = [
	'-DLUA_BUILD_TYPE=System',
	'-DWITH_LUA_ENGINE=LuaJIT',
	'-DBUILD_MODULE=ON',
	'-DBUILD_SHARED_LIBS=OFF',
	'-DBUILD_STATIC_LIBS=OFF',
	'-DWITH_SHARED_LIBUV=OFF'
];

/** Reject data that could escape native metadata, shell literals or Lua strings. */
function validate(data) {
	if (Object.keys(data.archive_build_packages || {}).join(',') !== MANAGERS.join(','))
		throw new TypeError('Incomplete source archive build package mapping.');
	for (const packages of Object.values(data.archive_build_packages)) {
		if (packages === null) continue;
		if (!Array.isArray(packages) || !packages.length || new Set(packages).size !== packages.length)
			throw new TypeError('Invalid source archive build package list.');
		for (const pkg of packages)
			if (typeof pkg !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9+_.-]*$/.test(pkg))
				throw new TypeError('Invalid source archive build package identity.');
	}
	if (data?.version !== 1 || Object.keys(data.libraries || {}).join(',') !== KEYS.join(','))
		throw new TypeError('Linux runtime catalogue requires its four ordered library identities.');
	for (const [key, library] of Object.entries(data.libraries)) {
		if (!/^lib[A-Za-z0-9_-]+\.so\.[0-9]+$/.test(library.soname))
			throw new TypeError(`Invalid runtime SONAME for ${key}.`);
		if (Object.keys(library.packages || {}).join(',') !== MANAGERS.join(','))
			throw new TypeError(`Incomplete native distribution package mapping for ${key}.`);
		for (const pkg of Object.values(library.packages))
			if (typeof pkg !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9+_.-]*$/.test(pkg))
				throw new TypeError(`Invalid native package for ${key}.`);
		if (!/^[A-Za-z][A-Za-z0-9_.-]*$/.test(library.nix_package))
			throw new TypeError(`Invalid Nix native package for ${key}.`);
	}
	for (const name of ['deb', 'rpm', 'arch', 'nix_library_path']) {
		const values = data.package_requirements?.[name];
		if (!Array.isArray(values) || !values.length || new Set(values).size !== values.length)
			throw new TypeError(`Missing or duplicate preserved ${name} requirements.`);
		for (const value of values)
			if (
				typeof value !== 'string' ||
				!/^[A-Za-z0-9][A-Za-z0-9+_.-]*(?: \(>= [0-9.]+\)| >= [0-9.]+)?$/.test(value)
			)
				throw new TypeError(`Invalid preserved ${name} requirement.`);
	}
	const digest = data.archive_digest_runtime;
	if (!digest || digest.soname !== 'libcrypto.so.3' || digest.nix_package !== 'openssl')
		throw new TypeError('Missing or invalid OpenSSL3 digest runtime identity.');
	if (
		!Array.isArray(digest.deb_dependency_alternatives) ||
		digest.deb_dependency_alternatives.join(',') !== 'libssl3t64,libssl3'
	)
		throw new TypeError('Invalid ordered Debian OpenSSL3 alternatives.');
	if (Object.keys(digest.package_alternatives || {}).join(',') !== MANAGERS.join(','))
		throw new TypeError('Incomplete digest runtime repair availability.');
	for (const [manager, packages] of Object.entries(digest.package_alternatives)) {
		if (packages === null) continue;
		if (
			manager !== 'apt' ||
			!Array.isArray(packages) ||
			packages.join(',') !== digest.deb_dependency_alternatives.join(',')
		)
			throw new TypeError('Unreviewed digest runtime repair provider.');
	}
	if (
		!Array.isArray(digest.portable_dlopen_roots) ||
		digest.portable_dlopen_roots.join(',') !== digest.soname
	)
		throw new TypeError('Missing explicit portable OpenSSL3 dlopen root.');
	const optional = data.optional_libraries;
	if (Object.keys(optional || {}).join(',') !== ['description', ...OPTIONAL_KEYS].join(','))
		throw new TypeError('Missing ordered optional native library identities.');
	for (const key of OPTIONAL_KEYS)
		if (
			typeof optional[key] !== 'string' ||
			!/^lib[A-Za-z0-9_.-]+\.so\.[0-9]+$/.test(optional[key])
		)
			throw new TypeError(`Invalid optional runtime SONAME for ${key}.`);
	const network = data.network_runtime;
	if (Object.keys(network?.source_luv_build_packages || {}).join(',') !== MANAGERS.join(','))
		throw new TypeError('Incomplete source luv build package mapping.');
	for (const packages of Object.values(network.source_luv_build_packages)) {
		if (packages === null) continue;
		if (!Array.isArray(packages) || !packages.length || new Set(packages).size !== packages.length)
			throw new TypeError('Invalid source luv build package list.');
		for (const pkg of packages)
			if (typeof pkg !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9+_.-]*$/.test(pkg))
				throw new TypeError('Invalid source luv build package identity.');
	}
	if (!network || Object.keys(network.libraries || {}).join(',') !== NETWORK_KEYS.join(','))
		throw new TypeError('Missing ordered native network library identities.');
	for (const soname of Object.values(network.libraries))
		if (typeof soname !== 'string' || !/^lib[A-Za-z0-9_.-]+\.so\.[0-9]+$/.test(soname))
			throw new TypeError('Invalid native network SONAME.');
	if (network.proxy_schema !== 'org.gnome.system.proxy' || network.curl_package !== 'curl')
		throw new TypeError('Invalid network schema or curl package identity.');
	if (Object.keys(network.providers || {}).join(',') !== MANAGERS.join(','))
		throw new TypeError('Incomplete explicit network provider availability.');
	for (const packages of Object.values(network.providers)) {
		if (packages === null) continue;
		if (!Array.isArray(packages) || !packages.length || new Set(packages).size !== packages.length)
			throw new TypeError('Invalid native network provider list.');
		for (const pkg of packages)
			if (typeof pkg !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9+_.-]*$/.test(pkg))
				throw new TypeError('Invalid native network provider package.');
	}
	const portable = network.portable;
	if (
		!portable ||
		!Array.isArray(portable.gio_modules) ||
		portable.gio_modules.join(',') !== 'libgiognomeproxy.so,libgiolibproxy.so,libdconfsettings.so'
	)
		throw new TypeError('Missing explicit portable GIO modules.');
	if (
		!Array.isArray(portable.system_ca_files) ||
		!portable.system_ca_files.length ||
		new Set(portable.system_ca_files).size !== portable.system_ca_files.length ||
		portable.system_ca_files.some(
			(file) =>
				typeof file !== 'string' || !/^\/[A-Za-z0-9_./-]+$/.test(file) || file.includes('..')
		)
	)
		throw new TypeError('Invalid recipient system trust candidates.');
	const sources = portable.flatpak_sources;
	if (
		!sources ||
		Object.keys(sources).join(',') !==
			'luv,schemas,krb5,curl,duktape,libproxy,glib_networking,luafilesystem,luaposix,sqlite,zstd,openssl,luajit'
	)
		throw new TypeError('Incomplete portable native source inventory.');
	for (const [name, source] of Object.entries(sources)) {
		// SQLite publishes its amalgamation only on its own site; every other
		// source is a GitHub repository or release asset.
		const host = name === 'sqlite' ? 'www\\.sqlite\\.org' : 'github\\.com';
		if (
			!new RegExp(`^https://${host}/[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+$`).test(source.url) ||
			source.url.includes('..')
		)
			throw new TypeError('Invalid portable native source identity.');
		if (
			ARCHIVE_SOURCES.has(name)
				? !/^[a-f0-9]{64}$/.test(source.sha256)
				: !/^[a-f0-9]{40}$/.test(source.commit)
		)
			throw new TypeError('Unpinned portable native source.');
	}
	return data;
}

/** Preserve all historical hard requirements and append each native library package once. */
function requirements(data, format) {
	validate(data);
	const manager = { deb: 'apt', rpm: 'dnf', arch: 'pacman' }[format];
	const native = manager
		? KEYS.map((key) => data.libraries[key].packages[manager])
		: KEYS.map((key) => data.libraries[key].nix_package);
	// The .deb, the .rpm and the Arch repack of the release tarball carry the
	// AppImage's private runtime prefix (tools/build/stage-linux-private-runtime.sh):
	// LuaJIT, luv, curl and libcrypto come from there, never from a host package.
	const privateRuntime = PRIVATE_RUNTIME_FORMATS.has(format);
	const network = manager && !privateRuntime ? data.network_runtime.providers[manager] || [] : [];
	const digest = privateRuntime
		? []
		: format === 'deb'
			? [data.archive_digest_runtime.deb_dependency_alternatives.join(' | ')]
			: format === 'nix_library_path'
				? [data.archive_digest_runtime.nix_package]
				: [];
	return [...new Set([...data.package_requirements[format], ...native, ...network, ...digest])];
}

/** Native Flatpak recipes use pinned canonical sources, never the build host ABI. */
/** The package formats that ship the private runtime prefix instead of host packages. */
const PRIVATE_RUNTIME_FORMATS = new Set(['deb', 'rpm', 'arch']);

/** Sources pinned as a release archive by SHA-256; the others are Git commits. */
const ARCHIVE_SOURCES = new Set(['duktape', 'sqlite', 'zstd', 'openssl']);

function flatpakModules(data) {
	validate(data);
	const sources = data.network_runtime.portable.flatpak_sources;
	const modules = [
		{
			name: 'network-luv',
			buildsystem: 'cmake-ninja',
			'config-opts': LUV_CMAKE_OPTIONS,
			'post-install': ['test -f /app/lib/lua/5.1/luv.so'],
			source: 'luv'
		},
		{
			name: 'network-schemas',
			buildsystem: 'meson',
			'config-opts': ['-Dintrospection=false'],
			'post-install': ['glib-compile-schemas /app/share/glib-2.0/schemas'],
			source: 'schemas'
		},
		{
			name: 'network-krb5',
			buildsystem: 'simple',
			'build-commands': [
				'cd src && autoreconf --verbose --force --install',
				'cd src && ./configure --prefix=/app --disable-static --disable-rpath --without-system-verto',
				'make -C src',
				'make -C src install'
			],
			'post-install': [
				'test -x /app/bin/krb5-config',
				'test -f /app/lib/libgssapi_krb5.so',
				'test -f /app/include/gssapi/gssapi.h',
				'test "$(pkg-config --variable=prefix mit-krb5-gssapi)" = /app',
				'/app/bin/krb5-config --libs gssapi'
			],
			source: 'krb5'
		},
		{
			name: 'network-curl',
			buildsystem: 'cmake-ninja',
			'config-opts': [
				'-DBUILD_CURL_EXE=ON',
				'-DBUILD_SHARED_LIBS=ON',
				'-DBUILD_TESTING=OFF',
				'-DCURL_USE_OPENSSL=ON',
				'-DCURL_USE_GSSAPI=ON',
				'-DGSS_ROOT_DIR=/app'
			],
			'post-install': [
				'test -x /app/bin/curl',
				"features=$(/app/bin/curl --disable --version) && printf '%s\\n' \"$features\" | grep -Eq '^Features: (.* )?GSS-API( |$)' && printf '%s\\n' \"$features\" | grep -Eq '^Features: (.* )?SPNEGO( |$)'"
			],
			source: 'curl'
		},
		{
			name: 'network-duktape',
			buildsystem: 'simple',
			'build-commands': [
				// Backport upstream #2480: keep libm after each input under --as-needed.
				"test \"$(grep -c '\\$(DUKTAPE_SRCDIR)/duktape\\.c$' Makefile.sharedlibrary)\" -eq 2 && sed -i 's|\\$(DUKTAPE_SRCDIR)/duktape\\.c$|$(DUKTAPE_SRCDIR)/duktape.c -lm|' Makefile.sharedlibrary",
				'make -f Makefile.sharedlibrary INSTALL_PREFIX=/app',
				'make -f Makefile.sharedlibrary INSTALL_PREFIX=/app install'
			],
			source: 'duktape'
		},
		{
			name: 'network-libproxy',
			buildsystem: 'meson',
			'config-opts': [
				'-Ddocs=false',
				'-Dtests=false',
				'-Dvapi=false',
				'-Dintrospection=false',
				'-Dconfig-xdp=true',
				'-Dpacrunner-duktape=true',
				'-Dcurl=true'
			],
			source: 'libproxy'
		},
		// The Flatpak proxy selection goes through libproxy, whose native XDP
		// implementation is built above. A private GNOME dconf view is not
		// promoted to host settings; portal delivery still needs native proof.
		{
			name: 'network-gio-proxy',
			buildsystem: 'meson',
			'config-opts': [
				'-Dlibproxy=enabled',
				'-Dgnome_proxy=disabled',
				'-Dgnutls=enabled',
				'-Denvironment_proxy=disabled',
				'-Dinstalled_tests=false'
			],
			source: 'glib_networking'
		},
		// The programs and Lua modules the driver runs from its own prefix only
		// (linux/infra/owned_programs.lua), the ones the other formats stage
		// from the oldest supported LTS. The command-line programs link their
		// library statically, so no second libcrypto or libsqlite3 shadows the
		// runtime's own in /app/lib.
		{
			name: 'owned-luafilesystem',
			buildsystem: 'simple',
			'build-commands': [
				'gcc -O2 -shared -fPIC -I/app/include/luajit-2.1 src/lfs.c -o lfs.so',
				'install -Dm755 lfs.so /app/lib/lua/5.1/lfs.so'
			],
			source: 'luafilesystem'
		},
		{
			name: 'owned-luaposix',
			buildsystem: 'simple',
			'build-commands': [
				'/app/bin/luajit build-aux/luke LUA_INCDIR=/app/include/luajit-2.1',
				'/app/bin/luajit build-aux/luke install INST_LIBDIR=/app/lib/lua/5.1 INST_LUADIR=/app/share/lua/5.1'
			],
			'post-install': [
				'test -f /app/lib/lua/5.1/posix/sys/stat.so',
				'test -f /app/share/lua/5.1/posix/init.lua'
			],
			source: 'luaposix'
		},
		{
			name: 'owned-sqlite3',
			buildsystem: 'simple',
			'build-commands': [
				'gcc -O2 -DSQLITE_THREADSAFE=0 -DSQLITE_OMIT_LOAD_EXTENSION shell.c sqlite3.c -o sqlite3 -lm',
				'install -Dm755 sqlite3 /app/bin/sqlite3'
			],
			source: 'sqlite'
		},
		{
			name: 'owned-zstd',
			buildsystem: 'simple',
			'build-commands': ['make -C programs zstd', 'install -Dm755 programs/zstd /app/bin/zstd'],
			source: 'zstd'
		},
		{
			name: 'owned-openssl',
			buildsystem: 'simple',
			'build-commands': [
				'./Configure no-shared no-tests --prefix=/app/lib/ergopti-openssl --openssldir=/app/lib/ergopti-openssl',
				'make build_programs',
				'install -Dm755 apps/openssl /app/bin/openssl'
			],
			source: 'openssl'
		}
	];
	return modules
		.map(({ source, ...recipe }) => {
			// Older Flatpak builders leave CMake's lib64 default outside /app/lib.
			// Every CMake module must share the installed runtime search directory.
			if (recipe.buildsystem === 'cmake-ninja')
				recipe['config-opts'].unshift('-DCMAKE_INSTALL_LIBDIR=lib');
			// Meson's SDK default can be lib64; the installed environment admits lib.
			if (recipe.buildsystem === 'meson') recipe['config-opts'].unshift('--libdir=lib');
			const input = sources[source];
			const pinned = ARCHIVE_SOURCES.has(source)
				? { type: 'archive', url: input.url, sha256: input.sha256 }
				: { type: 'git', url: input.url, commit: input.commit };
			// HTTP content encoding must not change bytes before digest verification.
			// The archive unpacker still owns decompression after authentication.
			if (pinned.type === 'archive') pinned['disable-http-decompression'] = true;
			return '  - ' + JSON.stringify({ ...recipe, sources: [pinned] }) + '\n';
		})
		.join('');
}

/** Replace exactly one owned region without altering the surrounding installer or recipe. */
function projectRegion(source, label, body) {
	const expression = new RegExp(
		`(^[\\t ]*# BEGIN GENERATED ${label}\\n)[\\s\\S]*?(^[\\t ]*# END GENERATED ${label}$)`,
		'gm'
	);
	const matches = [...source.matchAll(expression)];
	if (matches.length !== 1) throw new Error(`Expected exactly one generated region: ${label}.`);
	return source.replace(expression, (_, start, end) => start + body + '\n' + end);
}

/** Render complete output files; exported so tests exercise the real production projection. */
/** The four Linux archives of Ergopti's own Python, by native architecture and C library. */
const MANAGED_PYTHON_ARCHIVES = {
	'x86_64-gnu': 'x86_64-unknown-linux-gnu',
	'aarch64-gnu': 'aarch64-unknown-linux-gnu',
	'x86_64-musl': 'x86_64-unknown-linux-musl',
	'aarch64-musl': 'aarch64-unknown-linux-musl'
};

/**
 * Validates the managed Python pin against the shared managed Python release
 * (one uv release, version and build for every OS) and projects it for Lua.
 * @param {object} data The runtime catalogue.
 * @param {function} read Repository file reader.
 * @param {string} githubPrefix https://<GitHub host>/
 * @returns {string} The Lua table entry.
 */
function managedPythonProjection(data, read, githubPrefix) {
	const pin = data.managed_python;
	const release = JSON.parse(
		read('static/ergopti_plus/_shared/modules/llm/managed_python_release.json')
	);
	const shared = Object.values(release.downloads)[0];
	if (
		!pin ||
		Object.keys(pin).sort().join(',') !== 'archives,build,description,uv_release,version' ||
		pin.uv_release !== release.uv_release ||
		pin.version !== `${shared.major}.${shared.minor}.${shared.patch}` ||
		pin.build !== shared.build ||
		Object.keys(pin.archives || {}).join(',') !== Object.keys(MANAGED_PYTHON_ARCHIVES).join(',')
	)
		throw new TypeError(
			'The Linux managed Python pin must name the shared managed Python release.'
		);
	const rows = Object.entries(pin.archives).map(([key, archive]) => {
		if (
			Object.keys(archive).sort().join(',') !== 'bytes,sha256,triple' ||
			archive.triple !== MANAGED_PYTHON_ARCHIVES[key] ||
			!/^[a-f0-9]{64}$/.test(archive.sha256) ||
			!Number.isSafeInteger(archive.bytes) ||
			archive.bytes <= 0
		)
			throw new TypeError(`Invalid Linux managed Python archive ${key}.`);
		const url = `${githubPrefix}astral-sh/python-build-standalone/releases/download/${pin.build}/cpython-${pin.version}%2B${pin.build}-${archive.triple}-install_only_stripped.tar.gz`;
		return `\t\t\t[${JSON.stringify(key)}] = { url = ${JSON.stringify(url)}, sha256 = ${JSON.stringify(archive.sha256)}, bytes = ${archive.bytes} },`;
	});
	return `\tmanaged_python = {\n\t\tversion = ${JSON.stringify(pin.version)},\n\t\tbuild = ${JSON.stringify(pin.build)},\n\t\tarchives = {\n${rows.join('\n')}\n\t\t},\n\t},\n`;
}

function render(data, read) {
	validate(data);
	const result = {};
	const template = 'tools/build/templates/linux-portable-runtime-env.sh';
	result[template] = projectRegion(
		read(template),
		'LINUX PORTABLE TRUST',
		'ERGOPTI_SYSTEM_CA_FILES=(' +
			data.network_runtime.portable.system_ca_files.map((file) => `"${file}"`).join(' ') +
			')'
	);
	const rows = MANAGERS.flatMap((manager) =>
		KEYS.map((key) => {
			const lib = data.libraries[key];
			return `\t\t${manager}:${lib.soname}) echo "${lib.packages[manager]}" ;;`;
		})
	);
	for (const manager of MANAGERS)
		rows.push(`\t\t${manager}:curl) echo "${data.network_runtime.curl_package}" ;;`);
	const providerRows = MANAGERS.map((manager) => {
		const packages = data.network_runtime.providers[manager];
		return packages === null
			? `\t\t${manager}) return 1 ;;`
			: `\t\t${manager}) echo "${packages.join(' ')}" ;;`;
	});
	// Ordered alternatives are arguments to the actual metadata selector, not a
	// command-line request to install both mutually transitioning providers.
	rows.push(
		data.archive_digest_runtime.package_alternatives.apt === null
			? `\t\tapt:${data.archive_digest_runtime.soname}) return 1 ;;`
			: `\t\tapt:${data.archive_digest_runtime.soname}) _available_apt_runtime_package ${data.archive_digest_runtime.package_alternatives.apt.join(' ')} ;;`
	);
	const installer = 'static/ergopti_plus/linux/install.sh';
	const buildRows = MANAGERS.map((manager) => {
		const packages = data.archive_build_packages[manager];
		return packages === null
			? `\t\t${manager}) return 1 ;;`
			: `\t\t${manager}) echo "${packages.join(' ')}" ;;`;
	});
	result[installer] = projectRegion(
		projectRegion(read(installer), 'LINUX NATIVE PACKAGES', rows.join('\n')),
		'LINUX NATIVE CAPABILITIES',
		[
			...KEYS.map((key) => `_check_or_install_library ${data.libraries[key].soname}`),
			'_check_or_install curl'
		].join('\n')
	);
	result[installer] = projectRegion(
		result[installer],
		'LINUX ARCHIVE BUILD PACKAGES',
		`_native_output_build_packages() {\n\tcase "$1" in\n${buildRows.join('\n')}\n\t\t*) return 1 ;;\n\tesac\n}`
	);
	const luvSource = data.network_runtime.portable.flatpak_sources.luv;
	// The .rpm publishes its own LuaJIT luv binding built from the same pinned
	// recipe at package build time: Fedora's generic lua-luv targets another ABI.
	const luvPin = [
		'NATIVE_LUV_SOURCE_REVISION=' + JSON.stringify(luvSource.commit),
		'NATIVE_LUV_CMAKE_OPTIONS=(' +
			LUV_CMAKE_OPTIONS.map((option) => JSON.stringify(option)).join(' ') +
			')'
	];
	// Neither the installer nor the build script spells the host: both source
	// _shared/data/identifiers.sh and expand it at run time.
	const githubPrefix = `https://${JSON.parse(read(IDENTIFIERS)).hosts.github}/`;
	const luvRepository = luvSource.url.slice(githubPrefix.length);
	if (
		!luvSource.url.startsWith(githubPrefix) ||
		!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\.git$/.test(luvRepository)
	)
		throw new Error(`The luv source ${luvSource.url} is not a repository on ${githubPrefix}.`);
	const packagedLuvRecipe = [
		`NATIVE_LUV_SOURCE_URL="https://$ERGOPTI_HOST_GITHUB/${luvRepository}"`,
		...luvPin
	].join('\n');
	const luvBuildRows = MANAGERS.map((manager) => {
		const packages = data.network_runtime.source_luv_build_packages[manager];
		return packages === null
			? `\t\t${manager}) return 1 ;;`
			: `\t\t${manager}) echo "${packages.join(' ')}" ;;`;
	});
	result[installer] = projectRegion(
		result[installer],
		'LINUX SOURCE NETWORK BUILD',
		[
			`_network_source_build_packages() {\n\tcase "$1" in\n${luvBuildRows.join('\n')}\n\t\t*) return 1 ;;\n\tesac\n}`,
			packagedLuvRecipe
		].join('\n')
	);
	result[installer] = projectRegion(
		result[installer],
		'LINUX NETWORK PROVIDERS',
		`_network_runtime_packages() {\n\tcase "$1" in\n${providerRows.join('\n')}\n\t\t*) return 1 ;;\n\tesac\n}`
	);
	result[installer] = projectRegion(
		result[installer],
		'LINUX ARCHIVE DIGEST',
		'ARCHIVE_DIGEST_SONAME=' + JSON.stringify(data.archive_digest_runtime.soname)
	);
	const nativeNetwork = `\tnetwork_runtime = {\n\t\tlibraries = {\n${NETWORK_KEYS.map((key) => `\t\t\t${key} = ${JSON.stringify(data.network_runtime.libraries[key])},`).join('\n')}\n\t\t},\n\t\tproxy_schema = ${JSON.stringify(data.network_runtime.proxy_schema)},\n\t},\n`;
	const managedPython = managedPythonProjection(data, read, githubPrefix);
	result[LUA_OUTPUT] =
		`--- _generated/native_runtime.lua\n\n--- Generated by tools/codegen/codegen-linux-native-runtime.cjs; do not edit.\n--- Source: _shared/data/linux_native_runtime.json.\nreturn {\n${KEYS.map((key) => `\t${key} = ${JSON.stringify(data.libraries[key].soname)},`).join('\n')}\n\toptional = {\n${OPTIONAL_KEYS.map((key) => `\t\t${key} = ${JSON.stringify(data.optional_libraries[key])},`).join('\n')}\n\t},\n${nativeNetwork}\tarchive_digest_runtime = {\n\t\tschema_version = 1,\n\t\tsoname = ${JSON.stringify(data.archive_digest_runtime.soname)},\n\t},\n${managedPython}}\n`;
	for (const [file, format] of [
		['tools/build/build-linux-deb.sh', 'deb'],
		['tools/build/build-linux-rpm.sh', 'rpm'],
		['tools/build/PKGBUILD', 'arch'],
		['tools/build/nix/flake.nix', 'nix_library_path']
	]) {
		const packages = requirements(data, format);
		const body =
			format === 'deb'
				? 'Depends: ' + packages.join(', ')
				: format === 'rpm'
					? packages.map((pkg) => 'Requires:       ' + pkg).join('\n')
					: format === 'arch'
						? 'depends=(' + packages.map((pkg) => `'${pkg}'`).join(' ') + ')'
						: '                  ' + packages.join(' ');
		if (format === 'deb') {
			const source = read(file);
			if ([...source.matchAll(/^Depends: .+$/gm)].length !== 1)
				throw new Error('Expected exactly one Debian control dependency field.');
			result[file] = source.replace(/^Depends: .+$/m, body);
		} else {
			result[file] = projectRegion(read(file), 'LINUX NATIVE REQUIREMENTS', body);
		}
	}
	return result;
}

if (require.main === module) {
	const data = JSON.parse(fs.readFileSync(path.join(ROOT, SOURCE), 'utf8'));
	for (const [file, output] of Object.entries(
		render(data, (name) => fs.readFileSync(path.join(ROOT, name), 'utf8'))
	)) {
		fs.mkdirSync(path.dirname(path.join(ROOT, file)), { recursive: true });
		fs.writeFileSync(path.join(ROOT, file), output);
	}
	console.log('Linux native runtime dependency projections regenerated.');
}

module.exports = {
	LUV_CMAKE_OPTIONS,
	SOURCE,
	LUA_OUTPUT,
	MANAGERS,
	KEYS,
	NETWORK_KEYS,
	validate,
	flatpakModules,
	requirements,
	projectRegion,
	render
};
