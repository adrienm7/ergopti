<script>
	import { createEventDispatcher } from 'svelte';
	const dispatch = createEventDispatcher();

	export let plusValue;
	export let typeValue;
	export let colorValue;
	export let layerValue;

	function toggleCouleur() {
		if (colorValue === 'yes') {
			colorValue = 'no';
		} else {
			colorValue = 'yes';
		}
		dispatch('message', {
			plus: plusValue,
			type: typeValue,
			color: colorValue,
			layer: layerValue
		});
	}
</script>

<keyboard-control-color>
	<button on:click={toggleCouleur}>
		{#if colorValue === 'yes'}
			{@html '<p><span class="color-text-gradient">Couleur</span>&nbsp;➜ Bicolor</p>'}
		{:else}
			{@html '<p>Bicolor ➜&nbsp;<span class="color-text-gradient">Couleur</span></p>'}
		{/if}
	</button>
</keyboard-control-color>
