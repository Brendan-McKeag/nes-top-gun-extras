; ---------------------------------------------------------------------------
; Top Gun (USA) (Rev 1) - "Extras" menu hack
;
; Adds a title-screen menu (Select moves the cursor, Start chooses):
;   GAME START     - normal game
;   STAFF CREDITS  - shows the unused staff credits that are still in
;                    bank 6 ($9964-$9AD1), read straight from the ROM data
;   SPRITE VIEWER  - starts a game with Konami's orphaned sprite viewer
;                    routine ($E9FF) called after every controller read
;   DEMO RECORDER  - starts a game with Konami's orphaned attract-demo
;                    recorder ($CFA7) running; recorded pairs show in the radar
;   DEMO CHECK     - plays the attract demo while the same recorder runs
;                    alongside it, checking every pair against the ROM table
;   UNUSED SOUND   - plays sound $24, the one sound nothing in the game calls
;
; All new code lives in unused $FF padding of the fixed bank ($ED80-).
; Hooks into the original code (written separately by the build script):
;   $C010  JMP NewDispatch   (extended main-state jump table, adds state $0C)
;   $C3DA  JMP MenuStart     (title Start handler)
;   $C3DF  JMP MenuSelect    (title Select handler - was the dead $22 toggle)
;   $EAC6  JSR ViewerPad     (NMI controller read: sprite viewer)
;   $CE69  JSR RecDemoHook   (attract demo playback: recorder check)
; ---------------------------------------------------------------------------
.setcpu "6502"

; ---- RAM ------------------------------------------------------------------
; The game's own variables, except those marked "(free)": RAM the retail
; game never uses, claimed by this patch.
tmp0      = $00
tmp1      = $01
tmp2      = $02
tmp3      = $03
GameState = $18
SubState  = $19
FrameCnt  = $1A
MuteFlag  = $1C          ; 1 = attract/title mode, sound whitelist active
LastSet   = $1D          ; (free) last sprite set shown on the HUD
LastFrame = $1E          ; (free) last sprite frame shown on the HUD
BufIdx    = $21          ; PPU update buffer write index
Cursor    = $22          ; was the write-only title "Select" toggle
MenuStep  = $24          ; (free) 0..7 = drawing menu, 8 = done
ViewerOn  = $25          ; (free) sprite viewer enabled
P1Real    = $26          ; (free) true P1 held state (for input masking)
TimerLo   = $2C
TimerHi   = $2D
P1Held    = $F1
P1New     = $F5
P2New     = $F6
PpuBuf    = $0700
RecCheck  = $0E          ; (free) 1 = compare pairs with the ROM demo table
RecPrevF  = $1D          ; (= LastSet; viewer and recorder never run together)
RecOn     = $0106        ; recorder enabled          (free page-1 RAM)
RecCount  = $0107        ; pairs logged
RecRow    = $0108        ; next radar-box row for the log (0-6)
RecTab    = $0109        ; offset of the next ROM table entry to compare
ShA       = $010A        ; recorder's own $2A/$2B/$2F while it shadows the
ShB       = $010B        ;   attract demo (the playback uses the same three)
ShF       = $010C
RecClr    = $010D        ; radar-box rows cleared so far (7 = done)
RecMis    = $010E        ; mismatches against the ROM table
RecHold   = $010F        ; frames the final result is held on screen
MENU_ITEMS = 6

; ===========================================================================
; KONAMI'S ORIGINAL CODE AND DATA
; Everything named in this block is in the retail ROM and is used unchanged.
; A jsr/jmp/lda to one of these names is a call into the game's own code.
; Everything after this block (from .segment "CODE") is new code written for
; this patch. RAM marked "(free)" above is RAM the retail game never uses.
; ===========================================================================
; -- the orphaned debug routines this patch exists to show --
SpriteViewer= $E9FF      ; Konami's orphaned sprite viewer (controller 2)
Recorder    = $CFA7      ; Konami's orphaned attract-demo recorder
RecDur      = $2A        ; recorder variables (shared with the demo playback)
RecFrames   = $2B
RecBtn      = $2F
ObjSet      = $034E      ; object 0 metasprite set  (changed by the viewer)
ObjFrame    = $0368      ; object 0 metasprite frame
; -- the attract demo --
DemoTable   = $CEA9      ; shipped attract-demo table: (buttons, frames) pairs
DemoPlay    = $CE6F      ; shipped demo playback, one frame
DemoDone    = $1F
; -- game routines the new code calls --
JumpTable   = $C4BF
SetState    = $C0CB      ; A -> GameState, SubState = 0
ResetTimer  = $C3F6
GoTitle     = $C3EB      ; stop sound, redraw title, GameState = 1
StopSound   = $EC02
PlaySound   = $EC04
LoadGfx     = $C71C      ; X = graphics set
ClearObjs   = $C4F3
BankSave    = $EC1C      ; Y = bank, saves previous in $27
BankRestore = $EC28
PpuOff      = $EBDB
PpuOn       = $EB80
ReadPads    = $C36C
; ===========================================================================
; END OF ORIGINAL CODE REFERENCES - everything below is new
; ===========================================================================

