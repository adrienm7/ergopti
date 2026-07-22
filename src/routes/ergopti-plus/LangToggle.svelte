<!-- src/routes/ergopti-plus/LangToggle.svelte -->

<!--
==============================================================================
MODULE: Ergopti+ Page — Language Selector
DESCRIPTION:
A compact language switch with a sliding highlight, mirroring the OS toggle's
look. It renders one button per entry in AVAILABLE_LANGS, so exposing a new
language never requires touching this component.
==============================================================================
-->

<script>
	import { i18n, setLang, AVAILABLE_LANGS } from './i18n.svelte.js';

	let index = $derived(Math.max(0, AVAILABLE_LANGS.findIndex((l) => l.code === i18n.lang)));
</script>

<div
	class="lang-toggle"
	role="group"
	aria-label="Language / Langue"
	style="--n: {AVAILABLE_LANGS.length};"
>
	<span class="lang-slider" style="--i: {index};" aria-hidden="true"></span>
	{#each AVAILABLE_LANGS as l}
		<button
			type="button"
			class:active={i18n.lang === l.code}
			aria-pressed={i18n.lang === l.code}
			onclick={() => setLang(l.code)}
		>
			{l.label}
		</button>
	{/each}
</div>

<style>
	.lang-toggle {
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: 999px;
		display: inline-flex;
		gap: 0;
		padding: 3px;
		position: relative;
		width: calc(46px * var(--n, 2));
	}

	.lang-slider {
		background: rgba(255, 255, 255, 0.13);
		border-radius: 999px;
		bottom: 3px;
		left: 3px;
		position: absolute;
		top: 3px;
		transform: translateX(calc(var(--i, 0) * 100%));
		transition: transform 0.28s var(--ease-out, ease);
		width: calc((100% - 6px) / var(--n, 2));
		z-index: 0;
	}

	.lang-toggle button {
		background: transparent;
		border: 0;
		border-radius: 999px;
		color: var(--ink-soft);
		cursor: pointer;
		flex: 1;
		font: inherit;
		font-size: 0.78rem;
		font-weight: 700;
		letter-spacing: 0.04em;
		padding: 5px 0;
		position: relative;
		transition: color 0.25s var(--ease, ease);
		z-index: 1;
	}

	.lang-toggle button:hover {
		color: var(--ink);
	}

	.lang-toggle button.active {
		color: var(--ink);
	}

	@media (prefers-reduced-motion: reduce) {
		.lang-slider {
			transition: none;
		}
	}
</style>
