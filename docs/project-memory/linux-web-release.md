<!-- docs/project-memory/linux-web-release.md -->

# Linux, web, and release memory

## Linux input

### project-linux-grab-is-a-contract-not-a-flag

Observe mode and `EVIOCGRAB` mode have different correctness contracts. A driver
that does not grab cannot prevent a physical terminator from reaching the app;
replay logic must reflect the active mode.

### project-linux-a-field-must-be-named-at-every-boundary

Linux input records cross evdev, resolver, injector, and Lua boundaries. Preserve
the exact canonical field names at each hop.

### project-linux-writing-a-table-nobody-reads

Persisting a mapping is not implementation if the runtime resolver never reads
it. Tests must execute selection through injection.

### project-a-computed-label-is-a-list-of-one

Provider APIs may return a single computed label wrapped as a list. Normalize at
the adapter boundary rather than spreading shape checks through the driver.

## Website and documentation

### project-site-i18n-gettext-french-key

The website's gettext source keys are French user-facing strings. Do not replace
them with English developer identifiers without a deliberate catalog migration.

### project-svelte-script-comment-closing-tag

The HTML parser can terminate a Svelte `<script>` block on a closing-tag token
inside a comment. Avoid spelling that token literally in script comments.

### project-pages-deploy-branch-vs-workflow

GitHub Pages deployment source can be branch-based or workflow-based. Verify the
repository setting before changing CI; workflow files alone do not prove the
active deployment mode.

## Release artifacts

### project-release-notes-are-not-joined-to-the-assets

Release notes and uploaded binaries are separate publication steps. Verify the
tag, notes, and every expected asset explicitly.

### project-the-drift-guard-crashes-on-this-windows-box

When a cross-platform drift tool fails on Windows path/process semantics, use
the repository's supported wrapper and preserve the failure as a test fixture;
do not silently skip the guard.

