<script>
	import { discordLink } from '$lib/stores_infos.js';
</script>

<slot name="introduction" />

<bloc-main>
	<nav id="sidebar">
		<div>
			<p style="text-align:center; color:white; margin:0; padding:0; font-weight: bold">
				Contenu de la page
			</p>
			<div id="page-toc-pc">
				<div id="page-toc"></div>
			</div>
			<hr style="margin:0; margin-top:20px" />
			<p style="text-align:center; margin: 0; padding-top: 10px;">
				<a
					href="https://github.com/adrienm7/ergopti"
					target="_blank"
					style="font-size:0.9em!important; color:white">Repo GitHub <i class="icon-github"></i></a
				>
				—
				<a
					href={discordLink}
					style="position:relative; bottom:-0.1em; font-size:0.9em!important; color:white"
					>Serveur Discord <i class="icon-discord"></i></a
				>
			</p>
		</div>
	</nav>
	<div id="main-content">
		<main>
			<slot />
		</main>
	</div>
</bloc-main>

<slot name="bloc-fin" />
