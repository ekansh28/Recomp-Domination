# Downhill Domination Recomp

Static recompilation of *Downhill Domination* (PS2, USA, SCUS-971.77) to native
Linux x86, built on [PS2Recomp](https://github.com/ran-j/PS2Recomp).

**Status:** work in progress, not playable. The recompiled game boots, loads
its data from the disc, and draws textured graphics up to the "PRESS X TO
START" title screen and, with the pad working, into the main menu (see
[Progress](#progress)).

## Legal

This repository contains no game assets, ELF, BIOS or anything derived from
them (the Ghidra project, function lists and generated code stay local and are
git-ignored). You must supply your own legally obtained dump of the game.

## Setup

    ./setup.sh

Put your ISO at `Downhill Domination (USA)/Downhill Domination (USA).iso`.
The script installs dependencies (Arch/pacman), extracts the disc to `game/`,
clones PS2Recomp at a pinned commit, applies `patches/ps2recomp-runtime-env.patch`
and builds it.

## Progress

Done (the game runs on the PS2Recomp runtime):

- Boot, SIF commands and RPC, CD initialisation, IOP reset and module loading
  from the disc.
- Disc reads and file I/O, CD streaming, memory card (host folder), pad
  initialisation.
- Textures reach the GS: the GIF parser keeps its state across DMA packets, so
  an IMAGE upload split over several packets no longer turns texture data into
  bogus tags.
- The title screen with "PRESS X TO START" renders with textures; after it the
  game shows a controller-disconnected warning.
- Render hand-off between the game and its DMA interrupt works: the DMAC
  interrupt raised while its cause is disabled is kept pending and delivered on
  `EnableDmac` (as the hardware does), and COP0 `bc0t`/`bc0f` (CPCOND0) is
  translated as "DMA idle" instead of a constant false. Both used to leave the
  main thread spinning forever on a flag the interrupt handler should clear.

Not working yet:

- **Picture quality and speed:** not compared against PCSX2 beyond the title
  screen; the software rasteriser and the cycle-exact VU1 interpreter are slow (see
  [docs/performance.md](docs/performance.md) for measurements and what helped).
- **Crash on late X:** pressing X on the title after it has been idle for a while ends in a
  guest call through a garbage pointer (pre-existing; see the same document).
- **Intro movie / attract PSS:** not decoded. The game's own MPEG-2 player drives the
  EE IPU (bitstream fetch through `IPU_CMD`/`IPU_BP`, input and output through the IPU
  DMA channels); the runtime models the IPU registers as inert and has no IPU DMA, so
  the elementary stream never parses. The FFmpeg-backed `sceMpeg` HLE is not reachable
  because this game does not call the SDK API. See
  [docs/mpeg-playback.md](docs/mpeg-playback.md).
- **Sound:** disabled at the EE level. The game's sound IOP module cannot read
  the disc inside the emulated IOP.

## Workflow

The ELF is retail and has no symbols, so the game's SDK functions (libsif,
libcdvd, fio, memory card, pad, mpeg) run as ordinary recompiled code waiting
for a real IOP. Each one is bound to a runtime HLE stub by address.

1. Analyse `game/SCUS_971.77` in Ghidra (Emotion Engine extension) and export
   `config/config.toml` + `config/functions.csv` with
   `PS2Recomp/ps2xRecomp/tools/ghidra/ExportPS2Functions.java`.
2. `ps2_recomp config/config.toml`, copy the output into
   `PS2Recomp/ps2xRuntime/src/runner` and `include`, and build.
3. Iterate with `config/binds.txt`: add `handler@0xADDR` lines (a runtime stub
   name, `ret0` or `ret1`) and run `./run.sh`. No regeneration or rebuild is
   needed.

Scripts:

- `run.sh [secs]` runs the game (`BUILD=fast` selects the build without function tracing).
- `diag.sh` summarises where the last run stopped.
- `bind.sh` is the slow path (edits `config.toml`, regenerates, rebuilds).
- `rpc_table.py` lists game functions that use IOP RPC (SID and function number).
- `tools/ghidra/DecompileFunctions.java` exports C for a list of addresses, much
  easier to read than MIPS:
  `analyzeHeadless ghidra DownhillDom -process SCUS_971.77 -noanalysis -readOnly -scriptPath tools/ghidra -postScript DecompileFunctions.java 0xADDR,0xADDR out.c`

Runtime patch (`patches/ps2recomp-runtime-env.patch`) adds these environment
variables:

| Variable | Effect |
| --- | --- |
| `PS2X_CD_IMAGE` | ISO used for raw sector reads |
| `PS2X_BINDS` | file of `handler@0xADDR` lines applied at ELF load |
| `PS2X_DUMP_RAM="secs:path"` | writes the 32 MB EE RAM once after that many seconds |
| `PS2X_TRACE_CALLS=0xA,0xB` | logs the first calls to those guest addresses with arguments |
| `PS2X_TRACE_SYSCALLS=N` | logs the first N thread, semaphore and interrupt syscalls (3000 if N is 1) |
| `PS2X_PROF=1` | every 10 s prints VU1 and GS time shares and VU1 cycles per window (see [docs/performance.md](docs/performance.md)) |
| `PS2X_AUTOX=<secs>` | pulses X on the pad from that second on, for reproducible runs without a keyboard |

It also makes the scheduler match the real kernel (main thread at priority 1,
priority 0 accepted by `CreateThread`), makes the simulated `sceCdRead` take one
frame, and batches IOP cycles (the IOP scheduler dominated the profile).
The patch also adds the COP0 branch-condition case to the recompiler
(`control_flow_emitter.cpp`); the `ps2_recomp` tool must be rebuilt and the code
regenerated for it to take effect on newly generated files.
PCSX2 is a useful ground truth: its debugger shows the real thread table and can
break on memory writes.

## Roadmap

1. **Get through the menus into a race** and fix whatever breaks on the way.
2. **Compare frames against PCSX2** beyond the title and fix remaining GS/VU1
   differences and speed.
3. **Replace the temporary shortcuts:** bring back the sound IOP module and the
   intro movie (IPU DMA path).
4. **Make it playable:** confirm input, then run a race end to end.

## License

GPL-3.0, matching PS2Recomp (the generated code links against its runtime).
