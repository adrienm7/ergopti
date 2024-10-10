<script>
	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import SFB from '$lib/composants/SFB.svelte';
</script>

<h2>Autocritiques</h2>

<h3>L’importance des compromis</h3>
<p>
	Il n’est évidemment pas possible de maximiser tous ces paramètres en même temps. Par conséquent,
	certains choix ont dus être faits.
</p>
<p>
	Notamment, le <kbd>E</kbd> n’est pas sur l’index de la rangée de repos. Ce qui est pourtant
	étrange, tant son apparition est fréquente dans les textes. C’est la lettre la plus fréquente et
	de loin. Pourtant, elle ne se trouve pas sur l’index notamment afin de réduire les <SFB />s. Si le
	<kbd>E</kbd>
	avait été sur l’index, alors les 6 touches tapées par ce doigt auraient possiblement fait des <SFB
	/>s avec le <kbd>E</kbd>. <kbd>E</kbd> s’associe avec quasiment toutes les lettres, donc ce serait
	une très mauvaise idée. Au contraire, la voyelle <kbd>U</kbd>
	ne s’associe pas avec beaucoup de lettres, donc elle est bien mieux à cet emplacement. D’autant que
	cet arrangement des voyelles permet alors de très bons roulements.
</p>

<h3>Points d’amélioration</h3>
<p>
	Bien que largement supérieure à certaines dispositions telles que l’AZERTY et même le BÉPO, <Nom
	/> est malheureusement encore loin d’être parfaite. En effet, la création d’une disposition est une
	affaire de compromis, il est impossible de maximiser tous les aspects, car en maximisant le critère
	de distance aux touches, le <kbd>E</kbd> serait logiquement sur l’index, voire le pouce. Or, avoir
	cela engendrera beaucoup plus de <SFB />s, ce qui rendra impossible la maximisation de ce seconde
	critère.
</p>
<p>
	En outre, parfois tous les emplacements sont mauvais pour une touche, et il faut choisir le moins
	pire. Par conséquent, <Nom /> a évidemment des défauts, dont voici les principaux :
</p>

<h4>Distances non optimales</h4>
<ul>
	<li><kbd>E</kbd> est sur le majeur et non sur l’index.</li>
	<p>
		Théoriquement, l’index est plus fort et devrait donc être l’endroit idéal pour la lettre <kbd
			>E</kbd
		> qui est de loin la lettre la plus fréquente, loin devant la deuxième lettre la plus fréquente de
		l’alphabet.
	</p>
</ul>

<h4><SFB />s</h4>
<ul>
	<li>
		<kbd>SC</kbd> engendre beaucoup de <SFB />s, mais c’est à la moins pire combinaison (en
		fréquence d’apparition, NC > CR > CT > SC) et est en plus sur l’index qui est un doigt fort
		alors que le pire aurait été que cela soit sur l’annulaire ou l’auriculaire.
	</li>
	<li><kbd>PT</kbd></li>
	<li>
		<kbd>EO</kbd> et <kbd>OE</kbd> bien qu’inexistants en français, sont relativement fréquents en anglais
		(people, does)
	</li>
	<li>
		<kbd>K</kbd> est assez loin sur clavier ISO, surtout pour l’anglais avec ses <kbd>SK</kbd>,
		<kbd>CK</kbd>, etc.
	</li>
</ul>

<h4>Alternance des mains non maximale</h4>
<ul>
	<li>
		<kbd>W</kbd> devrait théoriquement plutôt être du côté droit du clavier car cette lettre est
		souvent précédée ou suivie d’une voyelle. Toutefois, la mettre sur l’index gauche permet de
		mettre cette lettre sur un excellent emplacement tout en n’entrainant aucun <SFB /> supplémentaire
		sur l’index gauche. Ainsi, la distance des doigts aux touches s’en trouve diminuée, et des roulements
		très confortables sont introduits.
	</li>
</ul>

<h4>Autres critiques</h4>
<p>
	Certaines dispositions telles qu’Optimot préfèrent mettre en accès direct l’apostrophe (single
	quote) plutôt que l’apostrophe typographique. Ceci car elle est souvent remplacée automatiquement
	dans les éditeurs de texte. Toutefois, la conversion des apostrophes en apostrophes typographiques
	est loin d’intervenir partout. Par exemple, elle ne se produit pas dans Discord, Messenger, Gmail
	et bien d’autres sites voire applications. Dans les premières versions d’<Nom />, une touche
	<kbd>’</kbd>
	avait donc été ajoutée. Dans les dernières versions elle a cependant été enlevée au profit de la
	touche inédite <kbd>★</kbd>.
</p>
<p>
	<Nom></Nom> possède peu de touches mortes et de couches de symboles. En effet, la disposition ne se
	prétend pas être exhaustive en incorporant tous les alphabets des langueus européennes comme le BÉPO,
	ou encore l’écriture phonétique comme Optimot. Ces couches n’intéressent que peu d’utilisateurs et
	occupent des emplacements du clavier très accessibles pour une utilisation très rare. La philosophie
	derrière <Nom /> est de fournir une base de réflexion, mais pas nécessairement de promouvoir l’utilisation
	de la disposition « HyperTexte ». Rien ne vaut une disposition créée sur-mesure pour vos usages. Si
	vous utilisez énormément Latex, peut-être voudrez-vous ramener le \ encore plus proche de vos doigts.
	De même, si vous voulez écrire régulièrement en allemand, il serait judicieux de mettre la touche morte
	des trémats à un endroit plus accessible.
</p>
