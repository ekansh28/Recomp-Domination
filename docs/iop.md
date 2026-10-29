# IOP services

The EE side of this game talks to the IOP through SIF RPC. Everything the game
opens — level data, textures, movies — is requested through those services, so
what the IOP can answer decides how far the game gets.

## What the game ships

`sceSifBindRpc` calls issued at boot (measured, no addresses):

| SID | Service |
| --- | --- |
| `0x80000001` | ioman |
| `0x80000002` | sifrpc itself |
| `0x80000003` | **fileio** |
| `0x80000100` / `0x80000101` | padman |
| `0x80000400` | mcserv |
| `0x80000592` / `0x80000593` / `0x80000595` / `0x80000597` | cdvdman / cdvd stream |
| `0x80000901` … `0x80000905` | mtapman |
| `0x80003456` / `0x80003457` | 989SND |

The game's own IOP image (`IOPRP270.IMG`, at the root of the disc) is a
container holding the retail kernel modules in sequence. `setup.sh` splits it
into `game/iopmod/NN_name.elf`; all fifteen are found:

    loadcore sifcmd sifman threadman ioman modload fileio cdvdman
    cdvdfsv loadfile timemani romdrv eesync sysclib stdio

That is where the retail `fileio`, `cdvdman` and friends live — the runtime
does not otherwise have them.

## Loading them

`PS2X_IOP_MODULES=<directory>` makes the runtime load every `*.elf` in that
directory into the emulated IOP, in filename order, right after the IOP reset
in `loadELF`. All fifteen load (`[IOP boot] NN_name.elf handled=1 id=N`).

**It is opt-in, and currently regresses.** The modules that take over a SID the
HLE set already answers — `cdvdman` above all — do not yet serve the guest as
well as the HLE path, and the boot loader stops completing (`workerDone=0`).
Until those services reach parity this stays behind the variable so the default
run is unaffected.

The module entry points do run — the emulator calls each module's entry after
loading, and `cdvdman` reaches its own init far enough to print `cdvdman Init`
through the IOP printf hook. Their imports all resolve as well; a run produces
no `[IOP] unhandled import` warning.

**`cdvdman` is what regresses the loader.** Loading the rest of the stack
(loadcore, sifcmd, sifman, threadman, ioman, modload, fileio, loadfile,
timemani, romdrv, eesync, sysclib, stdio — everything except `cdvdman` and
`cdvdfsv`) leaves the boot loader completing and the HLE CD path serving reads
exactly as before. `cdvdman` is the module that takes the CD SIDs away from the
HLE, and it does not drive the CD path well enough to finish booting.

**No module registers an RPC server**, so `hasRpcServer(sid)` stays false for
every SID and nothing can take over from the HLE. The modules run, their
imports resolve, and `sifman`'s `sceSifRegisterRpc` is implemented in the
emulator — but no module ends up reaching it, so the registration itself is
where to look next (most likely each module registers from its own thread, and
module-created threads are not being driven).

Two further faults to fix on this track:

1. The IOP faults during the first module's start with
   `[IOP] execution outside RAM pc=0x200000`; whatever the runtime initialises
   the IOP with is not enough for `loadcore` to complete cleanly.
2. `ioman` reports `Unknown device '%s'` / `Known devices are`, so the device
   table a module registers is not reaching it.

`IopSubsystem::canBindRpc` logs `[IOP] emulated RPC server for sid=...`
whenever a loaded module does own a SID, so this is measurable rather than
guessed.

Next step for this track: give the emulated IOP a working boot state so
`loadcore` completes, then confirm servers start appearing.

## The FILEIO client in the game

SID `0x80000003` is used with two functions, both one 32-bit word in and one
32-bit word out:

- `fn=1` — its reply is consumed as a byte size (rounded up to 16) for the
  caller's allocation.
- `fn=2` — takes the handle field the open produced; it is the close.

With `PS2X_TRACE_FILES=1` the boot path shows the order: the CD loader
completes, `fn=1` is issued, and the CD bounds stream then starts at the file's
LBA and delivers its sectors. The reply to `fn=1` is what the runtime must get
right; the HLE stub currently answers `0`, so the open yields a null handle.

## Generated runner files can be corrupted

`ps2xRuntime/src/runner/*.cpp` is recompiler output and is not versioned. One
file shipped with stray `0x0C` and `0xFF` bytes where a delay-slot statement
had been mangled, which only surfaced once a header change forced the whole
runner to rebuild (`error: source file is not valid UTF-8`).

To find such a file, scan the directory for bytes outside printable ASCII:

    powershell -c "Get-ChildItem PS2Recomp/ps2xRuntime/src/runner -Filter *.cpp |
      Where-Object { (Get-Content $_.FullName -Raw -Encoding Byte) -contains 0x0C }"

Repair it by rewriting the damaged lines in the recompiler's own style (the
`// 0xADDR: 0xWORD  mnemonic operands` comment above each statement identifies
the instruction, and the same instruction appears verbatim in other runner
files), keeping the file's CRLF endings.
