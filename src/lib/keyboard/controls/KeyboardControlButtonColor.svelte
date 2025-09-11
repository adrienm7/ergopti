<script>
	import { createEventDispatcher } from 'svelte';
	const dispatch = createEventDispatcher();

	export let colorValue;

	function toggleColor() {
		const newColor = colorValue === 'yes' ? 'no' : 'yes';
		colorValue = newColor;
		dispatch('message', { color: newColor });
	}
</script>

<keyboard-control-color>
	<button onclick={toggleColor}>
		{#if colorValue === 'yes'}
			<p><span class="color-text-gradient">Color</span>&nbsp;➜ Bicolor</p>
		{:else}
			<p>Bicolor ➜&nbsp;<span class="color-text-gradient">Color</span></p>
		{/if}
	</button>
</keyboard-control-color>
