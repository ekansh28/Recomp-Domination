# MPEG/PSS movie playback: why the attract sequence does not decode

This note records the verified state of the MPEG/PSS ("attract") playback path, the
first contract the runtime violates, and the two viable ways to fix it. It lists no
game addresses on purpose (see the "Legal"/committing rules in `AGENTS.md`): the
address-level detail lives with the disassembly locally.

## The game's player is its own MPEG-2 decoder

Downhill Domination statically links its MPEG player. It is **ordinary game code**,
not an IOP service and not the runtime's `sceMpeg` HLE. It plays the short
publisher/attract movies (`mov/dhsceapr.pss`, `mov/dhincog1.pss`, `mov/dhcopyrt.pss`,
`mov/loading.pss`, `mov/attract.pss`) and it decodes MPEG-2 video **on the EE, using
the Image Processing Unit (IPU)**.

The end-to-end path, as recovered from the disassembly, is:

1. The shell loop picks a movie id and calls the player's start routine with a PSS path.
2. A per-frame pump demultiplexes the PSS program stream (MPEG pack/PES start codes,
   audio + video stream ids) and dispatches the elementary video/audio payloads to
   registered stream callbacks.
3. A get-picture loop asks the player for one decoded picture at a time.
4. The picture routine parses the elementary stream (sequence header, picture header,
   slice/macroblock syntax) through a **bitstream reader that talks to the IPU**, and
   issues IPU decode commands.
5. Decoded macroblocks come back through the IPU output path and are copied into the
   guest image buffer, which the GS then displays.

The parser and bit reader are clearly identifiable as MPEG code: sequence-header
(0x000001B3), group (0x000001B8), picture (0x00000100), pack header (0x000001BA) and
program-end (0x000001B9) handling, plus the game's own debug strings
(`<<T1>> sceMpegGetPicture() decode error`, `MPEG Error - %s`,
`Invalid macroblock_type code: 0`, `DMA ADD not active`, `image buffer needs to be
aligned to 64byte boundary`).

## The IPU contract the runtime does not meet

The player uses the EE IPU through its memory-mapped registers and its DMA channels:

| Register | Use by the game |
| --- | --- |
| `IPU_CMD` (0x10002000) | written with a command nibble + argument; **read back to obtain the 32-bit bitstream word at the bit pointer** |
| `IPU_CTRL` (0x10002010) | busy / FIFO-status polling and reset |
| `IPU_BP` (0x10002020) | bitstream bit position and input-FIFO occupancy |
| `IPU_TOP` (0x10002030) | bitstream "top" (bits available above the pointer) |
| `IPU_IN_FIFO` (0x10007010) | 128-bit writes to push data into the IPU (used for the quantiser/VQ tables) |
| IPU_FROM / IPU_TO DMA | the bitstream is fed to, and decoded pictures read from, the IPU by DMA |

The bit reader's core primitive corresponds exactly to the "fetch the next N bits"
operation: it waits for `IPU_CTRL` not-busy, writes `IPU_CMD` with command `4`
(`FDEC`) and the bit count, and reads `IPU_CMD` back for the 32 bits at `IPU_BP`;
`FDEC` advances `IPU_BP` by the argument. (`BCLR` resets the input FIFO and sets
`IPU_BP`.) This matches PCSX2's IPU: `ipuRead32(IPU_CMD)` returns the 32 bits at
`g_BP.BP` (big-endian) and `IPUCMD_WRITE` advances `g_BP` for `BCLR/IDEC/BDEC/VDEC/
FDEC/SETIQ`.

### What the runtime does instead

`PS2Recomp/ps2xRuntime/src/lib/ps2_memory.cpp` models the IPU registers as inert
storage: reads of `IPU_CMD` return the last value **written** to it (the command word,
e.g. `0x40000000`), `IPU_CTRL` has bit 31 masked off and bit 30 clearing `CMD/BP/TOP`,
and `IPU_BP`/`IPU_TOP` are plain registers. There is **no IPU input FIFO, no bitstream
buffer, and no IPU_FROM/IPU_TO DMA handling anywhere in the runtime** (the only other
IPU code is the `sceIpuInit/RestartDMA/StopDMA/Sync` stubs, which only poke the IQ/VQ
tables). The runtime's `sceMpeg*` HLE (`Kernel/Stubs/MPEG.cpp`, FFmpeg-backed) is a
different facility: it serves games that call the SDK's `sceMpeg` API, which this game
does not.

## The first broken contract

`IPU_CMD` never returns bitstream data. Concretely, the bit reader's "fetch a word"
routine writes `0x40000000` (`FDEC`, length 0) and reads `IPU_CMD` expecting the next
32 bits; the runtime hands back `0x40000000`. The byte-align / start-code-prefix scan
that runs before every start code asks for 24 bits and compares them to `1`
(`0x000001`); it receives `0x40000000 >> 8 = 0x00400000`, which is never `1`, so it
loops forever calling the "advance 8 bits" primitive. The scan never terminates and no
elementary-stream parsing happens.

## Experimental confirmation (this session)

Two 45 s runs of the current runner, identical except for the binds file
(`PS2X_PROF=1`, `PS2X_CD_IMAGE` set):

