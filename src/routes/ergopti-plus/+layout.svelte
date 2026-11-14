<!-- src/routes/ergopti-plus/+layout.svelte -->

<!--
==============================================================================
MODULE: Ergopti+ Section Layout
DESCRIPTION:
Shell shared by the Ergopti+ overview and its sub-pages: language selector,
the Ergopti+ version, the local navigation between sub-pages and the sticky
download button. It bootstraps the shared page state once (language, OS
chrome style, GitHub release and repository signals), so moving between
sub-pages does not refetch them. Each sub-page renders only its own sections.
==============================================================================
-->

<script>
	import { onMount } from 'svelte';
	import { page } from '$app/state';
	import { resolve } from '$app/paths';
	import { getRelease } from '#lib/js/getGitHubRelease.js';
	import SubNav from '#lib/components/SubNav.svelte';
	import { ERGOPTI_PLUS_PAGES } from '#lib/js/siteNavigation.js';

	import './ergopti-plus.css';
	import { ui, restoreOS } from './state.svelte.js';
	import { t, restoreLang } from './i18n.svelte.js';
	import LangToggle from './LangToggle.svelte';
	import StickyCta from './StickyCta.svelte';

	let { children } = $props();

	let pathname = $derived(page.url.pathname.replace(/\/$/, ''));
	let items = $derived(
		ERGOPTI_PLUS_PAGES.map((entry) => ({
			href: resolve(entry.route),
			label: t(entry.label),
			current: pathname === resolve(entry.route)
		}))
	);
	// The installation page holds the real download section.
	let onInstallation = $derived(pathname === resolve('/ergopti-plus/installation'));

	onMount(async () => {
		restoreLang();
		restoreOS();
		ui.release = await getRelease();

		// Live GitHub trust signals (stars + licence). Best-effort: if the
		// unauthenticated API is rate-limited or offline, the badges stay hidden.
		try {
			const r = await fetch('https://api.github.com/repos/adrienm7/ergopti');
			if (r.ok) {
				const d = await r.json();
				ui.repo = { stars: d.stargazers_count ?? 0, license: d.license?.spdx_id || '' };
			}
		} catch (_) {
			/* ignore — trust badges are optional */
		}
	});
</script>

<svelte:head>
	<!-- The GitHub star badge fetches on mount — warm the connection up front -->
	<link rel="preconnect" href="https://api.github.com" crossorigin="anonymous" />
</svelte:head>

<!--
  The site-wide layout scans #main-content for heading ids, and tocbot looks
  for #page-toc; the Ergopti+ pages have no table of contents, so hidden
  stubs keep those owners satisfied.
-->
<div id="main-content" class="ep-shell">
	<div id="page-toc-pc" style="display: none">
		<div id="page-toc"></div>
	</div>

	<main class="ep-main">
		<div class="ep-root">
			<div class="ep-topbar">
				<LangToggle />
				<p class="ep-version" aria-live="polite">
					{#if ui.release}<span>Ergopti+ {ui.release.tag}</span>{/if}
				</p>
				<p class="legacy-link">
					<a href={resolve('/ergopti-plus-old')}>{t('Ancienne version de cette page →')}</a>
				</p>
			</div>
			<SubNav label={t('Pages d’Ergopti+')} {items} />

			{@render children()}

			<div class="ep-endspace"></div>
		</div>
	</main>

	{#if !onInstallation}<StickyCta />{/if}
</div>

<style>
	.ep-topbar {
		align-items: center;
		display: flex;
		flex-wrap: wrap;
		gap: 14px;
		justify-content: space-between;
		margin: 10px auto 0;
		max-width: 1140px;
		padding-inline: clamp(16px, 4vw, 48px);
	}

	.ep-version {
		color: rgba(255, 255, 255, 0.7);
		font-size: 0.85rem;
		margin: 0;
	}

	.legacy-link {
		margin: 0;
		text-align: right;
	}

	.legacy-link a {
		color: rgba(255, 255, 255, 0.35);
		font-size: 0.78rem;
		text-decoration: none;
		transition: color 0.25s ease;
	}

	.legacy-link a:hover {
		color: rgba(255, 255, 255, 0.7);
		text-decoration: underline;
	}

	.ep-endspace {
		height: clamp(56px, 8vw, 110px);
	}
</style>
