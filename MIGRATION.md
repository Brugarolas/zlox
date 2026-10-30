# Zig 0.17 / Lox migration notes

## Target

This tree targets Zig 0.17.0 and the final core Lox semantics described by *Crafting Interpreters*' bytecode VM (`clox`). It intentionally does not add language extensions that would make existing Lox programs behave differently.

## Zig modernization

- Reworked `build.zig` around the Zig 0.17 module/root-module build API.
- Replaced the old `b.args` forwarding path with `addPassthruArgs()`.
- Removed the `zig-clap` dependency; the small CLI now uses `std.process` directly.
- Migrated the entry point to `pub fn main(init: std.process.Init) !void`.
- Migrated file/stdin/stdout handling to the current `std.Io` API.
- Migrated lists to allocator-passed `std.ArrayList` operations.
- Replaced obsolete enum conversion builtins with `@backingInt` / `@fromBackingInt`.
- Updated object parent-pointer casts to the current `@fieldParentPtr` form.

## Lox correctness fixes

- Fixed scanner EOF handling, including empty input, so `peek()` cannot read past the source slice.
- Fixed truthiness: only `false` and `nil` are falsey; numbers, strings, functions, classes, and instances are truthy.
- Fixed equality: heap objects use identity equality; interned strings therefore retain value equality without unsafe object-type assumptions.
- Fixed unary negation so it writes the correct expression result instead of accidentally growing the old operand stack.
- Fixed duplicate-upvalue detection; the old loop could fail to advance and hang compilation.
- Fixed constant-pool overflow detection so the full index is checked before narrowing to an 8-bit operand.
- Restored canonical limits: 256 addressable local/upvalue slots and at most 255 arguments/parameters.
- Runtime errors now close open upvalues before the stack is reset, which is important for a persistent REPL VM.

## Performance / memory changes

- Hash-table load-factor checks use integer arithmetic instead of floating point.
- Hash-table capacities remain powers of two, allowing masked linear probing.
- Interned strings use pointer identity on normal table lookups.
- Constants are deduplicated per chunk before insertion. Repeated global/method names and repeated literals consume fewer constant slots and less memory.
- Bytecode and line arrays reserve capacity before either is mutated, avoiding partial writes on allocation failure.
- The original operand-stack VM has been replaced by the register VM described below.

## Garbage collector migration

During the first Zig 0.17 port the unsafe experimental moving collector was temporarily
replaced by a precise non-moving collector so the VM could be made correct before
reintroducing movement. That intermediate collector is no longer present in this tree.
The final implementation is the generational compacting collector described below.

The redesign specifically removes the old collector's dangerous assumptions: collection
never starts from inside an allocation while Zig locals may contain untracked raw object
pointers, object GC metadata no longer lives in a per-object `AutoHashMap`, and moving a
closed upvalue repairs its self-interior `location -> closed` pointer explicitly.

## Validation status

The source was statically audited against Zig 0.17 APIs and augmented with regression tests. The execution environment used for this migration did not have a Zig 0.17 compiler installed and could not download the toolchain, so the final local validation step remains:

```sh
zig build test
zig build -Doptimize=fast
zig build run -- examples/smoke.lox
```

## Generational compacting GC (second pass)

The initial 0.17 migration temporarily replaced the unsafe moving collector with
non-moving mark/sweep. The runtime now has a corrected generational collector:

- New objects enter an individually allocated young generation.
- Minor collections trace only young roots plus a remembered set of old holders.
- Survivors are aged and promoted after `GC_PROMOTION_AGE` minors.
- Promoted objects are evacuated into packed old-space arenas.
- Major collections mark the complete heap and evacuate every live object into a
  freshly packed old-space arena, then release the previous arenas in bulk.
- Interned strings remain weak and their keys are rewritten after movement.
- Closed upvalues explicitly repair their self-interior `location -> closed`
  pointer when moved.
- Function chunks, tables, string byte buffers and closure upvalue arrays remain
  stable external payloads; compacting an object transfers ownership instead of
  reallocating those payloads.
