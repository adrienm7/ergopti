<script>
	import * as stores_infos from '$lib/stores_infos.js';

	export let id;

	const baseLayers = [
		['Visuel', 'Visuel'],
		['➀ Primaire', 'Primary'],
		['➁ Shift', 'Shift'],
		['➂ AltGr', 'AltGr'],
		['➃ Shift + AltGr', 'ShiftAltGr'],
		['Ctrl', 'Ctrl'],
		['Circonflexe', 'Circonflexe'],
		['Circonflexe ⇧', 'CirconflexeShift'],
		['Tréma', 'Trema'],
		['Tréma ⇧', 'TremaShift'],
		['Exposant', 'Exposant'],
		['Indice', 'Indice'],
		['Grec', 'Greek'],
		['Grec ⇧', 'GreekShift'],
		['ℝ', 'R'],
		['ℝ ⇧', 'RShift'],
		['Currency', 'Currency'],
		['Currency ⇧', 'CurrencyShift']
	];

	const extraLayers = [
		['★ Layer', 'Layer'],
		['★ Virgule', ','],
		['★ À', 'À']
	];

	let layerValue;
	let availableLayers;

	stores_infos[id].subscribe((config) => {
		layerValue = config.layer;
		availableLayers = config.plus === 'yes' ? baseLayers.concat(extraLayers) : baseLayers;
	});

	function changeLayer(newLayer) {
		stores_infos[id].update((current) => ({
			...current,
			layer: newLayer
		}));
	}
</script>

<keyboard-control-layer>
	<select bind:value={layerValue} on:change={() => changeLayer(layerValue)}>
		{#each availableLayers as [label, value]}
			<option {value}>{label}</option>
		{/each}
	</select>
</keyboard-control-layer>
