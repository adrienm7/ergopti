﻿; Generated by kalamine on 2025-01-13

#NoEnv
#Persistent
#InstallKeybdHook
#SingleInstance,       force
#MaxThreadsBuffer
#MaxThreadsPerHotKey   3
#MaxHotkeysPerInterval 300
#MaxThreads            20

SendMode Event ; either Event or Input
SetKeyDelay,   -1
SetBatchLines, -1
Process, Priority, , R
SetWorkingDir, %A_ScriptDir%
StringCaseSense, On


;-------------------------------------------------------------------------------
; On/Off Switch
;-------------------------------------------------------------------------------

global Active := True

HideTrayTip() {
  TrayTip  ; Attempt to hide it the normal way.
  if SubStr(A_OSVersion,1,3) = "10." {
    Menu Tray, NoIcon
    Sleep 200  ; It may be necessary to adjust this sleep.
    Menu Tray, Icon
  }
}

ShowTrayTip() {
  title := "Ergopti"
  text := Active ? "ON" : "OFF"
  HideTrayTip()
  TrayTip, %title% , %text%, 1, 0x31
  SetTimer, HideTrayTip, -1500
}

RAlt & Alt::
Alt & RAlt::
  global Active
  Active := !Active
  ShowTrayTip()
  return

#If Active
SetTimer, ShowTrayTip, -1000  ; not working


;-------------------------------------------------------------------------------
; DeadKey Helpers
;-------------------------------------------------------------------------------

global DeadKey := ""

; Check CapsLock status, upper the char if needed and send the char
SendChar(char) {
  if % GetKeyState("CapsLock", "T") {
    if (StrLen(char) == 6) {
      ; we have something in the form of `U+NNNN `
      ; Change it to 0xNNNN so it can be passed to `Chr` function
      char := Chr("0x" SubStr(char, 3, 4))
    }
    StringUpper, char, char
  }
  Send, {%char%}
}

DoTerm(base:="") {
  global DeadKey

  term := SubStr(DeadKey, 2, 1)

  Send, {%term%}
  SendChar(base)
  DeadKey := ""
}

DoAction(action:="") {
  global DeadKey

  if (action == "U+0020") {
    Send, {SC39}
    DeadKey := ""
  }
  else if (StrLen(action) != 2) {
    SendChar(action)
    DeadKey := ""
  }
  else if (action == DeadKey) {
    DoTerm(SubStr(DeadKey, 2, 1))
  }
  else {
    DeadKey := action
  }
}

SendKey(base, deadkeymap) {
  if (!DeadKey) {
    DoAction(base)
  }
  else if (deadkeymap.HasKey(DeadKey)) {
    DoAction(deadkeymap[DeadKey])
  }
  else {
    DoTerm(base)
  }
}


;-------------------------------------------------------------------------------
; Base
;-------------------------------------------------------------------------------

;  Digits

 SC02::SendKey("U+0031", {"*^": "U+00b9"}) ; 1

 SC03::SendKey("U+0032", {"*^": "U+00b2"}) ; 2

 SC04::SendKey("U+0033", {"*^": "U+00b3"}) ; 3

 SC05::SendKey("U+0034", {"*^": "U+2074"}) ; 4

 SC06::SendKey("U+0035", {"*^": "U+2075"}) ; 5

 SC07::SendKey("U+0036", {"*^": "U+2076"}) ; 6

 SC08::SendKey("U+0037", {"*^": "U+2077"}) ; 7

 SC09::SendKey("U+0038", {"*^": "U+2078"}) ; 8

 SC0a::SendKey("U+0039", {"*^": "U+2079"}) ; 9

 SC0b::SendKey("U+0030", {"*^": "U+2070"}) ; 0

;  Letters, first row

 SC10::SendKey("U+00e8", {}) ; è
+SC10::SendKey("U+00c8", {}) ; È

 SC11::SendKey("U+0079", {"*^": "U+0177", "*¨": "U+00ff"}) ; y
