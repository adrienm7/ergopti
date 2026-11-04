# Untouched-baseline Pages guard reproduction

Baseline: `89b0b774c8c960c7ad458ac3cb98d5c97598e518`.

The failure is pre-existing. An exact extraction of baseline
`tools/test/test-ci-pipeline-wiring.cjs:2509–2793` (the two site constants and
`siteDeploymentProblems`, with its sole package dependency `yaml`) rejects the
baseline `.github/workflows/deploy-site.yml` under pinned Node **v22.22.2** and
locked YAML **2.9.1**. The original assertion `deepEqual(problems, [])` remains
unchanged and exits **1** with “only tested production bytes reach Pages”.

The resulting twelve problem labels exactly equal the full suite's failure,
including order and the five repeated “publication step if” labels. See
`full-suite-match.json`, `validation-receipt.json`, `stdout.txt`, `stderr.txt`
and `exit-code.txt`.

The bounded cause is contract/workflow drift: the workflow already adds a
`superseded` admission output, conditional receiving steps, and a deployment
job condition. The baseline validator still requires exactly the older output
map and unconditional receiving/publication shape. Thus it reports the new
output as “forward actual admission”, the five receiving-step conditions and
job condition, and each condition-bearing step as differing from its closed
expected object. This diagnostic does not decide whether those workflow changes
are correct or propose weakening the guard.

`identity-receipt.json` retains baseline Git blob IDs plus SHA-256 values for the
validator source, workflow, package.json, package-lock.json and .node-version.
For all five files, baseline bytes equal current working-tree bytes and index
bytes; the targeted staged diff is empty. The original runtime/workflow sources
were not edited, and no checkout or full duplicate repository was created.

Reproduce:

```
npx --yes --package=node@22.22.2 node /workspace/scratch/deep-integration/ci-baseline/probe.cjs
# Expected: original assertion fails, exit 1.
```

The VM executes the exact extracted original function, accepts only its actual
`require('yaml')` dependency, and records the same failure before running the
unmodified assertion. Only this Pages-publication boundary was replayed; this
is not a claim about later guards in the full CI wiring suite. All files created
for this diagnostic are under the named scratch directory. No fix, exception,
check suppression, test modification or external publication was performed.
