<script>
	import * as stores_infos from '#lib/stores_infos.js';
	import { onDestroy } from 'svelte';

	export let id;

	const extraLayers = [
		['★ Navigation', 'Layer'],
		['★ Virgule', ','],
		['★ Suffixes (À)', 'À']
	];

	let layerValue;
	let availableLayers = [];
	let config;
	// The levels of the shown layout come with its data (level_labels).
	let levelLabels = [];

	function refresh() {
		if (!config) return;
		const baseLayers = [['Visuel', 'Visuel'], ...levelLabels];
		layerValue = config.layer;
		availableLayers = config.plus === 'yes' ? baseLayers.concat(extraLayers) : baseLayers;
	}

	stores_infos[id].subscribe((current) => {
		config = current;
		refresh();
	});
	const stopLayout = stores_infos.layoutData.subscribe((data) => {
		if (!data) return;
		if (!Array.isArray(data.level_labels))
			throw new Error(`The layout data of ${data.name} names no level_labels`);
		levelLabels = data.level_labels.map(({ label, level }) => [label, level]);
		refresh();
	});
	onDestroy(stopLayout);

	function changeLayer(newLayer) {
		stores_infos[id].update((current) => ({
			...current,
			layer: newLayer
		}));
	}
</script>

<div class="keyboard-control-layer">
	<select
		id={'keyboard-layer-' + id}
		bind:value={layerValue}
		onchange={() => changeLayer(layerValue)}
		aria-label="Couche affichée sur le clavier"
	>
		{#each availableLayers as [label, value]}
			<option {value}>{label}</option>
		{/each}
	</select>
</div>
