<script>
	import '$lib/clavier/BlocClavier.css';
	import { Clavier } from '$lib/clavier/Clavier.js';
	import { onMount } from 'svelte';

	export let nom;
	let clavier = new Clavier(nom);
</script>

<bloc-clavier id={'clavier_' + nom}>
	{#each Array(7) as _, i}
		<bloc-ligne data-ligne={i + 1}>
			{#each Array(16) as _, j}
				<bloc-touche data-touche="vide" data-ligne={i + 1} data-colonne={j} style="--taille: 1;">
					<div>&nbsp;</div>
				</bloc-touche>
			{/each}
		</bloc-ligne>
	{/each}
</bloc-clavier>
