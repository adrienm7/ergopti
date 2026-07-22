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
	/** Read progress 0–100, reflecting how far down the page the visitor is. */
	let progress = $state(0);
	/** The active section's own accent colour, so the active pill matches it. */
	let activeAccent = $state('');
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

		// Reading-progress bar — throttled to animation frames so the scroll
		// handler never blocks the main thread.
		let ticking = false;
		const onScroll = () => {
			if (ticking) return;
			ticking = true;
			requestAnimationFrame(() => {
				const max = document.documentElement.scrollHeight - window.innerHeight;
				progress = max > 0 ? Math.min(100, (window.scrollY / max) * 100) : 0;
				ticking = false;
			});
		};
		window.addEventListener('scroll', onScroll, { passive: true });
		onScroll();

		return () => {
			io.disconnect();
			window.removeEventListener('scroll', onScroll);
		};
	});

	// Keep the active pill visible inside the horizontally-scrollable bar, and
	// adopt the active section's accent colour for the pill fill.
	$effect(() => {
		if (!activeId || !navEl) return;
		const section = document.getElementById(activeId);
		if (section) {
			const accent = getComputedStyle(section).getPropertyValue('--section-accent').trim();
			if (accent) activeAccent = accent;
		}
		const pill = navEl.querySelector(`a[href="#${activeId}"]`);
		if (!pill) return;
		const { offsetLeft, offsetWidth } = pill;
		const target = offsetLeft - navEl.clientWidth / 2 + offsetWidth / 2;
		navEl.scrollTo({ left: target, behavior: 'smooth' });
	});
</script>

<nav
	class="sticky-nav"
	aria-label="Sections de la page"
	style="--active-accent: {activeAccent || 'var(--accent-blue-deep)'};"
>
	<div class="read-progress" aria-hidden="true">
		<span style="width: {progress}%;"></span>
	</div>
	<div class="nav-scroll" bind:this={navEl}>
		{#each items as item}
			<a href="#{item.id}" class:active={activeId === item.id}>
				{item.label}
			</a>
		{/each}
	</div>
</nav>

<style>
	.sticky-nav {
		align-items: center;
		display: flex;
		flex-direction: column;
		gap: 8px;
		justify-content: center;
		margin-top: clamp(24px, 4vw, 40px);
		padding-inline: 12px;
		position: sticky;
		top: calc(var(--header-height) + var(--banner-height) + 8px);
		z-index: 60;
	}

	/* Thin reading-progress bar above the pill — its fill adopts the active
	 * section's accent colour, tying the whole page's motion together. */
	.read-progress {
		background: rgba(255, 255, 255, 0.08);
		border-radius: 2px;
		height: 3px;
		overflow: hidden;
		width: min(420px, 78vw);
	}

	.read-progress span {
		background: linear-gradient(
			90deg,
			var(--active-accent),
			color-mix(in srgb, var(--active-accent) 55%, #fff)
		);
		border-radius: 2px;
		display: block;
		height: 100%;
		transition:
			width 0.15s linear,
			background-color 0.4s var(--ease);
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

	/* The single blue pill marks the section currently in view — no item
	 * gets a permanent fill, or the scrollspy state becomes unreadable */
	.nav-scroll a.active {
		background: linear-gradient(
			135deg,
			var(--active-accent),
			color-mix(in srgb, var(--active-accent) 55%, var(--accent-cyan))
		);
		box-shadow: 0 4px 18px -6px color-mix(in srgb, var(--active-accent) 70%, transparent);
		color: #fff;
		transition:
			background-color 0.4s var(--ease),
			box-shadow 0.4s var(--ease);
	}
</style>
