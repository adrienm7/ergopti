<script>
	import * as stores_infos from '$lib/stores_infos.js';

	export let id;

	let plusValue;
	let layerValue;

	stores_infos[id].subscribe((config) => {
		plusValue = config.plus;
		layerValue = config.layer;
	});

	function togglePlus() {
		let newPlus;
		let newLayer = layerValue;

		if (plusValue === 'yes') {
			newPlus = 'no';

			// Reset the layer if it is specific to Ergopti+
			if ([',', 'À', 'Layer'].includes(layerValue)) {
				newLayer = 'Visuel';
			}
		} else {
			newPlus = 'yes';
		}

		stores_infos[id].update((current) => ({
			...current,
			plus: newPlus,
			layer: newLayer
		}));
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
