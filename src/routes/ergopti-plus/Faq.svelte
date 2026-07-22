<!-- src/routes/ergopti-plus/Faq.svelte -->

<!--
==============================================================================
MODULE: Ergopti+ Page — FAQ
DESCRIPTION:
Answers the objections that actually block a download: privacy, typing
latency, app compatibility, uninstall, cost. Built on native <details> so it
needs no JS, stays accessible, and works if scripting is disabled.
==============================================================================
-->

<script>
	import { reveal } from './reveal.js';
	import { FAQ_DATA } from './faq-data.js';
	import { t } from './i18n.svelte.js';
</script>

<section class="faq" id="ep-faq" style="--section-accent: #5e9cff;">
	<div class="ep-wrap">
		<header class="section-head" use:reveal>
			<p class="kicker">{t('Questions fréquentes')}</p>
			<h2>{t('Tout ce qu’on se demande avant d’installer.')}</h2>
			<p class="lead">
				{t('Confidentialité, performance, compatibilité — les réponses courtes, sans détour.')}
			</p>
		</header>

		<div class="faq-list">
			{#each FAQ_DATA as f, i}
				<details class="ep-card faq-item" use:reveal={{ delay: (i % 4) * 50 }}>
					<summary>
						<span class="faq-q">{t(f.q)}</span>
						<span class="faq-chevron" aria-hidden="true"></span>
					</summary>
					<div class="faq-a">
						<p>{@html t(f.a)}</p>
					</div>
				</details>
			{/each}
		</div>
	</div>
</section>

<style>
	.faq-list {
		display: flex;
		flex-direction: column;
		gap: 12px;
		margin: 0 auto;
		max-width: 760px;
	}

	.faq-item {
		--accent: #5e9cff;
		padding: 0;
	}

	.faq-item summary {
		align-items: center;
		cursor: pointer;
		display: flex;
		gap: 14px;
		justify-content: space-between;
		list-style: none;
		padding: 18px 22px;
	}

	.faq-item summary::-webkit-details-marker {
		display: none;
	}

	.faq-q {
		font-size: 1rem;
		font-weight: 650;
	}

	.faq-chevron {
		border-bottom: 2px solid var(--ink-faint);
		border-right: 2px solid var(--ink-faint);
		flex-shrink: 0;
		height: 9px;
		transform: rotate(45deg);
		transition: transform 0.3s var(--ease);
		width: 9px;
	}

	.faq-item[open] .faq-chevron {
		transform: rotate(-135deg);
	}

	.faq-a {
		padding: 0 22px 20px;
	}

	.faq-a p {
		color: var(--ink-soft);
		font-size: 0.92rem;
		line-height: 1.65;
		margin: 0;
	}

	.faq-a :global(strong) {
		color: var(--ink);
	}

	/* Answers ease in on open (native <details> cannot animate close). */
	@media (prefers-reduced-motion: no-preference) {
		.faq-item[open] .faq-a {
			animation: faq-open 0.32s var(--ease-out) both;
		}
	}

	@keyframes faq-open {
		from {
			opacity: 0;
			transform: translateY(-6px);
		}
	}
</style>