+SC11::SendKey("U+0059", {"*^": "U+0176", "*¨": "U+0178"}) ; Y

 SC12::SendKey("U+006f", {"*^": "U+00f4", "*¨": "U+00f6"}) ; o
+SC12::SendKey("U+004f", {"*^": "U+00d4", "*¨": "U+00d6"}) ; O

 SC13::SendKey("U+0077", {"*^": "U+0175", "*¨": "U+1e85"}) ; w
+SC13::SendKey("U+0057", {"*^": "U+0174", "*¨": "U+1e84"}) ; W

 SC14::SendKey("U+0062", {}) ; b
+SC14::SendKey("U+0042", {}) ; B

 SC15::SendKey("U+0066", {}) ; f
+SC15::SendKey("U+0046", {}) ; F

 SC16::SendKey("U+0067", {"*^": "U+011d"}) ; g
+SC16::SendKey("U+0047", {"*^": "U+011c"}) ; G

 SC17::SendKey("U+0068", {"*^": "U+0125", "*¨": "U+1e27"}) ; h
+SC17::SendKey("U+0048", {"*^": "U+0124", "*¨": "U+1e26"}) ; H

 SC18::SendKey("U+0063", {"*^": "U+0109"}) ; c
+SC18::SendKey("U+0043", {"*^": "U+0108"}) ; C

 SC19::SendKey("U+0078", {"*¨": "U+1e8d"}) ; x
+SC19::SendKey("U+0058", {"*¨": "U+1e8c"}) ; X

;  Letters, second row

 SC1e::SendKey("U+0061", {"*^": "U+00e2", "*¨": "U+00e4"}) ; a
+SC1e::SendKey("U+0041", {"*^": "U+00c2", "*¨": "U+00c4"}) ; A

 SC1f::SendKey("U+0069", {"*^": "U+00ee", "*¨": "U+00ef"}) ; i
+SC1f::SendKey("U+0049", {"*^": "U+00ce", "*¨": "U+00cf"}) ; I

 SC20::SendKey("U+0065", {"*^": "U+00ea", "*¨": "U+00eb"}) ; e
+SC20::SendKey("U+0045", {"*^": "U+00ca", "*¨": "U+00cb"}) ; E

 SC21::SendKey("U+0075", {"*^": "U+00fb", "*¨": "U+00fc"}) ; u
+SC21::SendKey("U+0055", {"*^": "U+00db", "*¨": "U+00dc"}) ; U

 SC22::SendKey("U+002e", {}) ; .
+SC22::SendKey("U+003a", {}) ; :

 SC23::SendKey("U+0076", {}) ; v
+SC23::SendKey("U+0056", {}) ; V

 SC24::SendKey("U+0073", {"*^": "U+015d"}) ; s
+SC24::SendKey("U+0053", {"*^": "U+015c"}) ; S

 SC25::SendKey("U+006e", {}) ; n
+SC25::SendKey("U+004e", {}) ; N

 SC26::SendKey("U+0074", {"*¨": "U+1e97"}) ; t
+SC26::SendKey("U+0054", {}) ; T

 SC27::SendKey("U+0072", {}) ; r
+SC27::SendKey("U+0052", {}) ; R

;  Letters, third row

 SC2c::SendKey("U+00e9", {}) ; é
+SC2c::SendKey("U+00c9", {}) ; É

 SC2d::SendKey("U+00e0", {}) ; à
+SC2d::SendKey("U+00c0", {}) ; À

 SC2e::SendKey("U+006a", {"*^": "U+0135"}) ; j
+SC2e::SendKey("U+004a", {"*^": "U+0134"}) ; J

 SC2f::SendKey("U+002c", {}) ; ,
+SC2f::SendKey("U+003b", {}) ; ;

 SC30::SendKey("U+006b", {}) ; k
+SC30::SendKey("U+004b", {}) ; K

 SC31::SendKey("U+006d", {}) ; m
+SC31::SendKey("U+004d", {}) ; M

 SC32::SendKey("U+0064", {}) ; d
+SC32::SendKey("U+0044", {}) ; D

 SC33::SendKey("U+006c", {}) ; l
