<script>
	import '$lib/css/clavier.css';
</script>

<bloc-clavier>
	{#each Array(5) as _, i}
		<bloc-ligne data-ligne={i + 1}>
			{#each Array(16) as _, j}
				<bloc-touche data-touche="vide" data-ligne={i + 1} data-colonne={j} style="--taille: 1;">
					<div>&nbsp;</div>
				</bloc-touche>
			{/each}
		</bloc-ligne>
	{/each}
</bloc-clavier>
