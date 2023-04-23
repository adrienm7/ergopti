<script>
	import { createEventDispatcher } from 'svelte';
	const dispatch = createEventDispatcher();

	export let typeValue;
	export let coucheValue;
	export let couleurValue;
	export let plusValue;

	function toggleCouleur() {
		if (couleurValue === 'oui') {
			couleurValue = 'non';
		} else {
			couleurValue = 'oui';
		}
		dispatch('message', {
			type: typeValue,
			couche: coucheValue,
			couleur: couleurValue,
			plus: plusValue
		});
	}
</script>

<button on:click={toggleCouleur}>
	{#if couleurValue === 'oui'}
		{@html '<p><span class="red-text-gradient">Couleur</span>&nbsp;➜ Noir&nbsp;et blanc</p>'}
	{:else}
		{@html '<p>Noir&nbsp;et blanc ➜&nbsp;<span class="red-text-gradient">Couleur</span></p>'}
	{/if}
</button>