- Moving GC is never entered from `alloc_obj()`. Allocations only schedule work;
  evacuation occurs at allocation-boundary VM safepoints after temporary pointers
  have been materialized in VM roots. This avoids invalidating Zig locals while also
  avoiding a GC-poll branch on every bytecode dispatch.
- Old-to-young writes use a remembered-set barrier. If remembered-set growth ever
  fails, minor GC falls back to scanning old space instead of becoming incorrect.
- Minor GC accounting is incremental: promoted payloads, closure upvalue arrays and
  mutable class/instance table growth update generation byte counters directly. A
  normal minor therefore does not rescan the whole old generation just to compute
  thresholds.

Tuning build options:

```text
-Dgc-nursery=<bytes>          default 524288
-Dgc-promotion-age=<count>    default 2
-Dgc-old-arena=<bytes>        default 262144
-Dgc-growth=<factor>          default 2
-Dstress-gc=true              force moving major collections at safepoints
-Dlog-gc=true                 log collection activity
```


## Register VM conversion

The interpreter now uses a fixed-width register bytecode rather than the original clox-style
operand stack.

- Dispatched instructions are 32-bit words encoded as `[C:8 | B:8 | A:8 | opcode:8]`.
- Each function records `max_registers` and addresses up to 256 registers.
- Lexical locals have stable registers; temporary expression registers are allocated above the
  local frontier and reused in LIFO order.
- The compiler distinguishes borrowed local registers from writable temporaries. Local reads can
  therefore feed returns, prints, conditions, assignments, and right-hand ALU operands directly
  instead of generating a `GET_LOCAL` push followed by a consumer opcode.
- Left-to-right Lox evaluation order is preserved explicitly. A borrowed left operand is
  snapshotted before compiling a right operand that may have side effects; this avoids the subtle
  `a + f()` bug where `f()` could mutate `a` before the addition reads it.
- When the right operand is itself a borrowed local and emitted no bytecode, that defensive
  snapshot is rolled back. Common expressions such as `a + b` therefore compile directly to one
  three-register ALU instruction (`ADD Rdst, Ra, Rb`).
- Calls use overlapping Lua-style register windows. `R[A]` is the callee/receiver, `R[A+1...]`
  are arguments, and the result replaces `R[A]`. Child frames reuse the caller's dead temporary
  window rather than allocating/copying a separate operand stack segment.
- `CALL`, `INVOKE`, and `INVOKE_SUPER` retain the complete call window in their GC root metadata
  while setup is in progress, so a moving collection cannot invalidate arguments before a child
  frame exists.
- Closures capture addresses in the register stack. `CLOSE_UPVALUE Rn` closes captured locals
  when scopes or frames end.
- Closure capture descriptors are fixed-width metadata words consumed by `CLOSURE`, avoiding the
  old byte-at-a-time descriptor decoding.
- Jumps are relative instruction-word offsets, so bytecode patching no longer depends on variable
  instruction widths.

The old runtime stack pointer/push/pop API has been removed. The VM owns a contiguous register
stack and each `CallFrame` points at its register-window base.

### Precise register roots for the moving GC

Scanning every inactive register would keep dead objects alive and, worse, could expose stale
pre-compaction pointers when a register slot is later reused. The compiler therefore records a
live register frontier beside every instruction.

`Chunk.root_tops` stores one byte per instruction. Values `1..255` encode the live register count;
`0` encodes the full 256-register window. The collector reads this metadata only during a GC, so
there is no `SetTop` opcode or per-dispatch stack-top update in the hot loop.

New local slots are initialized to `nil` before an initializer can allocate. Parameter slots are
excluded from that initialization because the caller has already populated them.

### Register-bytecode limits

The common instruction remains one 32-bit word, so the current fast encoding has these limits:

- 256 addressable registers per function;
- 256 constants/names per chunk (8-bit constant operands);
- 8-bit argument count, additionally constrained by the 256-register call window;
- signed 16-bit relative jump displacement.

Extended encodings can be introduced later for uncommon large functions without making the hot
instruction format wider.
