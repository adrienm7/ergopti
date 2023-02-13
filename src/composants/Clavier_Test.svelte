<script>
	import Base_Clavier from './Base_Clavier.svelte';
	import Controles_Clavier from '../composants/Controles_Clavier.svelte';
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
				couleur: couleur,
				plus: plus
			}
		});
	});
</script>

<div class="center">
	<bloc-clavier id={emplacement}>
		<Base_Clavier />
	</bloc-clavier>

	<mini-espace />

	{#if controles}
		<Controles_Clavier {emplacement} {type} {couche} {plus} {couleur} />
	{/if}
</div>

<style>
	.center {
		display: flex;
		flex-direction: column;
		justify-content: space-around;
	}
</style>
