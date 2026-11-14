<!-- src/lib/components/SiteFrame.svelte -->

<!--
==============================================================================
MODULE: Site Frame
DESCRIPTION:
Frames a shared page served from static/ (the layout editor, the layout
comparison) so that it loads exactly once. The prerendered page writes asset
paths relative to its depth and the client resolves them absolute; a
server-rendered src was therefore replaced at hydration and the framed page
loaded twice, its first load cut off. The address is set on the client only.
==============================================================================
-->

<script>
	import { onMount } from 'svelte';

	/**
	 * @type {{
	 *   src: string,
	 *   title: string,
	 *   class?: string,
	 *   height?: number,
	 *   frame?: HTMLIFrameElement
	 * }}
	 */
	let { src, title, class: className = '', height, frame = $bindable() } = $props();

	onMount(() => {
		frame.src = src;
	});
</script>

<iframe
	bind:this={frame}
	class={className}
	{title}
	style={height === undefined ? undefined : 'height:' + height + 'px'}
></iframe>
