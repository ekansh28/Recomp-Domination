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
directory into the emulated IOP, in filename order, right after the IOP reset in
`PS2Runtime::run()` (see below). All fifteen load
(`[IOP boot] NN_name.elf handled=1 id=N`).

**This is on by default**, with `cdvdman` and `cdvdfsv` skipped. Everything else
is load-compatible: the boot loader still completes and the HLE CD path still
serves its reads. `cdvdman` is the exception — it takes the CD SIDs off the HLE
and does not drive the CD path well enough to finish booting, so with it loaded
the loader stops completing (`workerDone=0`). `PS2X_IOP_MODULES=<dir>` selects a
different module directory and `PS2X_IOP_MODULES=0` disables the load.

The result, measured on a default run: `sifcmd` registers three servers —
`0x80000006` (threadman), `0x80000001` (ioman) and `0x80000003` (fileio, handler
at `0x26254`) — and **no RPC falls through to the HLE stub any more**. The file
handles the game opens are real values now instead of the zero the stub
returned.

### The load has to happen after the run-time IOP reset

Loading the modules from `loadELF` looked like it worked — the modules loaded,
their entry points ran, and they created and started threads — but the
scheduler's thread map was always empty and nothing ever ran. `PS2Runtime::run()`
calls `resetIop()` as its first act, and that walks `IopSubsystem::reset()` →
`IopEmulator::reset()` → `Impl::reset()`, which clears the kernel's threads, the
module list and the import registry. Everything `loadELF` had loaded was
discarded before the IOP scheduler first ran. The load now happens in `run()`,
straight after that reset.

That was the whole reason no module ever registered a server: their service
threads were never scheduled.

### Still open on this track

- `cdvdman`/`cdvdfsv` parity, so the whole set can load.
- The IOP faults once during the first module's start with
  `[IOP] execution outside RAM pc=0x200000`. It is not fatal — the remaining
  modules load, their services register and the loader still completes — but the
  cause is not yet pinned. Ruled out by instrumentation: an indirect branch
  leaving RAM, and a resolved import jumping out of RAM (neither trace fires).
  At the fault the registers are `ra=0x1020c` (inside the first module),
  `sp=0xffffff28` — a stack pointer that is not a stack at all — `t9=0`,
  `v0=1`, `branchPending=0`. So the module's start runs without the boot state
  it expects: the emulator calls a module entry with a bare CPU state and a
  synthesised stack, and nothing hands it a boot descriptor.
- `ioman` reports `Unknown device '%s'` / `Known devices are`. The emulated
  ioman's device table is empty because the host HLE intercepts `AddDrv` and
  keeps the devices in its own table, so a driver module registering `cdrom`
  never reaches the emulated module. Letting the loaded guest ioman own those
  imports was tried and **regresses the loader** (`workerDone` stays 0 and the
  CD read count drops from 525 to 414), so the HLE still answers ioman. The
  message is cosmetic for the HLE CD path, which never consults ioman; it only
  matters for opens that go through the emulated ioman.

`IopSubsystem::canBindRpc` logs `[IOP] emulated RPC server for sid=...` whenever
a loaded module owns a SID, and the kernel traces thread creation, starting and
scheduling, so all of this is measurable rather than guessed.

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
