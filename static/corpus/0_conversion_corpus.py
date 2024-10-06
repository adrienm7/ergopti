import os



# ==================================================
# ==================================================
# ======= Fonctions de remplacement de texte =======
# ==================================================
# ==================================================

def conversion_apostrophe_typo(texte):
	texte = texte.replace("’", "'")
	return texte

# Raccourcis avec ★
def raccourcis_magique(texte):
	texte = texte.replace("ainsi", "a★")
	texte = texte.replace("c'est", "c★")
	texte = texte.replace("c'était", "ct★")
	texte = texte.replace("déjà", "dé★")
	texte = texte.replace("donc", "d★")
	texte = texte.replace("d'être", "dê★")
	texte = texte.replace("l'être", "lê★")
	texte = texte.replace("être", "ê★")
	texte = texte.replace("faire", "f★")
	texte = texte.replace("heure", "h★")
	texte = texte.replace("j'étais", "gt★")
	texte = texte.replace("j'ai", "g★")
	texte = texte.replace("mais", "m★")
	texte = texte.replace("nouveau", "n★")
	texte = texte.replace("prendre", "p★")
	texte = texte.replace("question", "q★")
	texte = texte.replace("rien", "r★")
	texte = texte.replace("sous", "s★")
	texte = texte.replace("très", "t★")
	texte = texte.replace("exemple", "x★")
	return texte

# La touche A devient un J si elle est suivie d’une voyelle
def virgule_devient_j(texte):
	texte = texte.replace("ja", ",a")
	texte = texte.replace("Ja", ";a")
	texte = texte.replace("JA", ";A")
	texte = texte.replace("je", ",e")
	texte = texte.replace("Je", ";e")
	texte = texte.replace("JE", ";E")
	texte = texte.replace("ji", ",i")
	texte = texte.replace("Ji", ";i")
	texte = texte.replace("JI", ";I")
	texte = texte.replace("jo", ",o")
	texte = texte.replace("Jo", ";o")
	texte = texte.replace("JO", ";O")
	texte = texte.replace("ju", ",ê")
	texte = texte.replace("Ju", ";ê")
	texte = texte.replace("JU", ";Ê")
	texte = texte.replace("jé", ",é")
	texte = texte.replace("Jé", ";é")
	texte = texte.replace("JÉ", ";É")
	texte = texte.replace("j'", ",'")
	texte = texte.replace("J'", ";'")
	texte = texte.replace("j", ",à")
	texte = texte.replace("J", ";à")
	return texte

def diminution_SFBs_virgule(texte):
	texte = texte.replace("cd", ",c")
	texte = texte.replace("ds", ",d")
	texte = texte.replace("fs", ",f")
	texte = texte.replace("gl", ",g")
	texte = texte.replace("ph", ",h")
	texte = texte.replace("Ph", ";h")
	texte = texte.replace("PH", ";H")
	texte = texte.replace("cl", ",l")
	texte = texte.replace("Cl", ";l")
	texte = texte.replace("CL", ";L")
	texte = texte.replace("dv", ",m")
	texte = texte.replace("nl", ",n")
	texte = texte.replace("xp", ",p")
	texte = texte.replace("q'", ",q")
	texte = texte.replace("Q'", ";q")
	texte = texte.replace("rq", ",r")
	texte = texte.replace("sc", ",s")
	texte = texte.replace("Sc", ";s")
	texte = texte.replace("SC", ";S")
	texte = texte.replace("pt", ",t")
	texte = texte.replace("Pt", ";t")
	texte = texte.replace("PT", ";T")
	texte = texte.replace("dv", ",v")
	texte = texte.replace("'re", ",x")
	texte = texte.replace("bj", ",z")
	return texte

def conversion_qu(texte):
	texte = texte.replace("qu", "q")
	texte = texte.replace("Qu", "Q")
	texte = texte.replace("QU", "Q")
	return texte

# La touche Ê devient une touche morte circonflexe
def touche_morte_circonflexe(texte):
	texte = texte.replace("^a", "éê")
	texte = texte.replace("â", "éê")
	texte = texte.replace("a^i", "êé")
	texte = texte.replace("aî", "êé")
	texte = texte.replace("^i", "êi")
	texte = texte.replace("î", "êi")
	texte = texte.replace("^e", "ê")
	texte = texte.replace("^o", "êo")
	texte = texte.replace("ô", "êo")
	texte = texte.replace("^u", "êu")
	texte = texte.replace("û", "êu")
	return texte

