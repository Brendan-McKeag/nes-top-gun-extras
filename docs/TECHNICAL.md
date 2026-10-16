# Top Gun (NES): orphaned debug code

Technical notes on the development code left in Top Gun (USA) (Rev 1), written so anyone can find it in the ROM and check it for themselves.

**Which parts are Konami's.** Everything from [Overview](#overview) through [How to verify it yourself](#how-to-verify-it-yourself) describes the retail game's own code and data, exactly as shipped. The last two sections, [Game Genie codes](#game-genie-codes) and [What the Extras patch adds](#what-the-extras-patch-adds), describe changes made by this project. The only exception is step 5 of the verification steps, a minimal 17-byte patch that calls the two routines without adding anything else.

## Overview

Two pieces of Konami's development code survive in Top Gun (USA) (Rev 1) with nothing left that calls them: a sprite viewer at `$E9FF` and the recorder that produced the attract-mode demo at `$CFA7`. Both sit in the fixed bank, so their CPU addresses are valid no matter which bank is switched in.

| Item | Value |
| --- | --- |
| File | Top Gun (USA) (Rev 1).nes, 131,088 bytes: 16-byte iNES header + 128 KB PRG, no CHR ROM |
| Header | `4E 45 53 1A 08 00 20 00 …` = mapper 2 (UxROM), eight 16 KB PRG banks, CHR-RAM, horizontal mirroring |
| MD5 / SHA-1 (whole file) | `ac956bd3edb35ccc907561d5a98735da` / `6e233846ca3bb2f50b0176cc31f5cd9667a635f5` |
| CRC32 / SHA-1 (PRG only, no header) | `CF6D0D7A` / `c0fcc0e837e3ec8b075685bb27908037cb57af2a` |

**Finding a CPU address in the file.** Banks 0–6 switch in at `$8000`–`$BFFF`; bank 7 is fixed at `$C000`–`$FFFF`. For banks 0–6, file offset = `0x10 + bank × 0x4000 + (address − $8000)`. For bank 7, file offset = `address − $C000 + 0x1C010`. So `$E9FF` is at file offset `0x1EA0F` and `$CFA7` is at `0x1CFB7`. Every bank stores its own number in its first byte, which is how the game's bank-switch routine (`$EC1C`) knows what to restore.

| Routine | CPU address | File offset | Size | Reads | Writes |
| --- | --- | --- | --- | --- | --- |
| Sprite viewer | `$E9FF`–`$EA22` | `0x1EA0F`–`0x1EA32` | 36 bytes | `$F6` | `$0368`, `$034E` |
| Attract demo recorder | `$CFA7`–`$CFCC` | `0x1CFB7`–`0x1CFDC` | 38 bytes | `$18`, `$F1` | `$2A`, `$2B`, `$2F` |

**Controller variables used below.** The controller read at `$C36C` runs from the NMI handler. It leaves held buttons in `$F1` (controller 1) and `$F2` (controller 2), and newly pressed buttons in `$F5` and `$F6`. Bit values: A `$80`, B `$40`, Select `$20`, Start `$10`, Up `$08`, Down `$04`, Left `$02`, Right `$01`. The main game state is `$18`; state 7 is normal flight and state 2 is the attract demo.

## Sprite viewer (`$E9FF`)

A 36-byte routine that lets controller 2 step object 0 through every metasprite: A and B change the animation frame, Up and Down change the sprite set. It draws nothing itself; it only changes two RAM values that the game's own sprite renderer reads every frame.

Bytes at file offset `0x1EA0F`:

```
A5 F6 29 C0 F0 0C 29 40 F0 04 CE 68 03 60 EE 68
03 60 A5 F6 29 0C F0 0B 29 04 F0 04 CE 4E 03 60
EE 4E 03 60
```

```
E9FF  A5 F6     LDA $F6      ; controller 2, buttons newly pressed this frame
EA01  29 C0     AND #$C0     ; A or B?
EA03  F0 0C     BEQ $EA11    ; neither -> check the d-pad
EA05  29 40     AND #$40     ; B?
EA07  F0 04     BEQ $EA0D
EA09  CE 68 03  DEC $0368    ; B: previous frame of object 0
EA0C  60        RTS
EA0D  EE 68 03  INC $0368    ; A: next frame of object 0
EA10  60        RTS
EA11  A5 F6     LDA $F6
EA13  29 0C     AND #$0C     ; Up or Down?
EA15  F0 0B     BEQ $EA22    ; neither -> done
EA17  29 04     AND #$04     ; Down?
EA19  F0 04     BEQ $EA1F
EA1B  CE 4E 03  DEC $034E    ; Down: previous sprite set
EA1E  60        RTS
EA1F  EE 4E 03  INC $034E    ; Up: next sprite set
EA22  60        RTS
```

One change per call at most: A/B are checked first, and there are no range checks, so stepping past the end of a table draws garbage, exactly as a bare developer tool would.

**What the two addresses are.** Objects live in 26 slots held as parallel arrays spaced `$1A` bytes apart: `$0300` flags (bit 7 = draw), `$031A` X, `$0334` Y, `$034E` sprite set, `$0368` animation frame. Slot 0 is the first entry of each array. In flight, object 0 is the aiming reticle (set 0, frame 1).

**How it reaches the screen.** In the NMI, the handler maps bank 0 (`$EAD3`: `LDY #$00` / `JSR $EC1C`) and calls the sprite builder at `$8009` (`$EAD8`). The builder picks a set table for the current mission (`$30`), then indexes it with the object's set and frame:

```
bank 0, file offset 0x4F
803F  BD 4E 03  LDA $034E,X  ; object's sprite set
8042  0A        ASL A
8043  A8        TAY
8044  B1 0C     LDA ($0C),Y  ; ($0C) = set table for this mission
8046  85 0A     STA $0A
8048  C8        INY
8049  B1 0C     LDA ($0C),Y
804B  85 0B     STA $0B
804D  BD 68 03  LDA $0368,X  ; object's animation frame
8050  0A        ASL A
8051  A8        TAY
8052  B1 0A     LDA ($0A),Y  ; pointer to the metasprite
8054  85 08     STA $08
8056  C8        INY
8057  B1 0A     LDA ($0A),Y
8059  85 09     STA $09
805B  20 E1 80  JSR $80E1    ; write its sprites into OAM
```

**Why it counts as orphaned.**

- No `JSR $E9FF` (`20 FF E9`) or `JMP $E9FF` (`4C FF E9`) exists anywhere in the 128 KB.
- The address bytes `FF E9` appear once in the whole file, at `0x0A056`, inside bank 2 graphics data. `FE E9` (the form an RTS-style jump table would store) appears once, at `0x09479`, also bank 2 graphics.
- Nothing else in the shipped game reads `$F6`. The controller routine writes it and the demo playback clears it, so controller 2 has no other function in the final game.
- The routine sits between a data table that ends at `$E9FE` and the RESET handler at `$EA23`, with no code path falling into it.

## Attract demo recorder (`$CFA7`)

A 38-byte routine that turns controller 1 input during flight into (buttons, frames held) pairs. That is the exact format of the attract-demo table sitting directly in front of it at `$CEA9`–`$CFA6`, and the shipped table carries the recorder's overflow fingerprint (below).

Bytes at file offset `0x1CFB7`:

```
A5 18 C9 07 D0 12 A5 F1 C5 2F D0 0D E6 2B D0 08
A5 2B 85 2A A5 F1 85 2F 60 A5 2B 85 2A A5 F1 85
2F A9 01 85 2B 60
```

```
CFA7  A5 18     LDA $18      ; main game state
CFA9  C9 07     CMP #$07     ; record only during flight (state 7)
CFAB  D0 12     BNE $CFBF    ; -> RTS
CFAD  A5 F1     LDA $F1      ; controller 1, buttons held
CFAF  C5 2F     CMP $2F      ; same buttons as the ones being timed?
CFB1  D0 0D     BNE $CFC0    ; no -> close the pair
CFB3  E6 2B     INC $2B      ; yes -> one more frame
CFB5  D0 08     BNE $CFBF    ; counter didn't wrap -> RTS
CFB7  A5 2B     LDA $2B      ; wrapped after 256 frames:
CFB9  85 2A     STA $2A      ;   duration 00 (= 256 frames)
CFBB  A5 F1     LDA $F1
CFBD  85 2F     STA $2F      ;   same buttons keep being timed
CFBF  60        RTS
CFC0  A5 2B     LDA $2B      ; buttons changed:
CFC2  85 2A     STA $2A      ;   frames the old buttons were held
CFC4  A5 F1     LDA $F1
CFC6  85 2F     STA $2F      ;   new buttons to time
CFC8  A9 01     LDA #$01
CFCA  85 2B     STA $2B      ;   this frame counts as 1
CFCC  60        RTS
```

Each time the buttons change, the finished pair is (the old `$2F`, `$2A`). The routine never writes the pairs anywhere, so whoever used it was presumably reading `$2A` and `$2F` live through debugging hardware.

**The playback routine uses the same three variables.** In attract mode (state 2) the handler at `$CE62` calls `$CE6F` once per frame of the demo flight. It feeds the table's buttons into the game as if controller 1 were pressing them:

```
CE62  A6 34     LDX $34      ; has the demo flight started?
CE64  D0 03     BNE $CE69
CE66  4C D1 E7  JMP $E7D1    ; still on the takeoff screen
CE69  20 6F CE  JSR $CE6F    ; feed this frame's buttons
CE6C  4C CD CF  JMP $CFCD    ; then run the normal flight code
CE6F  A4 2B     LDY $2B      ; table index x2
CE71  F0 04     BEQ $CE77    ; first frame: load entry 0
CE73  A5 2A     LDA $2A      ; frames left on this entry
CE75  D0 14     BNE $CE8B    ; still running -> same buttons
CE77  B9 AA CE  LDA $CEAA,Y  ; next entry's frame count
CE7A  85 2A     STA $2A
CE7C  C9 FF     CMP #$FF
CE7E  D0 07     BNE $CE87
CE80  B9 A9 CE  LDA $CEA9,Y  ; FF FF ends the demo
CE83  C9 FF     CMP #$FF
CE85  F0 1F     BEQ $CEA6
CE87  C8        INY
CE88  C8        INY
CE89  84 2B     STY $2B
CE8B  B9 A7 CE  LDA $CEA7,Y  ; entry's buttons
CE8E  85 F1     STA $F1      ; -> controller 1 held
CE90  45 2F     EOR $2F
CE92  39 A7 CE  AND $CEA7,Y
CE95  85 F5     STA $F5      ; -> controller 1 newly pressed
CE97  A5 F1     LDA $F1
CE99  29 7F     AND #$7F
CE9B  85 2F     STA $2F      ; previous buttons (A bit stripped)
CE9D  A9 00     LDA #$00
CE9F  85 F2     STA $F2      ; controller 2 silenced
CEA1  85 F6     STA $F6
CEA3  C6 2A     DEC $2A      ; from 00 this wraps to FF: 256 frames
CEA5  60        RTS
CEA6  E6 1F     INC $1F      ; demo over
CEA8  60        RTS
```

| Variable | Recorder `$CFA7` | Playback `$CE6F` |
| --- | --- | --- |
| `$2A` | frames held for the pair just finished | frames left on the current entry |
| `$2B` | frames counted on the current buttons | table index × 2 |
| `$2F` | buttons being timed | previous buttons, for new-press detection |

**The demo table.** `$CEA9`–`$CFA6` (file offset `0x1CEB9`) holds 126 two-byte entries of (buttons, frames) and ends with `FF FF`. They add up to 4,946 frames, about 82 seconds at 60 fps. It starts `02 90` (Left for 144 frames), `00 58` (nothing for 88), `02 1E`, `00 06`, `04 0A` (Down for 10), `84 32` (A + Down for 50), `80 04` (A for 4). The recorder starts at `$CFA7`, the byte right after the table's `FF FF`, and ends right before `$CFCD`, the flight-state handler that the playback jumps to.

**The overflow fingerprint.** A recorder-made table can only contain the same buttons twice in a row immediately after a `00` entry, because that is the only time the recorder emits a pair without the buttons changing. The shipped table has exactly four repeated-button pairs, and all four follow that pattern. Every `00` duration in it is followed by the same buttons.

| Entries (0-based) | Bytes | Meaning |
| --- | --- | --- |
| 25–26 | `02 00`, `02 02` | Left held 258 frames |
| 37–38 | `00 00`, `00 24` | nothing pressed for 292 frames |
| 87–88 | `01 00`, `01 46` | Right held 326 frames |
| 89–90 | `00 00`, `00 24` | nothing pressed for 292 frames |

**Frame counts are per game frame, 60 per second.** The playback runs once every frame of the demo flight. During flight the game reads the controllers only on every other frame, but the main logic still runs every frame. So the recorder has to be called every frame to produce counts the playback can replay: a 40-frame hold must come out as `28`.

**Why it counts as orphaned.**

- No `JSR $CFA7` (`20 A7 CF`) or `JMP $CFA7` (`4C A7 CF`) exists anywhere in the file.
- The address bytes `A7 CF` appear once, at `0x08E3C`, inside bank 2 graphics data.
- Its own state check would skip the attract demo anyway: the demo runs in state 2, and the recorder only acts in state 7.

## The demo never reaches its own end

The attract demo stops after 4,100 of its 4,946 recorded frames, because the demo plane is shot down. The crash is never shown: the demo ends on the same frame. See `media/demo_ending.png`.

1. About 51 seconds into the recorded input (playback frame 3,053), the radar box switches to **DANGER !**, the game's "enemy on your tail" sequence (bank 6, `$89` = 1, step counter `$88`). Step 5 counts a timer at `$86` down from 112, once every 8 frames (about 15 seconds).
2. When the timer reaches zero, if the pursuer is roughly centred in the rear radar (its Y within 18 pixels of the middle), the enemy fires (`$8250`, step 6). The shot shows as a red blip creeping up to your plane's tail. In the demo this happens at playback frame 3,961.
3. About 2.3 seconds later the shot arrives: `$83E9` stores 0 in the damage meter `$4E`, an instant kill regardless of damage.
4. The next frame the crash state begins (flight sub-state `$2E` = 3). The crash handler at `$D216` checks the demo flag at `$D21A` (`LDA $1C`). In demo mode it skips the crash sound and red-sky sequence and goes straight to `$D244` (`INC $1F`): back to the title.

That leaves the last 74 frames of entry 107 and all of entries 108–125 unplayed: 846 frames, about 14 seconds, of real input (Left turns, two missile attempts, three gun bursts, more turning). Game Genie code `GIPSLX` changes `LDA $1C` at `$D21A` to `LDA $5C` (always 0 at that point), so the crash plays out in the demo, followed by a GAME OVER screen (the demo runs with no spare lives) that waits for Start. In a normal game nothing changes, because `$1C` is also 0 there.

Playback is deterministic: the demo ends on the same frame with or without extra CPU load, and the game's random number (`$96`/`$97`) only affects refuelling and landing. So if the developer's own recording session did not end with this shot, the game must have changed between recording and release; it can't be a timing glitch. Comparing the table with the Japanese version or US Rev 0 would help settle it.

## How to verify it yourself

All of this can be checked with a hex editor and any NES emulator that has a debugger (Mesen or FCEUX), using an unmodified Rev 1 file that matches the hashes above.

1. **Check the bytes.** Open the file in a hex editor and compare 36 bytes at `0x1EA0F` (viewer) and 38 bytes at `0x1CFB7` (recorder) with the listings above. The demo table starts at `0x1CEB9`.
2. **Check the fingerprint.** The four repeated-button pairs are at `0x1CEEB` (`02 00 02 02`), `0x1CF03` (`00 00 00 24`), `0x1CF67` (`01 00 01 46`) and `0x1CF6B` (`00 00 00 24`).
3. **Search for callers.** Search the whole file for `20 FF E9`, `4C FF E9`, `20 A7 CF` and `4C A7 CF`. All four return nothing.
4. **Watch them never run.** Set execute breakpoints on `$E9FF` and `$CFA7`, then play: title, attract demo, missile select, flight, refuelling, landing. Neither breakpoint fires. For contrast, a breakpoint on `$CE6F` fires every frame of the attract demo's flight.
5. **Make them run with a 17-byte patch.** The fixed bank has unused `FF` padding at `$ED80` (file `0x1ED90`). Write `20 6C C3 20 FF E9 60 20 A7 CF 4C 33 C9` there: a stub at `$ED80` that reads the controllers and then calls the viewer, and a stub at `$ED87` that calls the recorder and then continues to `$C933`. Point the NMI handler at them: change `0x1EAD7`–`0x1EAD8` from `6C C3` to `80 ED` (the controller read at `$EAC6`) and `0x1EB06`–`0x1EB07` from `33 C9` to `87 ED` (the call at `$EAF5`, which runs every frame). The viewer belongs on the controller read because in flight the pads are read only every other frame; called every frame, it would see each press twice. The recorder belongs on the every-frame call so its counts match the playback's.
6. **Try the viewer.** Start a game. In flight, press A or B on controller 2 to step the reticle's frame (`$0368`), or Up/Down to step its set (`$034E`).
7. **Try the recorder.** In the emulator's memory viewer, watch `$2A`, `$2B` and `$2F` while flying. `$2B` counts frames while you hold a button combination. When you change it, `$2A` takes the old count and `$2F` takes the new buttons. Hold one combination for more than 255 frames and you will see `$2A` become `00` while `$2F` stays the same: the same pattern the shipped demo table contains.

The patch in step 5 changes no original code apart from two call targets, so everything you see comes from the routines as shipped.

## Game Genie codes

All codes are in the fixed bank, so the 6-letter forms are safe; the 8-letter forms add a compare value.

| Effect | 6-letter | 8-letter | What they change |
| --- | --- | --- | --- |
| Sprite viewer on controller 2 | `NNIVKX` `OVIVSX` | `NNSVKXAX` `OVSVSXKV` | `$EADB`: `JSR $EC28` → `JSR $E9FF` |
| Demo recorder | `NZZGLA` `TOLGVY` `XVGKKN` | `NZXGLESG` `TOUGVNAA` `XVKKKYAV` | `$C023`: state 7 handler `$CFCD` → `$CFA7`; `$CFB6`: branch to RTS → branch to `$CFCD`; `$CFCC`: `RTS` → `NOP` |
| Let the demo's crash play out | `GIPSLX` | `GIOSLXGO` | `$D21B`: `LDA $1C` → `LDA $5C` |

- **Viewer.** The NMI calls `$EC28` right after the sprite builder to restore the previously mapped bank. The code calls the viewer there instead. The attract demo plays identically with it applied, and several minutes of flight showed no side effects.
- **Recorder.** The main-state jump table at `$C015` sends state 7 (flight) to the recorder instead of the flight handler. With its final `RTS` turned into a `NOP` and its mid-routine "return" branch retargeted, the recorder falls through to the flight handler at `$CFCD`, so it runs once per game frame of flight. Watch `$2A`, `$2B` and `$2F` in a RAM viewer. One path still returns early: when the same buttons are held for 256 frames, flight logic is skipped for that one frame.
- A real Game Genie takes three codes at once, so use the viewer or the recorder, not both; emulators have no such limit.

## What the Extras patch adds

The Extras patch (`TopGun_USA_Rev1_Extras_v1.0.bps` / `.ips`) adds a six-item title menu and calls the original routines unchanged. All new code sits in the fixed bank's unused padding at `$ED80`–`$F3AE` (file `0x1ED90`–`0x1F3BE`). Five original instructions are redirected into it:

| CPU address | File offset | Original | Patched | Purpose |
| --- | --- | --- | --- | --- |
| `$C010` | `0x1C020` | `A5 18 20` (`LDA $18` / `JSR $C4BF`) | `4C 80 ED` | Extended main-state table (adds the credits state `$0C`) and the per-frame recorder call |
| `$C3DA` | `0x1C3EA` | `A9 03 4C` (Start on the title) | `4C 0B EE` | Run the chosen menu item |
| `$C3DF` | `0x1C3EF` | `E6 22 A9` (dead Select toggle) | `4C EE ED` | Move the menu cursor; the write-only `$22` becomes the cursor |
| `$CE69` | `0x1CE79` | `20 6F CE` (`JSR` playback) | `20 9F F0` | Playback first, then the recorder check during DEMO CHECK |
| `$EAC6` | `0x1EAD6` | `20 6C C3` (`JSR` controller read) | `20 F7 EF` | Controller read first, then the sprite viewer |

| Menu item | Original Konami code it runs | Added by the patch |
| --- | --- | --- |
| GAME START | Everything, unchanged | Nothing beyond the menu |
| STAFF CREDITS | Credits data in bank 6 (`$9964`–`$9AD1`), font load (`$C71C`), Top Gun Anthem (sound `$47`) | A new state that scrolls the rows; quote marks and "O" drawn in place of glyphs this font lacks |
| SPRITE VIEWER | `$E9FF`, bank 0 sprite builder | Call after each controller read in flight; controller 1 path (hold Select); "SET:xx FR:yy" in the radar header |
| DEMO RECORDER | `$CFA7` | Call once per game frame in flight; radar-box log of each finished pair (number, buttons, frames); live "IN:bb T:cc" header |
| DEMO CHECK | `$CFA7`, playback `$CE6F`, table `$CEA9` | Recorder run on its own copy of `$2A`/`$2B`/`$2F` with `$18` briefly set to 7; each pair compared with the next table entry and marked OK or NG; "CHK:nn NG:mm" header |
| UNUSED SOUND | Sound driver, sound `$24` (which chains to `$08` and `$06`) | Lifts the title-screen sound whitelist (`$1C`) and delays the attract demo about 50 seconds |

New RAM: `$22` (the vestigial title toggle), `$0E`, `$1D`, `$1E`, `$24`–`$26` and `$0100`–`$010F`. Static checks and play-testing found nothing else in the game using them.

**Expected DEMO CHECK result:** 107 rows, every one OK, ending on "NG:00" when the demo plane is shot down. Row `07 00 12 OK`, for example, is table entry 7 (`00 12` at `0x1CEC7`). Row and entry numbers are shown in hexadecimal.
