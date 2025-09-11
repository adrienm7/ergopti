<script lang="ts">
	export let plusValue: string;
	export let layerValue: string;
	export let updateConfig: (partial: { plus: string; layer: string }) => void;

	function togglePlus() {
		let newPlus: string;
		let newLayer: string = layerValue;

		if (plusValue === 'yes') {
			newPlus = 'no';

			// Reset the layer if it is specific to Ergopti+
			if ([',', 'À', 'Layer'].includes(layerValue)) {
				newLayer = 'Visuel';
			}
		} else {
			newPlus = 'yes';
		}

		updateConfig({
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
