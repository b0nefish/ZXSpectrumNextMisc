;-------------------------------
; .DISPLAYEDGE
; © Peter Helcmanovsky 2020, license: https://opensource.org/licenses/MIT
;
; Displays green rectangle in tilemap 640x256x4 mode at the user defined edge and let
; the user further adjust per-pixel which pixels are well visible on his display. The
; final configuration can be then stored in /sys/displayedge.cfg file, to be readable
; by any other application. The config is for full width-pixel only (320x256 res)!
;
; Assembles with sjasmplus - https://github.com/z00m128/sjasmplus (v1.14.0+)
; For "testing" snapshot for emulators use option: -DTESTING (or uncomment define below)
;
; (TODO verify paths and if the documented filenames work)
; Reads /sys/displayedge.cfg by default, and allows user to adjust the configuration for
; current video mode (system F3 key to switch between 50/60 Hz => user can define both).
;
; There will be another set of asm source files in https://github.com/ped7g/ZXSpectrumNextMisc
; repository (hopefully it will become part of main distribution over time as well) to
; read the configuration file back and have simple API to detect the current mode and
; read back the user defined values. (TODO)
;
; command line options:
; TODO add cfg filename, and maybe CLI edit mode to write values for particular mode
; TODO without interactive part
;
; Changelist:
; v1    16/01/2020 P7G    Initial version
;
;-------------------------------
; Example of CFG file (deduct format from the example please)
/*
; full comment line
; the recognized video-mode names are: "hdmi", "zx48", "zx128", "zx128p3", "pentagon"
; the video-mode name is then appended by Hz: "_50", "_60" (pentagon only with "_50")
; the value is four decimal integers split by comma/space: left right top bottom of display
; the values are number of pixels (in 320x256 resolution) not visible to user
hdmi_50 = 1,2,3,4   ; one pixel on left side, two pixels on right, three at top, four at bottom
zx48_60=1,2,3,4
zx128_50 = 0, 0,  0, 0
zx128p3_50 = 255,255,255,255    ; can have extra comment, but will be lost by tool save
pentagon_60 = 0 0 8 16
; other whole-commented lines or unknown identifiers will be fully preserved when tool is
; storing new config (may get truncated when CFG is too big, expected size is under 3kB)
*/
;-------------------------------
/* screen layout design
- tilemode 80x32 (640x256x4) without attribute byte = 2560 bytes map
- the rectangle around (invisible part is solid "//" pattern, green frame is 8 dynamically
drawn chars gfx, inner part is "space" char)
- there is arrow pointing to particular edge of screen
 -- O/P to turn arrow counterclockwise/clockwise
 -- J (-)/K (+) to remove/add margin (H/L to remove/add per 8px)
 -- some button to flip 50/60Hz (although F3 will work too)
- near H/J/K/L controls there is current margin in pixels (decimal value)
- at bottom there is filename of cfg file (being edited)
- status of the file (new, no change, edited-needs save), buttons to reload/save
- on right there is table for all modes, emphasing current display mode and selected value

+-=-=-=-=-=-+-=-=-=-=-=--=-=-=-+-=-=-=-=-=--=-=-=-+
|           |       50 Hz      |       60 Hz      |
+-=-=-=-=-=-+-=-=-=-=-=--=-=-=-+-=-=-=-=-=--=-=-=-+
|           |        99        | v    > 99 <      |  Controls:  !
| HDMI      | 99 *modified* 99 | 99 *current*  99 |
| (locked)  |        99        | ^      99        | O > right P ! "< left"/"^ top"/"> right"/"v bot."
+-=-=-=-=-=-+-=-=-=-=-=--=-=-=-+-=-=-=-=-=--=-=-=-+
|           |        99        |        99        |     99      !
| ZX48      | 99 *modified* 99 | 99 *current*  99 | -8 -1 +1 +8 !
|           |        99        |        99        |  H  J  K  L !
+-=-=-=-=-=-+-=-=-=-=-=--=-=-=-+-=-=-=-=-=--=-=-=-+
|           |        99        |        99        | *S*ave      ! green dots before first tap
| ZX128     | 99 *modified* 99 | 99 *current*  99 | *R*eload    ! red dots after first tap (to confirm)
|           |        99        |        99        | *Q*uit      !
+-=-=-=-=-=-+-=-=-=-=-=--=-=-=-+-=-=-=-=-=--=-=-=-+ *T*iming    !
|           |        --        |        99        |
| ZX128+3   | -- not in cfg -- | 99 *current*  99 | press       !
|           |        --        |        99        | S/R/Q/T     !
+-=-=-=-=-=-+-=-=-=-=-=--=-=-=-+-=-=-=-=-=--=-=-=-+ twice to    !
|           |        99        |                  | confirm     !
| pentagon  | 99 *modified* 99 |                  |
|           |        99        |                  |
+-=-=-=-=-=-+-=-=-=-=-=--=-=-=-+-=-=-=-=-=--=-=-=-+ file [*new] !
$/sys/displayedge.cfg

video mode table is 51x23 +1 for filename
screen estate is 64x24 (without the extra +-32px on sides, just regular 256x192)
file status: "*new","*mod","*ok "  (yellow dot for new+mod, green for ok)
asciiart: swap left/right side, the table is on right side, controls on left

*/
;-------------------------------
    device zxspectrum48
    OPT reset --zxnext --syntax=abfw
