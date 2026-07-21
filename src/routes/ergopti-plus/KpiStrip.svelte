<!-- src/routes/ergopti-plus/KpiStrip.svelte -->

<!--
==============================================================================
MODULE: Ergopti+ Page — KPI Strip
DESCRIPTION:
Animated counters for the headline numbers. Every value is measured at build
time from the driver's own data files (hotstring TOMLs, models.json,
locales), so the strip can never lie.

FEATURES & RATIONALE:
1. Count-Up On Sight: counters animate when the strip enters the viewport
   (not at page load) so the effect is actually seen.
2. Data-Driven: values arrive as props from +page.server.js.
==============================================================================
-->

<script>
	import { onMount } from 'svelte';

	/** Duration of the count-up animation. */
	const COUNT_DURATION_MS = 1500;

	/** @type {{items: Array<{value: number, suffix: string, label: string}>}} */
	let { items } = $props();

	let counters = $state([]);
	let strip;
	let started = false;

	$effect.pre(() => {
		counters = items.map(() => 0);
	});

	/** Ease-out count-up over all counters at once. */
	function animate() {
		const start = performance.now();
		function tick(now) {
			const t = Math.min(1, (now - start) / COUNT_DURATION_MS);
			const eased = 1 - Math.pow(1 - t, 3);
			counters = items.map((k) => Math.round(k.value * eased));
			if (t < 1) requestAnimationFrame(tick);
		}
		requestAnimationFrame(tick);
	}

	onMount(() => {
		const io = new IntersectionObserver(
			(entries) => {
				if (entries.some((e) => e.isIntersecting) && !started) {
					started = true;
					animate();
					io.disconnect();
				}
			},
			{ threshold: 0.4 }
		);
		io.observe(strip);
		return () => io.disconnect();
	});

	/**
	 * Format a counter with a thin non-breaking space as thousands separator
	 * (French convention).
	 * @param {number} n
	 * @returns {string}
	 */
	function fmt(n) {
		return n.toLocaleString('fr-FR');
	}
</script>

<div class="kpi-strip ep-wrap" bind:this={strip}>
	{#each items as kpi, i}
		<div class="kpi">
			<div class="kpi-num">{fmt(counters[i] ?? 0)}{kpi.suffix}</div>
			<div class="kpi-label">{kpi.label}</div>
		</div>
	{/each}
</div>

<style>
	.kpi-strip {
		border-block: 1px solid var(--border);
		display: grid;
		gap: 18px;
		grid-template-columns: repeat(4, 1fr);
		margin-top: clamp(56px, 8vw, 96px);
		padding-block: clamp(24px, 3.5vw, 40px);
	}

	.kpi {
		text-align: center;
	}

	.kpi-num {
		background: linear-gradient(180deg, #fff, rgba(255, 255, 255, 0.65));
		-webkit-background-clip: text;
		background-clip: text;
		font-size: clamp(1.7rem, 3.4vw, 2.6rem);
		font-variant-numeric: tabular-nums;
		font-weight: 800;
		letter-spacing: -0.02em;
		-webkit-text-fill-color: transparent;
	}

	.kpi-label {
		color: var(--ink-faint);
		font-size: 0.85rem;
		line-height: 1.4;
		margin-top: 4px;
		text-wrap: balance;
	}

	@media (max-width: 880px) {
		.kpi-strip {
			grid-template-columns: repeat(2, 1fr);
		}
	}

	@media (max-width: 380px) {
		.kpi-strip {
			grid-template-columns: 1fr;
		}
	}
</style>
