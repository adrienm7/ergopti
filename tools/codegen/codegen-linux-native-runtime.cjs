// tools/codegen/codegen-linux-native-runtime.cjs

/** Projects the Linux runtime catalogue into native package and FFI consumers. */
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const ROOT = path.resolve(__dirname, '../..');
const SOURCE = 'static/ergopti_plus/_shared/data/linux_native_runtime.json';
const LUA_OUTPUT = 'static/ergopti_plus/linux/_generated/native_runtime.lua';
const MANAGERS = ['apt', 'dnf', 'zypper', 'pacman', 'xbps', 'apk'];
const KEYS = ['xkbcommon', 'xkbcommon_x11', 'x11', 'x11_xcb'];
const NETWORK_KEYS = ['gio', 'gobject', 'glib'];

/** Reject data that could escape native metadata, shell literals or Lua strings. */
function validate(data) {
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
	const network = data.network_runtime;
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
	return data;
}

/** Preserve all historical hard requirements and append each native library package once. */
function requirements(data, format) {
	validate(data);
	const manager = { deb: 'apt', rpm: 'dnf', arch: 'pacman' }[format];
	const native = manager
		? KEYS.map((key) => data.libraries[key].packages[manager])
		: KEYS.map((key) => data.libraries[key].nix_package);
	const network = manager ? data.network_runtime.providers[manager] || [] : [];
	return [...new Set([...data.package_requirements[format], ...native, ...network])];
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
function render(data, read) {
	validate(data);
	const result = {};
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
	const installer = 'static/ergopti_plus/linux/install.sh';
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
		'LINUX NETWORK PROVIDERS',
		`_network_runtime_packages() {\n\tcase "$1" in\n${providerRows.join('\n')}\n\t\t*) return 1 ;;\n\tesac\n}`
	);
	const nativeNetwork = `\tnetwork_runtime = {\n\t\tlibraries = {\n${NETWORK_KEYS.map((key) => `\t\t\t${key} = ${JSON.stringify(data.network_runtime.libraries[key])},`).join('\n')}\n\t\t},\n\t\tproxy_schema = ${JSON.stringify(data.network_runtime.proxy_schema)},\n\t},\n`;
	result[LUA_OUTPUT] =
		`--- _generated/native_runtime.lua\n\n--- Generated by tools/codegen/codegen-linux-native-runtime.cjs; do not edit.\n--- Source: _shared/data/linux_native_runtime.json.\nreturn {\n${KEYS.map((key) => `\t${key} = ${JSON.stringify(data.libraries[key].soname)},`).join('\n')}\n${nativeNetwork}}\n`;
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
	SOURCE,
	LUA_OUTPUT,
	MANAGERS,
	KEYS,
	NETWORK_KEYS,
	validate,
	requirements,
	projectRegion,
	render
};
