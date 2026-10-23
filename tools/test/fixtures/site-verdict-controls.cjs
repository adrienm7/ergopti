// tools/test/fixtures/site-verdict-controls.cjs

/** Finite modeled API and actual proof-file controls; no build, browser, Git or network actor. */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const subject = require('../../ci/site-verdict.cjs');
const admission = require('../../ci/site-deploy-admission.cjs');
const { fixture, reader } = require('./site-deploy-admission-controls.cjs');
const { siteLots } = require('../../dev/site-context.cjs');

function digest(bytes) {
	return crypto.createHash('sha256').update(bytes).digest('hex');
}

function setup(artifact, { event = 'push', source = 'a'.repeat(40) } = {}) {
	const parent = fs.realpathSync(os.tmpdir());
	const root = fs.mkdtempSync(path.join(parent, 'ergopti-site-verdict-'));
	const files = { sourceRoot: path.join(root, 'source'), bundleRoot: path.join(root, 'proofs') };
	fs.mkdirSync(path.join(files.sourceRoot, 'static'), { recursive: true });
	fs.mkdirSync(files.bundleRoot);
	const lock = Buffer.from('{"fixture":true}\n'),
		cname = Buffer.from('fixture.invalid\n');
	fs.writeFileSync(path.join(files.sourceRoot, 'package-lock.json'), lock);
	fs.writeFileSync(path.join(files.sourceRoot, 'static/CNAME'), cname);
	const env = {
		GITHUB_ACTIONS: 'true',
		GITHUB_REPOSITORY: admission.REPOSITORY,
		GITHUB_REPOSITORY_ID: '11',
		GITHUB_RUN_ID: '123',
		GITHUB_RUN_ATTEMPT: '2',
		GITHUB_EVENT_NAME: event,
		GITHUB_WORKFLOW: 'CI',
		GITHUB_SHA: source,
		SITE_PREDECESSOR_RESULT: 'success'
	};
	const model = fixture();
	Object.assign(model.run, {
		event,
		status: 'in_progress',
		conclusion: null,
		head_branch: 'feature/site-preview'
	});
	const proofs = {};
	for (const target of Object.values(siteLots())) {
		const context = {
			source_sha: source,
			run_id: '123',
			run_attempt: '1',
			target: target.target,
			base_path: target.base_path,
			lock_sha256: digest(lock)
		};
		const members = Object.entries({
			CNAME: cname,
			'index.html': Buffer.from('<!doctype html>fixture'),
			'version.json': Buffer.from(
				artifact.canonical({
					branch: target.target,
					base_path: target.base_path,
					source_sha: source
				})
			)
		})
			.map(([name, bytes]) => ({ path: name, bytes: bytes.length, sha256: digest(bytes) }))
			.sort((a, b) => a.path.localeCompare(b.path));
		const build = { schema_version: 1, ...context, members };
		const tested = artifact.recordTestbuild(
			build,
			{ ...context, run_attempt: '2' },
			artifact.SITE_BROWSERS.map((name) => ({
				name,
				routes: [...artifact.SITE_ROUTES],
				local_http_errors: 0,
				page_errors: 0,
				hydration: true,
				interaction: true
			}))
		);
		proofs[target.target] = { build, tested };
		fs.mkdirSync(path.join(files.bundleRoot, target.target));
	}
	const write = () => {
		for (const [target, proof] of Object.entries(proofs)) {
			fs.writeFileSync(
				path.join(files.bundleRoot, target, 'build.json'),
				artifact.canonical(proof.build)
			);
			fs.writeFileSync(
				path.join(files.bundleRoot, target, 'site-testbuild.json'),
				artifact.canonical(proof.tested)
			);
		}
	};
	write();
	return {
		root,
		parent,
		files,
		env,
		model,
		proofs,
		write,
		source,
		git: (args) => {
			assert.deepEqual(args, ['rev-parse', '--verify', 'HEAD^{commit}']);
			return source + '\n';
		}
	};
}

