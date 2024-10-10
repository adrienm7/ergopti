<script>
	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import SFB from '$lib/composants/SFB.svelte';
</script>

<h2>Placement logique des touches</h2>
<p>
	Afin de <span class="important"> faciliter la mémorisation</span> ainsi que de
	<span class="important">réduire la charge cognitive</span>, les touches de la disposition sont, le
	plus possible, <span style="text-decoration: underline;"> placées logiquement</span>. Ceci en
	particulier sur la couche <kbd>AltGr</kbd> :
</p>

<ul>
	<li>
		<kbd>AltGr</kbd> + <kbd>À</kbd> ➜ <kbd-sortie>\</kbd-sortie> car le
		<span class="hyper text-bold">\</span> est au-dessus du A (Le <kbd-sortie>\</kbd-sortie>
		était auparavant sur le
		<kbd>È</kbd> et le <kbd-sortie>`</kbd-sortie> sur le <kbd>À</kbd>, car plus logique. Cependant,
		cela a finalement été déplacé pour placer plus près ce symbole qui est très utilisé en
		programmation, notamment en LaTeX.)
	</li>
	<li>
		<kbd>AltGr</kbd> + <kbd>C</kbd> ➜ <kbd-sortie>ç</kbd-sortie>
		car la cédille est sous le <span class="hyper text-bold">C</span>
	</li>
	<li>
		<kbd>Shift</kbd> + <kbd>AltGr</kbd> + <kbd>★</kbd> ➜
		<kbd-sortie>δ</kbd-sortie>
		car cette touche morte permettant d’écrire les lettres grecques (α, β, γ, δ…) est sur la touche "magique"
		<span class="hyper text-bold">★</span>
	</li>
	<li>
		<kbd>Shift</kbd> + <kbd>AltGr</kbd> + <kbd>E</kbd> ➜
		<kbd-sortie>ᵉ</kbd-sortie>
		car c’est la touche morte <span class="hyper text-bold">E</span>xposant
	</li>
	<li>
		<kbd>AltGr</kbd> + <kbd>É</kbd> ➜ <kbd-sortie>/</kbd-sortie>
		car le <span class="hyper text-bold">/</span> est au-dessus du E
	</li>
	<li>
		<kbd>AltGr</kbd> + <kbd>È</kbd> ➜ <kbd-sortie>`</kbd-sortie>
		car le <span class="hyper text-bold">`</span> est au-dessus du E
	</li>
	<li>
		<kbd>AltGr</kbd> + <kbd>Ê</kbd> ➜ <kbd-sortie>^</kbd-sortie>
		car le <span class="hyper text-bold">^</span> est au-dessus du E
	</li>
	<li>
		<kbd>AltGr</kbd> + <kbd>H</kbd> ➜ <kbd-sortie>#</kbd-sortie>
		car c’est la première lettre de <span class="hyper text-bold">H</span>ashtag
	</li>
	<li>
		<kbd>AltGr</kbd> + <kbd>L</kbd> ➜ <kbd-sortie>=</kbd-sortie> car éga<span
			class="hyper text-bold">L</span
		>
	</li>
	<li>
		<kbd>AltGr</kbd> + <kbd>M</kbd> ➜ <kbd-sortie>&</kbd-sortie> car le nom de ce symbole est a<span
			class="hyper text-bold">M</span
		>persand
	</li>
	<li>
		<kbd>AltGr</kbd> + <kbd>P</kbd> ➜ <kbd-sortie>+</kbd-sortie>
		car c’est la première lettre de <span class="hyper text-bold">P</span>lus
	</li>
	<li>
		<kbd>Shift</kbd> + <kbd>AltGr</kbd> + <kbd>R</kbd> ➜
		<kbd-sortie>ℝ</kbd-sortie>
		car c’est la touche morte pour écrire les ensembles mathématiques (ℕ, ℤ, ℚ, ℝ, ℂ), dont l'un des
		plus connus est <span class="hyper text-bold">R</span>
	</li>
	<li>
		<kbd>Shift</kbd> + <kbd>AltGr</kbd> + <kbd>T</kbd> ➜
		<kbd-sortie style="font-weight: normal;">◌̈</kbd-sortie>
		car c’est la touche morte <span class="hyper text-bold">T</span>rémat
	</li>
	<li>
		<kbd>AltGr</kbd> + <kbd>V</kbd> ➜ <kbd-sortie>|</kbd-sortie> car c’est la barre
		<span class="hyper text-bold">V</span>erticale
	</li>
	<li>
		<kbd>AltGr</kbd> + <kbd>X</kbd> ➜ <kbd-sortie>*</kbd-sortie>
		car <span class="hyper text-bold">x</span> ressemble au fois
	</li>
</ul>

<mini-espace />

<p>D’autres sont placées par paires l’une à côté de l’autre :</p>
<ul>
	<li>
		<kbd>AltGr</kbd> + <kbd>A</kbd> ➜ <kbd-sortie>{'<'}</kbd-sortie> et <kbd>AltGr</kbd> +
		<kbd>I</kbd>
		➜ <kbd-sortie>{'>'}</kbd-sortie>
	</li>
	<li>
		<kbd>Shift</kbd> + <kbd>AltGr</kbd> + <kbd>A</kbd> ➜ <kbd-sortie>⩽</kbd-sortie> et
		<kbd>Shift</kbd>
		+ <kbd>AltGr</kbd> +
		<kbd>I</kbd>
		➜ <kbd-sortie>⩾</kbd-sortie>
	</li>
	<li>
		<kbd>AltGr</kbd> + <kbd>E</kbd> ➜ <kbd-sortie>{'{'}</kbd-sortie> et <kbd>AltGr</kbd> +
		<kbd>U</kbd>
		➜ <kbd-sortie>{'}'}</kbd-sortie>
	</li>
	<li>
		<kbd>AltGr</kbd> + <kbd>S</kbd> ➜ <kbd-sortie>(</kbd-sortie> et <kbd>AltGr</kbd> +
		<kbd>N</kbd>
		➜ <kbd-sortie>)</kbd-sortie>
	</li>
	<li>
		<kbd>AltGr</kbd> + <kbd>T</kbd> ➜ <kbd-sortie>[</kbd-sortie> et <kbd>AltGr</kbd> +
		<kbd>R</kbd>
		➜ <kbd-sortie>]</kbd-sortie>
	</li>
	<li>
		<kbd>AltGr</kbd> + <kbd>B</kbd> ➜ <kbd-sortie>«</kbd-sortie> et <kbd>AltGr</kbd> +
		<kbd>F</kbd>
		➜ <kbd-sortie>»</kbd-sortie>
	</li>
	<li>
		<kbd>Shift</kbd> + <kbd>AltGr</kbd> + <kbd>B</kbd> ➜ <kbd-sortie>“</kbd-sortie> et
		<kbd>Shift</kbd>
		+ <kbd>AltGr</kbd> +
		<kbd>F</kbd>
		➜ <kbd-sortie>”</kbd-sortie>
	</li>
</ul>
<mini-espace />
<p class="encadre">
	À noter que les touches sont aussi placées le plus possible par distance selon leur fréquence
	d’utilisation. Ainsi, les touches très utilisées comme les <kbd>()</kbd>,
	<kbd>{'{}'}</kbd>, etc. sont toutes sur la rangée du milieu et sur les doigts les plus forts.
</p>
<!-- <p class="encadre">
			<span class="text-bold">⚠ Attention</span> : Le <kbd>$</kbd> est l’un des seuls symboles à ne
			pas être sur un emplacement logique (le
			<kbd>D</kbd>
			de <span class="hyper text-bold">D</span>ollar). Ceci parce qu’il est plus intéressant de
			mettre le <kbd>"</kbd> sur cette lettre, afin d’avoir un excellent roulement <kbd>="</kbd>. Le
			<kbd>$</kbd>
			se trouve sur la touche <kbd>★</kbd>.
		</p> -->
<h2>Ponctuations avec espace insécable automatique</h2>
<p>
	Enfin, les ponctuations <kbd>;</kbd>, <kbd>:</kbd>, <kbd>?</kbd> et <kbd>!</kbd> ont une
	particularité. En effet, lors de l’utilisation de <kbd>Shift</kbd>, elles sont
	<span class="important">automatiquement envoyées avec un espace insécable</span> qui les précède. Les
	espaces insécables ne sont pas disponibles en AZERTY, et c’est très dommage. Ce sont des espaces qui
	ont pour comportement de toujours rester collés au texte qui les précède et les suit.
</p>
<p>
	Ainsi, vous n’aurez plus jamais de <kbd-sortie>?</kbd-sortie> qui se balade au début d’une ligne
	parce qu’il n’y avait plus de place sur la ligne précédente. Cela donne des documents avec un
	rendu bien plus professionnel. Attention cependant :
	<span class="important">ne les utilisez pas dans d’autres situations que l'écriture de texte</span
	>. Par exemple, en programmation, un espace insécable peut causer des erreurs, sans forcément être
	visible (vous ne verrez qu’un simple espace, qui pourtant sera la cause du problème).
</p>
<p>
	En revanche, en utilisant <kbd>AltGr</kbd>, la ponctuation seule est renvoyée. Cette méthode
	permet d’écrire dans un français impeccable en
	<kbd>Shift</kbd>, tout en programmant normalement avec la couche <kbd>AltGr</kbd>, qui contient
	d’ailleurs tout le reste des symboles nécessaires à l’écriture de code.
</p>
<mini-espace />
<div class="encadre">
	<p class="important margin0">Ainsi, il est facile de se rappeler où est quoi :</p>
	<ul class="margin0">
		<li>le français est en <kbd>Shift</kbd> ;</li>
		<li class="margin0">la programmation est en <kbd>AltGr</kbd>.</li>
	</ul>
</div>
