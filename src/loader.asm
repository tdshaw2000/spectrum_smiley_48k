; =============================================================================
; The BASIC loader, written out byte by byte as the Spectrum stores it.
; smiley.asm includes this file, and SAVETAP puts it first on the tape.
;
;   10 CLEAR 32767
;   20 POKE 23610,255
;   30 LOAD ""CODE
;   40 RANDOMIZE USR 32768
;
; Each BASIC line is stored as:
;   line number    2 bytes, HIGH byte first (the Z80 does the opposite)
;   length         2 bytes, low byte first: the text plus the final ENTER
;   text           keywords are single bytes ("tokens"), the rest is ASCII
;   ENTER          $0D
; =============================================================================

TOKEN_CODE        equ $AF
TOKEN_USR         equ $C0
TOKEN_LOAD        equ $EF
TOKEN_POKE        equ $F4
TOKEN_RANDOMIZE   equ $F9
TOKEN_CLEAR       equ $FD

BASIC_ENTER       equ $0D
BASIC_NUMBER_MARK equ $0E

BASIC_START       equ 23755     ; where BASIC programs live on a 48K Spectrum
AUTORUN_LINE      equ 10

ERR_NR            equ 23610     ; system variable: the report code, minus 1
NO_ERROR          equ 255

; A number is its digits, for LIST to show, then a marker and a hidden 5-byte
; form, which is the one BASIC really uses. For a whole number from 0 to 65535
; that is 0, sign (0 = positive), low byte, high byte, 0.
BASIC_NUMBER    macro digits?, value?
                defb digits?
                defb BASIC_NUMBER_MARK, 0, 0
                defw value?
                defb 0
                endm

; The digits are typed in, so stop the assembly if the code moves without them.
        assert CODE_START == 32768

        org BASIC_START

loader:
line_10:
        defb high 10, low 10
        defw line_20-line_10_text
line_10_text:                   ; CLEAR: keep BASIC and its stack below our code
        defb TOKEN_CLEAR
        BASIC_NUMBER "32767", CODE_START-1
        defb BASIC_ENTER
line_20:
        defb high 20, low 20
        defw line_30-line_20_text
line_20_text:                   ; POKE: "no error" in ERR_NR
        defb TOKEN_POKE
        BASIC_NUMBER "23610", ERR_NR
        defb ","
        BASIC_NUMBER "255", NO_ERROR
        defb BASIC_ENTER
line_30:
        defb high 30, low 30
        defw line_40-line_30_text
line_30_text:                   ; LOAD ""CODE: the next code block on the tape
        defb TOKEN_LOAD, '""', TOKEN_CODE, BASIC_ENTER
line_40:
        defb high 40, low 40
        defw loader_end-line_40_text
line_40_text:                   ; RANDOMIZE USR: call our code
        defb TOKEN_RANDOMIZE, TOKEN_USR
        BASIC_NUMBER "32768", start
        defb BASIC_ENTER
loader_end:
