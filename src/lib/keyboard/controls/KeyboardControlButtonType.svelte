<script>
	import { createEventDispatcher, onMount } from 'svelte';
	const dispatch = createEventDispatcher();

	export let plusValue;
	export let typeValue;
	export let colorValue;
	export let layerValue;

	function toggleType() {
		if (typeValue === 'iso') {
			typeValue = 'ergodox';
		} else {
			typeValue = 'iso';
		}
		dispatch('message', {
			plus: plusValue,
			type: typeValue,
			color: colorValue,
			layer: layerValue
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
