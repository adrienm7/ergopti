<script>
	import { createEventDispatcher } from 'svelte';
	const dispatch = createEventDispatcher();

	export let typeValue;
	export let layerValue;
	export let couleurValue;
	export let plusValue;

	function togglePlus() {
		if (plusValue === 'yes') {
			plusValue = 'no';
			if (layerValue === 'À' || layerValue === 'Layer') {
				// Dans le cas où l’on est sur une couche spécifique à Ergopti+, on change la couche pour une qui existe dans la version standard
				layerValue = 'Visuel';
			}
		} else {
			plusValue = 'yes';
		}
		dispatch('message', {
			type: typeValue,
			layer: layerValue,
			couleur: couleurValue,
			plus: plusValue
		});
	}
</script>

<keyboard-control-plus>
	<button on:click={togglePlus}>
		{#if plusValue === 'yes'}
			{@html '<p><span class="hyper">Plus</span>&nbsp;➜ Standard</p>'}
		{:else}
			{@html '<p>Standard ➜&nbsp;<span class="hyper" style = "padding:0; margin:0">Plus</span></p>'}
		{/if}
	</button>
</keyboard-control-plus>
