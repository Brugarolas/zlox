# Register VM design

The interpreter now executes fixed-width register bytecode instead of an operand-stack bytecode.
The source language remains canonical Lox; this is an implementation change only.

## Instruction format

Every dispatched instruction is one `u32`:

```text
31             24 23             16 15              8 7               0
+----------------+-----------------+-----------------+-----------------+
|       C        |        B        |        A        |     opcode      |
+----------------+-----------------+-----------------+-----------------+
```

`A`, `B`, and `C` are normally register indices or small immediates. Conditional jumps use
`A` as the condition register and `B:C` as a signed 16-bit relative instruction displacement.

The fixed width makes fetch/decode one aligned word load and removes byte-at-a-time operand
reads from the old VM.

## Register windows

A function may address 256 registers (`R0..R255`). `Function.max_registers` records the
maximum live window needed by that function.

- Normal functions use `R0` for their closure/callee slot and parameters begin at `R1`.
- Methods and initializers use `R0` for the receiver (`this`) and parameters begin at `R1`.
- Lexical locals have stable register numbers for their lifetime.
- Expression temporaries are allocated above the current local-register frontier and reused
  in LIFO order.

The VM owns one contiguous register stack. A child call frame starts at the caller's call-base
register, so caller temporaries that become dead at the call site are reused directly by the
callee rather than copied to a separate frame allocation.

## Calls

Calls use the following contiguous layout:

```text
R[A]       callee or receiver
R[A + 1]   argument 0
R[A + 2]   argument 1
...
```

`CALL A, argc` and `INVOKE A, argc, name` overwrite `R[A]` with the result. A Lox closure uses
that same address as the base of its child register window. Native calls and class construction
also return into `R[A]`.

The compiler materializes borrowed locals into the call window only when necessary. Nested
calls therefore naturally build their own window at the next free register and collapse back
to one result register when they complete.

## Borrowed locals versus temporaries

The compiler tracks whether an expression result is:

- **borrowed**: a stable lexical-local register that must not be overwritten; or
- **temporary**: a compiler-owned register that may be reused as a destination.

This avoids turning the register VM into a stack VM expressed with `MOVE`s. For example,
`return local;`, `print local;`, and `if (local)` consume the local register directly. For a
binary expression the left value is snapshotted before parsing the right side when required by
Lox's left-to-right evaluation semantics, while a simple right local can still be consumed
directly.

## Closures and upvalues

Captured locals point directly into the register stack, exactly as open upvalues pointed into
the old value stack. `CLOSE_UPVALUE Rn` closes every open upvalue at or above `Rn` when a scope
or frame exits.

`CLOSURE` is followed by fixed-width capture descriptors (`CAPTURE_LOCAL` or
`CAPTURE_UPVALUE`). They are metadata words consumed by the closure instruction and are not
independently dispatched.

## Moving-GC roots

A moving collector cannot conservatively treat inactive register slots as roots: those slots
may contain pointers from before an earlier compaction. The compiler therefore records the live
root frontier for each instruction.

`Chunk.root_tops` stores one byte per instruction; values `1..255` represent that many live
registers and `0` compactly represents all 256 registers. The dispatch loop does not update a
runtime stack top. The collector consults this metadata only when a collection actually runs.

New lexical-local slots are initialized to `nil` before an initializer that may allocate. This
ensures a newly-rooted slot can never expose a stale pointer from an older use of the shared
register stack.

Call instructions keep the entire callee/receiver + argument window rooted for their safepoint.
This is deliberately conservative while a call is suspended: the child frame overlaps those
same values, so the extra roots are valid and make allocation during class/call setup safe.

## Current limits

- 256 addressable registers per function (`R0..R255`).
- 256 constants per chunk because constant/name operands remain 8-bit.
- Argument count is encoded in one byte. In practice a call must also fit its callee and
  arguments into the function's 256-register window, so extreme 255-argument calls can hit the
  register-pressure limit when other locals are live.
- Conditional and normal jumps use a signed 16-bit instruction displacement.

These are bytecode-format limits, not intended language-design changes. Extended encodings can
be added later without changing the common 32-bit instruction format.
