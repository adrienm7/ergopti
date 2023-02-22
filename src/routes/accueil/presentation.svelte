<script>
	import Nom from '$lib/composants/Nom.svelte';
	import Nom_Plus from '$lib/composants/Nom_Plus.svelte';
	import SFB from '$lib/composants/SFB.svelte';
	import EnsembleClavier from '$lib/composants/clavier/Ensemble_Clavier.svelte';
</script>

<h2>Disposition clavier optimisée</h2>

<div class="accordion">
	<section>
		<input type="checkbox" name="acc" id="acc1" />
		<label for="acc1">
			<span class="numero-faq" />
			<h3>Distance des doigts aux touches</h3>
		</label>
		<div class="content">
			<p>
				En outre, chaque doigt a une force différente. Ainsi, un pouce a plus de force qu’un index,
				qui a plus de force qu’un majeur, qui a plus de force qu’un annulaire, qui a plus de force
				qu’un auriculaire. Par conséquent, les meilleurs emplacements sont ceux sur la rangée de
				repos, en partant de l’index à l’annulaire. Puis, les meilleurs emplacements seront sur les
				colonnes au-dessus et en-dessous de la rangée de repos, en partant là encore de l’index à
				l’annulaire. La rangée des chiffres est donc la moins accessible, c’est pour cela que
				laisser le <kbd>É</kbd> sur cette ligne comme en AZERTY est une très mauvaise idée, car cette
				lettre est beaucoup utilisée en français.
			</p>

			<mini-espace />

			<EnsembleClavier
				emplacement={'clavier-freq'}
				type={'iso'}
				couche={'Visuel'}
				couleur={'freq'}
				plus={'non'}
				controles={'non'}
			/>
		</div>
	</section>
	<section>
		<input type="checkbox" name="acc" id="acc2" />
		<label for="acc2">
			<span class="numero-faq" />
			<h3>Minimisation des SFBs</h3>
		</label>
		<div class="content">
			<p>
				Lorem, ipsum dolor sit amet consectetur adipisicing elit. Mollitia at exercitationem fuga
				laudantium commodi alias odio quibusdam praesentium earum impedit?
			</p>
		</div>
	</section>
	<section>
		<input type="checkbox" name="acc" id="acc3" />
		<label for="acc3">
			<span class="numero-faq" />
			<h3>Alternance des mains</h3>
		</label>
		<div class="content">
			<p>
				L’alternance des mains est très importante pour garantir une bonne <strong
					>fluidité de frappe</strong
				>, et donc un meilleur confort. L’objectif est d’essayer d’avoir le plus d’alternance des
				mains possible lors de la frappe de texte : main droite pour une touche, ensuite main gauche
				pour la touche suivante, puis main droite, main gauche, etc.
			</p>
			<p>
				Cette alternance des mains permet de <strong>ne pas surutiliser l’une des deux mains</strong
				> en tapant avec la majorité du texte, au détriment de l’autre main qui resterait au-dessus de
				sa partie du clavier, à attendre de pouvoir enfin entrer en jeu. Ainsi, avec une bonne alternance
				des mains, pendant qu’une main frappe une touche, l’autre peut se replacer sur la rangée du milieu
				et se préparer à frapper la suivante.
			</p>
			<p>
				Si la touche suivante est sur la même main que la touche précédente (sauf roulement, cf. le
				point suivant), la frappe sera moins confortable. Imaginez que vous deviez atteindre le <kbd
					>C</kbd
				>
				de l’AZERTY, puis le <kbd>T</kbd>, pour écrire <kbd>CT</kbd>, un bigramme très courant en
				français et anglais. Dans ce cas, vous devez d’abord légèrement abaisser votre main pour que
				le majeur atteigne la rangée du bas pour taper
				<kbd>C</kbd>. Puis, il faut que l’index atteigne quant à lui la rangée du haut pour taper
				<kbd>T</kbd>. En résulte un sentiment d’inconfort avec deux doigts proches mais qui doivent
				aller dans des directions différentes. Au contraire, en "parallélisant" les frappes sur les
				deux mains, le résultat se révèle bien plus satisfaisant.
			</p>
			<p>
				L’alternance des mains a une limite. Il est impossible d’alterner parfaitement à chaque
				frappe. C’est pourquoi, une fois une alternance maximale atteinte, il faut encore améliorer
				l’expérience de frappe dans le cas où deux touches de la même main doivent être frappées
				d’affilée. C’est là qu’interviennent les roulements, présentés en détail dans le point
				suivant.
			</p>
		</div>
	</section>
	<section>
		<input type="checkbox" name="acc" id="acc4" />
		<label for="acc4">
			<span class="numero-faq" />
			<h3>Optimisation des roulements</h3>
		</label>
		<div class="content">
			<p>
				L’optimisation de l’alternance des mains fait que lors de l’utilisation d’une main pour
				frapper une touche, il y a de fortes probabilités que le frappe suivante se fasse avec
				l’autre main. Toutefois, cela n’arrive pas dans la totalité des cas, c’est pourquoi il
				convient de s’assurer que le plus possible de frappes inter-mains se fassent à l’aide de
				roulements.
			</p>
			<p>
				Pour moi, un "roulement" désigne un déplacement sur deux doigts consécutifs et jamais à plus
				d’une rangée d’écart. Il y peu d’informations sur le sujet en ligne ; un roulement a
				probablement une définition plus large que la mienne, mais alors dans ce cas le côté "qui
				roule" est selon moi perdu. À la limite si c’est de l’index à l’auriculaire, mais pas de
				l’index à l’annulaire par exemple.
			</p>
			<p>
				En conclusion, un roulement est pour moi le <kbd>ST</kbd> du Bépo (idéalement, car mouvement
				horizontal), sinon le <kbd>LS</kbd> du Bépo, mais pas le <kbd>GL</kbd> ni le
				<kbd>TR</kbd>
				du Bépo. La disposition <Nom /> a été construite avec pour contrainte principale de permettre
				de réaliser les bigrammes consonne-consonne et voyelle-voyelle les plus courants grâce à des
				roulements, de préférence sur des doigts consécutifs dans un mouvement horizontal.
			</p>

			<h4>Très bons bigrammes voyelle-voyelle</h4>
			<ul class="margin-top-2">
				<li><kbd>AI</kbd></li>
				<li><kbd>IE</kbd></li>
				<li><kbd>EU</kbd></li>
				<li><kbd>OI</kbd></li>
				<li><kbd>OU</kbd></li>
			</ul>

			Avec même quelques trigrammes très confortables :
			<ul class="margin-top-2">
				<li><kbd>AIE</kbd> notamment pour écrire <span class="hyper text-bold">AIE</span>NT</li>
				(avec en plus NT qui est lui aussi un roulement, que demander de plus ?)
				<li><kbd>IEU</kbd></li>
				<li><kbd>YOU</kbd></li>
			</ul>
			<h4>Très bons bigrammes consonne-consonne</h4>
			<ul class="margin-top-2">
				<li>
					<kbd>CH</kbd> ce bigramme est extraordinaire, une fois habitué il est difficile de s’en passer
				</li>
				<li><kbd>PL</kbd></li>
				<li>
					<kbd>LD</kbd> surtout fréquent en anglais (WOU<span class="hyper text-bold">LD</span>, COU<span
						class="hyper text-bold">LD</span
					>, etc.)
				</li>
			</ul>
			<h4>Autres bons bigrammes</h4>
			<ul class="margin-top-2">
				<li>
					<kbd>OW</kbd> très utilisé en anglais (ALL<span class="hyper text-bold">OW</span>
					, D<span class="hyper text-bold">OW</span>N, FOLL<span class="hyper text-bold">OW</span>,
					H<span class="hyper text-bold">OW</span>, KN<span class="hyper text-bold">OW</span>, N<span
						class="hyper text-bold">OW</span
					>, <span class="hyper text-bold">OW</span>N, SH<span class="hyper text-bold">OW</span>,
					etc.)
				</li>
				<li>
					<kbd>WO</kbd> très utilisé en anglais (T<span class="hyper text-bold">WO</span>,
					<span class="hyper text-bold">WO</span>MAN, <span class="hyper text-bold">WO</span>RD,
					<span class="hyper text-bold">WO</span>RK, <span class="hyper text-bold">WO</span>RLD,
					<span class="hyper text-bold">WO</span>RTH, <span class="hyper text-bold">WO</span>ULD,
					etc.)
				</li>
				<li><kbd>+=</kbd> utilisé en programmation pour incrémenter</li>

				<li>
					<kbd>/*</kbd> et <kbd>*/</kbd> utilisés dans certains langages de programmation pour commenter
					du code
				</li>
			</ul>
		</div>
	</section>
	<section>
		<input type="checkbox" name="acc" id="acc5" />
		<label for="acc5">
			<span class="numero-faq" />
			<h3>Placement logique des touches</h3>
		</label>
		<div class="content">
			<p>
				Afin de faciliter la mémorisation, les touches sont placées logiquement, en particulier sur
				la couche <kbd>AltGr</kbd>. Ainsi :
			</p>

			<ul class="margin-top-2">
				<li>
					<kbd>AltGr</kbd> + <kbd>À</kbd> ➜ <kbd-sortie>`</kbd-sortie> car le
					<span class="hyper text-bold">`</span> est au-dessus du A
				</li>
				<li>
					<kbd>AltGr</kbd> + <kbd>B</kbd> ➜ <kbd-sortie>@</kbd-sortie> car aro<span
						class="hyper text-bold">B</span
					>ase
				</li>
				<li>
					<kbd>AltGr</kbd> + <kbd>C</kbd> ➜ <kbd-sortie>ç</kbd-sortie>
					car la cédille est sous le <span class="hyper text-bold">C</span>
				</li>
				<li>
					<kbd>AltGr</kbd> + <kbd>D</kbd> ➜ <kbd-sortie>$</kbd-sortie>
					car c’est le première lettre de <span class="hyper text-bold">D</span>ollar
				</li>
				<li>
					<kbd>AltGr</kbd> + <kbd>É</kbd> ➜ <kbd-sortie>/</kbd-sortie>
					car le <span class="hyper text-bold">/</span> est au-dessus du E
				</li>
				<li>
					<kbd>AltGr</kbd> + <kbd>È</kbd> ➜ <kbd-sortie>\</kbd-sortie>
					car le <span class="hyper text-bold">\</span> est au-dessus du E
				</li>
				<li>
					<kbd>AltGr</kbd> + <kbd>H</kbd> ➜ <kbd-sortie>#</kbd-sortie>
					car c’est le première lettre de <span class="hyper text-bold">H</span>ashtag
				</li>
				<li>
					<kbd>AltGr</kbd> + <kbd>L</kbd> ➜ <kbd-sortie>=</kbd-sortie> car éga<span
						class="hyper text-bold">L</span
					>
				</li>
				<li>
					<kbd>AltGr</kbd> + <kbd>M</kbd> ➜ <kbd-sortie>&</kbd-sortie> car le nom de ce symbole est
					a<span class="hyper text-bold">M</span>persand
				</li>
				<li>
					<kbd>AltGr</kbd> + <kbd>P</kbd> ➜ <kbd-sortie>+</kbd-sortie>
					car c’est le première lettre de <span class="hyper text-bold">P</span>lus
				</li>
				<li>
					<kbd>AltGr</kbd> + <kbd>V</kbd> ➜ <kbd-sortie>|</kbd-sortie> car c’est la barre
					<span class="hyper text-bold">V</span>erticale
				</li>
			</ul>

			<petit-espace />

			<p>D’autres sont placées par paires l’une à côté de l’autre :</p>
			<ul class="margin-top-2">
				<li>
					<kbd>AltGr</kbd> + <kbd>A</kbd> ➜ <kbd-sortie>[</kbd-sortie> et <kbd>AltGr</kbd> +
					<kbd>I</kbd>
					➜ <kbd-sortie>]</kbd-sortie>
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
					<kbd>AltGr</kbd> + <kbd>T</kbd> ➜ <kbd-sortie>{'<'}</kbd-sortie> et <kbd>AltGr</kbd> +
					<kbd>R</kbd>
					➜ <kbd-sortie>{'>'}</kbd-sortie>
				</li>
				<li>
					<kbd>Shift</kbd> + <kbd>AltGr</kbd> + <kbd>T</kbd> ➜ <kbd-sortie>⩽</kbd-sortie> et
					<kbd>Shift</kbd>
					+ <kbd>AltGr</kbd> +
					<kbd>R</kbd>
					➜ <kbd-sortie>⩾</kbd-sortie>
				</li>
				<li>
					<kbd>AltGr</kbd> + <kbd>G</kbd> ➜ <kbd-sortie>«</kbd-sortie> et <kbd>AltGr</kbd> +
					<kbd>X</kbd>
					➜ <kbd-sortie>»</kbd-sortie>
				</li>
				<li>
					<kbd>Shift</kbd> + <kbd>AltGr</kbd> + <kbd>G</kbd> ➜ <kbd-sortie>“</kbd-sortie> et
					<kbd>Shift</kbd>
					+ <kbd>AltGr</kbd> +
					<kbd>X</kbd>
					➜ <kbd-sortie>”</kbd-sortie>
				</li>
			</ul>
			<p>
				À noter que les touches sont aussi placées le plus possible par distance selon leur
				fréquence d’utilisation. Ainsi, les touches très utilisées comme les <kbd>()</kbd>,
				<kbd>{'{}'}</kbd>, etc. sont toutes sur la rangée du milieu et sur les doigts les plus
				forts.
			</p>
			<p>
				Enfin, les ponctuations <kbd>;</kbd>, <kbd>:</kbd>, <kbd>?</kbd> et <kbd>!</kbd> ont une
				particularité. Lors de l’utilisation de <kbd>Shift</kbd>, elles sont automatiquement
				envoyées avec une espace insécable automatique qui les précède. En revanche, avec
				<kbd>AltGr</kbd>, la ponctuation seule est renvoyée, pour notamment la programmation. Cela
				permet ainsi d’écrire dans un français impeccable en <kbd>Shift</kbd>, tout en programment
				normalement avec la couche <kbd>AltGr</kbd>, qui contient d’ailleurs tout le reste des
				symboles nécessaires à l’écriture de code.
			</p>
			<p>
				Ainsi, il est facile de se rappeler où est quoi : <strong
					>le français en <kbd>Shift</kbd>, la programmation en <kbd>AltGr</kbd></strong
				>.
			</p>
		</div>
	</section>
	<section>
		<input type="checkbox" name="acc" id="acc6" />
		<label for="acc6">
			<span class="numero-faq" />
			<h3>Chiffres en accès direct</h3>
		</label>
		<div class="content">
			<p>
				Les chiffres sont en accès direct sur les dispositions QWERTY ou encore DVORAK, mais pas en
				AZERTY. Chaque manière de faire a ses avantages, car en AZERTY les symboles sont alors en
				accès direct et donc plus facilement réalisables. En revanche, il devient compliqué d’écrire
				un chiffre ou un nombre en plein milieu d’une phrase, car cela nécessite de passer en <kbd
					>Shift</kbd
				> momentanément pour écrire le nombre.
			</p>
			<p>
				Le passage des chiffres en accès direct permet d’<strong
					>écrire très rapidement des nombres</strong
				>
				en milieu de phrase. La rangée des nombres est de toute façon pas très accessible, donc il faut
				mieux placer les symboles qu’elle contenait sur la couche <kbd>AltGr</kbd>, plus proches des
				mains car sur les 3 rangées du milieu pour ne pas avoir à trop bouger les doigts.
			</p>
		</div>
	</section>
	<section>
		<input type="checkbox" name="acc" id="acc7" />
		<label for="acc7">
			<span class="numero-faq" />
			<h3>Optimisation pour l’utilisation à une main</h3>
		</label>
		<div class="content">
			<p>
				Lorsqu’on utilise un ordinateur, la plupart du temps la souris est tenue de la main droite
				et la main gauche repose près de la partie gauche du clavier. Lorsqu’il faut rentrer du
				texte ou taper sur une touche, il est bien souvent nécessaire de ramener la main droite de
				la souris à la partie droite du clavier, de taper dessus, puis de retourner à sa souris pour
				continuer la navigation. Par conséquent, il est aussi important de s’assurer que, grâce a sa
				disposition clavier, beaucoup d’actions courantes puissent se réaliser avec la seule main
				gauche afin de <strong>ne pas avoir à lâcher la souris</strong>.
			</p>
			<p>
				La version de <Nom /> adaptée aux claviers de type Ergodox est ainsi complètement optimisée sur
				ce critère, car des touches <kbd>Copier</kbd>, <kbd>Coller</kbd>, <kbd>Couper</kbd> et
				<kbd>Alt+Tab</kbd>
				sont directement inclues à gauche du clavier.
			</p>
			<p>
				La version ISO ne peut quant à elle malheureusement pas bénéficier de ces touches de
				raccourci, car les touches à sa gauche sont déjà occupées par les touches
				<kbd>Shift</kbd>, <kbd>Capslock</kbd> et <kbd>Tab</kbd> contrairement à l’Ergodox où l’on peut
				placer ces touches sous les pouces.
			</p>
			<p>
				Dans tous les cas, le <kbd>=</kbd> a au moins été dupliqué à gauche en accès direct. Cela
				permet de faire facilement les raccourcis sur Excel comme <kbd>=</kbd> et <kbd>Alt</kbd> +
				<kbd>=</kbd>. En effet, normalement, le <kbd>=</kbd> se situe en <kbd>AltGr</kbd> +
				<kbd>L</kbd>.
			</p>
		</div>
	</section>
</div>
