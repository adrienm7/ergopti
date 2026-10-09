// tools/diagnostics/item36_xctest_evidence.cjs
'use strict';

/** Scoped item 36 evidence; this never substitutes for full package qualification. */
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { execFileSync } = require('node:child_process');
const { cleanTranscript } = require('./swift_xctest_evidence.cjs');

// Independent existing test identities, frozen before adding this receiving job.
const METHODS = Object.freeze({
	ReleaseArchiveStagingTests: Object.freeze([
		'testBothNativeArchivesKeepSignedBundleBytesModesSymlinksAndMetadata',
		'testPreferredArchiveChecksRejectDigestVersionCorruptionAndUnknownFormat',
		'testPrivateArchiveChildEnvironmentPreservesParentAndExecutableSearchPath',
		'testRequirementDisplayEvidenceRetainsBoundedEscapedOwnedStreams',
		'testActualNativeRequirementDisplayKeepsBothStreamsAndExitStatus',
		'testCIInstallSelectsDeclaredArchiveAndPreservesIndependentSignedSource',
		'testCIPreferredArchiveNeverFallsBackAfterDigestExtractionOrSignatureRefusal',
		'testActualSparkleFileKeyBindsBothArchivesAndRefusesCrossedSameLengthSignatures'
	]),
	SparkleArchiveUpdateAcceptanceTests: Object.freeze([
		'testPhysicalFixtureDirectoryUsesNativeRealpathThroughOwnedAlias',
		'testChildRefusalCaptureProjectsOnlyOneCompleteClosedCategory',
		'testSignatureAndApplicationFactsContainOnlyClosedObservations',
		'testUpdateProgressRequiresCompleteClosedFramesAndTheActualChildPID',
		'testStartupAdmissionRefusalIdentityRequiresExactRetiredProgressAndFixedTypedFields',
		'testRefusalErrorChainAdmitsOnlyBoundReceiptAndClosedDomainLabels',
		'testRefusalErrorChainRejectsForeignRecipientEventVersionAndNonce',
		'testRefusalErrorChainRejectsMalformedOrExcessiveIdentityRecords',
		'testNetworkProgressCounterDoesNotInventSuccessfulDelivery',
		'testServerExitRefusalMessageProjectsOnlyClosedFacts',
		'testDirectNativeChildExitACKAndCaptureRetirementAreIdempotent',
		'testOwnedCensusPathAdmitsParentAliasWithoutAdoptingDirectoryReplacement',
		'testStartupFramesDistinguishActualPrefixEmptyAndRefusedCapture',
		'testActualSparkleTarXZUpdateRefusesWrongKeyPreservesOldAppAndRetriesThroughRelaunch'
	]),
	HomebrewArchiveAcceptanceTests: Object.freeze([
		'testRealBrewZIPInstallXZUpgradeAndRefusalsPreserveInstalledState'
	]),
	HomebrewAutomationConsentTests: Object.freeze([
		'testAutomationConsentArgumentsRequireBothExplicitOptIns'
	])
});
const SOURCE_ROOTS = Object.freeze([
	'static/ergopti_plus/macos/launcher',
	'static/ergopti_plus/macos/adapters/release_stage.sh',
	'static/ergopti_plus/_shared/modules/updater/defaults.json',
	'tools/build',
	'tools/diagnostics'
]);
const NAMES = Object.freeze(
	Object.entries(METHODS).flatMap(([suite, methods]) =>
		methods.map((method) => `-[ErgoptiPlusTests.${suite} ${method}]`)
	)
);

/** Requires canonical owning pipeline exit statuses. */
function status(value) {
	if (!/^(?:0|[1-9][0-9]{0,2})$/.test(String(value)) || Number(value) > 255)
		throw new Error('Unadmitted item 36 pipeline status.');
	return Number(value);
}