;-------------------------------

;     DEFINE TESTING
    DEFINE DISP_ADDRESS     $2000
    DEFINE SP_ADDRESS       $3D00
    IFNDEF TESTING
        DEFINE ORG_ADDRESS      $2000
    ELSE
        OPT --zxnext=cspect
        DEFINE ORG_ADDRESS      $8003
        DEFINE TEST_CODE_PAGE   223         ; using the last page of 2MiB RAM (in emulator)
    ENDIF

    DEFINE TILE_MAP_ADR     $4000           ; 80*32 = 2560 (10*256)
    DEFINE TILE_GFX_ADR     $4A00           ; 128*32 = 4096
                                            ; = 6656 $1A00 -> fits into ULA classic VRAM

    STRUCT S_MODE_EDGES
        ; main values
left        BYTE    0
right       BYTE    0
top         BYTE    0
bottom      BYTE    0
        ; original values (from file), if 255, then this mode is new (not in file)
oLeft       BYTE    -1
oRight      BYTE    -1
oTop        BYTE    -1
oBottom     BYTE    -1
        ; internal flags and intermediate values
leftT       BYTE    0       ; full tiles left
rightT      BYTE    0       ; full tiles right
midT        BYTE    0       ; amount of semi top/bottom tiles (w/o left/right corner tiles)
        ; bit masks to redraw gfx tile with Green/Background color (columns/rows in bits)
        ; preserve the order of offsets, they are processed in "++DE" way
maskLeftG   BYTE    0
maskLeftB   BYTE    0
maskRightG  BYTE    0
maskRightB  BYTE    0
maskTopG    BYTE    0
maskTopB    BYTE    0
maskBottomG BYTE    0
maskBottomB BYTE    0
    ENDS

;; some further constants, mostly machine/API related
    INCLUDE "constants.i.asm"

;-----------------------------------------------------------------------------
;-- ESX DOS functions
M_GETSETDRV                     equ $89     ; get current drive (or use A='*'/'$' for current/system drive!)
M_GETHANDLE                     equ $8D     ; get file handle of current dot command
M_GETERR                        equ $93
F_OPEN                          equ $9A
F_CLOSE                         equ $9B
F_READ                          equ $9D
F_SEEK                          equ $9F
F_FGETPOS                       equ $A0
F_RENAME                        equ $B0
FA_READ                         equ $01

;; helper macros

ESXDOS      MACRO service? : push hl : pop ix : rst $08 : db service? : ENDM    ; copies HL into IX
NEXTREG2A   MACRO nextreg? : ld a,nextreg? : call readNextReg2A : ENDM
CSP_BREAK   MACRO : IFDEF TESTING : break : ENDIF : ENDM

;;-------------------------------
;; Start of the machine code itself
;;-------------------------------

        ORG     ORG_ADDRESS
__bin_b DISP    DISP_ADDRESS

