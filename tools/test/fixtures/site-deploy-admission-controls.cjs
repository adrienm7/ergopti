// tools/test/fixtures/site-deploy-admission-controls.cjs

/** Recording API controls for exact completed-CI admission; no hosted or native actors. */
'use strict';
const { API_PAGE_SIZE } = require('../../ci/github-api-page.cjs');

const assert = require('node:assert/strict');
const subject = require('../../ci/site-deploy-admission.cjs');
const { siteLot } = require('../../dev/site-context.cjs');

function fixture(target = 'main') {
	const source = 'a'.repeat(40);
	const run = {
		id: 123,
		repository: { id: 11, full_name: subject.REPOSITORY },
		head_repository: { id: 11, full_name: subject.REPOSITORY },
		event: 'push',
		status: 'completed',
		conclusion: 'success',
		head_branch: target,
		head_sha: source,
		run_attempt: 2,
		workflow_id: 77
	};
	const workflow = { id: 77, path: '.github/workflows/ci.yml', name: 'CI' };
	const jobs = [target, target === 'main' ? 'dev' : 'main'].flatMap((cellTarget, cellIndex) =>
		[
			['YAML, shared code & web / Build', 'Build and seal production site'],
			['YAML, shared code & web / Install and launch', 'Test received production site']
		].map(([name, writer], i) => ({
			id: 201 + i + cellIndex * 10,
			name: name + ' (' + siteLot(cellTarget) + ')',
			run_id: 123,
			head_sha: source,
			run_attempt: i + 1,
			status: 'completed',
			conclusion: 'success',
			steps: [
				{ name: 'Set up job', number: 1, status: 'completed', conclusion: 'success' },
				{
					name: writer + ' — ' + siteLot(cellTarget),
					number: 2,
					status: 'completed',
					conclusion: 'success'
				}
			]
		}))
	);
	const artifacts = ['common-site-build-', 'common-site-testbuild-'].map((name, i) => ({
		id: 301 + i,
		name: name + target,
		expired: false,
		digest: 'sha256:' + 'b'.repeat(64),
		workflow_run: {
			id: 123,
			repository_id: 11,
			head_repository_id: 11,
			head_sha: source,
			head_branch: target
		}
	}));
	const selection = {
		repository: subject.REPOSITORY,
		trigger: {
			kind: 'workflow_run',
			action: 'completed',
			run_id: 123,
			source_sha: source,
			branch: target
		}
	};
	return { run, workflow, jobs, artifacts, selection };
}

function reader(model) {
	const calls = [];
	const prefix = '/repos/' + subject.REPOSITORY + '/actions/';
	return {
		calls,
		readApi(endpoint) {
			calls.push(endpoint);
			if (endpoint === '/repos/' + subject.REPOSITORY + '/git/ref/heads/' + model.run.head_branch)
				return structuredClone(
					model.reference || {
						ref: 'refs/heads/' + model.run.head_branch,
						object: { type: 'commit', sha: model.run.head_sha }
					}
				);
			if (endpoint === prefix + 'runs/123') {
				const runReads = calls.filter((value) => value === endpoint).length;
				return structuredClone(runReads > 1 && model.finalRun ? model.finalRun : model.run);
			}
			if (endpoint === prefix + 'workflows/' + model.run.workflow_id)
				return structuredClone(model.workflow);
			for (const field of ['jobs', 'artifacts']) {
				const match = new RegExp(
					'^' +
						prefix +
						'runs/123/' +
						field +
						'\\?(?:filter=(all|latest)&)?per_page=' +
						API_PAGE_SIZE +
						'&page=([1-9][0-9]*)$'
				).exec(endpoint);
				if (match) {
					const page = Number(match[2]);
					const rows =
						field === 'jobs' && match[1] === 'latest' && model.latestJobs
							? model.latestJobs
							: model[field];
					return {
						total_count: model[field + 'Total'] ?? rows.length,
						[field]: structuredClone(rows.slice((page - 1) * API_PAGE_SIZE, page * API_PAGE_SIZE))
					};
				}
			}
			throw new Error('Unexpected recording API endpoint: ' + endpoint);
		}
	};
}

/** Executed by the existing site owner, preserving a direct scoped CLI as well. */
async function run(owner = subject, artifact = require('../../ci/site-artifact.cjs')) {
	let controls = 0;
	for (const target of ['main', 'dev']) {
		const model = fixture(target),
			api = reader(model);
		const result = await owner.admitProducer(model.selection, api.readApi);
		assert.deepEqual(result, {
			schema_version: 1,
			repository: subject.REPOSITORY,
			source_sha: 'a'.repeat(40),
			target,
			base_path: target === 'main' ? '' : '/dev',
			run_id: '123',
			run_attempt: '2',
			build_artifact_id: '301',
			testbuild_artifact_id: '302'
		});
		assert.equal(api.calls.filter((p) => p.endsWith('/runs/123')).length, 2);
		controls++;
		model.selection.trigger = { kind: 'manual', run_id: '123' };
		assert.deepEqual(await owner.admitProducer(model.selection, reader(model).readApi), result);
		controls++;
		model.jobs.forEach((job) => {
			job.run_attempt = 2;
		});
		assert.deepEqual(await owner.admitProducer(model.selection, reader(model).readApi), result);
		controls++;
	}
	const retry = fixture();
	retry.latestJobs = [retry.jobs[1]];
	retry.jobs.push({ ...retry.jobs[1], id: 203, run_attempt: 1 });
	assert.equal((await owner.admitProducer(retry.selection, reader(retry).readApi)).run_id, '123');
	controls++;
	const mutations = [
		[
			'foreign repository',
			(m) => {
				m.selection.repository = 'foreign/repository';
			},
			/foreign repository/
		],
		[
			'extra selection key',
			(m) => {
				m.selection.latest = true;
			},
			/closed deployment/
		],
		[
			'unknown event',
			(m) => {
				m.selection.trigger.kind = 'push';
			},
			/unsupported trigger/
		],
		[
			'not completed event',
			(m) => {
				m.selection.trigger.action = 'requested';
			},
			/completion event/
		],
		[
			'missing exact run',
			(m) => {
				delete m.selection.trigger.run_id;
			},
			/closed deployment/
		],
		[
			'noncanonical run',
			(m) => {
				m.selection.trigger.run_id = '0123';
			},
			/invalid positive/
		],
		[
			'fork repository',
			(m) => {
				m.run.head_repository.full_name = 'foreign/ergopti';
			},
			/fork run/
		],
		[
			'fork identity',
			(m) => {
				m.run.head_repository.id = 12;
			},
			/fork repository identity/
		],
		[
			'PR producer',
			(m) => {
				m.run.event = 'pull_request';
			},
			/successful push/
		],
		[
			'manual producer',
			(m) => {
				m.run.event = 'workflow_dispatch';
			},
			/successful push/
		],
		[
			'failed run',
			(m) => {
				m.run.conclusion = 'failure';
			},
			/successful push/
		],
		[
			'incomplete run',
			(m) => {
				m.run.status = 'in_progress';
			},
			/successful push/
		],
		[
			'foreign branch',
			(m) => {
				m.run.head_branch = 'feature/site';
			},
			/deployment target/
		],
		[
			'foreign event SHA',
			(m) => {
				m.selection.trigger.source_sha = 'b'.repeat(40);
			},
			/event differs/
		],
		[
			'foreign event branch',
			(m) => {
				m.selection.trigger.branch = 'dev';
			},
			/event differs/
		],
		[
			'wrong workflow',
			(m) => {
				m.workflow.path = '.github/workflows/foreign.yml';
			},
			/canonical CI/
		],
		[
			'wrong workflow ID',
			(m) => {
				m.workflow.id = 78;
			},
			/canonical CI/
		],
		[
			'wrong workflow name',
			(m) => {
				m.workflow.name = 'Fake CI';
			},
			/canonical CI/
		],
		[
			'missing build job',
			(m) => {
				m.jobs.shift();
			},
			/stage job name/
		],
		[
			'missing testbuild job',
			(m) => {
				m.jobs.splice(1, 1);
			},
			/stage job name/
		],
		[
			'duplicate job record',
			(m) => {
				m.jobs.push(structuredClone(m.jobs[0]));
			},
			/duplicate API/
		],
		[
			'duplicate job role',
			(m) => {
				m.jobs.push({ ...m.jobs[0], id: 203 });
			},
			/stage job name/
		],
		[
			'unknown caller prefix',
			(m) => {
				m.jobs[0].name = m.jobs[0].name.replace('YAML, shared code & web / ', 'Foreign / ');
			},
			/stage job name/
		],
		[
			'unknown job suffix',
			(m) => {
				m.jobs[0].name += ' forged';
			},
			/stage job name/
		],
		[
			'failed build',
			(m) => {
				m.jobs[0].conclusion = 'failure';
			},
			/not successful/
		],
		[
			'failed testbuild',
			(m) => {
				m.jobs[1].conclusion = 'failure';
			},
			/not successful/
		],
		[
			'skipped testbuild',
			(m) => {
				m.jobs[1].conclusion = 'skipped';
			},
			/not successful/
		],
		[
			'foreign job source',
			(m) => {
				m.jobs[0].head_sha = 'b'.repeat(40);
			},
			/not successful/
		],
		[
			'foreign job run',
			(m) => {
				m.jobs[0].run_id = 124;
			},
			/not successful/
		],
		[
			'future stage attempt',
			(m) => {
				m.jobs[1].run_attempt = 3;
			},
			/future stage/
		],
		[
			'backward lineage',
			(m) => {
				m.jobs[0].run_attempt = 2;
				m.jobs[1].run_attempt = 1;
			},
			/lineage runs backward/
		],
		[
			'missing build artifact',
			(m) => {
				m.artifacts.shift();
			},
			/exact site artifact/
		],
		[
			'missing testbuild artifact',
			(m) => {
				m.artifacts.pop();
			},
			/exact site artifact/
		],
		[
			'duplicate artifact record',
			(m) => {
				m.artifacts.push(structuredClone(m.artifacts[0]));
			},
			/duplicate API/
		],
		[
			'duplicate artifact role',
			(m) => {
				m.artifacts.push({ ...m.artifacts[0], id: 303 });
			},
			/exact site artifact/
		],
		[
			'expired artifact',
			(m) => {
				m.artifacts[0].expired = true;
			},
			/expired or unsealed/
		],
		[
			'missing API digest',
			(m) => {
				delete m.artifacts[0].digest;
			},
			/expired or unsealed/
		],
		[
			'cross-source artifact',
			(m) => {
				m.artifacts[0].workflow_run.head_sha = 'b'.repeat(40);
			},
			/foreign artifact owner/
		],
		[
			'cross-run artifact',
			(m) => {
				m.artifacts[0].workflow_run.id = 124;
			},
			/foreign artifact owner/
		],
		[
			'cross-branch artifact',
			(m) => {
				m.artifacts[0].workflow_run.head_branch = 'dev';
			},
			/foreign artifact owner/
		],
		[
			'missing artifact owner',
			(m) => {
				delete m.artifacts[0].workflow_run;
			},
			/foreign artifact owner/
		],
		[
			'truncated jobs census',
			(m) => {
				m.jobsTotal = m.jobs.length + 1;
			},
			/census is incomplete/
		],
		[
			'truncated artifact census',
			(m) => {
				m.artifactsTotal = 3;
			},
			/census is incomplete/
		],
		[
			'excessive census',
			(m) => {
				m.artifactsTotal = 1001;
			},
			/exceeds bounds/
		],
		[
			'rerun during admission',
			(m) => {
				m.finalRun = { ...m.run, status: 'in_progress', conclusion: null, run_attempt: 3 };
			},
			/changed during metadata/
		],
		[
			'late older source',
			(m) => {
				m.reference = { ref: 'refs/heads/main', object: { type: 'commit', sha: 'b'.repeat(40) } };
			},
			/target branch no longer/
		],
		[
			'foreign target ref',
			(m) => {
				m.reference = { ref: 'refs/heads/dev', object: { type: 'commit', sha: m.run.head_sha } };
			},
			/target branch no longer/
		],
		[
			'wrong target object',
			(m) => {
				m.reference = { ref: 'refs/heads/main', object: { type: 'tag', sha: m.run.head_sha } };
			},
			/target branch no longer/
		]
	];
	for (const [name, change, reason] of mutations) {
		const model = fixture();
		change(model);
		await assert.rejects(
			() => owner.admitProducer(model.selection, reader(model).readApi),
			reason,
			name
		);
		controls++;
	}
	const paginated = fixture();
	paginated.jobs.push(
		...Array.from({ length: 101 }, (_, i) => ({ id: 1000 + i, name: 'Unrelated role ' + i }))
	);
	paginated.artifacts.push(
		...Array.from({ length: 101 }, (_, i) => ({ id: 2000 + i, name: 'unrelated-' + i }))
	);
	const api = reader(paginated);
	assert.equal((await owner.admitProducer(paginated.selection, api.readApi)).run_id, '123');
	// 101 extra records span three pages of 50: the census reads every one.
	assert.equal(API_PAGE_SIZE, 50, 'GitHub answers 502 for heavier jobs pages');
	for (const page of [2, 3]) {
		assert.ok(
			api.calls.some((endpoint) => endpoint.endsWith('/jobs?filter=all&per_page=50&page=' + page))
		);
		assert.ok(
			api.calls.some((endpoint) => endpoint.endsWith('/artifacts?per_page=50&page=' + page))
		);
	}
	controls++;
	assert.equal(controls, 56, 'every declared metadata and retained-role control must execute');
	for (const [name, mutate, reason] of [
		[
			'latest failed Build hides old success',
			(m) => m.jobs.push({ ...m.jobs[0], id: 204, run_attempt: 2, conclusion: 'failure' }),
			/not successful/
		],
		[
			'latest failed Testbuild hides old success',
			(m) => {
				m.jobs[1].run_attempt = 1;
				m.jobs.push({ ...m.jobs[1], id: 204, run_attempt: 2, conclusion: 'failure' });
			},
			/not successful/
		],
		['two jobs in chosen attempt', (m) => m.jobs.push({ ...m.jobs[1], id: 204 }), /stage job name/],
		[
			'newer foreign alias',
			(m) =>
				m.jobs.push({
					...m.jobs[0],
					id: 204,
					run_attempt: 2,
					name: m.jobs[0].name.replace('YAML, shared code & web / ', 'Foreign / ')
				}),
			/stage job name/
		]
	]) {
		const m = fixture();
		mutate(m);
		await assert.rejects(() => owner.admitProducer(m.selection, reader(m).readApi), reason, name);
		controls++;
	}
	const env = {
		GITHUB_ACTIONS: 'true',
		GITHUB_REPOSITORY: subject.REPOSITORY,
		GITHUB_EVENT_NAME: 'workflow_run'
	};
	const event = {
		repository: { full_name: subject.REPOSITORY },
		action: 'completed',
		workflow_run: fixture().run
	};
	assert.deepEqual(owner.selectionFromEvent(env, event), fixture().selection);
	controls++;
	for (const [change, reason] of [
		[
			(e, value) => {
				e.GITHUB_ACTIONS = 'false';
			},
			/actual repository/
		],
		[
			(e, value) => {
				value.repository.full_name = 'foreign/repository';
			},
			/foreign event/
		],
		[
			(e, value) => {
				value.workflow_run.conclusion = 'failure';
			},
			/successful push/
		],
		[
			(e, value) => {
				value.workflow_run.status = 'in_progress';
			},
			/successful push/
		],
		[
			(e, value) => {
				value.workflow_run.event = 'pull_request';
			},
			/successful push/
		],
		[
			(e, value) => {
				e.GITHUB_EVENT_NAME = 'push';
			},
			/unsupported deployment/
		]
	]) {
		const e = { ...env },
			value = structuredClone(event);
		change(e, value);
		assert.throws(() => owner.selectionFromEvent(e, value), reason);
		controls++;
	}
	assert.deepEqual(
		owner.selectionFromEvent(
			{ ...env, GITHUB_EVENT_NAME: 'workflow_dispatch' },
			{ ...event, inputs: { run_id: '123' } }
		),
		{ repository: subject.REPOSITORY, trigger: { kind: 'manual', run_id: '123' } }
	);
	controls++;
	const fs = require('node:fs'),
		path = require('node:path'),
		os = require('node:os');
	const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-site-deploy-proof-'));
	try {
		for (const target of ['main', 'dev']) {
			const sourceRoot = path.join(temporary, target, 'source'),
				siteDirectory = path.join(temporary, target, 'site');
			fs.mkdirSync(path.join(sourceRoot, 'static'), { recursive: true });
			fs.mkdirSync(siteDirectory, { recursive: true });
			fs.writeFileSync(path.join(sourceRoot, 'package-lock.json'), '{}\n');
			const cname = Buffer.from('fixture.example\n');
			fs.writeFileSync(path.join(sourceRoot, 'static/CNAME'), cname);
			const admitted = await owner.admitProducer(
				fixture(target).selection,
				reader(fixture(target)).readApi
			);
			const context = {
				source_sha: admitted.source_sha,
				run_id: admitted.run_id,
				run_attempt: '1',
				target,
				base_path: admitted.base_path,
				lock_sha256: artifact.fileHash(path.join(sourceRoot, 'package-lock.json')).sha256
			};
			fs.writeFileSync(path.join(siteDirectory, 'CNAME'), cname);
			fs.writeFileSync(
				path.join(siteDirectory, 'version.json'),
				artifact.canonical({
					branch: target,
					base_path: context.base_path,
					source_sha: context.source_sha
				})
			);
			const homepage = path.join(siteDirectory, 'index.html');
			fs.writeFileSync(homepage, '<!doctype html><title>Controlled output fixture</title>');
			const build = artifact.seal(siteDirectory, context, cname);
			const browsers = artifact.SITE_BROWSERS.map((name) => ({
				name,
				routes: [...artifact.SITE_ROUTES],
				local_http_errors: 0,
				page_errors: 0,
				hydration: true,
				interaction: true
			}));
			const tested = artifact.recordTestbuild(build, { ...context, run_attempt: '2' }, browsers);
			const buildReceiptFile = path.join(temporary, target, 'build.json'),
				testbuildReceiptFile = path.join(temporary, target, 'testbuild.json');
			fs.writeFileSync(buildReceiptFile, artifact.canonical(build));
			fs.writeFileSync(testbuildReceiptFile, artifact.canonical(tested));
			const files = { siteDirectory, buildReceiptFile, testbuildReceiptFile, sourceRoot };
			const ports = {
				artifact,
				readApi: reader(fixture(target)).readApi,
				git(args) {
					assert.deepEqual(args, ['rev-parse', '--verify', 'HEAD^{commit}']);
					return context.source_sha + '\n';
				}
			};
			const result = owner.verifyDownloaded(admitted, files, ports);
			assert.equal(result.received.files, 3);
			assert.deepEqual(result.tested, {
				build_run_attempt: '1',
				testbuild_run_attempt: '2',
				receiving_run_attempt: '2'
			});
			controls++;
			const admissionFile = path.join(temporary, target, 'admission.json');
			fs.writeFileSync(admissionFile, JSON.stringify(admitted, null, 2) + '\n');
			await owner.main(
				[
					'verify',
					admissionFile,
					siteDirectory,
					buildReceiptFile,
					testbuildReceiptFile,
					sourceRoot
				],
				env,
				ports
			);
			controls++;
			await owner.main(['current', admissionFile], env, ports);
			controls++;
			const advanced = fixture(target);
			advanced.reference = {
				ref: 'refs/heads/' + target,
				object: { type: 'commit', sha: 'b'.repeat(40) }
			};
			await assert.rejects(
				() =>
					owner.main(['current', admissionFile], env, {
						...ports,
						readApi: reader(advanced).readApi
					}),
				/target branch no longer/
			);
			controls++;
			fs.writeFileSync(admissionFile, JSON.stringify(admitted));
			await assert.rejects(
				() =>
					owner.main(
						[
							'verify',
							admissionFile,
							siteDirectory,
							buildReceiptFile,
							testbuildReceiptFile,
							sourceRoot
						],
						env,
						ports
					),
				/canonical bytes/
			);
			controls++;
			assert.throws(
				() => owner.verifyDownloaded(admitted, files, { ...ports, git: () => 'c'.repeat(40) }),
				/checked-out source/
			);
			controls++;
			assert.throws(
				() => owner.verifyDownloaded({ ...admitted, extra: true }, files, ports),
				/closed deployment/
			);
			controls++;
			assert.throws(
				() => owner.verifyDownloaded({ ...admitted, build_artifact_id: 301 }, files, ports),
				/canonical strings/
			);
			controls++;
			assert.throws(
				() =>
					owner.verifyDownloaded(
						admitted,
						{ ...files, testbuildReceiptFile: testbuildReceiptFile + '.missing' },
						ports
					),
				/ENOENT/
			);
			controls++;
			const bad = structuredClone(tested);
			bad.browsers[0].hydration = false;
			fs.writeFileSync(testbuildReceiptFile, artifact.canonical(bad));
			assert.throws(() => owner.verifyDownloaded(admitted, files, ports), /browser|hydration/);
			controls++;
			const future = { ...tested, run_attempt: '3' };
			fs.writeFileSync(testbuildReceiptFile, artifact.canonical(future));
			assert.throws(() => owner.verifyDownloaded(admitted, files, ports), /future/);
			controls++;
			const wrongBuild = { ...tested, build_receipt_sha256: 'e'.repeat(64) };
			fs.writeFileSync(testbuildReceiptFile, artifact.canonical(wrongBuild));
			assert.throws(() => owner.verifyDownloaded(admitted, files, ports), /different Build bytes/);
			controls++;
			fs.writeFileSync(testbuildReceiptFile, artifact.canonical(tested));
			fs.appendFileSync(homepage, 'changed');
			assert.throws(() => owner.verifyDownloaded(admitted, files, ports), /received site bytes/);
			controls++;
			fs.writeFileSync(homepage, '<!doctype html><title>Controlled output fixture</title>');
			fs.writeFileSync(path.join(sourceRoot, 'package-lock.json'), '{"changed":true}\n');
			assert.throws(() => owner.verifyDownloaded(admitted, files, ports), /foreign lock_sha256/);
			controls++;
			fs.writeFileSync(path.join(sourceRoot, 'package-lock.json'), '{}\n');
			fs.writeFileSync(path.join(sourceRoot, 'static/CNAME'), 'foreign.example\n');
			assert.throws(() => owner.verifyDownloaded(admitted, files, ports), /CNAME/);
			controls++;
		}
		const eventFile = path.join(temporary, 'event.json'),
			outputReceipt = path.join(temporary, 'admitted.json'),
			outputFile = path.join(temporary, 'outputs.txt');
		fs.writeFileSync(eventFile, JSON.stringify(event));
		const cliEnv = { ...env, GITHUB_OUTPUT: outputFile };
		await owner.main(['admit', eventFile, outputReceipt], cliEnv, {
			artifact,
			readApi: reader(fixture()).readApi
		});
		const admitted = JSON.parse(fs.readFileSync(outputReceipt, 'utf8'));
		assert.equal(admitted.build_artifact_id, '301');
		assert.equal(
			fs.readFileSync(outputFile, 'utf8'),
			Object.entries(admitted)
				.map(([key, value]) => key + '=' + value + '\n')
				.join('')
		);
		controls++;
		const outputBefore = fs.readFileSync(outputFile);
		await assert.rejects(
			() =>
				owner.main(['admit', eventFile, outputReceipt], cliEnv, {
					artifact,
					readApi: reader(fixture()).readApi
				}),
			/EEXIST/
		);
		assert.deepEqual(fs.readFileSync(outputFile), outputBefore);
		controls++;
		await assert.rejects(
			() =>
				owner.main(
					['admit', eventFile, path.join(temporary, 'failed-output.json')],
					{ ...cliEnv, GITHUB_OUTPUT: path.join(temporary, 'missing', 'output.txt') },
					{ artifact, readApi: reader(fixture()).readApi }
				),
			/ENOENT/
		);
		controls++;
	} finally {
		assert.equal(path.resolve(path.dirname(temporary)), path.resolve(os.tmpdir()));
		assert.ok(path.basename(temporary).startsWith('ergopti-site-deploy-proof-'));
		fs.rmSync(temporary, { recursive: true });
	}
	assert.equal(
		controls,
		101,
		'metadata/event, retained-role reruns, target freshness, strict CLI transport and exact downloaded-byte controls all execute'
	);
	const markerMutations = [
		['missing writer steps', (m) => delete m.jobs[0].steps, /stage writer metadata/],
		['non-array writer steps', (m) => (m.jobs[0].steps = {}), /stage writer metadata/],
		['empty writer steps', (m) => (m.jobs[0].steps = []), /stage writer metadata/],
		['missing writer marker', (m) => m.jobs[0].steps.pop(), /stage writer metadata/],
		[
			'duplicate writer marker',
			(m) => m.jobs[0].steps.push({ ...m.jobs[0].steps[1], number: 3 }),
			/stage writer metadata/
		],
		[
			'two target markers in one stage job',
			(m) => m.jobs[0].steps.push({ ...m.jobs[2].steps[1], number: 3 }),
			/stage writer metadata/
		],
		[
			'unknown writer target',
			(m) => (m.jobs[0].steps[1].name = 'Build and seal production site — Preview site'),
			/unknown target or wrong-stage/
		],
		[
			'prefixed writer alias',
			(m) => (m.jobs[0].steps[1].name = 'Forged ' + m.jobs[0].steps[1].name),
			/unknown target or wrong-stage/
		],
		[
			'suffixed writer alias',
			(m) => (m.jobs[0].steps[1].name += ' forged'),
			/unknown target or wrong-stage/
		],
		[
			'wrong-stage writer marker',
			(m) => (m.jobs[0].steps[1] = structuredClone(m.jobs[1].steps[1])),
			/unknown target or wrong-stage/
		],
		[
			'other-target writer under an exact authored job name',
			(m) => (m.jobs[0].steps[1] = structuredClone(m.jobs[2].steps[1])),
			/unknown target or wrong-stage/
		],
		[
			'reserved writer under unrelated parent',
			(m) => m.jobs.push({ ...m.jobs[0], id: 203, name: 'Windows / Build' }),
			/foreign stage job name/
		],
		[
			'failed selected receipt writer despite successful job',
			(m) => (m.jobs[0].steps[1].conclusion = 'failure'),
			/receipt writer is not successful/
		],
		[
			'skipped selected receipt writer despite successful job',
			(m) => (m.jobs[1].steps[1].conclusion = 'skipped'),
			/receipt writer is not successful/
		],
		[
			'incomplete selected receipt writer',
			(m) => (m.jobs[1].steps[1].status = 'in_progress'),
			/receipt writer is not successful/
		],
		[
			'missing selected writer conclusion',
			(m) => delete m.jobs[1].steps[1].conclusion,
			/receipt writer is not successful/
		],
		['missing other-target Build', (m) => m.jobs.splice(2, 1), /stage job name/],
		['failed other-target Build', (m) => (m.jobs[2].conclusion = 'failure'), /not successful/],
		[
			'failed other-target receipt writer',
			(m) => (m.jobs[3].steps[1].conclusion = 'failure'),
			/receipt writer is not successful/
		],
		['missing other-target marker', (m) => m.jobs[2].steps.pop(), /stage writer metadata/],
		[
			'newer failed Build without marker hides old success',
			(m) =>
				m.jobs.push({ ...m.jobs[0], id: 203, run_attempt: 2, conclusion: 'failure', steps: [] }),
			/stage writer metadata/
		],
		[
			'newer skipped writer hides old success',
			(m) => {
				const newer = structuredClone(m.jobs[0]);
				Object.assign(newer, { id: 203, run_attempt: 2 });
				newer.steps[1].conclusion = 'skipped';
				m.jobs.push(newer);
			},
			/receipt writer is not successful/
		],
		[
			'older foreign writer marker cannot disappear during attempt selection',
			(m) => {
				const older = structuredClone(m.jobs[1]);
				Object.assign(older, { id: 203, run_attempt: 1, conclusion: 'failure' });
				older.steps[1].name = 'Test received production site — Preview site';
				m.jobs.push(older);
			},
			/unknown target or wrong-stage/
		],
		[
			'backward other-target lineage',
			(m) => {
				m.jobs[2].run_attempt = 2;
				m.jobs[3].run_attempt = 1;
			},
			/lineage runs backward/
		],
		[
			'newer failed other-target Build hides old success',
			(m) => m.jobs.push({ ...m.jobs[2], id: 203, run_attempt: 2, conclusion: 'failure' }),
			/not successful/
		]
	];
	assert.equal(markerMutations.length, 25, 'every declared writer-custody refusal is present');
	for (const target of ['main', 'dev']) {
		for (const [name, mutate, reason] of markerMutations) {
			const model = fixture(target);
			mutate(model);
			await assert.rejects(
				() => owner.admitProducer(model.selection, reader(model).readApi),
				reason,
				target + ': ' + name
			);
			controls++;
		}
		const retained = fixture(target);
		const older = structuredClone(retained.jobs[1]);
		Object.assign(older, { id: 203, run_attempt: 1, conclusion: 'failure' });
		older.steps[1].conclusion = 'failure';
		retained.jobs.push(older);
		retained.latestJobs = [retained.jobs[1], retained.jobs[3]];
		assert.deepEqual(
			await owner.admitProducer(retained.selection, reader(retained).readApi),
			await owner.admitProducer(fixture(target).selection, reader(fixture(target)).readApi)
		);
		controls++;
	}
	assert.equal(
		controls,
		153,
		'all original controls and both-target writer custody controls execute'
	);
	return {
		controls,
		scope:
			'recorded API and controlled actual-file integrity only; no build/browser/Git/network or hosted job-name proof'
	};
}

if (require.main === module)
	run()
		.then((result) => console.log(JSON.stringify(result)))
		.catch((error) => {
			console.error(error.stack);
			process.exitCode = 1;
		});
module.exports = { run, fixture, reader };