; tiles (title/copyright font)
T_CURSOR  = $18          ; repurposed glyph slot, '>' uploaded at runtime
T_OQUOTE  = $78
T_CQUOTE  = $2C

.segment "CODE"

; ===========================================================================
; Extended main-state dispatcher (jumped to from $C010)
; ===========================================================================
NewDispatch:
        lda RecOn               ; live recorder runs once per game frame
        beq @nr
        jsr RecFrame
@nr:    lda GameState
        cmp #$01
        beq @title
        lda #$00
        sta MenuStep            ; menu must be redrawn next time we hit the title
        beq @go
@title: jsr MenuStepDraw
@go:    lda GameState
        jsr JumpTable
        .word $C02D,$C08E,$C096,$C0D0,$C0F5,$C11A
        .word $E7D1,$CFCD,$C191,$C1F2,$C21A,$C258
        .word CreditsState      ; new state $0C

; ===========================================================================
; Title menu: drawn one piece per frame through the PPU buffer
; ===========================================================================
MenuStepDraw:
        lda MenuStep
        cmp #MENU_ITEMS+2
        bcs @done
        inc MenuStep
        cmp #$00
        bne @line
        ; step 0: upload '>' glyph into CHR tile $18
        ldx #$00
@g:     lda CursorGlyph,x
        jsr BufPut
        inx
        cpx #CursorGlyphEnd-CursorGlyph
        bne @g
        jmp BufClose
@line:  cmp #MENU_ITEMS+1
        beq @cur
        ; steps 1..MENU_ITEMS: menu lines
        sec
        sbc #$01
        asl a
        tax
        lda MenuLines,x
        sta tmp0
        lda MenuLines+1,x
        sta tmp1
        jmp QueueRecord
@cur:   lda #T_CURSOR
        jmp PutCursor
@done:  rts

; Select: move cursor
MenuSelect:
        lda MenuStep
        cmp #MENU_ITEMS+2
        bcc @r
        lda #$00
        jsr PutCursor           ; erase old
        inc Cursor
        lda Cursor
        cmp #MENU_ITEMS
        bcc @ok
        lda #$00
@ok:    sta Cursor
        lda #T_CURSOR
        jmp PutCursor
@r:     rts

; Start: run the chosen option
MenuStart:
        lda Cursor
        cmp #MENU_ITEMS
        bcc @ok
        lda #$00
        sta Cursor
@ok:    asl a
        tax
        lda MenuActions+1,x     ; RTS-style jump table
        pha
        lda MenuActions,x
        pha
        rts

MenuActions:
        .word ActGame-1, ActCredits-1, ActViewer-1, ActRecord-1, ActCheck-1, ActSound-1

ActGame:
        lda #$00
        sta ViewerOn
        sta RecOn
StartGame:
        lda #$03                ; original Start behaviour
        jmp SetState
ActViewer:
        lda #$01
        sta ViewerOn
        lda #$00
        sta RecOn
        sta P1Real
        lda #$FF
        sta LastSet
        bne StartGame
ActRecord:
        jsr RecEnable
        jmp StartGame
ActCheck:
        jsr RecEnable
        lda #$02                ; straight into the attract demo
        jmp SetState
ActCredits:
        lda #$0C
        jmp SetState
ActSound:
        lda #$00
        sta MuteFlag            ; lift the title-screen sound whitelist
        jsr StopSound
        lda #$24
        jsr PlaySound
        lda #$00
        sta TimerLo
        lda #$0C                ; ~50 s before the attract demo kicks in, so the
        sta TimerHi             ; whole chain ($24 -> $08 roar -> $06 engine) plays
        rts

