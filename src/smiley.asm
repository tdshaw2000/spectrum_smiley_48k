; =============================================================================
; SMILEY - move one character cell around the screen of a 48K ZX Spectrum.
;
;   Z = left   X = right   O = up   K = down   CAPS SHIFT + SPACE = BREAK
;
; Assembled with sjasmplus. See README.md for the screen and keyboard explanation.
;
; Conventions used throughout:
;   * A cell is passed in BC: B = row (0-23), C = column (0-31).
;   * IY and the alternate register HL' are never touched. The ROM needs IY in
;     its interrupt routine, and BASIC needs HL' back when we return to it.
; =============================================================================

; -----------------------------------------------------------------------------
; Constants. EQU only gives a number a name: it puts no bytes in the program.
; -----------------------------------------------------------------------------

CODE_START        equ $8000     ; first address of the "uncontended" upper 32K,
                                ; where the ULA never makes the CPU wait

; The screen: 6144 bytes of pixels followed by 768 bytes of attributes.
PIXELS_START      equ $4000
PIXELS_LENGTH     equ 6144      ; 192 lines x 32 bytes
ATTRIBUTES_START  equ $5800
ATTRIBUTES_LENGTH equ 768       ; 24 rows x 32 columns
SCREEN_ROWS       equ 24
SCREEN_COLUMNS    equ 32
CELL_LINES        equ 8         ; a cell is 8 pixel lines high

; Attribute byte: bit 7 = flash, bit 6 = bright, bits 5-3 = paper, 2-0 = ink.
SMILEY_ATTRIBUTE  equ $46       ; bright, paper 0 (black), ink 6 (yellow)
BLANK_ATTRIBUTE   equ $07       ; paper 0 (black), ink 7 (white)

START_ROW         equ 10
START_COLUMN      equ 15

; Port $FE is the ULA. Writing to it: bits 2-0 set the border colour.
ULA_PORT          equ $FE
BLACK             equ 0

; Reading it: the HIGH byte of the port address picks a half-row of five keys.
; One address bit is 0, and that bit chooses the half-row.
PORT_SHIFT_TO_V   equ $FEFE     ; CAPS SHIFT, Z, X, C, V
PORT_P_TO_Y       equ $DFFE     ; P, O, I, U, Y
PORT_ENTER_TO_H   equ $BFFE     ; ENTER, L, K, J, H
PORT_SPACE_TO_B   equ $7FFE     ; SPACE, SYMBOL SHIFT, M, N, B

; Which bit of the byte read belongs to which key. A pressed key reads as 0.
Z_BIT             equ 1         ; in PORT_SHIFT_TO_V
X_BIT             equ 2         ; in PORT_SHIFT_TO_V
O_BIT             equ 1         ; in PORT_P_TO_Y
K_BIT             equ 2         ; in PORT_ENTER_TO_H
SPACE_BIT         equ 0         ; in PORT_SPACE_TO_B; CAPS SHIFT is also a bit 0

; A move is loaded into DE: D = change of row, E = change of column.
; There are no signed registers: -1 is just $FF, because $FF + 1 wraps to 0.
MOVE_LEFT         equ $00FF     ; row  0, column -1
MOVE_RIGHT        equ $0001     ; row  0, column +1
MOVE_UP           equ $FF00     ; row -1, column  0
MOVE_DOWN         equ $0100     ; row +1, column  0

; One move every 6 frames: 50 / 6 = 8.3 moves per second.
REPEAT_FRAMES     equ 6

        ; Assemble into the memory of an imaginary 48K Spectrum. SAVETAP, at the
        ; end of this file, saves parts of that memory to the tape.
        device ZXSPECTRUM48

        org CODE_START

; -----------------------------------------------------------------------------
; start - where RANDOMIZE USR 32768 arrives.
; USR is a CALL: BASIC's return address is on the stack, so a RET at this level
; goes back to BASIC. Everything is set up here rather than relying on values
; from the tape, so the program can be run again after BREAK.
; -----------------------------------------------------------------------------
start:
        ei                      ; HALT waits for an interrupt, so with
                                ; interrupts off it would wait for ever
        ld a,BLACK
        out (ULA_PORT),a        ; black border

        call clear_screen

        ; B and C are the two halves of BC, so one load sets row and column.
        ld bc,START_ROW*256+START_COLUMN
        ld (position),bc

        xor a                   ; A = 0 (XOR with itself: shorter than LD A,0)
        ld (repeat_delay),a     ; no wait before the first move

        call draw_smiley        ; BC still holds the starting cell

