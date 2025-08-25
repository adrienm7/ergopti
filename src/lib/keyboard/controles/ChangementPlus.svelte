<script>
	import { createEventDispatcher } from 'svelte';
	const dispatch = createEventDispatcher();

	export let typeValue;
	export let coucheValue;
	export let couleurValue;
	export let plusValue;

	function togglePlus() {
		if (plusValue === 'oui') {
			plusValue = 'non';
			if (coucheValue === 'À' || coucheValue === 'Layer') {
				// Dans le cas où l’on est sur une couche spécifique à Ergopti+, on change la couche pour une qui existe dans la version standard
				coucheValue = 'Visuel';
			}
		} else {
			plusValue = 'oui';
		}
		dispatch('message', {
			type: typeValue,
			couche: coucheValue,
			couleur: couleurValue,
			plus: plusValue
		});
	}
</script>

<button on:click={togglePlus}>
	{#if plusValue === 'oui'}
		{@html '<p><span class="hyper">Plus</span>&nbsp;➜ Standard</p>'}
	{:else}
		{@html '<p>Standard ➜&nbsp;<span class="hyper" style = "padding:0; margin:0">Plus</span></p>'}
	{/if}
</button>