/** Admits one serial Selected tests run with every independently pinned method. */
function evaluate(text, scriptStatus, teeStatus) {
	const script = status(scriptStatus),
		tee = status(teeStatus);
	const errors = [];
	const starts = new Set(),
		terminals = new Set(),
		suites = new Set();
	let root = 'before',
		bundle = 'before',
		suite = null,
		active = null,
		summary = null;
	const reject = (label) => {
		if (!errors.includes(label)) errors.push(label);
	};
	for (const line of cleanTranscript(text).split('\n')) {
		if (!line.trim()) continue;
		if (summary !== null) {
			const count =
				/^\s*Executed (0|[1-9][0-9]*) tests?, with (\d+) failures? \((\d+) unexpected\) in /.exec(
					line
				);
			const expected = summary === 'root' || summary === 'bundle' ? 24 : METHODS[summary].length;
			if (!count || Number(count[1]) !== expected || count[2] !== '0' || count[3] !== '0')
				reject('summary');
			if (summary === 'root') root = 'after';
			if (summary === 'bundle') bundle = 'after';
			summary = null;
			continue;
		}
		const opening = /^Test Suite '([^']+)' started at /.exec(line);
		const closing = /^Test Suite '([^']+)' (passed|failed) at /.exec(line);
		const starting = /^Test Case '([^']+)' started\.$/.exec(line);
		const terminal =
			/^Test Case '([^']+)' (passed|failed|skipped) \(\d+(?:\.\d+)? seconds?\)\.$/.exec(line);
		if (opening) {
			if (opening[1] === 'Selected tests') {
				if (root !== 'before' || suite !== null || active !== null) reject('root');
				root = 'running';
			} else if (opening[1] === 'ErgoptiPlusPackageTests.xctest') {
				if (root !== 'running' || bundle !== 'before' || suite !== null || active !== null)
					reject('bundle');
				bundle = 'running';
			} else if (Object.hasOwn(METHODS, opening[1])) {
				if (
					root !== 'running' ||
					bundle !== 'running' ||
					suite !== null ||
					suites.has(opening[1]) ||
					active !== null
				)
					reject('suite');
				suite = opening[1];
				suites.add(suite);
			} else reject('foreign-suite');
		} else if (closing) {
			if (closing[2] !== 'passed') reject('failed-suite');
			if (closing[1] === 'Selected tests') {
				if (root !== 'running' || bundle !== 'after' || suite !== null || active !== null)
					reject('root');
				root = 'summary';
				summary = 'root';
			} else if (closing[1] === 'ErgoptiPlusPackageTests.xctest') {
				if (root !== 'running' || bundle !== 'running' || suite !== null || active !== null)
					reject('bundle');
				bundle = 'summary';
				summary = 'bundle';
			} else if (suite === closing[1]) {
				if (root !== 'running' || active !== null) reject('suite');
				summary = suite;
				suite = null;
			} else reject('foreign-suite');
		} else if (starting) {
			if (
				root !== 'running' ||
				active !== null ||
				!NAMES.includes(starting[1]) ||
				starts.has(starting[1]) ||
				!starting[1].startsWith(`-[ErgoptiPlusTests.${suite} `)
			)
				reject('start');
			starts.add(starting[1]);
			active = starting[1];
		} else if (terminal) {
			if (root !== 'running' || active !== terminal[1] || terminals.has(terminal[1]))
				reject('terminal');
			if (terminal[2] !== 'passed') reject('failed-or-skipped-case');
			terminals.add(terminal[1]);
			active = null;
		} else if (/^Test (Suite|Case) |^\s*Executed |(?:^|: )(?:fatal )?error: /.test(line))
			reject('unadmitted-test-frame');
	}
	if (
		root !== 'after' ||
		bundle !== 'after' ||
		suite !== null ||
		active !== null ||
		summary !== null ||
		suites.size !== 4 ||
		starts.size !== 24 ||
		terminals.size !== 24 ||
		NAMES.some((name) => !starts.has(name) || !terminals.has(name))
	)
		reject('incomplete');
	if (script !== 0 || tee !== 0) reject('pipeline');
	return {
		schema: 1,
		scope: 'item36-native-only',
		complete: errors.length === 0,
		full_package_qualified: false,
		script_status: script,
		capture_status: tee,
		completed_methods: [...terminals].filter((name) => NAMES.includes(name)),
		errors
	};
}

