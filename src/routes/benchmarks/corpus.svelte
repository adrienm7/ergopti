<script>
	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import SFB from '$lib/composants/SFB.svelte';
</script>

<h2>La question du corpus</h2>
<p>
	Maintenant que vous avez été avertis sur comment bien comparer des dispositions, il reste encore
	la <span class="important">question fondamentale du corpus</span>. Effectivement, vos résultats
	vont sensiblement différer selon le corpus utilisé. Un corpus avec beaucoup de dialogues aura
	beaucoup de "je", un corpus plus "sérieux" aura beaucoup de z dû au vouvoiement tandis qu’un
	corpus parlant de trains aura plus de <kbd>W</kbd> dû à une fréquence plus élevée du mot "wagon".
</p>
<p>
	Évidemment, plus votre corpus sera volumineux et diversifié, plus vos résultats seront crédibles.
	Toutefois, cela augmentera d’autant les temps de calcul.
</p>

<mini-espace></mini-espace>

<p>
	En conclusion, <span class="important"
		>ne prenez les résultats des benchmarks que comme des tendances générales</span
	>. Une disposition meilleure de 2,48% sur un certain corpus n’implique pas que la disposition soit
	meilleure de 2,48% en général. En outre, passé une certaine performance, les gains sont marginaux.
</p>
<p>
	Par exemple, il serait probablement possible d’améliorer encore les résultats de <Nom /> sur KLAnext,
	mais cela se ferait au détriment d’autres choses pas forcément quantifiables comme le comfort général
	ou la disparition de certains roulements. Autre exemple, certaines dispositions optimisent tellement
	que les chiffres ne sont pas dans l’ordre mais plutôt du genre 3210987654. Cela rend la disposition
	beaucoup moins logique et donc plus difficile à apprendre, pour seulement optimiser légèrement leurs
	scores.
</p>
<p>
	Il serait aussi possible de faire cela pour les majuscules. Cela nous paraît évident que la
	majuscule d’une lettre soit en <kbd>Shift</kbd> + <kbd>Lettre</kbd>. Pourtant, il serait tout à
	fait possible que cela ne soit pas le cas, notamment pour optimiser les <SFB></SFB>s. Toutefois,
	cela impliquerait dans ce cas d’apprendre deux fois plus de choses : où sont les lettres, et où
	sont les majuscules. Tout cela pour peu de gains si ce n’est d’avoir un score légèrement supérieur
	sur les comparateurs de dispositions.
</p>
