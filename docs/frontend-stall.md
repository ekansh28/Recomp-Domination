# The front-end stall

After the loader finishes, the game enters the shell and never leaves it: the
frame stays black and one function runs about a million times per second while
the shell sits still. This is that stall.

## What it is not

An earlier reading of this stall — that a descriptor walk steps by
`([p] >> 2) << 4` and cannot advance because the step is zero — is **wrong**.
The routine that was blamed (`FUN_0021AC08`) zeroes the word it was supposed to
be stuck on as its very first action (`sw $zero, 0x0($s0)`), so it cannot be
spinning on that word.

## It only happens with the IOP modules loaded

This matters, and it invalidated an earlier round of measurements. Measured over
the same 16 s window:

| run | `0x21ac80` | CD reads | shell entries |
| --- | --- | --- | --- |
| default (no boot modules) | 0 | 246 | 6 |
| with the boot modules | ~350000 | 525 | 12 |

Loading the game's own IOP services takes the game **further** — more than twice
the CD reads, twice the shell passes — and lands it here. So this stall is a
later stage than the one the modules-are-neutral measurement suggested, and any
watch or trace aimed at it has to be run with the modules loaded.

## What it is

`FUN_0021AE70(set, descriptor)` is a **table lookup**. It returns the index of a
matching entry, or the first free index, or `-1` for "not found". The key comes
from bits 32..37 of the 64-bit tag at `descriptor+8`; the search walks 8-byte
entries at `set+0xC` and compares against that key, and the empty-table gate is
a `blez` on the count word at `set+0`.

So `-1` is normal control flow — "absent", after which the caller appends — not
an error. The inner block at `0x21ac80` runs it about 350000 times in one call
because the descriptor it is handed never yields a hit.

## Why it never yields a hit

The descriptor pointer is computed as `set + ([set+4] << 4)`. With `[set+4]`
zero the descriptor pointer lands on the header itself, where the 64-bit word at
`+8` is not a tag at all, so no lookup can ever match.

`[set+4]` is the header size in 16-byte units — `1` for a 16-byte header — and
**nothing in the recompiled runner writes it**. An exhaustive search of the
runner for stores to that field found only readers (`FUN_0021AC08`, `FUN_0021A5C8`,
`FUN_002197F0`). The set-builder writes the count at `+0` and the entries, and
never its own header size.

## What is known about the producer

- The set object the loop works on lives at a fixed heap address whose header
  the walk reads (`+0` a counter the routine zeroes, `+4` a count, `+8` the
  start of a 15-entry table the routine clears).
- Instrumenting guest writes (`PS2X_TRACE_WATCH`) over the whole of that object
  during a full run records **no writes at all** — neither the routine's own
  clears nor anything else. Every write seen anywhere near it is the manager
  record slot that points at it, written by the registrar.
- So whatever is supposed to fill the object that `FUN_0021AE70` serves from is
  not running, or is running against a different address.

## What the header fields mean

Four separate readers agree on the shape of the object:

```
first descriptor = object + ([object+4] << 4)
```

`+0` is a count — the routine clears it on entry and increments it per built
entry. `+4` is therefore the **header size in 16-byte units**: for a 16-byte
header the value that makes the walk land past the header is `1`. Descriptors
are 16 bytes and self-describing (first dword = size in bytes), and the walk
`p += ([p] >> 2) << 4` stops on `[p] == 0`.

That is why `+4` at zero hurts: the walk starts on the header itself, where a
stray `1` gives a stride of zero.

## A dead end, recorded

The function on the registration path that looked like the populator is not one:
it only writes its own stack frame and calls the logger that formats
`loading file (%s) in memory %p - %p`. It builds a log message; it does not fill
the object.

## Next step

Find where the set's header is supposed to be initialised — the code that writes
`[set+4] = 1` before the consumer pass runs — or show that the header is meant to
arrive as data (a blob copied into the freshly allocated set) and that the copy
is the missing step.

Two ways in:

1. Watch the resolved set address with the boot modules loaded (the address
   differs between configurations — an earlier watch used the address from a
   modules-off run and therefore observed nothing). A watch on the count word at
   `set+0` should fire from the builder's own clears; if it does not, the address
   being watched is still wrong.
2. Decompile the set's allocation path (`FUN_0020d2d8` and the pool allocator it
   uses) and the caller that feeds it, and check whether the header word is
   written from a register that is zero in our run and non-zero on hardware.
