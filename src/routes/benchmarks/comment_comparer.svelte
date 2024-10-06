<script>
	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import SFB from '$lib/composants/SFB.svelte';
</script>

<section class="contenu">
	<h2 data-aos="zoom-out" data-aos-mirror="true">Comment bien utiliser KLAnext</h2>
	<p>
		Pour bien utiliser des comparateurs de disposition, il faut <span class="important"
			>comparer ce qui est comparable</span
		>. Ceci est très important, car si vous ne le faites pas, alors vos résultats n’auront aucune
		valeur.
	</p>
	<mini-espace />
	<h3 data-aos="fade-right" data-aos-mirror="true">Comparer le même type de clavier</h3>
	<p>
		Ne comparez pas une disposition ISO avec une disposition Ergodox. Sinon, logiquement la
		disposition Ergodox sera mieux notée. Elle aura en effet une distance aux touches moindre, car
		les pouces seront beaucoup plus mis à contribution. En outre, les <SFB />s seront diminués, car
		<kbd>Shift</kbd>, <kbd>Enter</kbd>, etc. ne seront plus sur les auriculaires mais sur les
		pouces.
	</p>

	<mini-espace />
	<h3 data-aos="fade-right" data-aos-mirror="true">
		Comparer des claviers possédant une touche pour tous les caractères du corpus
	</h3>
	<p>
		Un autre point à bien faire attention est de <span class="important"
			>s’assurer que toutes les lettres soient bien dans les dispositions à comparer</span
		>. Une disposition faite pour la langue anglaise aura de très bons scores pour des textes
		français. Cela s’explique parce que tous les caractères accentués seront "sautés", n’existant
		pas dans la disposition anglophone.
	</p>

	<mini-espace />
	<h3 data-aos="fade-right" data-aos-mirror="true">
		Conclusion sur la comparaison de dispositions
	</h3>
	<p>
		Comparer des dispositions n’est pas aussi simple qu’on pourrait de prime abord le penser. Il ne
		suffit pas de balancer son texte et sa disposition dans un comparateur et de le faire tourner.
	</p>

	<p>
		En outre, la philosophie derrière la construction du clavier doit être prise en compte.
		Certaines dispositions comme Optimot préfèrent mettre l’apostrophe droite en accès direct plutôt
		que celle typographique, partant du principe que la plupart des éditeurs de texte la
		remplaceront de toute manière par l’apostrophe typographique. Dans ce cas précis, le caractère
		faisant office d’"apostrophe" est l’apostrophe droite, alors que d’autres dispositions comme une
		version précédente d’<Nom /> font la distinction entre les deux.
	</p>
	<p>
		Pour comparer avec le plus d’exactitude les dispositions, il faudrait alors les modifier pour
		soit remplacer l’apostrophe typographique par une apostrophe droite, soit en ajoutant une
		apostrophe typographique dans la disposition n’en ayant pas.
	</p>
	<p class="important">
		➜ Comparer ce qui est comparable. Si le symbole n’existe pas dans la disposition, la touche ne
		sera pas tapée.
	</p>
</section>

<section class="contenu">
	<h2 data-aos="zoom-out" data-aos-mirror="true">La question du corpus</h2>
	<p>
		Maintenant que vous avez été avertis sur comment bien comparer des dispositions, il reste encore
		la <span class="important">question fondamentale du corpus</span>. Effectivement, vos résultats
		vont sensiblement différer selon le corpus utilisé. Un corpus avec beaucoup de dialogues aura
		beaucoup de "je", un corpus plus "sérieux" aura beaucoup de z dû au vouvoiement tandis qu’un
		corpus parlant de trains aura plus de <kbd>W</kbd> dû à une fréquence plus élevée du mot "wagon".
	</p>
	<p>
		Évidemment, plus votre corpus sera volumineux, plus vos résultats seront crédibles. Toutefois,
		cela augmentera d’autant les temps de calcul.
	</p>

	<p>
		En conclusion, <span class="important"
			>ne prenez les résultats des benchmarks que comme des tendances générales</span
		>. Une disposition meilleure de 2,48% sur un certain corpus n’implique pas que la disposition
		soit meilleure de 2,48% en général. En outre, passé une certaine performance, les gains sont
		marginaux.
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
		majuscule d’une lettre soit en Shift + Lettre. Pourtant, il serait tout à fait possible que cela
		ne soit pas le cas, mais cela impliquerait alors d’apprendre deux fois plus de choses : où sont
		les lettres, et où sont les majuscules. Tout cela pour peu de gains si ce n’est d’avoir un score
		légèrement supérieur sur les comparateurs de dispositions.
	</p>
</section>