+SC33::SendKey("U+004c", {}) ; L

 SC34::SendKey("U+0070", {}) ; p
+SC34::SendKey("U+0050", {}) ; P

 SC35::SendKey("U+0027", {}) ; '
+SC35::SendKey("U+003f", {}) ; ?

;  Pinky keys

 SC1a::SendKey("U+007a", {"*^": "U+1e91"}) ; z
+SC1a::SendKey("U+005a", {"*^": "U+1e90"}) ; Z

 SC1b::SendKey("*¨", {"*¨": "¨"})
+SC1b::SendKey("U+202f", {"*^": "U+005e", "*¨": "U+0022"}) ;  

 SC28::SendKey("U+0071", {}) ; q
+SC28::SendKey("U+0051", {}) ; Q

 SC2b::SendKey("*^", {"*^": "^"})
+SC2b::SendKey("U+0021", {}) ; !

 SC56::SendKey("U+00ea", {}) ; ê
+SC56::SendKey("U+00ca", {}) ; Ê

;  Space bar

 SC39::SendKey("U+0020", {"*^": "U+005e", "*¨": "U+0022"}) ;  
+SC39::SendKey("U+002d", {"*^": "U+005e", "*¨": "U+0022"}) ; -


;-------------------------------------------------------------------------------
; AltGr
;-------------------------------------------------------------------------------

;  Digits

