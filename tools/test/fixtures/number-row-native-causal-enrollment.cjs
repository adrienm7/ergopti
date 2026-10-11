'use strict';

/** Source admission only; never executes a native test or treats its result as green. */
module.exports = function causalEnrollment(pipeline) {
	const MACOS_BOX = '.github/workflows/ci-macos.yml';
	const NOT_CANCELLED = '${{ !cancelled() }}';
	// Prospective native causal enrollment: parse owned steps, not whole implementation strings.
	const NUMBER_ROW_CAUSAL_NAME = 'Receive native final-byte number-row causal refusal';
	const NUMBER_ROW_CAUSAL_KEEP = 'Retain native final-byte number-row causal diagnostics';
	function problems(files) {
		const mac = files.find((entry) => entry.rel === MACOS_BOX)?.text ?? '';
		const jobs = pipeline
			.jobsOfText(mac, MACOS_BOX)
			.filter((job) => job.id === 'managed-ollama-native');
		if (jobs.length !== 1) return ['one causal native owner job required'];
		const steps = pipeline.steps(jobs[0].body);
		const cohort = pipeline.step(jobs[0].body, NUMBER_ROW_CAUSAL_NAME);
		const keep = pipeline.step(jobs[0].body, NUMBER_ROW_CAUSAL_KEEP);
		const problems = [];
		const require = (ok, label) => {
			if (!ok) problems.push(label);
		};
		require(pipeline.stepField(cohort, 'if') === NOT_CANCELLED, 'causal cohort remains mandatory');
		require(pipeline.stepField(keep, 'if') === 'always()', 'causal retention remains mandatory');
		for (const body of [cohort, keep])
			require(pipeline.stepField(body, 'continue-on-error') ===
				null, 'causal failure remains fatal');
		require(pipeline.stepField(cohort, 'shell') === 'bash', 'causal status owner shell');
		require(pipeline.stepField(cohort, 'timeout-minutes') === '10', 'bounded causal child');
		const names = steps.map((step) => step.name);
		const positive = names.indexOf('Retain selected number-row Carbon XCTest diagnostics');
		const causal = names.indexOf(NUMBER_ROW_CAUSAL_NAME),
			retained = names.indexOf(NUMBER_ROW_CAUSAL_KEEP);
		require(positive >= 0 &&
			causal > positive &&
			retained === causal + 1 &&
			names.indexOf('Qualify actual native PAC source ownership XCTest controls') >
				retained, 'independent causal receiving order');
		const lines = (pipeline.runOf(cohort) ?? [])
			.map((line) => line.trim())
			.filter((line) => line && !line.startsWith('#'));
		const code = lines.join('\n'),
			calls = code.replace(/\\\n\s*/g, ' ');
		require(lines.includes(
			'recipe="tools/diagnostics/fixtures/number-row-native-causal/projection-manifest.original-c15.json.raw"'
		), 'enrolled immutable source recipe');
		require(lines.includes(
			'portable_receiving="$(mktemp -d "$evidence/portable-receiving.XXXXXX")"'
		), 'fresh portable receiving root');
		require(calls.includes('python3 -B tools/diagnostics/test_number_row_native_causal.py') &&
			calls.includes(
				'--fixture-manifest tools/diagnostics/fixtures/number-row-native-causal/fixture-manifest.json.raw'
			) &&
			calls.includes(
				'--projection "$controls_projection" --receiving "$portable_receiving" --receiver "$receiver"'
			) &&
			calls.includes('--positive-receiver tools/diagnostics/keyboard_geometry_xctest_receipt.py') &&
			calls.includes(
				'--transport tools/diagnostics/tis_evidence_transport.cjs --node "$(command -v node)"'
			) &&
			calls.includes(
				'2>&1 | tee "$evidence/portable-controls.log"'
			), 'complete explicit portable enrollment');
		// This straight-line command contract permits no branch, function, heredoc or
		// hidden success substitute. Projection preparation belongs to its pinned helper.
		require(!/^(?:if|elif|else|fi|for|while|until|case|function)\b|<<|\|\||&&/m.test(
			code
		), 'causal commands cannot be conditionally bypassed');
		require(lines[0] === 'set -euo pipefail', 'strict native pipeline');
		// Exact owned source enrollment closes extra/reordered shell commands and every argv port.
		const receivedCompositionSHA =
			'0ecbffdbbbc22ced77277e9838b1212b2e0341cacce8a3e0732c6a8c018f9a9f';
		require(/^[0-9a-f]{64}$/.test(
			receivedCompositionSHA
		), 'independently received generator digest is still pending');
		const expectedCommands = [
			'set -euo pipefail',
			'test "$(git rev-parse HEAD)" = "$GITHUB_SHA"',
			'evidence="$RUNNER_TEMP/number-row-causal-evidence"',
			'mkdir "$evidence"',
			'projection="$(mktemp -d "$RUNNER_TEMP/number-row-current-projection.XXXXXX")"',
			'controls_projection="$(mktemp -d "$RUNNER_TEMP/number-row-historical-controls.XXXXXX")"',
			'projection_evidence="$evidence/source-proof"',
			'mkdir "$projection_evidence"',
			'private_scratch="$(mktemp -d "$evidence/compile.XXXXXX")"',
			'recipe="tools/diagnostics/fixtures/number-row-native-causal/projection-manifest.original-c15.json.raw"',
			'receiver="tools/diagnostics/number_row_native_causal.py"',
			'prepare="tools/diagnostics/prepare_number_row_native_causal.py"',
			'generator="tools/diagnostics/generate_number_row_source_composition.py"',
			'composition_controls="tools/diagnostics/test_number_row_source_composition.py"',
			'approval="tools/diagnostics/fixtures/number-row-native-causal/g5-source-approvals.json.raw"',
			'approval_sha="47b2dc03e558db6418234ab6c69a279cc91fd9c29bc587505e13ea0989764549"',
			'receiver_sha="d913505e2d3522d5023227b947f3c7896ba3ef4aeadfbd0c1a7042fa9686c148"',
			'composition="$evidence/source-composition.json"',
			'composition_sha="0ecbffdbbbc22ced77277e9838b1212b2e0341cacce8a3e0732c6a8c018f9a9f"',
			'git show "$GITHUB_SHA:$prepare" | cmp - "$prepare"',
			'git show "$GITHUB_SHA:$generator" | cmp - "$generator"',
			'git show "$GITHUB_SHA:$composition_controls" | cmp - "$composition_controls"',
			'git show "$GITHUB_SHA:$approval" | cmp - "$approval"',
			"printf '%s  %s\\n' '9203a7f77e0ed607557283b8ff27355ad871d99e58229e018c213d7653e79139' \"$prepare\" | shasum -a 256 -c -",
			"printf '%s  %s\\n' '8478aca8584e3da947f1e2c3b0f894874cce77aa97022be7832cb40d4182644c' \"$generator\" | shasum -a 256 -c -",
			"printf '%s  %s\\n' '0981b0f400596680b19215ffcd2ecef20346dca8bfeae8c46a46f0a7ad68e7f1' \"$composition_controls\" | shasum -a 256 -c -",
			'printf \'%s  %s\\n\' "$receiver_sha" "$receiver" | shasum -a 256 -c -',
			'printf \'%s  %s\\n\' "$approval_sha" "$approval" | shasum -a 256 -c -',
			'cp "$approval" "$evidence/g5-source-approvals.json"',
			'set +e',
			'python3 -B "$generator"  --head "$GITHUB_SHA" --recipe "$recipe" --approval "$approval"  --approval-sha256 "$approval_sha" --receiver "$receiver" --output "$composition"  > "$evidence/source-composition-generator.stdout.raw" 2> "$evidence/source-composition-generator.stderr.raw"',
			'composition_generator_status=$?',
			'set -e',
			'printf \'%s\\n\' "$composition_generator_status" > "$evidence/source-composition-generator.status.txt"',
			'test "$composition_generator_status" -eq 0',
			'printf \'%s  %s\\n\' "$composition_sha" "$composition" | shasum -a 256 -c -',
			'python3 -B "$prepare" --composition-controls  "$GITHUB_SHA" "$recipe" "$projection" "$projection_evidence" "$receiver" "$receiver_sha"  "$composition" "$composition_sha" "$approval" "$approval_sha" "$controls_projection"',
			'cp "$projection_evidence/NumberRowSourceProbe.original.swift" "$evidence/NumberRowSourceProbe.original.swift"',
			'cp "$projection_evidence/actual-git-projection.json" "$evidence/actual-git-projection.json"',
			'cp "$projection_evidence/historical-controls-projection.json" "$evidence/historical-controls-projection.json"',
			'portable_receiving="$(mktemp -d "$evidence/portable-receiving.XXXXXX")"',
			'python3 -B tools/diagnostics/test_number_row_native_causal.py  --fixture-manifest tools/diagnostics/fixtures/number-row-native-causal/fixture-manifest.json.raw  --projection "$controls_projection" --receiving "$portable_receiving" --receiver "$receiver"  --positive-receiver tools/diagnostics/keyboard_geometry_xctest_receipt.py  --transport tools/diagnostics/tis_evidence_transport.cjs --node "$(command -v node)"  2>&1 | tee "$evidence/portable-controls.log"',
			'grep -E \'^Ran 53 tests in [0-9.]+s$\' "$evidence/portable-controls.log"',
			'grep -x \'OK\' "$evidence/portable-controls.log"',
			'composition_receiving="$(mktemp -d "$evidence/composition-receiving.XXXXXX")"',
			'python3 -B "$composition_controls"  --repo "$GITHUB_WORKSPACE" --head "$GITHUB_SHA" --recipe "$recipe"  --approval "$approval" --approval-sha256 "$approval_sha"  --composition "$composition" --composition-sha256 "$composition_sha"  --projection "$projection" --controls-projection "$controls_projection"  --original-producer "$evidence/NumberRowSourceProbe.original.swift"  --receiver "$receiver" --positive-receiver tools/diagnostics/keyboard_geometry_xctest_receipt.py  --receiving "$composition_receiving"  2>&1 | tee "$evidence/composition-controls.log"',
			'grep -E \'^Ran 51 tests in [0-9.]+s$\' "$evidence/composition-controls.log"',
			'grep -x \'OK\' "$evidence/composition-controls.log"',
			'source="$projection/static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/NumberRowSourceProbeTests.swift"',
			'producer="$projection/static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/NumberRowSourceProbe.swift"',
			'cp "$source" "$evidence/NumberRowSourceProbeTests.swift"',
			'cp "$producer" "$evidence/NumberRowSourceProbe.counterfactual.swift"',
			'cp "$recipe" "$evidence/projection-manifest.json"',
			'export ERGOPTI_TIS_EVIDENCE_DIR="$(mktemp -d "$evidence/tis-session.XXXXXX")"',
			'export ERGOPTI_TIS_EVIDENCE_SESSION="$(node -e \'process.stdout.write(require("node:crypto").randomBytes(32).toString("hex"))\')"',
			'set +e',
			'swift test --package-path "$projection/static/ergopti_plus/macos/launcher"  --scratch-path "$private_scratch"  --filter \'(^|[.])NumberRowSourceProbeTests($|[/.])\'  2>&1 | tee "$evidence/number-row-causal-xctest.log"',
			'number_row_causal_statuses=("${PIPESTATUS[@]}")',
			'set -e',
			'test "${#number_row_causal_statuses[@]}" -eq 2',
			'printf \'%s\\n\' "${number_row_causal_statuses[@]}" > "$evidence/actual-pipeline-statuses.txt"',
			'python3 -B "$receiver"  --manifest "$recipe" --projection "$projection"  --original-producer "$evidence/NumberRowSourceProbe.original.swift"  --test-source "$source" --log "$evidence/number-row-causal-xctest.log"  --transport tools/diagnostics/tis_evidence_transport.cjs --node "$(command -v node)"  --tis-root "$ERGOPTI_TIS_EVIDENCE_DIR" --session "$ERGOPTI_TIS_EVIDENCE_SESSION"  --swift-exit "${number_row_causal_statuses[0]}" --capture-exit "${number_row_causal_statuses[1]}"  --tis-stdout "$evidence/tis-decoder.stdout.raw" --tis-stderr "$evidence/tis-decoder.stderr.raw"  --receipt "$evidence/number-row-causal-verdict.json"  --composition "$composition" --composition-sha256 "$composition_sha"  --source-approval "$approval" --source-approval-sha256 "$approval_sha" --source-head "$GITHUB_SHA"',
			'test "$(git rev-parse HEAD)" = "$GITHUB_SHA"',
			'git show "$GITHUB_SHA:$recipe" | cmp - "$recipe"',
			'git show "$GITHUB_SHA:$receiver" | cmp - "$receiver"',
			'git show "$GITHUB_SHA:$prepare" | cmp - "$prepare"',
			'git show "$GITHUB_SHA:$generator" | cmp - "$generator"',
			'git show "$GITHUB_SHA:$composition_controls" | cmp - "$composition_controls"',
			'git show "$GITHUB_SHA:$approval" | cmp - "$approval"'
		];
		require(JSON.stringify(calls.split('\n')) ===
			JSON.stringify(
				expectedCommands
			), 'exact straight-line composition, historical53, current51 and native receiving commands');
		require(lines.filter((line) => line === 'test "$(git rev-parse HEAD)" = "$GITHUB_SHA"')
			.length === 2, 'actual source HEAD before and after');
		require(lines.filter(
			(line) =>
				line === 'projection="$(mktemp -d "$RUNNER_TEMP/number-row-current-projection.XXXXXX")"'
		).length === 1 &&
			lines.filter((line) => line === 'private_scratch="$(mktemp -d "$evidence/compile.XXXXXX")"')
				.length === 1, 'separate fresh projection and scratch');
		require(calls.includes(
			'python3 -B "$prepare" --composition-controls  "$GITHUB_SHA" "$recipe" "$projection" "$projection_evidence" "$receiver" "$receiver_sha"  "$composition" "$composition_sha" "$approval" "$approval_sha" "$controls_projection"'
		), 'original Git projection helper receives actual source');
		require(calls.match(/\bswift test\b/g)?.length === 1 &&
			calls.match(/--filter\b/g)?.length === 1 &&
			calls.includes(
				"--filter '(^|[.])NumberRowSourceProbeTests($|[/.])'"
			), 'unique full independent twelve-case selector');
		require(calls.includes('--package-path "$projection/static/ergopti_plus/macos/launcher"') &&
			calls.includes('--scratch-path "$private_scratch"'), 'owned projected native compile');
		require(code.includes(
			'2>&1 | tee "$evidence/number-row-causal-xctest.log"\nnumber_row_causal_statuses=("${PIPESTATUS[@]}")\nset -e'
		), 'immediate original process and capture statuses');
		require(lines.includes(
			'test "${#number_row_causal_statuses[@]}" -eq 2'
		), 'two actual statuses required');
		require(calls.match(/python3 -B "\$receiver"/g)?.length === 1 &&
			calls.includes(
				'--swift-exit "${number_row_causal_statuses[0]}" --capture-exit "${number_row_causal_statuses[1]}"'
			), 'strict expected-red receiver gets original statuses');
		for (const pair of [
			'--manifest "$recipe" --projection "$projection"',
			'--original-producer "$evidence/NumberRowSourceProbe.original.swift"',
			'--test-source "$source"',
			'--transport tools/diagnostics/tis_evidence_transport.cjs',
			'--tis-root "$ERGOPTI_TIS_EVIDENCE_DIR" --session "$ERGOPTI_TIS_EVIDENCE_SESSION"',
			'--tis-stdout "$evidence/tis-decoder.stdout.raw" --tis-stderr "$evidence/tis-decoder.stderr.raw"'
		])
			require(calls.includes(pair), 'lossless original source and restoration receiving: ' + pair);
		require(lines.includes(
			'export ERGOPTI_TIS_EVIDENCE_DIR="$(mktemp -d "$evidence/tis-session.XXXXXX")"'
		) &&
			calls.includes(
				'require("node:crypto").randomBytes(32).toString("hex")'
			), 'fresh native TIS session');
		for (const slot of ['recipe', 'receiver', 'prepare'])
			require(lines.includes(
				`git show "$GITHUB_SHA:$${slot}" | cmp - "$${slot}"`
			), 'retained current receiver/source image: ' + slot);
		require(pipeline.stepField(keep, 'uses') ===
			'actions/upload-artifact@v4', 'actual causal evidence upload');
		require(/^ {10}if-no-files-found: error$/m.test(keep) &&
			/^ {10}retention-days: 7$/m.test(keep), 'strict evidence retention');
		for (const suffix of [
			'number-row-causal-xctest.log',
			'actual-pipeline-statuses.txt',
			'number-row-causal-verdict.json',
			'actual-git-projection.json',
			'projection-manifest.json',
			'NumberRowSourceProbe.original.swift',
			'NumberRowSourceProbe.counterfactual.swift',
			'NumberRowSourceProbeTests.swift',
			'tis-decoder.stdout.raw',
			'tis-decoder.stderr.raw',
			'tis-session.*/start.json',
			'tis-session.*/manifest.json',
			'tis-session.*/record-*.dat',
			'tis-session.*/refusal.json',
			'portable-controls.log',
			'source-composition-generator.stdout.raw',
			'source-composition-generator.stderr.raw',
			'source-composition-generator.status.txt',
			'g5-source-approvals.json',
			'source-composition.json',
			'historical-controls-projection.json',
			'composition-controls.log'
		])
			require(keep.includes(
				'${{ runner.temp }}/number-row-causal-evidence/' + suffix
			), 'retained raw/source/restoration asset: ' + suffix);
		return problems;
	}

	function admit(mac) {
		try {
			if (problems([{ rel: MACOS_BOX, text: mac }]).length !== 0) return null;
			const job = pipeline
				.jobsOfText(mac, MACOS_BOX)
				.find((job) => job.id === 'managed-ollama-native');
			const owned = pipeline.step(job.body, NUMBER_ROW_CAUSAL_NAME);
			const filter = "--filter '(^|[.])NumberRowSourceProbeTests($|[/.])'";
			// Remove only this strict independently received selector, not a foreign filter.
			if (owned.split(filter).length !== 2 || mac.split(owned).length !== 2) return null;
			return mac.replace(owned, () => owned.replace(filter, ''));
		} catch {
			return null;
		}
	}
	return { problems, admit };
};
