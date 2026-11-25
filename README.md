# Smiley for the 48K ZX Spectrum

A small Z80 assembly program: a one-cell smiley that you move around the screen.

| Key | Action |
|---|---|
| Z / X | left / right |
| O / K | up / down |
| CAPS SHIFT + SPACE (BREAK) | back to BASIC |

After BREAK, start it again with `RANDOMIZE USR 32768`. (`RUN` runs the loader,
which waits for the tape.)

## Build

```
make          # build/smiley.tap, .lst (listing), .sym (symbols)
make clean    # delete build/
```

You need `make` and [sjasmplus](https://github.com/z00m128/sjasmplus). Ubuntu has no
package for sjasmplus, so build it from source, without root after the first line:

```
sudo apt install g++ make
curl -LO https://github.com/z00m128/sjasmplus/releases/download/v1.24.0/sjasmplus-1.24.0-src.tar.xz
echo "0b5013f07e8d8505f9e296529655668b6fdf0268625c19e883b0fff484e209f1  sjasmplus-1.24.0-src.tar.xz" | sha256sum -c
tar -xJf sjasmplus-1.24.0-src.tar.xz
make -C sjasmplus-1.24.0
install -m 755 sjasmplus-1.24.0/build/release/sjasmplus ~/.local/bin/
```

## Load

Open `build/smiley.tap` in Fuse. If it doesn't load by itself, type
`LOAD ""` and press ENTER. On a 48K Spectrum, that is `J`, then SYMBOL SHIFT + `P`
twice. Then start the tape.

The tape starts with a BASIC program, written out in `src/loader.asm`:

```
10 CLEAR 32767            keep BASIC and its stack below our code at 32768
20 POKE 23610,255         ERR_NR = "no error"
30 LOAD ""CODE            load the machine code
40 RANDOMIZE USR 32768    run it
```

## Test

The tests run the program in SkoolKit's Z80 simulator, starting from a tape
loaded by the real 48K ROM.

```
python3 -m venv .venv
.venv/bin/pip install -r requirements-dev.txt
make test
```

## How screen addresses work

The screen is 256 x 192 pixels, one bit each: 6144 bytes at `$4000`. Then there are
768 attribute bytes (colours) at `$5800`, one for each 8 x 8 cell.

The **attributes** are in plain reading order:

```
address = $5800 + row * 32 + column
```

The **pixels** are not. The screen is split into three thirds of 8 rows. In each
third, memory holds the top line of all 8 rows, then the second line of all 8 rows,
and so on. The address of the top line of a cell is:

```
address = $4000 + ((row AND $18) << 8) + ((row AND 7) << 5) + column
```

`row AND $18` chooses the third, and `row AND 7` the row in that third. In bits, with
`T` = third, `L` = pixel line in the cell, `R` = row in the third, `C` = column:

```
   H: 0 1 0 T T L L L    L: R R R C C C C C
```

The line number is in the low bits of H, so the next line of a cell is 256 bytes
further on: `INC H`.

Example, row 10, column 15:

```
row AND $18 = 8,  8 << 8 = $0800
row AND 7   = 2,  2 << 5 = $0040
pixels:     $4000 + $0800 + $0040 + $0F = $484F, then $494F, $4A4F ... $4F4F
attribute:  $5800 + 10 * 32 + 15        = $594F
```

## How the keyboard ports work

The 40 keys are wired as 8 half-rows of 5. You read a half-row from port `$xxFE`. The
low byte `$FE` selects the ULA, and the high byte chooses the half-row by having one
bit set to 0:

| Port | Bit 0 | Bit 1 | Bit 2 | Bit 3 | Bit 4 |
|---|---|---|---|---|---|
| `$FEFE` | CAPS SHIFT | **Z** | **X** | C | V |
| `$FDFE` | A | S | D | F | G |
| `$FBFE` | Q | W | E | R | T |
| `$F7FE` | 1 | 2 | 3 | 4 | 5 |
| `$EFFE` | 0 | 9 | 8 | 7 | 6 |
| `$DFFE` | P | **O** | I | U | Y |
| `$BFFE` | ENTER | L | **K** | J | H |
| `$7FFE` | SPACE | SYMBOL SHIFT | M | N | B |

A pressed key reads as **0**. Bits 5-7 are not keys, so test single bits rather than
the whole byte:

```
        ld bc,$FEFE
        in a,(c)        ; puts all of BC on the address bus
        bit 1,a         ; Z flag set = the Z key is pressed
```

Writing to port `$FE` is different: bits 0-2 set the border colour.