# SFBs sur la main gauche
def diminution_SFBs_e_circ(texte):
	texte = texte.replace("eo", "êe")
	texte = texte.replace("oe", "eê")
	return texte
def diminution_SFBs_e_grave(texte):
	texte = texte.replace("éi", "èy")
	texte = texte.replace("ié", "yè")
	texte = texte.replace("bu", "èu")
	texte = texte.replace("Bu", "Èu")
	texte = texte.replace("ub", "uè")
	texte = texte.replace("Ub", "Uè")
	texte = texte.replace("u,", "è,")
	texte = texte.replace("u.", "è.")
	return texte

def suffixes_a_grave(texte):
	texte = texte.replace("aire", "àa")
	texte = texte.replace("ence", "àc")
	texte = texte.replace("ould", "àd")
	texte = texte.replace("ying", "àé")
	texte = texte.replace("able", "àê")
	texte = texte.replace("iste", "àf")
	texte = texte.replace("ought", "àg")
	texte = texte.replace("techn", "àh")
	texte = texte.replace("ight", "ài")
	texte = texte.replace("ique", "àk")
	texte = texte.replace("elle", "àl")
	texte = texte.replace("isme", "àm")
	texte = texte.replace("ation", "àn")
	texte = texte.replace("ique", "àq")
	texte = texte.replace("erre", "àr")
	texte = texte.replace("ement", "às")
	texte = texte.replace("ction", "àt")
	texte = texte.replace("ieux", "àx")
	return texte



# Roulements sur la main droite
def roulements_main_droite(texte):
	texte = texte.replace("ght", "ghc")
	texte = texte.replace("GHT", "GHC")

	texte = texte.replace("q'", "p'")
	texte = texte.replace("Q'", "P'")

	texte = texte.replace("wh", "hc")
	texte = texte.replace("Wh", "Hc")
	texte = texte.replace("WH", "HC")

	texte = texte.replace("gt", "gx")
	texte = texte.replace("Gt", "Gx")
	texte = texte.replace("GT", "GX")
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
	texte = texte.replace("êê", "ê★")
	texte = texte.replace("ÊÊ", "Ê★")
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
	# texte = texte.replace("  ", " ")
	# texte = texte.replace("\n\n", "\n★")
	texte = texte.replace("★u", "★ê") # Évite les SFBs comme con★u en tapant con★ê
	return texte



# Archives

# def conversion_minuscules(texte):
# 	texte = texte.lower()
# 	return texte

# def autocorrection(texte):
# 	texte = texte.replace("www.", "ww")
# 	return texte







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
		nouveau_texte = conversion_apostrophe_typo(nouveau_texte) # Tout le reste des fonctions part du principe qu’on est en apostrophe droite
		nouveau_texte = raccourcis_magique(nouveau_texte) # Avant de s’embêter à faire les combinaisons pour réduire les SFBs, etc. autant directement taper un mot entier avec la touche ★

		nouveau_texte = conversion_qu(nouveau_texte)
		nouveau_texte = touche_morte_circonflexe(nouveau_texte)

		nouveau_texte = diminution_SFBs_virgule(nouveau_texte)
		nouveau_texte = virgule_devient_j(nouveau_texte)

		nouveau_texte = roulements_main_droite(nouveau_texte)
		nouveau_texte = diminution_SFBs_e_circ(nouveau_texte)
		nouveau_texte = diminution_SFBs_e_grave(nouveau_texte)
		nouveau_texte = suffixes_a_grave(nouveau_texte)

		nouveau_texte = touche_repetition(nouveau_texte)
		# nouveau_texte = nouveau_texte.replace("★,", "★à") # Correction pour éviter les SFBs comme pex★, donnant "par exemple,"
		# nouveau_texte = nouveau_texte.replace("★.", "★àé") # Correction pour éviter les SFBs comme pex★, donnant "par exemple."

		# Créer le dossier s'il n'existe pas
		dossier = "modifie/"
		if not os.path.exists(dossier):
			os.makedirs(dossier)
		
		output = open(dossier + nom_fichier + " (converti).txt", "w", encoding="utf-8")
		output.write(nouveau_texte)
		output.close()