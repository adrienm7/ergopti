<script>
	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import SFB from '$lib/composants/SFB.svelte';

	import { version } from '$lib/stores_infos.js';
	let versionValue;
	version.subscribe((value) => {
		versionValue = value;
	});
</script>

<h2>
	Analyse de la vraie disposition<br /><NomPlus></NomPlus>
</h2>
<p>
	Une réelle analyse de <NomPlus></NomPlus> nécessite de modifier le corpus afin d’y refléter les nouvelles
	manières de taper les touches. Par exemple, il faut modifier toutes les doubles lettres du corpus pour
	les remplacer par la lettre suivie de <kbd>★</kbd>. De même, tous les <SFB></SFB>s pris en charge
	par <NomPlus></NomPlus>, comme <kbd-sortie>pt</kbd-sortie> en
	<kbd>,t</kbd>, doivent être remplacés. Un
	<a href="/corpus/conversion_corpus.py">simple script Python</a> permet de faire ces modifications.
</p>
<p>
	Toutefois, modifier le corpus rend la comparaison avec les autres dispositions plus compliquée,
	car ce ne sera pas le même corpus pour toutes. Utiliser le même corpus modifié pour les autres
	dispositions peut engendrer des très bonnes performances chez elles, ceci car la touche <kbd
		>★</kbd
	> ne sera pas parmi leurs touches et sera donc systématiquement ignorée, améliorant sensiblement leurs
	stats.
</p>
<p>
	Voici les résultats de <NomPlus></NomPlus> obtenus sur le corpus français-anglais Essais :
</p>
<bloc-image>
	<enhanced:img
		src="$lib/benchmarks/plus/ergopti+_reduction_SFBs.jpg"
		alt="Screenshot de benchmark Ergopti+"
	/>
</bloc-image>
<h3>Analyse des <SFB></SFB>s</h3>
<p>
	Cette analyse met en lumière la quasi-suppression des <SFB></SFB>s, avec une valeur d’environ 3.
	Pour rappel, la valeur de cette métrique avec un corpus non modifié est de 25 pour la même
	disposition. Ainsi, l’utilisation d’<NomPlus></NomPlus> divise par environ 8 le nombre de <SFB
	></SFB>s d’<Nom></Nom>.
</p>
<p>Voici une vue plus détaillée (attention, les axes des ordonnées ne sont pas les mêmes) :</p>
<h4><Nom></Nom></h4>
<bloc-image>
	<enhanced:img src="$lib/benchmarks/plus/SFBs_ergopti.jpg" alt="SFBs de la disposition Ergopti" />
</bloc-image>
<h4><NomPlus></NomPlus></h4>
<bloc-image>
	<enhanced:img
		src="$lib/benchmarks/plus/SFBs_ergopti+.jpg"
		alt="SFBs de la disposition Ergopti+"
	/>
</bloc-image>
<p>
	Plusieurs <SFB></SFB>s se produisent maintenant sur l’index gauche en <kbd>★,</kbd> et
	<kbd>★.</kbd>, même s’ils sont déjà deux fois moins nombreux qu’avec <NomPlus></NomPlus>. Il y a
	sans doute possiblité d’améliorer cela, c’est un point à l’étude. En dehors de cela, les
	réductions de <SFB></SFB>s sont spectaculaires, en particulier sur les annulaires et auriculaires.
	Enfin, l’index droit voit son nombre de <SFB></SFB>s chuter drastiquement, de 27 000 à 2500, soit
	une division par 10 !
</p>
<h3>Analyse de la distance parcourue</h3>
<p>
	Les gains de touches tapées ne sont pas reflétés sur la capture d’écran de résumé des scores. Avec
	le corpus normal, nous avions 50 306 touches tapées par <Nom></Nom>. Ce nombre tombe à 45 525
	touches tapées avec <NomPlus></NomPlus>. Le gain de 10% s’explique probablement surtout par les
	raccourcis de suffixes en
	<kbd>À</kbd>.
</p>
<p>
	Ce gain peut paraître dérisoire, mais c’est quand même un gain de 10% de touches en moins à taper
	! Ou autrement dit une augmentation de la vitesse de 10% sans effort (si ce n’est mémoriser les
	raccourcis de <NomPlus></NomPlus>).
</p>
<p>
	La réduction du nombre de touches à taper peut encore s’accroître en personnalisant sa disposition
	pour y ajouter ses propres raccourcis. Dans la version <NomPlus></NomPlus> testés, seule une petite
	vingtaine de mots très courants ont été remplacés par un raccourci. Parmi ceux-ci :
	<kbd-sortie>ainsi</kbd-sortie>
	en <kbd>a★</kbd>, <kbd-sortie>exemple</kbd-sortie> en <kbd>x★</kbd> et
	<kbd-sortie>faire</kbd-sortie>
	en <kbd>f★</kbd>.
</p>
<h3>Analyse de la fréquence d’utilisation des doigts</h3>
<bloc-image>
	<enhanced:img
		src="$lib/benchmarks/plus/finger_usage_comparison.jpg"
		alt="Comparaison de la fréquence d’utilisation des doigts"
	/>
</bloc-image>
<p>
	Comme vous pouvez le constater sur l’image ci-dessous, l’index gauche est plus utilisé (6% vs 8%)
	avec <NomPlus></NomPlus>. Cela vient des nombreuses utilisations de la touche
	<kbd>★</kbd>, dont la fréquence d’utilisation est désormais comparable à celle de la touche
	<kbd>É</kbd>, soit un peu moins de 2%.
</p>