RecEnable:
        lda #$00
        sta ViewerOn
        sta RecCount
        sta RecRow
        sta RecClr
        lda #$01
        sta RecOn
        rts

; A = tile, drawn at the cursor position
PutCursor:
        pha
        lda #$01
        jsr BufPut
        lda Cursor
        asl a
        tax
        lda CursorAddr,x
        jsr BufPut
        lda CursorAddr+1,x
        jsr BufPut
        pla
        jsr BufPut
        jmp BufClose

; queue record at (tmp0): [hi][lo][bytes...][FF]
QueueRecord:
        lda #$01
        jsr BufPut
        ldy #$00
@l:     lda (tmp0),y
        cmp #$FF
        beq @end
        jsr BufPut
        iny
        bne @l
@end:   jmp BufClose

BufPut:                         ; append A to the PPU buffer
        stx tmp3
        ldx BufIdx
        sta PpuBuf,x
        inx
        stx BufIdx
        ldx tmp3
        rts
BufClose:                       ; end the current record
        lda #$FF
        jmp BufPut

; ===========================================================================
; New state $0C: unused staff credits, shown as a scrolling roll
; ===========================================================================
CRED_END  = 464                 ; scroll position where the roll stops
CredIdx   = $0100               ; (free page-1 RAM, below the stack)
CredDiv   = $0101
CredPosL  = $0102
CredPosH  = $0103
CredQuote = $0104
CredLine  = $0105

CreditsState:
        lda SubState
        bne @run
        jsr StopSound
        jsr ClearObjs
        ldx #$1E                ; font/title CHR set (same as copyright)
        jsr LoadGfx
        ldx #$00                ; clear both nametables, scroll = 0
        jsr LoadGfx
        lda #$00
        sta CredIdx
        sta CredDiv
        sta CredPosL
        sta CredPosH
        ldx #$00                ; palette: black background, white text
@p:     lda CreditsPal,x
        jsr BufPut
        inx
        cpx #CreditsPalEnd-CreditsPal
        bne @p
        lda #$47                ; Top Gun Anthem
        jsr PlaySound
        inc SubState
        rts
@run:   lda P1New
        and #$10
        beq @scroll
        jsr ResetTimer
        jmp GoTitle             ; back to the title / menu
@scroll:
        lda CredPosH            ; hold once the roll has finished
        cmp #>CRED_END
        bcc @go
        lda CredPosL
        cmp #<CRED_END
        bcs @r
@go:    lda CredDiv             ; 1 pixel every 2 frames
        eor #$01
        sta CredDiv
        beq @r
        lda CredPosL
        and #$07
        bne @move
        lda CredPosH            ; line = pos / 8
        lsr a
        lda CredPosL
        ror a
        lsr a
        lsr a
        sta CredLine
        ldx CredIdx
        lda CredLines,x
        cmp CredLine
        bne @move
        jsr QueueCreditLine
        inc CredIdx
@move:  inc CredPosL
        bne @scr
        inc CredPosH
@scr:   lda CredPosH            ; nametables $2000/$2800 stack vertically
        bne @low
        lda CredPosL
        cmp #240
        bcs @low
        sta $FC
        lda #$88
        sta $FF
@r:     rts
@low:   lda CredPosL
        sec
        sbc #240
        sta $FC
        lda #$8A
        sta $FF
        rts

; Queue credits entry X (line CredLine) into the row just below the screen.
; The text is read straight out of bank 6. Byte $07 (a quote mark in the
; lost Japanese font) becomes quote marks and $1E (an 'O' in that font)
; becomes 'O', because the font in this ROM lacks those glyphs.
QueueCreditLine:
        lda CredLine
        clc
        adc #30
        cmp #60
        bcc @a
        sbc #60
@a:     ldy #$20
        cmp #30
        bcc @b
        sbc #30
        ldy #$28