start:
    ;; close the file handle of the dot command itself
        push    hl
        rst $08 : db M_GETHANDLE
        rst $08 : db F_CLOSE
        pop     hl

    ;; parse the arguments on command line (HL = arguments)
        ; no options implemented yet

    ;; page-in the bank5 explicitly (just to be sure it's Bank 5 there)
        nextreg MMU2_4000_NR_52,5*2
        nextreg MMU3_6000_NR_53,5*2+1

    ;; copy the font data to Bank 5 VRAM (also to create buffer to parse .cfg file)
        ld      hl,tilemapFont_char24
        ld      de,TILE_GFX_ADR + 24*32
        ld      bc,(128-24)*32
        ldir

    ;; read the current cfg file and parse the values, maybe remember which modes are stored
    ; FIXME all

    ;; set Tilemode 80x32 (640x256x4)
        ; enter it in a way to make it possible to restore the original mode completely
        ; i.e. read old_$69 and do $69=0 (layer2 off, bank 5 ULA, no timex mode)
        ; preserve also the $6x tilemap registers and set my tilemap mode
        ; preserve tilemap clip window, reset it to full res
        ; preserve layer priorities, set ula (tiles) on top to be sure
        ; disable ULA pixels? (is it part of tile $6x?)
        ; preserve also transparency[global,tiles], transparency fallback colour

        ;FIXME all the preservations

        ; set up the tilemode and machine state
        nextreg TURBO_CONTROL_NR_07,3               ; 28Mhz mode
        nextreg SPRITE_CONTROL_NR_15,%000'100'00    ; layer priority: USL
        nextreg TRANSPARENCY_FALLBACK_COL_NR_4A,0   ; black transparency fallback color
        nextreg TILEMAP_TRANSPARENCY_I_NR_4C,$0F
        nextreg ULA_CONTROL_NR_68,$80               ; disable ULA layer
        nextreg DISPLAY_CONTROL_NR_69,0             ; layer2 off, bank 5, timex=0
        nextreg TILEMAP_CONTROL_NR_6B,%1110'0011    ; 80x32x1, 4bpp, pal0, 512tile-mode, force tile-over-ULA
        nextreg TILEMAP_DEFAULT_ATTR_NR_6C,$00      ; no pal offset, no mirror/rot, 0 bit8
        nextreg TILEMAP_BASE_ADR_NR_6E,high TILE_MAP_ADR
        nextreg TILEMAP_GFX_ADR_NR_6F,high TILE_GFX_ADR
        ; reset tile-clipping write-index, and reset clip window
        nextreg CLIP_WINDOW_CONTROL_NR_1C,%0000'1000
        nextreg CLIP_TILEMAP_NR_1B,0
        nextreg CLIP_TILEMAP_NR_1B,159
        nextreg CLIP_TILEMAP_NR_1B,0
        nextreg CLIP_TILEMAP_NR_1B,255
        ; reset tilemode [x,y] offset
        nextreg TILEMAP_XOFFSET_MSB_NR_2F,0
        nextreg TILEMAP_XOFFSET_LSB_NR_30,0
        nextreg TILEMAP_YOFFSET_NR_31,0
        ; set tilemap palette
        nextreg PALETTE_CONTROL_NR_43,%0'011'0000   ; tilemap pal0
        nextreg PALETTE_INDEX_NR_40,0
        ld      hl,tilemapPalette
        ld      b,tilemapPalette_SZ
.setPalLoop:
        ld      a,(hl)
        inc     hl
        nextreg PALETTE_VALUE_9BIT_NR_44,a
        djnz    .setPalLoop

    ;; enter the interactive loop (make sure the screen will get full refresh)
    ; FIXME all
        ; if mode did change (or tainted by first time) - redraw everything
        ; listen to keys, redraw edge and control graphics
        ; when "save" is requested, parse the old cfg file and overwrite/add new data:
        ; - probably rename old to backup, open for read, open for write new cfg, copy
        ; - all comment lines, write modified lines instead of old values where needed
        ; - add new modes after the other block, close the files
        ; - (delete old backup before first step)
        ; when "quit" is requested, restore tilemap mode to previous values and do
        ; classic ULA CLS (shouldn't hurt even if the user was in different mode)
        ; and return.

        call    RedrawMainMap

debugLoop1:
        ld      ix,debugEdges   ;;DEBUG
        call    RedrawEdge

        ; DEBUG HALT
        ei
        halt
        ld      a,(debugEdges.left)
        inc     a
        and     31
        ld      (debugEdges.left),a
        ld      (debugEdges.right),a
        ld      (debugEdges.top),a
        ld      (debugEdges.bottom),a

; debugWaitForKey:
;         xor     a
;         in      a,(254)
;         rra
;         jr      c,debugWaitForKey
        .2 halt
        jr      debugLoop1

    ;; return to NextZXOS with "no error"
    ; - CF=0 when exiting (CF=1 A=esx_err, CF=1, A=0, HL="dc" custom error string)
        xor     a
        ret

debugEdges:  S_MODE_EDGES {15, 15, 15, 15}

;-------------------------------

;-------------------------------
RedrawEdge:
    ;; reset dynamic tiles gfx, chars numbers:
    ; TOP:      $10 $16 $11
    ; MIDDLE:   $12 ' ' $13  **$18** (full)
    ; BOTTOM:   $14 $17 $15

    ; copy fully invisible tile ($18) to all others as base of drawing
        ld      hl,TILE_GFX_ADR + $19 * 32 - 1  ; $18 as source of stripe data (full tile)
        ld      de,TILE_GFX_ADR + $18 * 32 - 1  ; copy downward to $17 .. $10 tiles
        ld      bc,8 * 32
        lddr
    ; calculate bit-masks for left/right/top/bottom sides to make drawing tiles easy
        ; read the masks for all sides from tables (too lazy to calculate them in code)
        ; two masks for each side (first creates green frame, second background fill)

        MACRO LdiTwoValuesFromTableByAnd table?, value?, and_mask?
            ld      hl,table?
            ld      a,value?
            and     and_mask?
            add     hl,a
            ldi
            ldi
        ENDM

        push    ix
        pop     de
        add     de,S_MODE_EDGES.maskLeftG   ; DE = ix+S_MODE_EDGES.maskLeftG
        LdiTwoValuesFromTableByAnd  RedrawTileMasksLeft,    (ix+S_MODE_EDGES.left),     3
        LdiTwoValuesFromTableByAnd  RedrawTileMasksRight,   (ix+S_MODE_EDGES.right),    3
        LdiTwoValuesFromTableByAnd  RedrawTileMasksTop,     (ix+S_MODE_EDGES.top),      7
        LdiTwoValuesFromTableByAnd  RedrawTileMasksBottom,  (ix+S_MODE_EDGES.bottom),   7

    ; now further patch the actual tiles gfx with these bit-masks which pixel to draw
        ; two masks to cover vertical/horizontal pixels 0 = keep stripes, 1 = draw pixel
        ; horizontal mask is 4b copied twice: %0011'0011 => will draw right 4 pixels, keep 4 left
    ; green filling to create "frame" gfx
        ld      hl,TILE_GFX_ADR + $10 * 32
        ld      a,$66           ; draw green full-width pixel (2x1)
        ld      d,(ix+S_MODE_EDGES.maskTopG)
        ld      e,(ix+S_MODE_EDGES.maskLeftG)
        call    RedrawTile
        ld      e,(ix+S_MODE_EDGES.maskRightG)
        call    RedrawTile
        ld      d,$FF           ; all rows
        ld      e,(ix+S_MODE_EDGES.maskLeftG)
        call    RedrawTile
        ld      e,(ix+S_MODE_EDGES.maskRightG)
        call    RedrawTile
        ld      d,(ix+S_MODE_EDGES.maskBottomG)
        ld      e,(ix+S_MODE_EDGES.maskLeftG)
        call    RedrawTile
        ld      e,(ix+S_MODE_EDGES.maskRightG)
        call    RedrawTile
        ld      e,$FF           ; all columns
        ld      d,(ix+S_MODE_EDGES.maskTopG)
        call    RedrawTile
        ld      d,(ix+S_MODE_EDGES.maskBottomG)
        call    RedrawTile
    ; background filling to finalize the "frame" gfx
        ld      hl,TILE_GFX_ADR + $10 * 32
        xor     a               ; draw background
        ld      d,(ix+S_MODE_EDGES.maskTopB)
        ld      e,(ix+S_MODE_EDGES.maskLeftB)
        call    RedrawTile
        ld      e,(ix+S_MODE_EDGES.maskRightB)
        call    RedrawTile
        ld      d,$FF
        ld      e,(ix+S_MODE_EDGES.maskLeftB)
        call    RedrawTile
        ld      e,(ix+S_MODE_EDGES.maskRightB)
        call    RedrawTile
        ld      d,(ix+S_MODE_EDGES.maskBottomB)
        ld      e,(ix+S_MODE_EDGES.maskLeftB)
        call    RedrawTile
        ld      e,(ix+S_MODE_EDGES.maskRightB)
        call    RedrawTile
        ld      e,$FF           ; all columns
        ld      d,(ix+S_MODE_EDGES.maskTopB)
        call    RedrawTile
        ld      d,(ix+S_MODE_EDGES.maskBottomB)
        call    RedrawTile

    ;; now redraw the tile map in the border area

    ; calculate left/middle/right tiles numbers for side-rows
        ld      a,(ix+S_MODE_EDGES.left)
        srl     a
        srl     a
        ld      (ix+S_MODE_EDGES.leftT),a       ; pixels/4
        ld      b,a
        ld      a,(ix+S_MODE_EDGES.right)
        srl     a
        srl     a
        ld      (ix+S_MODE_EDGES.rightT),a      ; pixels/4
        add     a,b
        neg
        add     a,80-2
        ld      (ix+S_MODE_EDGES.midT),a        ; middleT = 80 - leftT - rightT - 2
    ; fill the full-tile chars at top and the top edge of green frame
        ld      c,$18           ; full tile char
        ld      hl,$4000
        ld      a,(ix+S_MODE_EDGES.top)
        call    FillFullBorderRows
        ; HL = address to draw top semi-edge
        ld      de,$1016
        call    FillDetailedRow
    ; fill remaining border top rows with clearing rows (drawing space in middle)
.clearingTopRow:
        bit     0,h     ; 3*80 = 240, 4*80 = 320 -> after four lines the H=$41
        jr      nz,.noClearingTopRow
        ld      de,$1220        ; E=' '
        call    FillDetailedRow
        jr      .clearingTopRow
.noClearingTopRow:
    ; fill 24 rows clearing sides, but skipping 64 chars in middle (64x24 = PAPER area)
        ld      de,(' '<<8)|24  ; D = space char, E = counter
.drawSideRowsLoop:
        ld      b,(ix+S_MODE_EDGES.leftT)
        call    FillBCharsWithC
        ld      (hl),$12
        inc     hl
.clearLeftSide:
        bit     3,l             ; left border ends when +8 is set in address
        jr      nz,.clearLeftSideDone
        ld      (hl),d
        inc     hl
        jr      .clearLeftSide
.clearLeftSideDone:
        add     hl,64           ; skip the middle part
        ld      a,8-1
        sub     (ix+S_MODE_EDGES.rightT)
        jr      z,.clearRightSideDone
.clearRightSide:
        ld      (hl),d
        inc     hl
        dec     a
        jr      nz,.clearRightSide
.clearRightSideDone:
        ld      (hl),$13
        inc     hl
        ld      b,(ix+S_MODE_EDGES.rightT)
        call    FillBCharsWithC
        dec     e
        jr      nz,.drawSideRowsLoop
    ; draw the clearing bottom part
        ld      a,23
        sub     (ix+S_MODE_EDGES.bottom)    ; CF=1 for 24..31 pixels (no clearing row)
        jr      .clearingBottomRowEntry
.clearingBottomRow:
        ld      de,$1220        ; E=' '
        call    FillDetailedRow
        sub     8               ; one more full line to clear?
.clearingBottomRowEntry:
        jr      nc,.clearingBottomRow
    ; draw the bottom part of frame, fill remaining bottom and exit
        ld      de,$1417
        call    FillDetailedRow
        ld      a,(ix+S_MODE_EDGES.bottom)
        ;  |
        ; fallthrough to FillFullBorderRows
        ;  |
FillFullBorderRows:
    ; HL = start address, A = edge pixels, C = tile char ($18)
        and     ~7              ; whole full-rows, pre-multiplied by 8
        ld      e,a
        ld      d,80/8
        mul     de              ; whole full-rows * 80 = 0..240 (3*80 = 240) (fits 8b)
        ld      b,e
        ;  |
        ; fallthrough to FillBCharsWithC
        ;  |
FillBCharsWithC:
        ; check if called with B==0
        inc     b
        dec     b
        ret     z
.fillChars:
        ld      (hl),c
        inc     hl
        djnz    .fillChars
        ret

FillDetailedRow:
    ; HL = address, D = left char (+1 right char), E = middle char, C = $18 (tile char)
        ld      b,(ix+S_MODE_EDGES.leftT)
        call    FillBCharsWithC
        ld      (hl),d
        inc     hl
        ld      c,e
        ld      b,(ix+S_MODE_EDGES.midT)
        call    FillBCharsWithC
        inc     d
        ld      (hl),d
        inc     hl
        ld      c,$18
        ld      b,(ix+S_MODE_EDGES.rightT)
        jr      FillBCharsWithC

RedrawTile:
    ; A = color to draw (two 4bpp pixels together), HL = tile address
    ; D = vertical mask, E = horizontal mask (0 = keep, 1 = draw) (masks are AND-ed)
    ; horizontal mask is only 4b, but copied twice
        ld      b,8
.RowsLoop:
        rlc     d
        jr      nc,.keepFullRowOfStripes
        DUP     4           ; 4x2 = 8 pixels per row
            rlc     e
            jr      nc,$+2+1    ; skip draw
            ld      (hl),a      ; draw two pixels at time (4bpp)
            inc     hl
        EDUP
        djnz    .RowsLoop
        ret
.keepFullRowOfStripes:
        .4  inc     hl  ; HL += 4 (skip full row)
        djnz    .RowsLoop
        ret

RedrawTileMasksLeft:
        DB      $FF, $77, $33, $11,  $00
RedrawTileMasksRight:
        DB      $FF, $EE, $CC, $88,  $00
RedrawTileMasksTop:
        DB      $FF, $7F, $3F, $1F,  $0F, $07, $03, $01,  $00
RedrawTileMasksBottom:
        DB      $FF, $FE, $FC, $F8,  $F0, $E0, $C0, $80,  $00

;-------------------------------
RedrawMainMap:
        ; clear full map first with space character
        ld      hl,$4000
        ld      de,$4001
        ld      bc,80*32-1
        ld      (hl),' '
        ldir
        ; draw table grid 51x23 ... do the horizontal lines first, position it at [21,4]
        ld      hl,$4000 + 4*80 + 21
        call    DrawTableGridHorizontalLine
        ld      hl,$4000 + 6*80 + 21
        ld      c,6
.tableGridHorizontalLoop:
        call    DrawTableGridHorizontalLine
        add     hl,80-51 + 3*80
        dec     c
        jr      nz,.tableGridHorizontalLoop
        ld      hl,$4000 + 4*80 + 21
        call    DrawTableGridVerticalLine
        ld      hl,$4000 + 4*80 + 21 + 12
        call    DrawTableGridVerticalLine
        ld      hl,$4000 + 4*80 + 21 + 12 + 19
        call    DrawTableGridVerticalLine
        ld      hl,$4000 + 4*80 + 21 + 12 + 19*2
        call    DrawTableGridVerticalLine
        ; draw fixed legend text
        ld      hl,FixedLegendText
        ;  |
        ; fallthrough to DrawStringsWithAddressData
        ;  |
DrawStringsWithAddressData:
        call    DrawStringWithAddressData
        jr      nz,DrawStringsWithAddressData
        ret

; HL = address of data: DW adr, DC text (with bit 7 set on last char)
; returns HL after the string, ZF=1 when "adr" was not $4xxx, ZF=0 otherwise
DrawStringWithAddressData:
        ld      e,(hl)
        inc     hl
        ld      d,(hl)
        inc     hl
        bit     6,d
        ret     z       ; DE was not $4xxx address, exit with ZF=1
.stringLoop:
        ld      a,(hl)
        and     $7F
        ld      (de),a
        inc     de
        bit     7,(hl)
        inc     hl
        jr      z,.stringLoop
        ret

DrawTableGridHorizontalLine:
        ld      a,'='
        ld      b,51
.loop:
        ld      (hl),a
        inc     hl
        xor     '=' ^ '-'
        djnz    .loop
        ret

DrawTableGridVerticalLine:
        ld      b,23
.loop:
        ld      a,' '
        cp      (hl)
        ld      a,'+'
        jr      nz,.doThePlusChar
        ld      a,'|'
.doThePlusChar:
        ld      (hl),a
        add     hl,80
        djnz    .loop
        ret

FixedLegendText:
        DW      $4000 + 5*80 + 21 + 20
        DC      "50 Hz"
        DW      $4000 + 5*80 + 21 + 39
        DC      "60 Hz"
        DW      $4000 + 8*80 + 24
        DC      "HDMI"
        DW      $4000 + 12*80 + 24
        DC      "ZX48"
        DW      $4000 + 16*80 + 24
        DC      "ZX128"
        DW      $4000 + 20*80 + 24
        DC      "ZX128+3"
        DW      $4000 + 24*80 + 24
        DC      "Pentagon"
        DW      $4000 + 7*80 + 10
        DC      "Controls:"
        DW      $4000 + 9*80 + 9
        DC      "O"
        DW      $4000 + 9*80 + 19
        DC      "P"
        DW      $4000 + 12*80 + 9
        DC      "-8 -1 +1 +8"
        DW      $4000 + 13*80 + 10
        DC      "H  J  K  L"
        DW      $4000 + 15*80 + 10
        DC      "S ave"
        DW      $4000 + 16*80 + 10
        DC      "R eload"
        DW      $4000 + 17*80 + 10
        DC      "Q uit"
        DW      $4000 + 18*80 + 10
        DC      "T iming"
        DW      $4000 + 20*80 + 10
        DC      "press"
        DW      $4000 + 21*80 + 10
        DC      "S/R/Q/T"
        DW      $4000 + 22*80 + 10
        DC      "twice to"
        DW      $4000 + 23*80 + 10
        DC      "confirm"
        DW      $4000 + 26*80 + 9
        DC      "file ["
        DW      $4000 + 26*80 + 19
        DC      "]"
        ;; DEBUG
        DW      $4000 + 27*80 + 9
        DC      16,17,32,18,19,32,20,21,32,22,23,32,24,32,25,32,26,32,27,32,28,29,30,31," (debug)"
        DW      0

;-------------------------------
; PALETTE data for tilemode (full 9bit colors)
tilemapPalette:
                db  %101'101'11,0       ; 0 white-blueish (paper)
                db  %100'100'10,1       ; 1 light grey (25% ink)
                db  %010'010'01,1       ; 2 dark grey (75% ink)
                db  %000'000'00,0       ; 3 black (full ink)
                db  %110'001'00,1       ; 4 red
                db  %111'110'00,1       ; 5 yellow
                db  %000'100'00,0       ; 6 green
tilemapPalette_SZ:  EQU $ - tilemapPalette

;-------------------------------
; FONT data for tilemode (32B per char, almost 4kiB of data)
; desperate times, desperate measures: this is font designed for copper-8x6 tilemode
; TODO replace with something designed for 8x8 later

tilemapFont:    EQU     tilemapFont_char24 - 24*32
        ; 24 chars skipped (3*256)
        ; starts at character 32 - 4 dir_arrows - 3 color dots - 1 reserve = 24
tilemapFont_char24:
    OPT push listoff
        INCLUDE "tilemap_font_8x6.i.asm"
    OPT pop

;-------------------------------
;; FIXME requires cleanup (everything below)
;-------------------------------
;-------------------------------
;-------------------------------
;-------------------------------

;-------------------------------
;;FIXME just the remnants of custom error message exit
emptyLineFinish:                    ; here the stack is still old one (OS/BASIC)
        call    cleanupBeforeBasic
        ld      hl,0 ;txt_Usage        ; this fails to show anything in TESTING because ROM-mapping
        call    printmsg            ; show usage info
        ; simple `ret` is enough on real board, but continue with full returnToBasic
        ; to make it work also in TESTING, where the ROM has to be mapped back
returnToBasic:  ; cleanup as much as possible
        ei
        xor     a                   ; CF=0, A=0 (OK OK)
.err:   nop                         ; place for 'scf' in case error path reuses this
        ret

;-------------------------------
cleanupBeforeBasic:                 ; internal cleanup, before the need of old stack (must preserve HL)
        ; map C000..FFFF region back to BASIC bank
        ld      a,($5b5c)
        and     7
        ret

V_1_3_BanksOffsetTestFailed:
        call    prepareForErrorOutput
        ld      hl,0 ; FIXME errTxt_BanksOffsetMismatch
        jp      customErrorToBasic  ; will reset some things second time, but nevermind

;-------------------------------
customErrorToBasic: ; HL = message with |80 last char
        ld      a,$37               ; nop -> scf in exit path
        ld      (returnToBasic.err),a
        jp      returnToBasic

;-------------------------------
readNextReg2A:
        ld      bc,TBBLUE_REGISTER_SELECT_P_243B
        out     (c),a
        inc     b
        in      a,(c)
        ret

;-------------------------------
bankLoadDelay:
        ld      a,123
.delayL or      a
        ret     z
        ; scanline based frame delay (not allowing IM1 to damage bank 5 data)
        push    af
.scanlineWaitForMsb0:
        NEXTREG2A   RASTER_LINE_MSB_NR_1E
        rra
        jr      c,.scanlineWaitForMsb0
.scanlineWaitForMsb1:
        NEXTREG2A   RASTER_LINE_MSB_NR_1E
        rra
        jr      nc,.scanlineWaitForMsb1
        pop     af
        dec     a
        jr      .delayL

;-------------------------------
printmsg:
        ld      a,(hl)
        inc     hl
        and     a
        ret     z                       ; exit if terminator
        and     $7F                     ; clear 7th bit
        rst     $10
        jr      printmsg

;-------------------------------
fclose: ret     ; this will be modified to NOP after fopen
        ld      a,(handle)
        ESXDOS  F_CLOSE
        ld      a,201
        ld      (fclose),a              ; lock fclose behind `ret` again (nop->ret)
        ret

;-------------------------------
fread:
handle=$+1  ld a,1              ; SMC self-modify code, storage of file handle
        ESXDOS  F_READ
        ret     nc
        ; in case of error just continue into "fileError" routine
fileError:                      ; esxDOS error code arrives in a
        push    af
        and     7
        out     (254),a         ; modify also BORDER by low 3 bits of error code
        pop     af
        ld      b,1             ; return error message to 32-byte buffer at DE
        ld      de,esxError
        ESXDOS  M_GETERR
        ld      hl,esxError
        jp      customErrorToBasic

;-------------------------------
prepareForErrorOutput           ; do "CLS" of ULA screen with white paper ("error" case)
        nextreg MMU2_4000_NR_52,5*2   ; page-in the bank5 explicitly
        nextreg MMU3_6000_NR_53,5*2+1
        call    cleanupBeforeBasic
        ld      a,7             ; "error" CLS
        jr      clsWithBordercol.withA

;-------------------------------
clsWithBordercol        ; do "CLS" of ULA screen, using the border colour value from header
        ld      a,7
.withA: out     ($FE),a     ; change border colour
        ; bank 5 should be already paged in here (nextregs reset)
        ld      hl,$4000
        ld      de,$4001
        ld      bc,$1800
        ld      (hl),l
        ldir    ; HL=$5800, DE=$5801 (for next block)
        .3 add  a,a         ; *8
        ld      (hl),a
        ld      bc,32*24-1
        ldir
        ret

last:       ; after last machine code byte which should be part of the binary

    ;; reserved space for values (but not initialized, i.e. not part of the binary)
nexFileVersion  db      0       ; BCD-packed ($13 for V1.3)
esxError        ds      34
filename        ds      100 ; FIXME remove: NEXLOAD_MAX_FNAME

lastReserved:   ASSERT  lastReserved < $3D00
    ENDT        ;; end of DISP

    IFNDEF TESTING
        SAVEBIN "DISPLAYEDGE",start,last-start
    ELSE
testStart
        ; inject "jp testStart" at $8000 for easy re-run from BASIC (if not overwritten)
        ld      a,$C3
        ld      (ORG_ADDRESS-3),a
        ld      hl,testStart
        ld      (ORG_ADDRESS-2),hl
        ; move the code into 0x2000..3FFF area, faking dot command environment
        nextreg MMU1_2000_NR_51,TEST_CODE_PAGE
        ; copy the machine code into the area
        ld      hl,__bin_b
        ld      de,$2000
        ld      bc,last-start
        ldir
        ; setup fake argument and launch loader
        ld      hl,testFakeArgumentsLine
;         CSP_BREAK
        jp      $2000

testFakeArgumentsLine   DZ  " nothing yet ..."

        SAVESNA "DISPLAYEDGE.SNA",testStart
;         CSPECTMAP
    ENDIF
