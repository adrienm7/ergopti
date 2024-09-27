import os

# Définir le répertoire de travail actuel
os.chdir("D:/Documents/Github/hypertexte/0) Documents/2) Corpus")






# ==================================================
# ==================================================
# ======= Fonctions de remplacement de texte =======
# ==================================================
# ==================================================



# Conversion en minuscules de tout le texte pour éviter que les changements ne s’effectuent pas sur les majuscules
def conversion_minuscules(texte):
	texte = texte.lower()
	return texte



def conversion_apostrophe_typo(texte):
	texte = texte.replace("’", "'")
	return texte



def autocorrection(texte):
	texte = texte.replace("www.", "ww")
	return texte



# Raccourcis avec ★
def raccourcis_magique(texte):
	texte = texte.replace("ainsi", "a★")
	texte = texte.replace("c'est", "c★")
	texte = texte.replace("donc", "d★")
	texte = texte.replace("déjà", "dé★")
	texte = texte.replace("faire", "f★")
	texte = texte.replace("j'étais", "gt★")
	texte = texte.replace("j'ai", "g★")
	texte = texte.replace("d'être", "dê★")
	texte = texte.replace("l'être", "lê★")
	texte = texte.replace("être", "ê★")
	texte = texte.replace("mais", "m★")
	texte = texte.replace("question", "q★")
	texte = texte.replace("rien", "r★")
	texte = texte.replace("très", "t★")
	return texte



def raccourcis_virgule(texte):
	texte = texte.replace("cd", ",c")
	texte = texte.replace("ds", ",d")
	texte = texte.replace("je", ",e")
	texte = texte.replace(",f", ",f")
	texte = texte.replace("gl", ",g")
	texte = texte.replace("gl", ",g")
	texte = texte.replace("nh", ",h")
	texte = texte.replace("cl", ",l")
	texte = texte.replace("mpl", ",m")
	texte = texte.replace("nl", ",n")
	texte = texte.replace("ph", ",p")
	texte = texte.replace("qu'", ",q")
	texte = texte.replace("q'", ",q")
	texte = texte.replace("rq", ",r")
	texte = texte.replace("sc", ",s")
	texte = texte.replace("pt", ",t")
	texte = texte.replace("dv", ",v")
	texte = texte.replace("'re", ",x")
	return texte

def raccourcis_virgule_old(texte):
	texte = texte.replace("able", ",a")
	texte = texte.replace("sc", ",c")
	texte = texte.replace("would", ",d")
	texte = texte.replace("the  ", ",e")
	texte = texte.replace("ence", ",f")
	texte = texte.replace("ought", ",g")
	texte = texte.replace("techn", ",h")
	texte = texte.replace("ight", ",i")
	texte = texte.replace("toujours ", ",j")
	texte = texte.replace("elle", ",l")
	texte = texte.replace("ements", ",m")
	texte = texte.replace("ation", ",n")
	texte = texte.replace("could", ",o")
	texte = texte.replace("mpl", ",p")
	# texte = texte.replace("ique", ",q")
	texte = texte.replace("ring", ",r")
	texte = texte.replace("ement", ",s")
	texte = texte.replace("ction", ",t")
	texte = texte.replace("ance", ",v")
	texte = texte.replace("ieux", ",x")
	texte = texte.replace("ying", ",y")
	texte = texte.replace("ez-vous", ",z")
	texte = texte.replace("qu"", ","")
	texte = texte.replace("Qu"", ","")
	return texte



def conversion_qu(texte):
	texte = texte.replace("qu", "q")
	texte = texte.replace("Qu", "Q")
	texte = texte.replace("QU", "Q")
	return texte



# Plus besoin de la touche morte circonflexe avec les remplacements de texte
def touche_morte_circonflexe(texte):
	texte = texte.replace("^a", "êè")
	texte = texte.replace("â", "êè")
	texte = texte.replace("^i", "êi")
	texte = texte.replace("î", "êi")
	texte = texte.replace("^e", "ê")
	texte = texte.replace("^o", "êo")
	texte = texte.replace("ô", "êo")
	texte = texte.replace("^u", "êu")
	texte = texte.replace("û", "êu")
	return texte



# SFBs sur la main gauche
def diminution_sfbs_e_circ(texte):
	texte = texte.replace("ié", "êé")
	texte = texte.replace("éi", "éê")
	return texte
def diminution_sfbs_a_grave(texte):
	texte = texte.replace("oe", "oà")
	texte = texte.replace("eo", "ào")
	texte = texte.replace("bu", "àu")
	texte = texte.replace("ub", "uà")
	texte = texte.replace("u,", "à,")
	texte = texte.replace("u.", "à.")
	return texte



# Roulements sur la main droite
def roulements_main_droite(texte):
	texte = texte.replace("ght", "ghc")
	texte = texte.replace("GHT", "GHC")

	texte = texte.replace("wh", "hc")
	texte = texte.replace("Wh", "Hc")
	texte = texte.replace("WH", "HC")

	texte = texte.replace("wh", "hc")
	texte = texte.replace("Wh", "Hc")
	texte = texte.replace("WH", "HC")

	texte = texte.replace("gt", "gx")
	texte = texte.replace("Gt", "Gx")
	texte = texte.replace("GT", "GX")
	return texte