@b:     sta tmp2
        sty tmp1
        lsr a
        lsr a
        lsr a
        clc
        adc tmp1
        sta tmp1                ; address high
        lda tmp2
        and #$07
        asl a
        asl a
        asl a
        asl a
        asl a
        ora CredCol,x
        sta tmp0                ; address low
        lda #$01
        jsr BufPut
        lda tmp1
        jsr BufPut
        lda tmp0
        jsr BufPut
        lda CredSrcLo,x
        sta tmp0
        lda CredSrcHi,x
        sta tmp1
        lda CredLen,x
        sta tmp2
        lda #$00
        sta CredQuote
        ldy #$06
        jsr BankSave
        ldy #$00
@ch:    lda (tmp0),y
        cmp #$07
        bne @n1
        lda CredQuote
        eor #$01
        sta CredQuote
        beq @close
        lda #T_OQUOTE
        bne @out
@close: lda #T_CQUOTE
        bne @out
@n1:    cmp #$1E
        bne @out
        lda #$01
@out:   jsr BufPut
        iny
        cpy tmp2
        bne @ch
        jsr BankRestore
        jmp BufClose

; ===========================================================================
; Sprite viewer: NMI controller hook (replaces JSR $C36C at $EAC6)
;   Controller 2: A/B = frame +/-, Up/Down = set +/-   (Konami's routine)
;   Controller 1: hold Select and use A/B/Up/Down       (added convenience)
; ===========================================================================
ViewerPad:
        lda ViewerOn
        bne @on
        jmp ReadPads
@on:    lda P1Real              ; keep edge detection honest even when
        sta P1Held              ; we hide P1 input from the game below
        jsr ReadPads
        lda P1Held
        sta P1Real
        lda GameState
        cmp #$07
        bne @r
        jsr SpriteViewer        ; original routine, reads controller 2
        lda P1Held
        and #$20
        beq @hud
        lda P2New               ; run it again with P1's presses
        pha
        lda P1New
        sta P2New
        jsr SpriteViewer
        pla
        sta P2New
        lda #$00
        sta P1Held              ; game doesn't see P1 while Select is held
        sta P1New
@hud:   lda ObjSet
        cmp LastSet
        bne @draw
        lda ObjFrame
        cmp LastFrame
        bne @draw
        lda FrameCnt
        and #$1F
        bne @r
@draw:  lda ObjSet
        sta LastSet
        lda ObjFrame
        sta LastFrame
        lda #<HudText
        sta tmp0
        lda #>HudText
        sta tmp1
        lda #$01
        jsr BufPut
        ldy #$00
@t:     lda (tmp0),y
        cmp #$FF
        beq @nums
        jsr BufPut
        iny
        bne @t
@nums:  lda LastSet
        jsr PutHex
        ldx #$00
@t2:    lda HudText2,x
        jsr BufPut
        inx
        cpx #HudText2End-HudText2
        bne @t2
        lda LastFrame
        jsr PutHex
        jmp BufClose
@r:     rts

; ===========================================================================
; Attract-demo recorder
;   Live (DEMO RECORDER): the original routine runs every frame of flight on
;   the player's input. Each finished (buttons, frames) pair is listed in the
;   radar box; the radar header shows the buttons and frame count in progress.
;   Check (DEMO CHECK / attract mode): the original routine runs alongside the
;   shipped demo playback on its own copy of $2A/$2B/$2F, and every pair it
;   produces is compared with the next entry of the ROM table at $CEA9.
; ===========================================================================
RecFrame:                       ; every game frame, from NewDispatch. In flight
        lda GameState           ; the pads are read only every other frame, but
                                ; the demo playback (and so the table's frame
                                ; counts) runs every frame, so the recorder must too.
        cmp #$07
        beq @fly
        cmp #$02                ; attract demo: the check hook owns the log
        beq @r
        lda #$00                ; not flying: clear the radar box on re-entry
        sta RecClr
        sta RecRow
@r:     rts
@fly:   jsr RecClearStep
        lda #$00
        sta RecCheck
        jsr RecStep
        jmp RecHeaderLive

RecDemoHook:                    ; replaces JSR $CE6F at $CE69
        lda RecOn
        bne @on
        jmp DemoPlay
@on:
        lda RecFrames           ; playback index 0 = first frame of demo flight
        bne @run
        lda DemoTable           ; recorder starts out timing entry 0's buttons
        sta ShF
        lda #$00
        sta ShA
        sta ShB
        sta RecCount
        sta RecRow
        sta RecTab
        sta RecClr
        sta RecMis
        sta RecHold
@run:   jsr DemoPlay            ; original playback sets this frame's $F1
        lda DemoDone
        beq @rec
        lda RecHold             ; demo finished: hold the result ~3 seconds
        cmp #180
        bcs @r
        inc RecHold
        lda #$00
        sta DemoDone
        beq @show
@rec:   lda RecDur              ; swap in the recorder's own variables
        pha
        lda RecFrames
        pha
        lda RecBtn
        pha
        lda ShA
        sta RecDur
        lda ShB
        sta RecFrames
        lda ShF
        sta RecBtn
        lda GameState           ; the recorder only acts in state 7
        pha
        lda #$07
        sta GameState
        jsr RecClearStep
        lda #$01
        sta RecCheck
        jsr RecStep
        pla
        sta GameState
        lda RecDur
        sta ShA
        lda RecFrames
        sta ShB
        lda RecBtn
        sta ShF
        pla
        sta RecBtn
        pla
        sta RecFrames
        pla
        sta RecDur
@show:  jmp RecHeaderCheck
@r:     rts

; Run Konami's recorder for one frame and log any pair it finishes.
RecStep:
        lda RecBtn
        sta RecPrevF
        jsr Recorder            ; $CFA7, unmodified
        lda RecBtn
        cmp RecPrevF
        bne @pair               ; buttons changed: pair closed
        lda RecFrames
        beq @pair               ; wrapped after 256 frames: pair with 00
        rts                     ; still counting
@pair:  lda #$01
        jsr BufPut
        lda RecRow              ; radar box row 19 + RecRow, column 10
        asl a
        asl a
        asl a
        asl a
        asl a
        clc
        adc #$6A
        tax
        lda #$2A
        adc #$00
        jsr BufPut
        txa
        jsr BufPut
        lda RecCount            ; nn bb dd OK
        jsr PutHex
        lda #$0F
        jsr BufPut
        lda RecPrevF
        jsr PutHex
        lda #$0F
        jsr BufPut
        lda RecDur
        jsr PutHex
        lda #$0F
        jsr BufPut
        lda RecCheck
        beq @blank
        ldx RecTab              ; compare with the ROM table entry
        lda DemoTable,x
        cmp RecPrevF
        bne @ng
        lda DemoTable+1,x
        cmp RecDur
        bne @ng
        lda #$01                ; "OK"
        jsr BufPut
        lda #$1A
        bne @st
@ng:    inc RecMis
        lda #$1D                ; "NG"
        jsr BufPut
        lda #$16
@st:    jsr BufPut
        inc RecTab
        inc RecTab
        jmp @tail
@blank: lda #$0F
        jsr BufPut
        lda #$0F
        jsr BufPut
@tail:  lda #$0F
        jsr BufPut
        jsr BufClose
        inc RecCount
        inc RecRow
        lda RecRow
        cmp #$07
        bcc @r
        lda #$00
        sta RecRow
@r:     rts

; Blank one radar-box row per frame until all seven are clear.
RecClearStep:
        lda RecClr
        cmp #$07
        bcs @r
        inc RecClr
        asl a
        asl a
        asl a
        asl a
        asl a
        clc
        adc #$6A
        tax
        lda #$01
        jsr BufPut
        lda #$2A
        adc #$00
        jsr BufPut
        txa
        jsr BufPut
        ldx #$0C
@b:     lda #$0F
        jsr BufPut
        dex
        bne @b
        jmp BufClose
@r:     rts

; Radar header, live: "IN:bb T:cc"  (buttons being timed, frames so far)
RecHeaderLive:
        lda #$01
        jsr BufPut
        lda #$2A
        jsr BufPut
        lda #$4A
        jsr BufPut
        lda #$02                ; I
        jsr BufPut
        lda #$1D                ; N
        jsr BufPut
        lda #$18                ; :
        jsr BufPut
        lda RecBtn
        jsr PutHex
        lda #$0F
        jsr BufPut
        lda #$23                ; T
        jsr BufPut
        lda #$18
        jsr BufPut
        lda RecFrames
        jsr PutHex
        lda #$0F
        jsr BufPut
        lda #$0F
        jsr BufPut
        jmp BufClose

; Radar header, check: "CHK:nn NG:mm"  (pairs checked, mismatches)
RecHeaderCheck:
        lda #$01
        jsr BufPut
        lda #$2A
        jsr BufPut
        lda #$4A
        jsr BufPut
        lda #$12                ; C
        jsr BufPut
        lda #$17                ; H
        jsr BufPut
        lda #$1A                ; K
        jsr BufPut
        lda #$18
        jsr BufPut
        lda RecCount
        jsr PutHex
        lda #$0F
        jsr BufPut
        lda #$1D                ; N
        jsr BufPut
        lda #$16                ; G
        jsr BufPut
        lda #$18
        jsr BufPut
        lda RecMis
        jsr PutHex
        jmp BufClose

PutHex:                         ; HUD font: 0-9 = $01-$0A, A-F = $10-$15
        pha
        lsr a
        lsr a
        lsr a
        lsr a
        jsr @dig
        pla
        and #$0F
@dig:   cmp #$0A
        bcc @num
        adc #$05                ; carry set: +6 -> $10..$15
        jmp BufPut
@num:   clc
        adc #$01
        jmp BufPut

; ===========================================================================
; Data
; ===========================================================================
CursorGlyph:                    ; buffer record: CHR $0180 (tile $18), '>'
        .byte $01,$01,$80
        .byte $60,$30,$18,$0C,$18,$30,$60,$00     ; plane 0
        .byte $60,$30,$18,$0C,$18,$30,$60,$00     ; plane 1 (colour 3)
CursorGlyphEnd:

; title font: A=$10.. Z=$29, O=$01, I=$02, space=$00
MenuLines:
        .word MenuL0, MenuL1, MenuL2, MenuL3, MenuL4, MenuL5
MenuL0: .byte $21,$F1, $16,$10,$1C,$14,$00,$22,$23,$10,$21,$23, $FF                 ; GAME START
MenuL1: .byte $22,$31, $22,$23,$10,$15,$15,$00,$12,$21,$14,$13,$02,$23,$22, $FF     ; STAFF CREDITS
MenuL2: .byte $22,$6F, $00,$00,$22,$1F,$21,$02,$23,$14,$00,$25,$02,$14,$26,$14,$21, $FF ; SPRITE VIEWER (overwrites PUSH START KEY!)
MenuL3: .byte $22,$B1, $13,$14,$1C,$01,$00,$21,$14,$12,$01,$21,$13,$14,$21, $FF     ; DEMO RECORDER
MenuL4: .byte $22,$F1, $13,$14,$1C,$01,$00,$12,$17,$14,$12,$1A, $FF                 ; DEMO CHECK
MenuL5: .byte $23,$31, $24,$1D,$24,$22,$14,$13,$00,$22,$01,$24,$1D,$13, $FF         ; UNUSED SOUND
CursorAddr:
        .byte $21,$EF, $22,$2F, $22,$6F, $22,$AF, $22,$EF, $23,$2F

CreditsPal:
        .byte $01,$3F,$00
        .byte $0F,$0F,$0F,$30, $0F,$0F,$0F,$30, $0F,$0F,$0F,$30, $0F,$0F,$0F,$30
        .byte $FF
CreditsPalEnd:

; credits roll: line number, source (bank 6), length, column
.define CRED_LINES  0, 2, 4, 6, 8, 10, 14,16,18,20,22,24,26,28,30,32,34,36,38, 42
.define CRED_SRC    $9964,$9974,$9984,$9994,$99A4,$99B4, $99E5,$99F6,$9A07,$9A18,$9A29,$9A3A,$9A4B,$9A5C,$9A6D,$9A7E,$9A8F,$9AA0,$9AB1, $9AC2
CredLines:  .byte CRED_LINES, $FF
CredSrcLo:  .lobytes CRED_SRC
CredSrcHi:  .hibytes CRED_SRC
CredLen:    .byte 16,16,16,16,16,16, 17,17,17,17,17,17,17,17,17,17,17,17,17, 16
CredCol:    .byte  8, 8, 8, 8, 8, 8,  7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,  8

; HUD LCD font (gameplay CHR): ':' = $18, blank = $0F
HudText:                        ; radar header line (row 18, cols 10-21)
        .byte $2A,$4A
        .byte $22,$14,$23,$18                               ; SET:
        .byte $FF
HudText2:
        .byte $0F,$15,$21,$18                               ;  FR:
HudText2End:
