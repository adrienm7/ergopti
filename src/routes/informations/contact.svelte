<script>
	import Ergopti from '$lib/components/Ergopti.svelte';
	import ErgoptiPlus from '$lib/components/ErgoptiPlus.svelte';
	import SFB from '$lib/components/SFB.svelte';
	import { discordLink } from '$lib/stores_infos.js';
</script>

<section>
	<h2>Contact</h2>
	<div class="encadre">
		<p class="text-center margin0">
			Le créateur de la disposition <Ergopti /> et de ce site est <strong>Adrien MOYAUX</strong>.
		</p>
		<p>
			Vous pouvez créer une nouvelle <em>Issue</em> sur
			<a class="link" href="https://github.com/adrienm7/ergopti">la page GitHub du projet</a> si vous
			avez une question ou un problème, notamment pour l’installation.
		</p>
		<p class="margin0">
			Il est aussi possible de rejoindre le <a class="link" href={discordLink}
				>serveur Discord BÉPO | Ergodis</a
			>
			où <Ergopti></Ergopti> dispose d’un canal dédié, simplifiant les échanges.
		</p>
	</div>
</section>