# La touche A devient un J si elle est suivie d’une voyelle
def virgule_devient_j(texte):
	texte = texte.replace("ja", ",a")
	texte = texte.replace("je", ",e")
	texte = texte.replace("ji", ",i")
	texte = texte.replace("jo", ",o")
	texte = texte.replace("ju", ",ê")
	texte = texte.replace("jé", ",é")
	texte = texte.replace("j'", ",'")
	return texte






# Touche de répétition ★
def touche_repetition(texte):
	# for i in range(10):
	texte = texte.replace("àà", "à★")
	texte = texte.replace("ÀÀ", "À★")
	texte = texte.replace("aa", "a★")
	texte = texte.replace("AA", "A★")
	texte = texte.replace("bb", "b★")
	texte = texte.replace("BB", "B★")
	texte = texte.replace("cc", "c★")
	texte = texte.replace("CC", "C★")
	texte = texte.replace("dd", "d★")
	texte = texte.replace("DD", "D★")
	texte = texte.replace("ee", "e★")
	texte = texte.replace("EE", "E★")
	texte = texte.replace("éé", "é★")
	texte = texte.replace("ÉÉ", "É★")
	texte = texte.replace("èè", "è★")
	texte = texte.replace("ÈÈ", "È★")
	texte = texte.replace("ff", "f★")
	texte = texte.replace("FF", "F★")
	texte = texte.replace("gg", "g★")
	texte = texte.replace("GG", "G★")
	texte = texte.replace("hh", "h★")
	texte = texte.replace("HH", "H★")
	texte = texte.replace("ii", "i★")
	texte = texte.replace("II", "I★")
	texte = texte.replace("jj", "j★")
	texte = texte.replace("JJ", "J★")
	texte = texte.replace("kk", "k★")
	texte = texte.replace("KK", "K★")
	texte = texte.replace("ll", "l★")
	texte = texte.replace("LL", "L★")
	texte = texte.replace("mm", "m★")
	texte = texte.replace("MM", "M★")
	texte = texte.replace("nn", "n★")
	texte = texte.replace("NN", "N★")
	texte = texte.replace("oo", "o★")
	texte = texte.replace("OO", "O★")
	texte = texte.replace("pp", "p★")
	texte = texte.replace("PP", "P★")
	texte = texte.replace("qq", "q★")
	texte = texte.replace("QQ", "Q★")
	texte = texte.replace("rr", "r★")
	texte = texte.replace("RR", "R★")
	texte = texte.replace("ss", "s★")
	texte = texte.replace("SS", "S★")
	texte = texte.replace("tt", "t★")
	texte = texte.replace("TT", "T★")
	texte = texte.replace("uu", "u★")
	texte = texte.replace("UU", "U★")
	texte = texte.replace("vv", "v★")
	texte = texte.replace("VV", "V★")
	texte = texte.replace("ww", "w★")
	texte = texte.replace("WW", "W★")
	texte = texte.replace("xx", "x★")
	texte = texte.replace("XX", "X★")
	texte = texte.replace("yy", "y★")
	texte = texte.replace("YY", "Y★")
	texte = texte.replace("zz", "z★")
	texte = texte.replace("ZZ", "Z★")
	texte = texte.replace("00", "0★")
	texte = texte.replace("11", "1★")
	texte = texte.replace("22", "2★")
	texte = texte.replace("33", "3★")
	texte = texte.replace("44", "4★")
	texte = texte.replace("55", "5★")
	texte = texte.replace("66", "6★")
	texte = texte.replace("77", "7★")
	texte = texte.replace("88", "8★")
	texte = texte.replace("99", "9★")
	texte = texte.replace(",,", ",★")
	texte = texte.replace("..", ".★")
	texte = texte.replace(">>", ">★")
	texte = texte.replace("<<", "<★")
	texte = texte.replace("{{", "{★")
	texte = texte.replace("}}", "}★")
	texte = texte.replace("((", "(★")
	texte = texte.replace("))", ")★")
	texte = texte.replace("[", "[★")
	texte = texte.replace("]", "]★")
	texte = texte.replace("  ", " ")
	# texte = texte.replace("\n\n", "\n★")

	texte = texte.replace("★u", "★ê")
	return texte







# ==========================
# ==========================
# ======= Conversion =======
# ==========================
# ==========================



for nom_fichier in os.listdir("original"):
	if os.path.isfile("original/" + nom_fichier):
		input = open("original/" + nom_fichier, "r", encoding="utf-8")
		ancien_texte = input.read()
		input.close()
		
		nouveau_texte = ancien_texte
		nouveau_texte = conversion_minuscules(nouveau_texte)
		nouveau_texte = conversion_apostrophe_typo(nouveau_texte)
		nouveau_texte = raccourcis_magique(nouveau_texte)

		nouveau_texte = conversion_qu(nouveau_texte)

		nouveau_texte = raccourcis_virgule(nouveau_texte)
		nouveau_texte = virgule_devient_j(nouveau_texte)

		nouveau_texte = diminution_sfbs_e_circ(nouveau_texte)
		nouveau_texte = diminution_sfbs_a_grave(nouveau_texte)
		nouveau_texte = roulements_main_droite(nouveau_texte)

		nouveau_texte = touche_morte_circonflexe(nouveau_texte)
		nouveau_texte = autocorrection(nouveau_texte)
		nouveau_texte = touche_repetition(nouveau_texte)

		output = open("modifie/" + nom_fichier + " (converti).txt", "w", encoding="utf-8")
		output.write(nouveau_texte)
		output.close()