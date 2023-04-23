<script>
	import { createEventDispatcher, onMount } from 'svelte';
	const dispatch = createEventDispatcher();

	export let typeValue;
	export let coucheValue;
	export let couleurValue;
	export let plusValue;

	function toggleType() {
		if (typeValue === 'iso') {
			typeValue = 'ergodox';
		} else {
			typeValue = 'iso';
		}
		dispatch('message', {
			type: typeValue,
			couche: coucheValue,
			couleur: couleurValue,
			plus: plusValue
		});
	}
</script>

<button on:click={toggleType}>
	{#if typeValue === 'ergodox'}
		{@html '<p><span class="ergodox-text-gradient">Ergodox</span> ➜&nbsp;ISO</p>'}
	{:else}
		{@html '<p>ISO&nbsp;➜ <span class="ergodox-text-gradient">Ergodox</span></p>'}
	{/if}
</button>