; -----------------------------------------------------------------------------
; main_loop - runs once per frame.
; HALT stops the CPU until the next interrupt, which the ULA makes 50 times a
; second, just as it starts a new TV frame. The ULA is then drawing the border
; above the picture, so we have time to change the screen without flicker.
; -----------------------------------------------------------------------------
main_loop:
        halt

        call check_break        ; Z flag set if BREAK is pressed
        ret z                   ; back to BASIC

        call read_direction     ; Z flag set if a movement key is pressed
        jr nz,no_key            ; and then DE = the move

        ; A key is down. Has the repeat delay run out?
        ld a,(repeat_delay)
        or a                    ; OR A changes nothing, but sets Z if A is 0
        jr nz,still_waiting

        ; Yes: restart the delay and move. This frame is the first of the six,
        ; which leaves five to wait.
        ld a,REPEAT_FRAMES-1
        ld (repeat_delay),a
        call move_smiley
        jr main_loop

still_waiting:
        dec a                   ; one frame fewer to wait
        ld (repeat_delay),a
        jr main_loop

no_key:
        xor a                   ; nothing held: forget the delay, so that the
        ld (repeat_delay),a     ; next press moves at once
        jr main_loop

; -----------------------------------------------------------------------------
; check_break - is BREAK (CAPS SHIFT + SPACE) pressed?
;   Out:     Z flag set if both keys are down
;   Changes: A, BC, D
; -----------------------------------------------------------------------------
check_break:
        ; IN A,(C) puts all of BC on the address bus, not only C. That is how
        ; B selects the half-row.
        ld bc,PORT_SHIFT_TO_V
        in a,(c)
        ld d,a                  ; keep it while we read the other half-row
        ld bc,PORT_SPACE_TO_B
        in a,(c)

        ; Both keys are bit 0 of their half-rows, and 0 means pressed. After
        ; the OR, bit 0 is 0 only if it was 0 in both bytes.
        or d
        bit SPACE_BIT,a         ; Z = bit is 0 = both pressed
        ret

; -----------------------------------------------------------------------------
; read_direction - which movement key is pressed?
; The keys are tested in order Z, X, O, K, and the first one pressed wins, so a
; move is never diagonal.
;   Out:     Z flag set if a key is pressed, and DE = its move
;            Z flag clear if none is pressed (DE is then meaningless)
;   Changes: A, BC, DE
; BIT n,A sets Z when bit n is 0, which is exactly "pressed". LD changes no
; flags, so each RET Z acts on the BIT just before it.
; -----------------------------------------------------------------------------
read_direction:
        ld bc,PORT_SHIFT_TO_V
        in a,(c)
        ld de,MOVE_LEFT
        bit Z_BIT,a
        ret z
        ld de,MOVE_RIGHT        ; same half-row, so no need to read it again
        bit X_BIT,a
        ret z

        ld bc,PORT_P_TO_Y
        in a,(c)
        ld de,MOVE_UP
        bit O_BIT,a
        ret z

        ld bc,PORT_ENTER_TO_H
        in a,(c)
        ld de,MOVE_DOWN
        bit K_BIT,a
        ret                     ; Z or not Z: the caller finds out

; -----------------------------------------------------------------------------
; move_smiley - move by DE, unless that would leave the screen.
;   In:      D = change of row, E = change of column (each -1, 0 or +1)
;   Changes: A, BC, DE, HL
; One unsigned compare catches both edges. Moving up from row 0 gives
; 0 + $FF = 255, and 255 is "not less than 24", the same as row 24.
; CP n sets the carry flag if A < n, so NC means off the screen.
; -----------------------------------------------------------------------------
move_smiley:
        ld bc,(position)        ; B = old row, C = old column

        ld a,b
        add a,d
        cp SCREEN_ROWS
        ret nc                  ; off the top or bottom: stay where we are
        ld d,a                  ; D = new row

        ld a,c
        add a,e
        cp SCREEN_COLUMNS
        ret nc                  ; off the left or right: stay where we are
        ld e,a                  ; E = new column

        ; The move is allowed. erase_cell uses BC and HL, and the stack keeps
        ; the new cell safe meanwhile. PUSH DE, POP BC also copies DE to BC.
        push de
        call erase_cell         ; BC = old cell
        pop bc                  ; BC = new cell
        ld (position),bc
        jp draw_smiley          ; JP, not CALL then RET: draw_smiley's own RET
                                ; goes back to our caller

