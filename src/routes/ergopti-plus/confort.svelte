<script>
	import Ergopti from '$lib/components/Ergopti.svelte';
	import ErgoptiPlus from '$lib/components/ErgoptiPlus.svelte';
	import SFB from '$lib/components/SFB.svelte';
</script>

<section>
	<h2>Confort</h2>

	<h3>
		Touche <kbd>BackSpace</kbd> à la place de <kbd>"LAlt"</kbd>
	</h3>
	<p>
		La touche <kbd>BackSpace</kbd> est l’une des touches les plus utilisées sur un clavier. En
		effet, elle permet de corriger une erreur, ce qui est très fréquent lors de la frappe d’un
		texte. Pourtant, sur les claviers standards, elle est extrêmement loin, étant placée tout en
		haut à droite. Par conséquent, il est logique de vouloir la mettre sur un emplacement très
		accessible. C’est pour cela que la touche <kbd>BackSpace</kbd> a été dupliquée sur la touche
		<kbd>"LAlt"</kbd> avec <ErgoptiPlus />.
	</p>
	<p>
		La touche <kbd-output>Delete</kbd-output> se trouve quant à elle sur la combinaison
		<kbd>Shift</kbd> + <kbd>"LAlt"</kbd>.
	</p>
	<p>
		Pour être encore plus confortable et rapide, deux raccourcis optionnels ont en outre été
		implémentés :
	</p>
	<ul>
		<li>
			<kbd>AltGr</kbd> + <kbd>"LAlt"</kbd> ➜ <kbd-output>Ctrl</kbd-output> +
			<kbd-output>BackSpace</kbd-output> ;
		</li>
		<li>
			<kbd>AltGr</kbd> + <kbd>"CapsLock"</kbd> ➜ <kbd-output>Ctrl</kbd-output> +
			<kbd-output>Delete</kbd-output>.
		</li>
	</ul>

	<h3>[QU] automatiques avant les voyelles</h3>
	<p>
		La touche <kbd>Q</kbd> est à 99% du temps suivie d’un <kbd>U</kbd> si une voyelle vient ensuite.
		Par conséquent, lors de la frappe de <kbd>Q</kbd> + <kbd>Voyelle</kbd>, un <kbd>U</kbd>
		s’intercale automatiquement entre les deux pour donner <kbd-output>Q</kbd-output> +
		<kbd-output>U</kbd-output>
		+ <kbd-output>Voyelle</kbd-output>.
	</p>
	<p>
		Ainsi, pour écrire <kbd-output>que</kbd-output>, il suffira d’écrire <kbd>qe</kbd>. De même,
		pour écrire <kbd-output>pourquoi</kbd-output>, il suffira d’écrire
		<kbd>pourqoi</kbd>.
	</p>

	<h3>Touche [OÙ]</h3>
	<p>
		La touche <kbd>Ù</kbd> n’est utilisée que pour écrire <kbd-output>où</kbd-output>. Ainsi, autant
		transformer cette touche en raccourci pour écrire <kbd-output>où</kbd-output> afin d’économiser
		une frappe certaine sur la touche <kbd>O</kbd> et améliorer l’alternance des mains.
	</p>
	<p>
		Ainsi, le <kbd-output>ù</kbd-output> en <kbd>AltGr</kbd> + <kbd>W</kbd> se transforme en
		<kbd-output>où</kbd-output> si <ErgoptiPlus></ErgoptiPlus> est activé.
	</p>

	<h3>
		<kbd>Ê</kbd> fait office de <kbd class="morte">◌̂</kbd>
	</h3>

	<p>
		La touche morte <kbd class="morte">◌̂</kbd> est utilisée la majorité du temps suivie de
		<kbd>E</kbd> afin d’écrire <kbd-output>Ê</kbd-output>. C’est pour cela qu’une touche
		<kbd>Ê</kbd>
		a été placée sur l’auriculaire gauche afin d’éviter un appui sur deux touches pour cette lettre circonflexe
		très commune. Elle demeure une touche optionnelle, ce qui explique son emplacement sur la 105e touche,
		qui n’existe pas sur les claviers ANSI. Ainsi, sur ce genre de claviers où cette touche n’existe
		pas, on peut toujours écrire <kbd-output>ê</kbd-output> en utilisant la touche morte.
	</p>
	<p>
		Toutefois, dans de rares cas, il est nécessaire d’écrire <kbd>Â</kbd>,
		<kbd>Î</kbd>, <kbd>Ô</kbd> ou encore <kbd>Û</kbd>. Ainsi, <kbd>ÊA</kbd> va donner
		<kbd-output>Â</kbd-output>, <kbd>ÊI</kbd> va donner <kbd-output>Î</kbd-output>, etc. Cela permet
		de ne plus du tout avoir à utiliser la touche morte <kbd class="morte">◌̂</kbd>, et donc bouger
		encore moins les mains.
	</p>
	<tiny-space></tiny-space>
	<p>
		Les plus attentifs d’entre vous remarqueront que l’écriture de <kbd-output>Â</kbd-output> et de
		<kbd-output>AÎ</kbd-output>
		(par exemple pour écrire « paraît ») engendre des <SFB></SFB>s avec cette nouvelle méthode.
		C’est pour cela qu’il est aussi possible de réaliser <kbd>éê</kbd> pour obtenir
		<kbd-output>â</kbd-output>
		et <kbd>êé</kbd> pour <kbd-output>aî</kbd-output>. Ces options offrent en outre des roulements
		extrêmement confortables sur des bigrammes qui n’existent pas et donc ne posent aucun problème.
	</p>
	<p>
		En outre, le mécanisme de correction automatique d’<ErgoptiPlus /> permet de donner
		<kbd-output>paraît</kbd-output>
		lors de l’écriture de <kbd>parait</kbd>, rendant ce <SFB /> encore plus inoffensif.
	</p>

	<h3>
		Remplacement automatique des <kbd>'</kbd> par <kbd>’</kbd>
	</h3>
	<p>
		Lorsqu’on écrit en français ou anglais, il faudrait idéalement utiliser l’apostrophe
		typographique plutôt que l’apostrophe droite. C’est pour cette raison qu’<ErgoptiPlus /> va automatiquement
		l’utiliser à la place de l’apostrophe droite lors de l’écriture de texte. Cette apostrophe est d’ailleurs
		plus jolie et présente l’avantage de ne pas avoir à être échappée en programmation si une chaîne
		de caractères est écrite avec ce caractère à l’intérieur. Il n’y a pas besoin de réfléchir : il suffit
		d’écrire normalement et l’apostrophe typographique apparaîtra automatiquement si c’est du texte qui
		est écrit et non du code. Les faux positifs devraient être extrêmement rares.
	</p>
	<p>
		Un autre raccourci a aussi été ajouté pour avoir la possibilité d’écrire <kbd-output
			>N'T</kbd-output
		>
		par un roulement. Effectivement, <kbd>nt'</kbd> se transforme en
		<kbd-output>n't</kbd-output> pour pouvoir faire [majeur, annulaire, auriculaire] plutôt que
		[majeur, auriculaire, annulaire]. Ce raccourci est utile pour réaliser les négations en anglais
		telles que <kbd-output>don't</kbd-output>, <kbd-output>won't</kbd-output> ou
		<kbd-output>can't</kbd-output>.
	</p>

	<h3>
		Utilisation de la touche <kbd>,</kbd> + <kbd>voyelle</kbd> en tant que <kbd>j</kbd>
	</h3>
	<p>
		La touche <kbd>j</kbd> minuscule se fait remplacer par <kbd class="glow">★</kbd> avec <ErgoptiPlus
		></ErgoptiPlus>. Cette nouvelle touche possède plusieurs fonctionnalités extrêmement utiles qui
		seront détaillées par la suite. Toutefois, elle prend la place du <kbd>j</kbd> et il convient
		donc de replacer ce caractère autre part. Il convient de noter que seul le caractère
		<kbd-output>j</kbd-output>
		change de place, la touche <kbd class="glow">j/★</kbd> restant une touche <kbd>J</kbd> dans tous
		les autres cas, que ce soit pour les raccourcis avec
		<kbd>Ctrl</kbd>
		(<kbd-output>Ctrl</kbd-output>
		+
		<kbd-output>J</kbd-output>), avec <kbd>Alt</kbd> (<kbd-output>Alt</kbd-output> +
		<kbd-output>J</kbd-output>), ou simplement les caractères en <kbd>AltGr</kbd> (<kbd-output
			>"</kbd-output
		>) ou en <kbd>Shift</kbd>
		(<kbd-output>J</kbd-output>).
	</p>
	<p>
		La touche <kbd>,</kbd> est alors utilisée pour réaliser cette substitution, celle-ci étant sur
		le même doigt que l’ancienne touche <kbd>J</kbd> et juste à côté de son ancien emplacement. Les
		combinaisons <kbd>,i</kbd>, <kbd>,e</kbd>, etc. n’existent pas en français. En réalité, la
		lettre
		<kbd>,</kbd> est systématiquement suivie d’un espace. Cela fournit une formidable opportunité
		d’utiliser cette touche comme un <kbd-output>j</kbd-output> lorsqu’elle est suivie d’une
		voyelle, et donc de remplacer efficacement la touche <kbd>j</kbd>.
	</p>
	<p>
		Dans les rares cas où l’on souhaite écrire <kbd>j</kbd> + <kbd>consonne</kbd>, il est possible
		d’écrire par exemple <kbd>ja</kbd> et de supprimer la voyelle. Une autre possibilité est de
		réaliser la suite de touches <kbd>,</kbd> + <kbd>à</kbd> qui donne la lettre
		<kbd-output>j</kbd-output>. Dernière possibilité, <kbd-output>j</kbd-output> est aussi présente
		nativement en <kbd>Shift</kbd> + <kbd>AltGr</kbd> +
		<kbd class="glow">j/★</kbd>. En fait, on pourrait même toujours utiliser cet emplacement en
		<kbd>Shift</kbd>
		+ <kbd>AltGr</kbd> sans utiliser l’astuce de la touche <kbd>,</kbd>, mais utiliser cette
		dernière permet une frappe plus rapide et plus fluide, car il suffit de taper sur <kbd>,</kbd> et
		non d’activer plusieurs modificateurs en même temps.
	</p>

	<p class="text-bold">En résumé :</p>
	<ul class="margin-top-2">
		<li><kbd>,a</kbd> ➜ <kbd-output>ja</kbd-output> ;</li>
		<li><kbd>,i</kbd> ➜ <kbd-output>ji</kbd-output> ;</li>
		<li><kbd>,e</kbd> ➜ <kbd-output>je</kbd-output> ;</li>
		<li><kbd>,é</kbd> ➜ <kbd-output>jé</kbd-output> ;</li>
		<li><kbd>,o</kbd> ➜ <kbd-output>jo</kbd-output> ;</li>
		<li><kbd>,u</kbd> ➜ <kbd-output>ju</kbd-output> ;</li>
		<li><kbd>,ê</kbd> ➜ <kbd-output>ju</kbd-output> pour éviter un <SFB /> ;</li>
		<li><kbd>,'</kbd> ➜ <kbd-output>j’</kbd-output> ;</li>
		<li><kbd>,à</kbd> ➜ <kbd-output>j</kbd-output> ;</li>
		<li>
			<kbd>Shift</kbd> + <kbd class="glow">j/★</kbd> ➜
			<kbd-output>J</kbd-output> ;
		</li>
		<li>
			<kbd>Shift</kbd> + <kbd>AltGr</kbd> + <kbd class="glow">j/★</kbd> ➜
			<kbd-output>j</kbd-output>.
		</li>
	</ul>

	<p>
		L’avantage de ce choix en <kbd>,</kbd> est aussi que contrairement à une touche morte, il n’y a
		pas besoin ici de frapper sur deux touches pour n’en donner qu’une seule. Nul besoin de taper
		sur
		<kbd>touche morte</kbd> + <kbd>j sur la touche morte</kbd> +
		<kbd>voyelle</kbd>, il suffit de faire <kbd>,</kbd> + <kbd>voyelle</kbd>. Ainsi, la frappe n’est
		absolument pas ralentie, car on ne rajoute pas de touches supplémentaires à taper.
	</p>

	<h3>
		Utilisation de la touche <kbd>,</kbd> + <kbd>consonne</kbd> pour avoir une disposition 1DFH
	</h3>
	<p>
		La disposition <Ergopti></Ergopti> n’est pas 1DFH de base. En effet, il y a trop de lettres à placer,
		notamment les voyelles accentuées du français, pour que toutes les touches soient à une distance
		maximale d’une touche de la position de repos de chaque doigt (« 1u Distance From Home »). C’est
		pourquoi il y a les lettres <kbd>Q</kbd> et <kbd>Z</kbd> sur l’auriculaire droit, non sur la
		colonne de repos de ce doigt, mais à droite de celle-ci. De même pour la touche <kbd>K</kbd> qui
		est pile au milieu du clavier, mais trop loin de chacun des deux index pour être considérée 1DFH.
	</p>
	<p>
		En outre, réaliser un <kbd-output>ç</kbd-output> ou un <kbd-output>où</kbd-output> est un peu
		inconfortable, car il faut utiliser <kbd>AltGr</kbd> pour les obtenir. La frappe serait encore plus
		fluide en utilisant une touche morte au lieu d’un modificateur. En effet, celui-ci qui peut dans
		certains cas demeurer activé pour la lettre d’après, et donc entraîner des erreurs de frappe.
	</p>
	<p>
		C’est pour toutes ces raisons qu’il est possible d’utiliser la touche <kbd>,</kbd> comme une
		super touche morte avec <ErgoptiPlus></ErgoptiPlus> :
	</p>
	<ul>
		<li><kbd>,</kbd> + <kbd>è</kbd> = <kbd-output>z</kbd-output> ;</li>
		<li><kbd>,</kbd> + <kbd>y</kbd> = <kbd-output>k</kbd-output> ;</li>
		<li><kbd>,</kbd> + <kbd>s</kbd> = <kbd-output>q</kbd-output> ;</li>
		<li><kbd>,</kbd> + <kbd>c</kbd> = <kbd-output>ç</kbd-output> ;</li>
		<li><kbd>,</kbd> + <kbd>x</kbd> = <kbd-output>où</kbd-output>.</li>
	</ul>
</section>