/** Binds this scope to the actual clean checkout and real file bytes. */
function sourceReceipt(repository, candidate) {
	if (!/^[0-9a-f]{40}$/.test(candidate)) throw new Error('Unadmitted item 36 candidate.');
	const git = (args) => execFileSync('git', args, { cwd: repository, encoding: 'utf8' });
	if (git(['rev-parse', 'HEAD']).trim() !== candidate)
		throw new Error('Item 36 source candidate changed.');
	git(['diff', '--exit-code', 'HEAD', '--']);
	// SwiftPM discovers source/header/resource entries implicitly inside targets,
	// including ignored files. Bind only tracked target inputs before acquisition.
	const launcher = 'static/ergopti_plus/macos/launcher';
	const implicitInputs = git([
		'ls-files',
		'--others',
		'-z',
		'--',
		`${launcher}/Sources`,
		`${launcher}/Tests`
	])
		.split('\0')
		.filter(Boolean);
	const alternateManifests = git(['ls-files', '--others', '-z', '--', launcher])
		.split('\0')
		.filter((file) => /^Package(?:@swift-[0-9.]+)?\.swift$/.test(file.slice(launcher.length + 1)));
	if (implicitInputs.length || alternateManifests.length)
		throw new Error('Item 36 source contains an unbound compiler input.');
	const files = git(['ls-files', '-z', '--', ...SOURCE_ROOTS])
		.split('\0')
		.filter(Boolean)
		.sort();
	if (!files.length) throw new Error('Item 36 source inventory unavailable.');
	const sources = {};
	for (const relative of files) {
		const absolute = path.join(repository, relative);
		if (!fs.lstatSync(absolute).isFile())
			throw new Error('Item 36 source is not a regular tracked file.');
		sources[relative] = crypto.createHash('sha256').update(fs.readFileSync(absolute)).digest('hex');
	}
	for (const [suite, methods] of Object.entries(METHODS)) {
		const relative = `static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/${suite}.swift`;
		if (!Object.hasOwn(sources, relative)) throw new Error('Item 36 test source unavailable.');
		const actual = [
			...fs.readFileSync(path.join(repository, relative), 'utf8').matchAll(/\bfunc (test\w+)\(/g)
		].map((match) => match[1]);
		if (JSON.stringify([...actual].sort()) !== JSON.stringify([...methods].sort()))
			throw new Error('Item 36 independent method inventory differs.');
	}
	return { schema: 1, scope: 'item36-native-only', candidate, sources };
}

/** Refuses replaced, special or oversized capture files before reading them. */
function readBoundedRegular(file, maximum) {
	const descriptor = fs.openSync(
		file,
		fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK
	);
	try {
		const before = fs.fstatSync(descriptor);
		const named = fs.lstatSync(file);
		if (
			!before.isFile() ||
			before.size > maximum ||
			before.dev !== named.dev ||
			before.ino !== named.ino
		)
			throw new Error('Unadmitted item 36 capture.');
		const bytes = fs.readFileSync(descriptor);
		const after = fs.fstatSync(descriptor);
		const finalName = fs.lstatSync(file);
		if (
			bytes.length !== before.size ||
			after.size !== before.size ||
			after.mtimeMs !== before.mtimeMs ||
			after.dev !== finalName.dev ||
			after.ino !== finalName.ino
		)
			throw new Error('Item 36 capture changed.');
		return new TextDecoder('utf-8', { fatal: true }).decode(bytes);
	} finally {
		fs.closeSync(descriptor);
	}
}

/** Records source before acquisition, then judges only that unchanged source. */
function main(args, repository = path.resolve(__dirname, '../..')) {
	try {
		if (args.length === 3 && args[0] === 'begin') {
			const receipt = sourceReceipt(repository, args[1]);
			fs.writeFileSync(args[2], JSON.stringify(receipt, null, '\t') + '\n', {
				flag: 'wx',
				mode: 0o600
			});
			return 0;
		}
		if (args.length !== 7 || args[0] !== 'judge')
			throw new Error('Item 36 evidence arguments refused.');
		const before = JSON.parse(readBoundedRegular(args[5], 1048576));
		const after = sourceReceipt(repository, args[4]);
		if (JSON.stringify(before) !== JSON.stringify(after))
			throw new Error('Item 36 source changed during native receiving.');
		const receipt = {
			...evaluate(readBoundedRegular(args[1], 16777216), args[2], args[3]),
			source: after
		};
		fs.writeFileSync(args[6], JSON.stringify(receipt, null, '\t') + '\n', {
			flag: 'wx',
			mode: 0o600
		});
		console.log(
			`::notice title=Item 36 scoped native qualification::complete=${receipt.complete} methods=${receipt.completed_methods.length} full_package_qualified=false candidate=${after.candidate}`
		);
		return receipt.complete ? 0 : 1;
	} catch {
		console.error(
			'::error::Item 36 scoped native evidence refused; full package remains unqualified.'
		);
		return 1;
	}
}

module.exports = { METHODS, NAMES, evaluate, sourceReceipt, main };
if (require.main === module) process.exitCode = main(process.argv.slice(2));
