<!-- src/routes/ergopti-plus/StickyNav.svelte -->

<!--
==============================================================================
MODULE: Ergopti+ Page — Sticky Section Navigation
DESCRIPTION:
Pill-style sticky navigation bar with scrollspy. Sits under the site's fixed
header, highlights the section currently in the viewport's middle band, and
scrolls horizontally on narrow screens.

FEATURES & RATIONALE:
1. Hierarchy: the page is long — a persistent map of its sections keeps the
   visitor oriented and lets them jump straight to what they care about.
2. Native Anchors: links are plain #anchors; the site already sets
   scroll-padding-top for the fixed header, so no JS scrolling is needed.
==============================================================================
-->

<script>
	import { onMount } from 'svelte';

	/** Middle-band rootMargin: the section crossing it becomes active. */
	const SPY_ROOT_MARGIN = '-35% 0px -55% 0px';

	/** @type {{items: Array<{id: string, label: string}>}} */
	let { items } = $props();

	let activeId = $state('');
	let navEl;

	onMount(() => {
		const sections = items.map((i) => document.getElementById(i.id)).filter((el) => el !== null);

		const io = new IntersectionObserver(
			(entries) => {
				for (const entry of entries) {
					if (entry.isIntersecting) activeId = entry.target.id;
				}
			},
			{ rootMargin: SPY_ROOT_MARGIN }
		);
		sections.forEach((s) => io.observe(s));
		return () => io.disconnect();
	});

	// Keep the active pill visible inside the horizontally-scrollable bar.
	$effect(() => {
		if (!activeId || !navEl) return;
		const pill = navEl.querySelector(`a[href="#${activeId}"]`);
		if (!pill) return;
		const { offsetLeft, offsetWidth } = pill;
		const target = offsetLeft - navEl.clientWidth / 2 + offsetWidth / 2;
		navEl.scrollTo({ left: target, behavior: 'smooth' });
	});
</script>

<nav class="sticky-nav" aria-label="Sections de la page">
	<div class="nav-scroll" bind:this={navEl}>
		{#each items as item}
			<a
				href="#{item.id}"
				class:active={activeId === item.id}
				class:cta={item.id === 'telecharger'}
			>
				{item.label}
			</a>
		{/each}
	</div>
</nav>

<style>
	.sticky-nav {
		display: flex;
		justify-content: center;
		margin-top: clamp(24px, 4vw, 40px);
		padding-inline: 12px;
		position: sticky;
		top: calc(var(--header-height) + var(--banner-height) + 8px);
		z-index: 60;
	}

	.nav-scroll {
		backdrop-filter: blur(14px);
		-webkit-backdrop-filter: blur(14px);
		background: rgba(8, 14, 30, 0.75);
		border: 1px solid var(--border-strong);
		border-radius: 999px;
		box-shadow: 0 8px 32px -8px rgba(0, 0, 0, 0.5);
		display: flex;
		gap: 2px;
		max-width: 100%;
		overflow-x: auto;
		padding: 5px;
		scrollbar-width: none;
	}

	.nav-scroll::-webkit-scrollbar {
		display: none;
	}

	.nav-scroll a {
		border-radius: 999px;
		color: var(--ink-faint);
		flex-shrink: 0;
		font-size: 0.84rem;
		font-weight: 600;
		padding: 7px 14px;
		text-decoration: none;
		transition:
			background-color 0.25s var(--ease),
			color 0.25s var(--ease);
		white-space: nowrap;
	}

	.nav-scroll a:hover {
		background: rgba(255, 255, 255, 0.07);
		color: var(--ink);
	}

	.nav-scroll a.active {
		background: rgba(49, 190, 255, 0.14);
		color: var(--ink);
	}

	.nav-scroll a.cta {
		background: linear-gradient(135deg, var(--accent-blue-deep), var(--accent-cyan));
		color: #fff;
	}

	.nav-scroll a.cta:hover {
		filter: brightness(1.1);
	}
</style>
