#Requires Autohotkey v2.0+
#SingleInstance Force
InstallKeybdHook
SetWorkingDir(A_ScriptDir) ; Ensures a consistent starting directory.
#Hotstring EndChars -()[]{}:;'"/\,.?!`n`s`t  

; Initialisation des variables, ne pas toucher
global script_actif := TRUE

; ======= Raccourcis de gestion du script en AltGr =======

#SuspendExempt
^!Enter:: ; Désactivation/Réactivation du script avec AltGr + Enter
{
    global script_actif := !script_actif
    if !script_actif {
        Pause 1 ; Met en pause ce qui est en train d’être exécuté
        Suspend 1
    } else {
        Reload ; De cette façon, ce qui était en train d’être exécuté ne continue pas
    }
}

^!SC00E:: ; Sauvegarde et recharge le script avec AltGr + BackSpace
{

    Send("^s") ; Sauvegarde du script grâce au raccourci Ctrl + S
    Reload
}

^!Delete:: Edit ; Modification du script avec AltGr + Suppr
#SuspendExempt False

; ======================================================
; ======================================================
; ======================================================
; ================ 1/ AZERTY ➜ ERGOPTI ================
; ======== Convertit un pilote AZERTY en ERGOPTI =======
; ======================================================
; ======================================================
; ======================================================

#InputLevel 50 ; Très important, il faut être en InputLevel le plus haut pour le remappage AZERTY vers Ergopti
; Car ensuite on va remapper les touches déjà remappées, donc il faut que l’InputLevel des autres raccourcis soit plus bas

/* ======= Carte des scancodes des touches du clavier =======
        Un scancode est sous la forme SC000.
        Donc pour sélectionner la touche à l'emplacement F du clavier AZERTY, le scancode est SC021,
        SC039 pour la barre d'espace, SC028 pour la touche ù, SC003 pour la touche &/1, etc.
        Les scancodes sont beaucoup plus fiables que d'utiliser le nom des touches.
        Pour que les tap holds fonctionnent, il faut nécessairement faire tout le reste des raccourcis avec les scancodes.

	---     ---------------   ---------------   ---------------   -----------
	| 01|   | 3B| 3C| 3D| 3E| | 3F| 40| 41| 42| | 43| 44| 57| 58| |+37|+46|+45|
	---     ---------------   ---------------   ---------------   -----------
	-----------------------------------------------------------   -----------   ---------------
	| 29| 02| 03| 04| 05| 06| 07| 08| 09| 0A| 0B| 0C| 0D|     0E| |*52|*47|*49| |+45|+35|+37| 4A|
	|-----------------------------------------------------------| |-----------| |---------------|
	|   0F| 10| 11| 12| 13| 14| 15| 16| 17| 18| 19| 1A| 1B|     | |*53|*4F|*51| | 47| 48| 49|   |
	|------------------------------------------------------|  1C|  -----------  |-----------| 4E|
	|    3A| 1E| 1F| 20| 21| 22| 23| 24| 25| 26| 27| 28| 2B|    |               | 4B| 4C| 4D|   |
	|-----------------------------------------------------------|      ---      |---------------|
	|  2A| 56| 2C| 2D| 2E| 2F| 30| 31| 32| 33| 34| 35|       136|     |*4C|     | 4F| 50| 51|   |
	|-----------------------------------------------------------|  -----------  |-----------|-1C|
	|   1D|15B|   38|                       39|138|15C|15D|  11D| |*4B|*50|*4D| |     52| 53|   |
	-----------------------------------------------------------   -----------   ---------------
*/

; =========================
; ======= 1.1) Base =======
; =========================

; Pas de Send ici, sinon les raccourcis et shift ne fonctionnent plus !!!

; === Rangée des chiffres ===

SC029::=
SC002:: Send("{U+0031}") ; 1
SC003:: Send("{U+0032}") ; 2
SC004:: Send("{U+0033}") ; 3
SC005:: Send("{U+0034}") ; 4
SC006:: Send("{U+0035}") ; 5
SC007:: Send("{U+0036}") ; 6
SC008:: Send("{U+0037}") ; 7
SC009:: Send("{U+0038}") ; 8
SC00A:: Send("{U+0039}") ; 9
SC00B:: Send("{U+0030}") ; 0
SC00C:: Send("{U+20AC}") ; €
SC00D:: Send("{U+0025}") ; %

; === Rangée du haut ===

SC010::è
SC011::y
SC012::o
SC013::w
SC014::b
SC015::f
SC016::c
SC017::h
SC018::g
SC019::x
SC01A::z
SC01B::+SC01A ; La touche morte tréma
^SC01B::^SC035 ; Raccourci Ctrl + ! pour mettre sous format nombre dans Excel