; -----------------------------------------------------------------------------
; clear_screen - blank all pixels and set every attribute to BLANK_ATTRIBUTE.
;   Changes: A, BC, DE, HL
; LDIR copies BC bytes from (HL) to (DE), going upwards. If DE is HL + 1, each
; byte copied becomes the source of the next copy, so the first byte spreads
; through the whole block.
; -----------------------------------------------------------------------------
clear_screen:
        ld hl,PIXELS_START
        ld de,PIXELS_START+1
        ld bc,PIXELS_LENGTH-1   ; -1 because we write the first byte ourselves
        ld (hl),0
        ldir

        ld hl,ATTRIBUTES_START
        ld de,ATTRIBUTES_START+1
        ld bc,ATTRIBUTES_LENGTH-1
        ld (hl),BLANK_ATTRIBUTE
        ldir
        ret

; -----------------------------------------------------------------------------
; draw_smiley - draw the smiley in a cell.
;   In:      B = row, C = column
;   Changes: A, B, DE, HL
; -----------------------------------------------------------------------------
draw_smiley:
        call cell_attribute_address
        ld (hl),SMILEY_ATTRIBUTE

        call cell_pixel_address
        ld de,smiley_bitmap
        ld b,CELL_LINES         ; DJNZ counts down in B
draw_line:
        ld a,(de)
        ld (hl),a
        inc de                  ; next byte of the bitmap
        inc h                   ; next pixel line: adding 1 to H adds 256 to HL
        djnz draw_line          ; B = B - 1, and loop unless it is now 0
        ret

; -----------------------------------------------------------------------------
; erase_cell - zero a cell's 8 pixel bytes and reset its attribute.
;   In:      B = row, C = column
;   Changes: A, B, HL
; -----------------------------------------------------------------------------
erase_cell:
        call cell_attribute_address
        ld (hl),BLANK_ATTRIBUTE

        call cell_pixel_address
        xor a                   ; A = 0: eight pixels off
        ld b,CELL_LINES
erase_line:
        ld (hl),a
        inc h
        djnz erase_line
        ret

; -----------------------------------------------------------------------------
; cell_pixel_address - address of the top pixel line of a cell.
;   In:      B = row, C = column
;   Out:     HL = $4000 + ((row AND $18) << 8) + ((row AND 7) << 5) + column
;   Changes: A, HL
; In binary, with the row as RRrrr and the column as ccccc:
;   H = 010RR000   (the lowest three bits choose the pixel line: 0 = top)
;   L = rrrccccc
; The parts never overlap, so OR can join them instead of ADD.
; -----------------------------------------------------------------------------
cell_pixel_address:
        ld a,b
        and $18                 ; keep RR, which are already in the right place
        or high PIXELS_START    ; HIGH gives the high byte, $40
        ld h,a

        ld a,b
        and $07                 ; keep rrr: A = 00000rrr
        rrca                    ; rotate right three times. The bits that fall
        rrca                    ; off the right come back on the left, so
        rrca                    ; A = rrr00000, the same as shifting left 5
        or c                    ; add the column
        ld l,a
        ret

; -----------------------------------------------------------------------------
; cell_attribute_address - address of a cell's attribute byte.
;   In:      B = row, C = column
;   Out:     HL = $5800 + row * 32 + column
;   Changes: A, HL
; -----------------------------------------------------------------------------
cell_attribute_address:
        ld l,b
        ld h,0                  ; HL = row, in 16 bits (23 * 32 needs more than 8)
        add hl,hl               ; row * 2
        add hl,hl               ; row * 4
        add hl,hl               ; row * 8
        add hl,hl               ; row * 16
        add hl,hl               ; row * 32: the low five bits are now 0...
        ld a,l
        or c                    ; ...so OR adds the column
        ld l,a
        ld a,h
        or high ATTRIBUTES_START
        ld h,a
        ret

; -----------------------------------------------------------------------------
; Data
; -----------------------------------------------------------------------------

smiley_bitmap:                  ; one byte per line, one bit per pixel
        defb $3C                ; ..####..
        defb $42                ; .#....#.
        defb $A5                ; #.#..#.#
        defb $81                ; #......#
        defb $A5                ; #.#..#.#
        defb $99                ; #..##..#
        defb $42                ; .#....#.
        defb $3C                ; ..####..

; Variables. start sets them, so these values do not matter. The Z80 stores a
; word low byte first: C (column) is at position, B (row) at position + 1.
position:
        defw 0
repeat_delay:                   ; frames to wait before a held key moves again
        defb 0
code_end:

; -----------------------------------------------------------------------------
; The tape: the BASIC loader, then the machine code. Each SAVETAP writes a
; header block and a data block. The file goes in the folder that the Makefile
; names with --outprefix.
; -----------------------------------------------------------------------------
        include "loader.asm"

        emptytap "smiley.tap"
        savetap "smiley.tap",BASIC,"loader",loader,loader_end-loader,AUTORUN_LINE
        savetap "smiley.tap",CODE,"smiley",start,code_end-start
