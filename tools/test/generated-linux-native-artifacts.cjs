// tools/test/generated-linux-native-artifacts.cjs

/**
 * ==============================================================================
 * MODULE: Generated Linux Native Artifact Source Admission
 * DESCRIPTION:
 * A source guard can admit a native bundle file only when its tracked C/header,
 * canonical builder, no-replace publication and mandatory bundle check agree.
 * This proves the source recipe; actual compiler/ELF/package qualification is
 * a separate native gate. Generated binaries never enter the tracked tree.
 * The proxy sign-in relay (docs/design/proxy-auth-relay.md) is admitted the
 * same way, from its Go sources and its own no-replace builder.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const DRIVER = 'tools/build/build-linux-driver.sh';
const BUILDER = 'tools/build/build-linux-native-output.sh';
const NATIVE_SOURCE = 'static/ergopti_plus/linux/native/archive_output/';
const OUTPUT = 'linux/bin/libergopti_archive_publication.so';
const INPUTS = [
	DRIVER,
	BUILDER,
	NATIVE_SOURCE + 'archive_publication.c',
	NATIVE_SOURCE + 'archive_publication.h'
];
const DEFAULT_OUTPUT = 'OUTPUT_DIR="${REPO_ROOT}/build/linux/linux/bin"';
const RELAY_BUILDER = 'tools/build/build-proxy-relay.sh';
const RELAY_SOURCE = 'static/ergopti_plus/_shared/core/network/native/go/native_http/';
const RELAY_OUTPUT = 'linux/bin/ergopti-proxy-relay';
const RELAY_GENERATE =
	'bash "${SCRIPT_DIR}/build-proxy-relay.sh" --output "${BUILD_DIR}/linux/bin/ergopti-proxy-relay"';
const RELAY_INPUTS = [
	RELAY_BUILDER,
	RELAY_SOURCE + 'go.mod',
	RELAY_SOURCE + 'cmd/ergopti-proxy-relay/main.go'
];

/** Admit the exact generated output only from its complete tracked source recipe. */
function classifyGeneratedNativeArtifacts(sources) {
	const refused = () => {
		throw new Error('Generated native artifact source recipe refused.');
	};
	if (INPUTS.slice(1).every((name) => sources[name] == null)) return new Set();
	if (INPUTS.some((name) => typeof sources[name] !== 'string' || sources[name].length === 0))
		refused();
	const executableLines = (source) =>
		source
			.split('\n')
			.filter((line) => !line.trimStart().startsWith('#'))
			.join('\n');
	const driver = executableLines(sources[DRIVER]);
	const builder = executableLines(sources[BUILDER]);
	const required = /REQUIRED_FILES=\(([\s\S]*?)\n\)/.exec(driver);
	const copy = driver.indexOf('copy_tree "${LINUX_SRC}/" "${BUILD_DIR}/linux/" --exclude vendor');
	// The driver hands the backend build its own bundle's bin directory, so the
	// generated library lands where the mandatory bundle check looks for it.
	const generate = driver.indexOf(
		'bash "${SCRIPT_DIR}/build-linux-native-output.sh" --output-directory "${BUILD_DIR}/linux/bin"'
	);
	const check = driver.indexOf('for f in "${REQUIRED_FILES[@]}"; do');
	const requiredLoop = /for f in "\$\{REQUIRED_FILES\[@\]\}"; do\n([\s\S]*?)\ndone/.exec(driver);
	const fatalCheck = /if \[ \$MISSING -gt 0 \]; then\n([\s\S]*?)\nfi/.exec(driver);
	if (
		!driver.includes('set -euo pipefail') ||
		!driver.includes('BUILD_DIR="${ERGOPTI_LINUX_BUILD_DIR:-${REPO_ROOT}/build/linux}"') ||
		copy < 0 ||
		generate <= copy ||
		check <= generate ||
		!required ||
		!required[1].includes('"' + OUTPUT + '"') ||
		!requiredLoop ||
		!requiredLoop[1].includes('if [ ! -f "${BUILD_DIR}/${f}" ]; then') ||
		!requiredLoop[1].includes('MISSING=$((MISSING + 1))') ||
		!fatalCheck ||
		!/^\s*exit 1$/m.test(fatalCheck[1])
	)
		refused();
	for (const fragment of [
		'set -euo pipefail',
		'SOURCE_DIR="${REPO_ROOT}/static/ergopti_plus/linux/native/archive_output"',
		DEFAULT_OUTPUT,
		'for source_name in archive_publication.c archive_publication.h; do',
		'[[ -f "${SOURCE_DIR}/${source_name}" && ! -L "${SOURCE_DIR}/${source_name}" ]]',
		'DESTINATION="${OUTPUT_DIR}/libergopti_archive_publication.so"',
		'-Wl,-soname,libergopti_archive_publication.so',
		'-I "$SOURCE_DIR" "$SOURCE_DIR/archive_publication.c"',
		'-o "${STAGE_DIR}/libergopti_archive_publication.so"',
		'ln -T -- "${STAGE_DIR}/libergopti_archive_publication.so" "$DESTINATION"'
	])
		if (!builder.includes(fragment)) refused();
	if (
		!sources[INPUTS[2]].includes('#include "archive_publication.h"') ||
		!sources[INPUTS[3]].includes('ergopti_archive_publication_abi_version')
	)
		refused();
	const artifacts = new Set([OUTPUT]);
	// A revision from before the relay names none of it and admits none. Once
	// the driver builds it, the complete recipe is required: a missing input
	// refuses rather than dropping the file silently from the admitted set.
	if (!driver.includes(RELAY_GENERATE) && RELAY_INPUTS.every((name) => sources[name] == null))
		return artifacts;
	if (RELAY_INPUTS.some((name) => typeof sources[name] !== 'string' || sources[name].length === 0))
		refused();
	const relayBuilder = executableLines(sources[RELAY_BUILDER]);
	const relayGenerate = driver.indexOf(RELAY_GENERATE);
	if (
		relayGenerate <= copy ||
		check <= relayGenerate ||
		!required[1].includes('"' + RELAY_OUTPUT + '"') ||
		!sources[RELAY_INPUTS[1]].includes(
			'module github.com/adrienm7/ergopti/static/ergopti_plus/_shared/core/network/native/go/native_http'
		) ||
		!sources[RELAY_INPUTS[2]].includes('package main')
	)
		refused();
	for (const fragment of [
		'set -euo pipefail',
		'SOURCE_DIR="${REPO_ROOT}/static/ergopti_plus/_shared/core/network/native/go/native_http"',
		'[[ ! -e "$OUTPUT" && ! -L "$OUTPUT" ]]',
		'export GOTOOLCHAIN=local GOPROXY=off GOFLAGS=-mod=readonly GOWORK=off CGO_ENABLED=1',
		'go build -trimpath -buildvcs=false -ldflags=\'-s -w\' -o "$STAGE" ./cmd/ergopti-proxy-relay',
		'mv -- "$STAGE" "$OUTPUT"'
	])
		if (!relayBuilder.includes(fragment)) refused();
	artifacts.add(RELAY_OUTPUT);
	return artifacts;
}

/** Read literal, tracked recipe inputs, also for the existing historical revision guard. */
function generatedNativeRecipe(root, rev = null) {
	const listing = execFileSync(
		'git',
		rev
			? ['ls-tree', '-r', '--name-only', rev, '--', ...INPUTS, ...RELAY_INPUTS]
			: ['ls-files', '--', ...INPUTS, ...RELAY_INPUTS],
		{ cwd: root, encoding: 'utf8' }
	);
	const tracked = new Set(listing.split('\n').filter(Boolean));
	const sources = {};
	for (const name of [...INPUTS, ...RELAY_INPUTS]) {
		if (!tracked.has(name)) {
			sources[name] = null;
			continue;
		}
		if (rev)
			sources[name] = execFileSync('git', ['show', `${rev}:${name}`], {
				cwd: root,
				encoding: 'utf8'
			});
		else {
			const filename = path.join(root, name);
			const fact = fs.lstatSync(filename);
			if (!fact.isFile() || fact.isSymbolicLink())
				throw new Error('Literal generated artifact source required.');
			sources[name] = fs.readFileSync(filename, 'utf8');
		}
	}
	return { sources, artifacts: classifyGeneratedNativeArtifacts(sources) };
}

/** Match the resolved static-tree key without crossing the actual Linux driver root. */
function isGeneratedLinuxAsset(target, artifacts) {
	return (
		typeof target === 'string' &&
		target.startsWith('ergopti_plus/linux/') &&
		artifacts.has(target.slice('ergopti_plus/'.length))
	);
}

module.exports = {
	generatedNativeRecipe,
	classifyGeneratedNativeArtifacts,
	isGeneratedLinuxAsset,
	DEFAULT_OUTPUT,
	OUTPUT,
	DRIVER,
	BUILDER,
	RELAY_OUTPUT,
	RELAY_GENERATE,
	RELAY_BUILDER
};