; === Rangée du milieu ===

SC01E::a
SC01F::i
SC020::e
SC021::u
SC022::.
SC023::v
SC024::s
SC025::n
SC026::t
SC027::r
SC028::q
SC02B::SC01A ; SC01A est la touche morte ^ en AZERTY

; === Rangée du bas ===

SC056::ê
SC02C::é
SC02D::à
SC02E::j
SC02F::,
SC030::k
SC031::m
SC032::d
SC033::l
SC034::p
SC035::'

; ==========================
; ======= 1.2) Shift =======
; ==========================

+SC039:: Send("{U+002D}") ; - sur la barre d’espace

; === Rangée des chiffres ===

+SC029:: Send("=")
+SC002:: Send("{U+0031}") ; 1
+SC003:: Send("{U+0032}") ; 2
+SC004:: Send("{U+0033}") ; 3
+SC005:: Send("{U+0034}") ; 4
+SC006:: Send("{U+0035}") ; 5
+SC007:: Send("{U+0036}") ; 6
+SC008:: Send("{U+0037}") ; 7
+SC009:: Send("{U+0038}") ; 8
+SC00A:: Send("{U+0039}") ; 9
+SC00B:: Send("º")
+SC00C:: {
    Send(" ")
    Sleep(50)
    Send("{U+20AC}") ; €
}
+SC00D:: {
    Send(" ")
    Sleep(50)
    Send("%")
}

; === Rangée du haut ===

+SC010:: Send("È")
+SC011:: Send("Y")
+SC012:: Send("O")
+SC013:: Send("W")
+SC014:: Send("B")
+SC015:: Send("F")
+SC016:: Send("C")
+SC017:: Send("H")
+SC018:: Send("G")
+SC019:: Send("X")
+SC01A:: Send("Z")
+SC01B:: Send(" ") ; Espace fine insécable

; === Rangée du milieu ===

+SC01E:: Send("A")
+SC01F:: Send("I")
+SC020:: Send("E")
+SC021:: Send("U")
+SC022:: {
    Send(" ")
    Sleep(50)
    Send("{U+003A}") ; :
}
+SC023:: Send("V")
+SC024:: Send("S")
+SC025:: Send("N")
+SC026:: Send("T")
+SC027:: Send("R")
+SC028:: Send("Q")
+SC02B:: {
    Send(" ")
    Sleep(50)
    Send("{!}")
}

; === Rangée du bas ===

+SC056:: Send("Ê")
+SC02C:: Send("É")
+SC02D:: Send("À")
+SC02E:: Send("J")
+SC02F:: {
    Send(" ")
    Sleep(50)
    Send("{U+003B}") ; ;
}
+SC030:: Send("K")
+SC031:: Send("M")
+SC032:: Send("D")
+SC033:: Send("L")
+SC034:: Send("P")
+SC035:: {
    Send(" ")
    Sleep(50)
    Send("?")
}

; Met en Shift les caractères exotiques lors du Capslock
#HotIf GetKeyState("CapsLock", "T")
SC002:: Send(1)
SC003:: Send(2)
SC004:: Send(3)
SC005:: Send(4)
SC006:: Send(5)
SC007:: Send(6)
SC008:: Send(7)
SC009:: Send(8)
SC00A:: Send(9)
SC00B:: Send(0)
SC010:: Send("È")
SC022:: Send("{U+002E}") ; .
SC02C:: Send("É")
SC02D:: Send("À")
SC056:: Send("Ê")
SC02E:: Send("J")
SC02F:: Send(",")
SC034:: Send("P")
SC035:: Send("'")
#HotIf

; ==========================
; ======= 1.3) AltGr =======
; ==========================

; On est forcé d’utiliser des Send ici, sinon la touche Ctrl reste activée dans certains cas
; Mais le problème est que les remplacements de texte ne fonctionnent alors plus
; Ce problème est résolu en utilisant l’envoi Unicode ! (j’ai l’impression, à vérifier)

<^>!SC039:: Send("_") ; Sur la barre d’espace

; === Rangée des chiffres ===

; ^!SC029::
<^>!SC002:: Send("1") ; AltGr + 1
<^>!SC003:: Send("2") ; AltGr + 2
<^>!SC004:: Send("3") ; AltGr + 3
<^>!SC005:: Send("4") ; AltGr + 4
<^>!SC006:: Send("5") ; AltGr + 5
<^>!SC007:: Send("6") ; AltGr + 6
<^>!SC008:: Send("7") ; AltGr + 7
<^>!SC009:: Send("8") ; AltGr + 8
<^>!SC00A:: Send("9") ; AltGr + 9
<^>!SC00B:: Send("°") ; AltGr + 0
<^>!SC00C:: Send("£")
<^>!SC00D:: Send("‰")

