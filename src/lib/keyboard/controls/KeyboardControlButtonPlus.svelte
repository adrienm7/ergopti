<script>
	import { createEventDispatcher } from 'svelte';
	const dispatch = createEventDispatcher();

	export let plusValue;
	export let layerValue;

	function togglePlus() {
		let newPlus,
			newLayer = layerValue;

		if (plusValue === 'yes') {
			newPlus = 'no';

			// Reset the layer if it is specific to Ergopti+
			if (layerValue === 'À' || layerValue === 'Layer') {
				newLayer = 'Visuel';
			}
		} else {
			newPlus = 'yes';
		}

		plusValue = newPlus;
		layerValue = newLayer;

		dispatch('message', {
			plus: newPlus,
			layer: newLayer
		});
	}
</script>

<keyboard-control-plus>
	<button onclick={togglePlus}>
		{#if plusValue === 'yes'}
			<p><span class="hyper">Plus</span>&nbsp;➜ Standard</p>
		{:else}
			<p>Standard ➜&nbsp;<span class="hyper" style="padding:0; margin:0">Plus</span></p>
		{/if}
	</button>
</keyboard-control-plus>
