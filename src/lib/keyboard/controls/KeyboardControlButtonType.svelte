<script>
	import { createEventDispatcher, onMount } from 'svelte';
	const dispatch = createEventDispatcher();

	export let typeValue;
	export let layerValue;
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
			layer: layerValue,
			couleur: couleurValue,
			plus: plusValue
		});
	}
</script>

<keyboard-control-type>
	<button on:click={toggleType}>
		{#if typeValue === 'ergodox'}
			{@html '<p><span class="ergodox-text-gradient">Ergodox</span> ➜&nbsp;ISO</p>'}
		{:else}
			{@html '<p>ISO&nbsp;➜ <span class="ergodox-text-gradient">Ergodox</span></p>'}
		{/if}
	</button>
</keyboard-control-type>
