<script>
	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import SFB from '$lib/composants/SFB.svelte';
</script>

<div class="main">
	<h1 data-aos="zoom-in">Benchmarks</h1>
	<hr class="margin-h1" />

	<p>
		Il existe de nombreux comparateurs de dispositions, certains ayant même une interface en ligne.
		Le site <span class="important">KLAnext</span> est l’un d’entre eux et est gratuitement
		accessible à l’adresse
		<a href="https://klanext.keyboard-design.com">https://klanext.keyboard-design.com</a>. C’est
		l’un des comparateurs en ligne les plus utilisés en raison de son algorithme de notation qui
		serait "meilleur" que ses autres dérivés en ligne. C’est par exemple ce qui est dit
		<a href="https://sites.google.com/alanreiser.com/handsdown/home/statistics">ici</a>.
	</p>
	<p>
		Toutefois, de nouveaux analyseurs émergent régulièrement et prennent en compte de nouvelles
		métriques comme les ciseaux, les roulements, etc. non analysées par KLAnext. L’<a
			href="https://ergol.org/stats/">analyseur d’Ergo‑L</a
		> est par exemple très complet, mais nécessite de cloner leur projet GitHub en local et créer un
		fichier de disposition. Il n’y a pas d’interface graphique simple comme KLAnext par exemple.
	</p>
</div>