* **Current `config/binds.txt`** (includes the diagnostic `ret0` override for the
  parser entry point `0x251A10`): the game boots to the shell loop (`FUN_001ebfd8`
  runs ~19 k times), loads `SHELL*.VAG`/`DHSKAT.SKX`, starts CD streaming
  (`cmd=5/1/2`), and draws a uniform gray 640x448 frame
  (`nonBlack=143360 first=0,0,0,255 center=28,28,28`). The parser entry point is
  **never entered** (it is replaced by a constant `0`), and the picture routine
  (`0x24d400`) and get-picture loop (`0x23c498`) run exactly once each.
* **Same binds without the override**: the real parser at `0x251A10` is entered
  (once; it then loops internally), and the guest PC settles **inside the byte-align
  scan** (`0x251970`/`0x251978`/`0x251984`, inside `FUN_00251928`). Frame throughput
  collapses to ~0.3 fps (19 scheduler ticks in 45 s, vs ~840 ticks in the baseline)
  and the presenter stops emitting `frame:stats` at all. The `ps2_log.txt` grows from
  81 MB to 303 MB because the scan spins.

Conclusion, both directions:

* Removing the `ret0` override **un-masks** the real parser but does not fix the
  movie: it converts a wrong-but-responsive gray shell into a livelock in the
  bitstream scan, because the IPU still yields no data. Do not remove that binding on
  its own.
* The binding is nonetheless a misidentification: the overridden routine is the MPEG
  start-code parser, not an optional multimedia "worker", and the override
  short-circuits picture processing (the picture routine takes its state-0 path and
  returns immediately).

## Options for the real fix

**A. Emulate the EE IPU.** Implement the input FIFO + bitstream pointer
(`BCLR`/`FDEC`/`SETIQ`/`SETVQ`/`SETTH`, `IPU_CMD` read, `IPU_CTRL`, `IPU_BP`,
`IPU_TOP`) and the IPU_FROM/IPU_TO DMA channels. This makes the *parse* stage work
and is the exact contract fix, but it is not sufficient on its own: the IPU's
`IDEC`/`BDEC` commands also perform the variable-length decode and inverse DCT, so
without those the pictures still will not appear. A usable version means porting the
IPU decode pipeline.

**B. Route this game's video through the existing FFmpeg HLE.** Rather than
emulating the IPU, intercept the game's demux/decode boundary and use the already
linked FFmpeg decoder, writing decoded frames into the guest image buffer in the
layout the GS expects (the HLE already has a macroblock-strip writer). The natural
seams are the PSS demultiplexer (which already isolates video PES payloads and
invokes a per-stream callback) and the per-picture decode routine. This is the
approach that actually produces a movie, and it reuses code that is already in the
tree.

**Nothing smaller is honest.** A partial IPU (bitstream only) leaves the movie absent
while adding hardware emulation with no user-visible effect; removing the diagnostic
binding alone is a regression. Both of those were therefore not shipped.

## Progress: an IPU bitstream model is now in the runtime

`ps2_memory.{h,cpp}` now models the IPU interface the player uses, exported to
`patches/ps2recomp-runtime-env.patch`:

* `IPU_CMD` writes are decoded (`BCLR` clears the input FIFO and sets the bit pointer,
  `FDEC`/`VDEC`/`IDEC`/`BDEC`/`SETIQ`/`SETVQ` advance it), `IPU_CMD` reads return the
  32 bitstream bits at `IPU_BP` big-endian, and `IPU_CTRL`/`IPU_BP`/`IPU_TOP` report
  non-busy/pointer state so the guest's polling loops terminate.
* The IPU input FIFO (`0x10007010`) and the IPU DMA channels are serviced: DMA4
  (`IPU_TO`, memory to IPU) feeds the bitstream, DMA3 (`IPU_FROM`) drains decoded
  data. Both complete immediately (QWC cleared, start bit cleared).
* `PS2X_TRACE_IPU=1` prints the first IPU commands, bit reads and DMA writes.

**A live trace shows the feed is still missing.** With the real parser enabled
(`ret0@0x251A10` removed), the guest issues `BCLR`, loads the IQ/VQ tables through
`IPU_IN_FIFO`, `BCLR`s again, and then loops `FDEC` forever reading zeros: no IPU DMA
channel is ever *started* (the guest only writes CHCR values `0x0/0x1/0x5`, never with
the `STR` bit `0x100`), and the only `IPU_IN_FIFO` writes are the 160 bytes of
quantiser/VQ tables. So the elementary stream does not reach the IPU in this boot path
yet, and the earlier livelock is unchanged. Identifying what is supposed to fill the
input FIFO (a DMA start the runtime swallows, or a request-driven refill callback) is
the next step.

Also fixed here: the input-buffer trim could erase past the end when the bit pointer
advanced over data that had not arrived, which tripped a checked-iterator assertion in
a debug build (`cannot seek vector iterator after end`). The pointer is now clamped to
the data actually held, matching the hardware stall.

## Next highest-value experiment

Decide between A and B by measuring how far a *demux-only* fix gets: add the IPU
bitstream model just far enough that the PSS demultiplex and header parsing complete
(observable as sane sequence-header dimensions and reaching the picture decode), and
record whether the game then fails specifically at `IDEC`/`BDEC`. If it does, option B
is the only path to a picture and the demux seam is where the FFmpeg feed belongs.
Keep every step behind an off-by-default environment switch until it is proven.
