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

## What it is

`FUN_0021AC08` is entered three times per run, and the whole bin-builder chain
around it runs three times (`FUN_001BAD48` seven). The million repeats are an
**inner poll loop**:

```
loop:
    $a1 = $s1                    ; the table pointer for this record
    $a0 = $s0                    ; the set object
    $v0 = FUN_0021AE70($a0, $a1)
    if ($v0 != -1) goto 0x21AE08 ; consumed something
    goto loop                    ; nothing yet - ask again
```

`FUN_0021AE70` is asked for the next item and answers `-1` every single time.
The loop is a waiter, not a stuck cursor: the producer it is waiting on never
produces.

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

Find `FUN_0021AE70`'s data source and what feeds it — that is the producer that
never runs — and the code that should write the header's `+4` before the
consumer pass runs. Instrument the read that returns `-1` (its comparison
against the sentinel) rather than the loop, and trace which structure it
consults and who was supposed to write it.