; === Rangée du haut ===

<^>!SC010:: Send("{U+0060}") ; `
<^>!SC011:: Send("{U+0040}") ; @
<^>!SC012:: Send("œ")
<^>!SC013:: Send("où") ; Sur W
<^>!SC014:: Send("« ")
<^>!SC015:: Send(" »")
<^>!SC016:: Send("{U+00E7}") ; ç
<^>!SC017:: Send("{U+0023}") ; #
<^>!SC018:: Send("{U+007E}") ; ~
<^>!SC019:: Send("{U+002A}") ; *
<^>!SC01A:: Send("{U+0025}") ; %
<^>!SC01B:: Send(" ") ; Espace insécable

; === Rangée du milieu ===
<^>!SC01E:: Send("{U+003C}") ; <
<^>!SC01F:: Send("{U+003E}") ; >
<^>!SC020:: Send("{U+007B}") ; {
<^>!SC021:: Send("{U+007D}") ; }
<^>!SC022:: Send("{U+003A}") ; :
<^>!SC023:: Send("{U+007C}") ; |
<^>!SC024:: Send("{U+0028}") ; (
<^>!SC025:: Send("{U+0029}") ; )
<^>!SC026:: Send("{U+005B}") ; [
<^>!SC027:: Send("{U+005D}") ; ]
<^>!SC028:: Send("{U+2019}") ; ’
<^>!SC02B:: Send("{U+0021}") ; !

; === Rangée du bas ===

<^>!SC056:: Send("{U+005E}") ; ^
<^>!SC02C:: Send("{U+002F}") ; /
<^>!SC02D:: Send("{U+005C}") ; \
<^>!SC02E:: Send("{U+0022}") ; "
<^>!SC02F:: Send("{U+003B}") ; ;
<^>!SC030:: Send("…")
<^>!SC031:: Send("{U+0026}") ; &
<^>!SC032:: Send("{U+0024}") ; $
<^>!SC033:: Send("{U+003D}") ; =
<^>!SC034:: Send("{U+002B}") ; +
<^>!SC035:: Send("{U+003F}") ; ?

; ==================================
; ======= 1.4) Shift + AltGr =======
; ==================================

; === Rangée des chiffres ===

+^!SC029:: Send("⁰")
+^!SC002:: Send("¹")
+^!SC003:: Send("²")
+^!SC004:: Send("³")
+^!SC005:: Send("⁴")
+^!SC006:: Send("⁵")
+^!SC007:: Send("⁶")
+^!SC008:: Send("⁷")
+^!SC009:: Send("⁸")
+^!SC00A:: Send("⁹")
+^!SC00B:: Send("ª")
+^!SC00C:: return
+^!SC00D:: Send("‱")

; === Rangée du haut ===

+^!SC010:: Send("„")
+^!SC011:: Send("„")
+^!SC012:: Send("Œ")
+^!SC013:: Send("Où")
+^!SC014:: Send("“")
+^!SC015:: Send("”")
+^!SC016:: Send("Ç")
+^!SC017:: return
+^!SC018:: Send("≈")
+^!SC019:: Send("×")
+^!SC01A:: Send("‰")
+^!SC01B:: Send("£")

; === Rangée du milieu ===

+^!SC01E:: Send("≤")
+^!SC01F:: Send("≥")
+^!SC020:: return ; Touche morte Exposant en E
+^!SC021:: return ; Touche morte grec (μ) sur U
+^!SC022:: Send("·")
+^!SC023:: Send("¦")
+^!SC024:: Send("—")
+^!SC025:: Send("–")
+^!SC026:: Send("+{SC01A}") ; La touche morte ¨ sur T(réma)
+^!SC027:: return
+^!SC028:: Send("€")
+^!SC02B:: Send("¡")

; === Rangée du bas ===

+^!SC056:: return
+^!SC02C:: Send("÷")
+^!SC02D:: return ; Touche morte Indice
+^!SC02E:: return
+^!SC02F:: return
+^!SC030:: return
+^!SC031:: Send("−")
+^!SC032:: Send("§")
+^!SC033:: Send("≠")
+^!SC034:: Send("±")
+^!SC035:: Send("¿")

; ============================
; ======= 1.5) Control =======
; ============================

^SC02F:: Send("^v") ; Corrige le problème avec Win+V qui ne fonctionne pas
^SC010:: Send("^z") ; Ctrl + È donne Ctrl + Z
^SC056:: Send("^x") ; Ctrl + Ê donne Ctrl + X
^SC02C:: Send("^c") ; Ctrl + É donne Ctrl + C
^SC02D:: Send("^v") ; Ctrl + À donne Ctrl + V
