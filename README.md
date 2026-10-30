# zlox

A compact **register-based** bytecode implementation of Lox from *Crafting Interpreters*,
modernized for **Zig 0.17.0**.

The VM implements the final core Lox language: lexical scope, first-class functions, closures
and upvalues, classes, fields, methods, initializers, inheritance, `this`, `super`, loops,
short-circuit logic, globals, locals, and native functions.

## Requirements

- Zig 0.17.0

No third-party packages are required.

## Build

```sh
zig build
```

For maximum runtime performance:

```sh
zig build -Doptimize=fast
```

The executable is installed as `zig-out/bin/zlox` (`zlox.exe` on Windows).

## Run

Run a file:

```sh
zig build run -- examples/smoke.lox
```

Start the REPL:

```sh
zig build run -- --repl
```

With no arguments, the executable also starts the REPL.

## Tests

```sh
zig build test
```

For aggressive moving-GC validation:

```sh
zig build test -Dstress-gc=true -Dlog-gc=true
```

The suite covers arithmetic, evaluation order, nested register call windows, control flow,
closures/upvalues, local and global classes, inheritance, `this`, `super`, object identity,
Lox truthiness, scanner EOF handling, persistent REPL globals, and generational/moving-GC
regressions.

## Register VM

The old operand-stack bytecode has been replaced with a fixed-width 32-bit register format:

```text
[ C:8 | B:8 | A:8 | opcode:8 ]
```

Each function can address `R0..R255`. Lexical locals keep stable register numbers and expression
temporaries are allocated above them. Calls use a contiguous Lua-style window: `R[A]` contains
the callee/receiver, arguments occupy `R[A+1...]`, and the result replaces `R[A]`.

The compiler distinguishes borrowed local registers from temporary registers. Consequently
simple local consumers (`return x`, `print x`, conditions, right-hand arithmetic operands) can
read the local directly instead of emitting the old `GET_LOCAL`/push traffic. Simple local/local
binary expressions can lower directly to a single three-register arithmetic/comparison instruction.

The dispatch loop no longer maintains an operand-stack top. Precise moving-GC roots are recorded
as one byte of out-of-line `root_top` metadata per instruction and consulted only during a
collection.

See `REGISTER_VM.md` for the bytecode layout, call convention, closure handling, GC-root model,
and current encoding limits.

## Build options

```text
-Dprint-code=true          Disassemble bytecode after compilation
-Dtrace=true               Trace VM registers and bytecode execution
-Dsafe-object-casts=true   Validate heap-object downcasts
-Dstress-gc=true           Schedule a moving major GC after every object allocation
-Dlog-gc=true              Log collector activity
-Dgc-growth=N              Heap growth factor after collection (default: 2)
-Dgc-nursery=N             Young-generation threshold in bytes (default: 524288)
-Dgc-promotion-age=N       Minor GCs survived before promotion (default: 2)
-Dgc-old-arena=N           Minimum old-space arena size (default: 262144)
```

Debug instrumentation is disabled by default, including Debug builds.

## Runtime notes

- Strings are interned and normal string-table lookup uses pointer identity after interning.
- Object equality is identity based, as in canonical Lox.
- Only `false` and `nil` are falsey.
- The collector is generational and moving: minor GCs trace young roots plus remembered old
  objects, while major GCs compact live object bodies into fresh old-space arenas.
- Interned strings are weak roots.
- Constants and property/global names currently use 8-bit chunk indices (256 constants/chunk).
- The register bytecode has 256 addressable registers per function.

See `MIGRATION.md` for the Zig/Lox migration and `REGISTER_VM.md` for the VM architecture.
