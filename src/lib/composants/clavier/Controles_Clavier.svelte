<script>
	import { construct_svelte_component } from 'svelte/internal';

	export let data;
	export let emplacement;
	export let type;
	export let couche;
	export let couleur;
	export let plus;
	export let controles;

	// let options = ['Visuel', 'Primary', 'Shift', 'AltGr', 'ShiftAltGr', 'layer', 'à'];
	let options = [
		['Visuel', 'Visuel'],
		['Primary', 'Primary'],
		['Shift', 'Shift'],
		['AltGr', 'AltGr'],
		['Shift + AltGr', 'ShiftAltGr'],
		['Layer', 'layer'],
		['Touche À', 'à']
	];
</script>

<controles-clavier class="btn-group">
	<select bind:value={couche} on:change={() => changerCouche(couche)}>
		{#each options as value}<option value={value[1]}>{value[0]}</option>{/each}
	</select>
	<button on:click={togglePlus} data-button="plus">
		{plus === 'oui' ? 'Plus ➜ Standard' : 'Standard ➜ Plus'}
	</button>
	<button on:click={toggleCouleur} data-button="couleur">
		{couleur === 'oui' ? 'Couleur ➜ Noir et blanc' : 'Noir et blanc ➜ Couleur'}
	</button>
	<button on:click={toggleIso} data-button="type">
		{type === 'iso' ? 'ISO ➜ Ergodox' : 'Ergodox ➜ ISO'}
	</button>
</controles-clavier>
