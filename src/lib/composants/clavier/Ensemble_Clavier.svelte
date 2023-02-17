<script>
	import Bloc_Clavier from './Bloc_Clavier.svelte';
	import Controles_Clavier from './Controles_Clavier.svelte';
	import hypertexte from '$lib/data/hypertexte.json';
	import { majClavier } from '$lib/js/clavier.js';
	import { onMount } from 'svelte';

	export let emplacement;
	export let type;
	export let couche;
	export let couleur;
	export let plus;
	export let controles;

	onMount(() => {
		majClavier({
			emplacement: emplacement,
			data: hypertexte,
			config: {
				type: type,
				couche: couche,
				plus: plus,
				controles: controles
			}
		});
	});
</script>

<ensemble-clavier id={emplacement} class="center" data-couleur={couleur}>
	<Bloc_Clavier />
	{#if controles}
		<mini-espace />
		<Controles_Clavier {emplacement} {type} {couche} {plus} {couleur} {controles} />
	{/if}
</ensemble-clavier>

<style>
	.center {
		display: flex;
		flex-direction: column;
		justify-content: space-around;
	}
</style>
