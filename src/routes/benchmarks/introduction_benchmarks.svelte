<script>
	import Ergopti from '$lib/components/Ergopti.svelte';
	import ErgoptiPlus from '$lib/components/ErgoptiPlus.svelte';
	import SFB from '$lib/components/SFB.svelte';
</script>

<section class="main">
	<h1 data-aos="zoom-in">Benchmarks</h1>
	<hr class="margin-h1" />

	<p>
		Il existe de nombreux comparateurs de dispositions, certains ayant même une interface en ligne.
		Le site <strong>KLAnext</strong> est l’un d’entre eux et a l’avantage d’être très simple
		d’utilisation. Il est gratuitement accessible à l’adresse
		<a href="https://klanext.keyboard-design.com" target="_blank" class="link"
			>https://klanext.keyboard-design.com</a
		>. C’est l’un des comparateurs en ligne les plus utilisés en raison de son algorithme de
		notation qui serait "meilleur" que ses autres dérivés en ligne. C’est par exemple ce qui est dit
		<a
			class="link"
			href="https://sites.google.com/alanreiser.com/handsdown/home/statistics"
			target="_blank">ici</a
		>.
	</p>
	<p>
		Toutefois, de nouveaux analyseurs émergent régulièrement et prennent en compte de nouvelles
		métriques comme les ciseaux, les roulements, etc. non analysées par KLAnext. Ces autres
		métriques sont également très importantes et leur non prise en compte dans KLAnext peut conduire
		à des résultats biaisés. L’<a href="https://ergol.org/stats/" target="_blank" class="link"
			>analyseur d’Ergo‑L</a
		> est par exemple beaucoup plus complet. Toutefois, il nécessite de cloner leur projet GitHub en
		local et de créer son fichier de disposition. Il n’a pas d’interface graphique simple comme KLAnext.
	</p>
</section>
