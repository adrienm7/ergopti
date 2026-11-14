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
	/** @type {{ label: string, items: Array<{href: string, label: string, current: boolean}> }} */
	let { label, items } = $props();

	let list = $state();

	$effect(() => {
		// Bring the current tab into view on narrow screens after each navigation.
		items;
		const current = list?.querySelector('[aria-current="page"]');
		if (current && list.scrollWidth > list.clientWidth)
			list.scrollLeft = current.offsetLeft - (list.clientWidth - current.offsetWidth) / 2;
	});
</script>

<nav class="subnav" aria-label={label}>
	<ul bind:this={list}>
		{#each items as item (item.href)}
			<li>
				<a href={item.href} aria-current={item.current ? 'page' : undefined}>{item.label}</a>
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
	}
</style>
