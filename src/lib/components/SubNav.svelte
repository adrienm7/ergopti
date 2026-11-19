<!-- src/lib/components/SubNav.svelte -->

<!--
==============================================================================
MODULE: Section Sub-Navigation
DESCRIPTION:
Local navigation between the sub-pages of one product section (Disposition
Ergopti, Ergopti+). Tabs wrap on wide screens and scroll sideways on a phone,
where the current tab is brought into view.
==============================================================================
-->

<script>
	/**
	 * @type {{
	 *   label: string,
	 *   items: Array<{href: string, label: string, current: boolean, icon?: string}>,
	 *   compact?: boolean
	 * }}
	 */
	let { label, items, compact = false } = $props();

	let list = $state();

	$effect(() => {
		// Bring the current tab into view on narrow screens after each navigation.
		items;
		const current = list?.querySelector('[aria-current="page"]');
		if (current && list.scrollWidth > list.clientWidth)
			list.scrollLeft = current.offsetLeft - (list.clientWidth - current.offsetWidth) / 2;
	});
</script>

<nav class="subnav" class:compact aria-label={label}>
	<ul bind:this={list}>
		{#each items as item (item.href)}
			<li>
				<a href={item.href} aria-current={item.current ? 'page' : undefined}
					>{#if item.icon}<svg class="icon" viewBox="0 0 24 24" aria-hidden="true" focusable="false"
							><path d={item.icon} /></svg
						>{/if}<span class="label">{item.label}</span></a
				>
			</li>
		{/each}
	</ul>
</nav>

<style>
	.subnav {
		margin: 0 auto;
		max-width: min(1100px, 100%);
		padding: 0.75rem 16px 0;
	}

	.subnav ul {
		display: flex;
		flex-wrap: wrap;
		gap: 0.5rem;
		justify-content: center;
		list-style: none;
		margin: 0;
		padding: 0;
		position: relative;
	}

	.subnav a {
		background: rgba(0, 0, 0, 0.35);
		border: 1px solid rgba(255, 255, 255, 0.15);
		border-radius: 999px;
		color: rgba(255, 255, 255, 0.9);
		display: inline-block;
		font-size: 0.95rem;
		padding: 0.35rem 0.9rem;
		text-decoration: none;
		white-space: nowrap;
	}

	/*
	 * Slim tab bar of an app-like workspace (Ergopti Studio), in the top menu's
	 * own style: it continues the header's dark band across the full width (no
	 * page background shows between them, maintainer 2026-11-15), and its tabs
	 * are the menu's text links, the current one in the purple gradient.
	 */
	.subnav.compact {
		background-color: var(--header-color);
		border-top: 1px solid rgba(255, 255, 255, 0.08);
		/* Its padding stays inside the full width, and as a flex item of a bar it
		   may shrink below its tabs' single-row width (they wrap instead). */
		box-sizing: border-box;
		max-width: none;
		min-width: 0;
		padding: 0 16px;
		width: 100%;
	}

	.subnav.compact ul {
		gap: var(--items-menu-spacing);
	}

	.subnav.compact a {
		background: none;
		border: 0;
		border-radius: 0;
		color: var(--couleur-liens-header);
		font-size: 1rem;
		padding: 0.45rem 0.6rem;
		position: relative;
	}

	.subnav.compact a:hover .label,
	.subnav.compact a:focus-visible .label {
		-webkit-background-clip: text;
		background-clip: text;
		background-image: linear-gradient(var(--gradient-blue));
		color: transparent;
		-webkit-text-fill-color: transparent;
	}

	.subnav.compact a[aria-current='page'] {
		background: none;
		font-weight: bold;
	}

	.subnav.compact a[aria-current='page'] .label {
		-webkit-background-clip: text;
		background-clip: text;
		background-image: linear-gradient(var(--gradient-purple));
		color: transparent;
		-webkit-text-fill-color: transparent;
	}

	/* The current tab's underline, in the same gradient. */
	.subnav.compact a[aria-current='page']::after {
		background-image: linear-gradient(to right, var(--gradient-purple));
		border-radius: 3px;
		bottom: 0;
		content: '';
		height: 3px;
		left: 0.6rem;
		position: absolute;
		right: 0.6rem;
	}

	/* A tab's decorative icon (items[].icon), in the link's colour. */
	.subnav .icon {
		fill: none;
		height: 1.1em;
		margin-right: 0.4em;
		stroke: currentColor;
		stroke-linecap: round;
		stroke-linejoin: round;
		stroke-width: 2;
		vertical-align: -0.2em;
		width: 1.1em;
	}

	.subnav a:hover,
	.subnav a:focus-visible {
		border-color: rgba(255, 255, 255, 0.5);
	}

	.subnav a[aria-current='page'] {
		background: linear-gradient(var(--gradient-purple));
		border-color: transparent;
		color: white;
		font-weight: bold;
	}

	@media (max-width: 700px) {
		.subnav ul {
			flex-wrap: nowrap;
			justify-content: flex-start;
			overflow-x: auto;
			padding-bottom: 0.4rem;
			scrollbar-width: thin;
		}

		/* The few Studio tabs wrap onto a second row rather than scroll, so every
		   tab stays in view at 320 px and at 200 % text (WCAG 1.4.10). */
		.subnav.compact {
			padding: 0 8px;
		}

		.subnav.compact ul {
			flex-wrap: wrap;
			justify-content: center;
			overflow-x: visible;
			padding-bottom: 0;
		}

		.subnav.compact a {
			padding: 0.45rem 0.4rem;
		}

		.subnav.compact a[aria-current='page']::after {
			left: 0.4rem;
			right: 0.4rem;
		}
	}
</style>