;  Letters, first row

 <^>!SC10::SendKey("U+0060", {}) ; `
<^>!+SC10::SendKey("U+00e6", {}) ; æ

 <^>!SC11::SendKey("U+0040", {}) ; @
<^>!+SC11::SendKey("U+00ed", {}) ; í

 <^>!SC12::SendKey("U+0153", {}) ; œ
<^>!+SC12::SendKey("U+00f3", {}) ; ó

 <^>!SC13::SendKey("U+00f9", {}) ; ù
<^>!+SC13::SendKey("U+00d9", {}) ; Ù

 <^>!SC14::SendKey("U+00ab", {}) ; «

 <^>!SC15::SendKey("U+00bb", {}) ; »

 <^>!SC16::SendKey("U+007e", {}) ; ~
<^>!+SC16::SendKey("U+2248", {}) ; ≈

 <^>!SC17::SendKey("U+0023", {}) ; #

 <^>!SC18::SendKey("U+00e7", {}) ; ç
<^>!+SC18::SendKey("U+00c7", {}) ; Ç

 <^>!SC19::SendKey("U+002a", {}) ; *
<^>!+SC19::SendKey("U+00d7", {}) ; ×

;  Letters, second row

 <^>!SC1e::SendKey("U+003c", {}) ; <
<^>!+SC1e::SendKey("U+2264", {}) ; ≤

 <^>!SC1f::SendKey("U+003e", {}) ; >
<^>!+SC1f::SendKey("U+2265", {}) ; ≥

 <^>!SC20::SendKey("U+007b", {}) ; {

 <^>!SC21::SendKey("U+007d", {}) ; }

 <^>!SC22::SendKey("U+003a", {}) ; :
<^>!+SC22::SendKey("U+00b7", {}) ; ·

 <^>!SC23::SendKey("U+007c", {}) ; |
<^>!+SC23::SendKey("U+00a6", {}) ; ¦

 <^>!SC24::SendKey("U+0028", {"*^": "U+207d"}) ; (

 <^>!SC25::SendKey("U+0029", {"*^": "U+207e"}) ; )
<^>!+SC25::SendKey("U+00f1", {}) ; ñ

 <^>!SC26::SendKey("U+005b", {}) ; [

 <^>!SC27::SendKey("U+005d", {}) ; ]

;  Letters, third row

 <^>!SC2c::SendKey("U+002f", {}) ; /

 <^>!SC2d::SendKey("U+005c", {}) ; \
<^>!+SC2d::SendKey("U+00e1", {}) ; á

 <^>!SC2e::SendKey("U+0022", {}) ; "

 <^>!SC2f::SendKey("U+003b", {}) ; ;
<^>!+SC2f::SendKey("U+2019", {}) ; ’

 <^>!SC30::SendKey("U+2026", {}) ; …

 <^>!SC31::SendKey("U+0026", {}) ; &

 <^>!SC32::SendKey("U+0024", {}) ; $
<^>!+SC32::SendKey("U+00a7", {}) ; §

 <^>!SC33::SendKey("U+003d", {"*^": "U+207c"}) ; =
<^>!+SC33::SendKey("U+2260", {}) ; ≠

 <^>!SC34::SendKey("U+002b", {"*^": "U+207a"}) ; +
<^>!+SC34::SendKey("U+00b1", {}) ; ±

 <^>!SC35::SendKey("U+003f", {}) ; ?
<^>!+SC35::SendKey("U+00bf", {}) ; ¿

;  Pinky keys

 <^>!SC1a::SendKey("U+0025", {}) ; %
<^>!+SC1a::SendKey("U+2030", {}) ; ‰

 <^>!SC1b::SendKey("U+00a0", {"*^": "U+005e", "*¨": "U+0022"}) ;  
<^>!+SC1b::SendKey("U+00a3", {}) ; £

 <^>!SC28::SendKey("U+2019", {}) ; ’
<^>!+SC28::SendKey("U+20ac", {}) ; €

 <^>!SC2b::SendKey("U+0021", {}) ; !
<^>!+SC2b::SendKey("U+00a1", {}) ; ¡

 <^>!SC56::SendKey("U+005e", {}) ; ^

;  Space bar

 <^>!SC39::SendKey("U+005f", {"*^": "U+005e", "*¨": "U+0022"}) ; _
<^>!+SC39::SendKey("U+0020", {"*^": "U+005e", "*¨": "U+0022"}) ;  

; Special Keys

$<^>!Esc::       Send {SC01}
$<^>!End::       Send {SC4f}
$<^>!Home::      Send {SC47}
$<^>!Delete::    Send {SC53}
$<^>!Backspace:: Send {SC0e}


;-------------------------------------------------------------------------------
; Ctrl
;-------------------------------------------------------------------------------

;  Digits

;  Letters, first row

 ^SC11::Send  ^y
^+SC11::Send ^+Y

 ^SC12::Send  ^o
^+SC12::Send ^+O

 ^SC13::Send  ^w
^+SC13::Send ^+W

 ^SC14::Send  ^b
^+SC14::Send ^+B

 ^SC15::Send  ^f
^+SC15::Send ^+F

 ^SC16::Send  ^g
^+SC16::Send ^+G

 ^SC17::Send  ^h
^+SC17::Send ^+H

 ^SC18::Send  ^c
^+SC18::Send ^+C

 ^SC19::Send  ^x
^+SC19::Send ^+X

;  Letters, second row

 ^SC1e::Send  ^a
^+SC1e::Send ^+A

 ^SC1f::Send  ^i
^+SC1f::Send ^+I

 ^SC20::Send  ^e
^+SC20::Send ^+E

 ^SC21::Send  ^u
^+SC21::Send ^+U

 ^SC23::Send  ^v
^+SC23::Send ^+V

 ^SC24::Send  ^s
^+SC24::Send ^+S

 ^SC25::Send  ^n
^+SC25::Send ^+N

 ^SC26::Send  ^t
^+SC26::Send ^+T

 ^SC27::Send  ^r
^+SC27::Send ^+R

;  Letters, third row

 ^SC2e::Send  ^j
^+SC2e::Send ^+J

 ^SC30::Send  ^k
^+SC30::Send ^+K

 ^SC31::Send  ^m
^+SC31::Send ^+M

 ^SC32::Send  ^d
^+SC32::Send ^+D

 ^SC33::Send  ^l
^+SC33::Send ^+L

 ^SC34::Send  ^p
^+SC34::Send ^+P

;  Pinky keys

 ^SC1a::Send  ^z
^+SC1a::Send ^+Z

 ^SC28::Send  ^q
^+SC28::Send ^+Q

;  Space bar