/** Run only under an explicitly approved controller with all actor APIs disabled. */
async function run(owner = subject, artifact = require('../../ci/site-artifact.cjs')) {
	let controls = 0;
	async function control(label, mutate, reason, options) {
		const value = setup(artifact, options);
		try {
			if (mutate) mutate(value);
			const api = reader(value.model);
			const ports = { artifact, git: value.git, readApi: api.readApi };
			if (reason)
				await assert.rejects(
					() => owner.verifyBundles(value.files, value.env, ports),
					reason,
					label
				);
			else {
				const result = await owner.verifyBundles(value.files, value.env, ports);
				assert.equal(result.scope, 'bound-site-proof-bundles');
				assert.equal(result.source_sha, value.source);
				assert.equal(result.api_head_sha, value.model.run.head_sha);
				assert.deepEqual(result.targets, {
					main: { build_run_attempt: '1', testbuild_run_attempt: '2', manifest_files: 3 },
					dev: { build_run_attempt: '1', testbuild_run_attempt: '2', manifest_files: 3 }
				});
				assert.ok(
					!api.calls.some(
						(endpoint) => endpoint.includes('/git/ref/') || endpoint.includes('/artifacts')
					),
					'Verdict does not apply deployment freshness or substitute artifact metadata for proofs.'
				);
			}
			controls++;
		} finally {
			assert.equal(path.dirname(value.root), value.parent);
			fs.rmSync(value.root, { recursive: true });
		}
	}
	await control('in-progress feature push with both actual proof bundles', null);
	await control('ordinary manual preview', null, null, { event: 'workflow_dispatch' });
	await control(
		'PR merge source and API head remain distinct',
		(v) => {
			v.model.run.head_repository = { id: 12, full_name: 'fixture/contribution' };
		},
		null,
		{ event: 'pull_request', source: 'c'.repeat(40) }
	);
	await control('older failed attempt cannot replace selected successful writers', (v) => {
		const older = structuredClone(v.model.jobs[1]);
		Object.assign(older, { id: 299, run_attempt: 1, conclusion: 'failure' });
		older.steps[1].conclusion = 'failure';
		v.model.jobs.push(older);
	});
	await control('partial rerun lists the carried-over Build under the new attempt', (v) => {
		const times = { started_at: '2026-10-23T01:21:12Z', completed_at: '2026-10-23T01:25:00Z' };
		Object.assign(v.model.jobs[0], times);
		v.model.jobs.push({ ...structuredClone(v.model.jobs[0]), id: 298, run_attempt: 2 });
	});
	const mutations = [
		[
			'genuine Build rerun with fresh times does not match an older receipt',
			(v) => {
				Object.assign(v.model.jobs[0], {
					started_at: '2026-10-23T01:21:12Z',
					completed_at: '2026-10-23T01:25:00Z'
				});
				v.model.jobs.push({
					...structuredClone(v.model.jobs[0]),
					id: 298,
					run_attempt: 2,
					started_at: '2026-10-23T01:59:00Z',
					completed_at: '2026-10-23T02:03:00Z'
				});
			},
			/Build receipt differs/
		],
		[
			'missing target',
			(v) => fs.rmSync(path.join(v.files.bundleRoot, 'dev'), { recursive: true }),
			/bundle members/
		],
		[
			'foreign target',
			(v) => fs.mkdirSync(path.join(v.files.bundleRoot, 'foreign')),
			/bundle members/
		],
		[
			'extra root file',
			(v) => fs.writeFileSync(path.join(v.files.bundleRoot, 'extra'), 'x'),
			/bundle members/
		],
		[
			'missing Build receipt',
			(v) => fs.unlinkSync(path.join(v.files.bundleRoot, 'main/build.json')),
			/bundle members/
		],
		[
			'missing browser proof',
			(v) => fs.unlinkSync(path.join(v.files.bundleRoot, 'dev/site-testbuild.json')),
			/bundle members/
		],
		[
			'extra bundle member',
			(v) => fs.writeFileSync(path.join(v.files.bundleRoot, 'dev/extra'), 'x'),
			/bundle members/
		],
		[
			'receipt is directory',
			(v) => {
				const p = path.join(v.files.bundleRoot, 'main/build.json');
				fs.unlinkSync(p);
				fs.mkdirSync(p);
			},
			/ordinary files/
		],
		[
			'noncanonical Build receipt',
			(v) => fs.appendFileSync(path.join(v.files.bundleRoot, 'main/build.json'), ' '),
			/canonical/
		],
		[
			'extra Build receipt key',
			(v) => {
				v.proofs.main.build.foreign = true;
				v.write();
			},
			/closed site artifact keys/
		],
		[
			'duplicate member',
			(v) => {
				v.proofs.main.build.members.push(v.proofs.main.build.members[0]);
				v.write();
			},
			/duplicate or unordered/
		],
		[
			'wrong receipt source',
			(v) => {
				v.proofs.dev.tested.source_sha = 'd'.repeat(40);
				v.write();
			},
			/foreign source_sha/
		],
		[
			'wrong receipt run',
			(v) => {
				v.proofs.dev.tested.run_id = '124';
				v.write();
			},
			/foreign run_id/
		],
		[
			'wrong receipt lock',
			(v) => {
				v.proofs.dev.tested.lock_sha256 = 'd'.repeat(64);
				v.write();
			},
			/foreign lock_sha256/
		],
		[
			'wrong receipt target',
			(v) => {
				v.proofs.dev.tested.target = 'main';
				v.proofs.dev.tested.base_path = '';
				v.write();
			},
			/foreign target/
		],
		[
			'wrong target base',
			(v) => {
				v.proofs.dev.tested.base_path = '';
				v.write();
			},
			/BASE_PATH/
		],
		[
			'future browser attempt',
			(v) => {
				v.proofs.dev.tested.run_attempt = '3';
				v.write();
			},
			/future/
		],
		[
			'browser bound to other manifest',
			(v) => {
				v.proofs.main.tested.build_receipt_sha256 = 'd'.repeat(64);
				v.write();
			},
			/different Build bytes/
		],
		[
			'incomplete browsers',
			(v) => {
				v.proofs.dev.tested.browsers.pop();
				v.write();
			},
			/incomplete browser/
		],
		[
			'incomplete routes',
			(v) => {
				v.proofs.dev.tested.browsers[0].routes.pop();
				v.write();
			},
			/complete ordered site routes/
		],
		[
			'browser error',
			(v) => {
				v.proofs.dev.tested.browsers[0].page_errors = 1;
				v.write();
			},
			/browser did not complete/
		],
		[
			'hydration missing',
			(v) => {
				v.proofs.dev.tested.browsers[0].hydration = false;
				v.write();
			},
			/browser did not complete/
		],
		[
			'interaction missing',
			(v) => {
				v.proofs.dev.tested.browsers[0].interaction = false;
				v.write();
			},
			/browser did not complete/
		],
		[
			'receipt older than actual selected Build',
			(v) => {
				v.model.jobs[0].run_attempt = 2;
			},
			/Build receipt differs/
		],
		[
			'receipt older than selected browser writer',
			(v) => {
				v.proofs.main.tested.run_attempt = '1';
				v.write();
			},
			/browser proof differs/
		],
		[
			'newest failed Build hides retained proof',
			(v) =>
				v.model.jobs.push({ ...v.model.jobs[0], id: 299, run_attempt: 2, conclusion: 'failure' }),
			/not successful/
		],
		[
			'selected writer failed',
			(v) => {
				v.model.jobs[3].steps[1].conclusion = 'failure';
			},
			/receipt writer is not successful/
		],
		[
			'other target writer missing',
			(v) => {
				v.model.jobs[3].steps.pop();
			},
			/stage writer metadata/
		],
		[
			'wrong API job head',
			(v) => {
				v.model.jobs[0].head_sha = 'd'.repeat(40);
			},
			/source\/run/
		],
		[
			'old Common API alias',
			(v) => {
				v.model.jobs[0].name = v.model.jobs[0].name.replace('YAML, shared code & web', 'Common');
			},
			/foreign stage job name/
		],
		[
			'foreign run id',
			(v) => {
				v.model.run.id = 124;
			},
			/foreign current run/
		],
		[
			'foreign run attempt',
			(v) => {
				v.model.run.run_attempt = 3;
			},
			/foreign current run/
		],
		[
			'foreign run repository',
			(v) => {
				v.model.run.repository.id = 12;
			},
			/foreign current run repository/
		],
		[
			'foreign event identity',
			(v) => {
				v.model.run.event = 'workflow_dispatch';
			},
			/run event differs/
		],
		[
			'foreign CI workflow',
			(v) => {
				v.model.workflow.path = '.github/workflows/other.yml';
			},
			/not canonical CI/
		],
		[
			'push API head is not checked-out source',
			(v) => {
				v.model.run.head_sha = 'd'.repeat(40);
			},
			/API head differs/
		],
		[
			'run changes during receipt receiving',
			(v) => {
				v.model.finalRun = { ...v.model.run, head_branch: 'feature/changed' };
			},
			/run identity changed/
		],
		[
			'checked-out source mismatch',
			(v) => {
				v.git = () => 'd'.repeat(40) + '\n';
			},
			/checked-out commit/
		],
		[
			'predecessor failure',
			(v) => {
				v.env.SITE_PREDECESSOR_RESULT = 'failure';
			},
			/preceding site stage/
		],
		[
			'predecessor skipped',
			(v) => {
				v.env.SITE_PREDECESSOR_RESULT = 'skipped';
			},
			/preceding site stage/
		],
		[
			'missing actual CI context',
			(v) => {
				delete v.env.GITHUB_ACTIONS;
			},
			/actual repository CI/
		]
	];
	assert.equal(mutations.length, 41, 'every declared proof and current-run refusal is present');
	for (const [label, mutate, reason] of mutations) await control(label, mutate, reason);
	for (const name of ['CNAME', 'version.json', 'index.html']) {
		await control(
			'missing bound manifest metadata: ' + name,
			(v) => {
				v.proofs.main.build.members = v.proofs.main.build.members.filter(
					(row) => row.path !== name
				);
				v.proofs.main.tested.build_receipt_sha256 = digest(artifact.canonical(v.proofs.main.build));
				v.write();
			},
			/manifest/
		);
	}
	await control(
		'foreign CNAME member hash despite browser digest binding',
		(v) => {
			v.proofs.main.build.members.find((row) => row.path === 'CNAME').sha256 = 'd'.repeat(64);
			v.proofs.main.tested.build_receipt_sha256 = digest(artifact.canonical(v.proofs.main.build));
			v.write();
		},
		/foreign CNAME/
	);
	await control(
		'PR job must bind the observed API head, not the merge receipt source',
		(v) => {
			v.model.jobs[0].head_sha = v.source;
		},
		/source\/run/,
		{ event: 'pull_request', source: 'c'.repeat(40) }
	);
	assert.equal(controls, 51, 'all two-target, attempt, source and PR identity controls execute');
	return {
		controls,
		scope:
			'synthetic API observations and actual bounded proof-file reads only; no new site bytes, browser, Git, network or hosted identity receiving'
	};
}

module.exports = { run };
