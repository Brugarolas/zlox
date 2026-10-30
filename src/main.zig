const std = @import("std");
const Allocator = std.mem.Allocator;

const VMType = @import("vm.zig");
const InterpretError = VMType.InterpretError;
const FunctionType = @import("compile.zig").FunctionType;
const Compiler = @import("compile.zig").Compiler;
const Scanner = @import("scanner.zig");
const GC = @import("gc.zig");
const Value = @import("value.zig").Value;
const Obj = @import("obj.zig");
const Bytecode = @import("chunk.zig");
const Opcode = Bytecode.Opcode;
const Instruction = Bytecode.Instruction;

const max_source_bytes: usize = 128 * 1024 * 1024;
const repl_buffer_bytes: usize = 64 * 1024;

const usage =
    \\Usage: zlox [options] [file]
    \\
    \\Options:
    \\  -h, --help    Show this help and exit.
    \\  -r, --repl    Start the interactive REPL.
    \\
    \\With no arguments, zlox starts the REPL.
    \\
;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const stdout = &stdout_file.interface;
    defer stdout.flush() catch {};

    if (args.len == 1) return repl(init.io, init.gpa, stdout);

    if (args.len == 2) {
        const arg = args[1];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try stdout.writeAll(usage);
            return;
        }
        if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--repl")) {
            return repl(init.io, init.gpa, stdout);
        }
        if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("Unknown option: {s}\n{s}", .{ arg, usage });
            std.process.exit(64);
        }
        return run_file(init.io, init.gpa, arg, stdout);
    }

    std.debug.print("Expected at most one Lox source file.\n{s}", .{usage});
    std.process.exit(64);
}

pub fn repl(io: std.Io, allocator: Allocator, output: *std.Io.Writer) !void {
    const vm = try create_vm(allocator, output);
    defer vm.destroy();

    var stdin_buffer: [repl_buffer_bytes]u8 = undefined;
    var stdin_file = std.Io.File.stdin().readerStreaming(io, &stdin_buffer);
    const input = &stdin_file.interface;

    while (true) {
        try output.writeAll("> ");
        try output.flush();

        const line = try input.takeDelimiter('\n') orelse return;
        compile_and_run(vm, line) catch |err| switch (err) {
            InterpretError.CompileError, InterpretError.RuntimeError => {
                // A REPL error is local to the current line. Globals remain alive.
            },
            else => return err,
        };
        try output.flush();
    }
}

pub fn run_file(io: std.Io, allocator: Allocator, path: []const u8, output: *std.Io.Writer) !void {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(max_source_bytes),
    );
    defer allocator.free(source);

    const vm = try create_vm(allocator, output);
    defer vm.destroy();

    compile_and_run(vm, source) catch |err| switch (err) {
        InterpretError.CompileError => {
            try output.flush();
            std.process.exit(65);
        },
        InterpretError.RuntimeError => {
            try output.flush();
            std.process.exit(70);
        },
        else => return err,
    };
}

/// Runs one source string in an isolated VM and tears it down afterwards.
pub fn interpret(allocator: Allocator, source: []const u8) !void {
    const vm = try create_vm(allocator, null);
    defer vm.destroy();
    try compile_and_run(vm, source);
}

/// Runs one source string and returns the live VM for tests and embedding.
/// The caller owns the returned VM and must call `destroy()`.
pub fn interpret_without_teardown(allocator: Allocator, source: []const u8) !*VMType {
    const vm = try create_vm(allocator, null);
    errdefer vm.destroy();
    try compile_and_run(vm, source);
    return vm;
}

fn create_vm(allocator: Allocator, output: ?*std.Io.Writer) !*VMType {
    const gc = try allocator.create(GC);
    errdefer allocator.destroy(gc);

    try gc.init(allocator, false);
    var gc_initialized = true;
    errdefer if (gc_initialized) gc.free_objects();

    const vm = try VMType.create(allocator, gc, output);
    gc_initialized = false;
    gc.patch_allocator();
    return vm;
}

fn compile_and_run(vm: *VMType, source: []const u8) !void {
    const gc = vm.gc;

    // The compiler allocates GC-managed objects before the top-level closure is
    // installed in the VM. Pause collection until that closure becomes a root.
    const gc_was_enabled = gc.pause();
    var gc_restored = false;
    defer if (!gc_restored) gc.restore(gc_was_enabled);

    var parser = Compiler.init_parser();
    var scanner = Scanner.init(source);
    var compiler = try Compiler.init(gc, null, &scanner, &parser, null, FunctionType.Script);
    const function = try compiler.compile() orelse return InterpretError.CompileError;
    const closure = try Obj.Closure.init(gc, function);

    vm.prepare_script(closure);
    gc.restore(gc_was_enabled);
    gc_restored = true;

    try vm.run();
}

test "fib" {
    const source =
        \\ fun fib(x) {
        \\     if (x <= 1) {
        \\         return x;
        \\     }
        \\     return fib(x - 1) + fib(x - 2);
        \\ }
        \\
        \\ var result = fib(2);
    ;

    const vm = try interpret_without_teardown(std.testing.allocator, source);
    defer {
        vm.destroy();
    }

    const result_str = try vm.get_string("result");
    const value = vm.gc.globals.get(result_str) orelse @panic("result not found");

    try std.testing.expect(Value.eq(value, Value.number(1)));
}

test "invoking fields" {
    const source =
        \\class Oops {
        \\    init() {
        \\        fun f() {
        \\            return 420;
        \\        }
        \\
        \\        this.field = f;
        \\    }
        \\}
        \\
        \\var oops = Oops();
        \\var result = oops.field();
    ;

    const vm = try interpret_without_teardown(std.testing.allocator, source);
    defer {
        vm.destroy();
    }

    const result_str = try vm.get_string("result");
    const value = vm.gc.globals.get(result_str) orelse @panic("result not found");

    try std.testing.expect(Value.eq(value, Value.number(420)));
}

test "misusing this" {
    const source =
        \\fun notMethod() {
        \\    print this;
        \\}
    ;

    try std.testing.expectError(
        InterpretError.CompileError,
        interpret(std.testing.allocator, source),
    );
}

test "superclasses" {
    const source =
        \\class Doughnut {
        \\  cook() {
        \\    print "Dunk in the fryer.";
        \\    this.finish("sprinkles");
        \\  }
        \\
        \\  finish(ingredient) {
        \\    return "Finish with " + ingredient;
        \\  }
        \\}
        \\
        \\class Cruller < Doughnut {
        \\  finish(ingredient) {
        \\    // No sprinkles, always icing.
        \\    return super.finish("icing");
        \\  }
        \\}
        \\
        \\var cruller = Cruller();
        \\var result = cruller.finish("noice");
    ;

    const vm = try interpret_without_teardown(std.testing.allocator, source);
    defer {
        vm.destroy();
    }

    const expected = try vm.get_string("Finish with icing");
    const result_str = try vm.get_string("result");
    const value = vm.gc.globals.get(result_str) orelse @panic("result not found");

    try std.testing.expect(Value.eq(value, Value.obj(expected.widen())));
}

test "local class inheritance uses register-backed super" {
    const source =
        \\fun build() {
        \\    class Base {
        \\        value() { return 40; }
        \\    }
        \\    class Derived < Base {
        \\        value() { return super.value() + 2; }
        \\    }
        \\    return Derived().value();
        \\}
        \\var result = build();
    ;

    const vm = try interpret_without_teardown(std.testing.allocator, source);
    defer vm.destroy();

    const result_name = try vm.get_string("result");
    const result = vm.gc.globals.get(result_name) orelse @panic("result not found");
    try std.testing.expect(Value.eq(result, Value.number(42)));
}

test "nested this" {
    const source =
        \\class nested {
        \\    method() {
        \\        fun function() {
        \\            return this.lol;
        \\        }
        \\        return function();
        \\    }
        \\}
        \\
        \\var nested = nested();
        \\nested.lol = 420;
        \\var result = nested.method();
    ;

    const vm = try interpret_without_teardown(std.testing.allocator, source);
    defer {
        vm.destroy();
    }

    const result_str = try vm.get_string("result");
    const value = vm.gc.globals.get(result_str) orelse @panic("result not found");

    try std.testing.expect(Value.eq(value, Value.number(420)));
}

test "this" {
    const source =
        \\class Nested {
        \\    method() {
        \\      return this.lol;
        \\    }
        \\ }
        \\
        \\var nested = Nested();
        \\nested.lol = 420;
        \\var result = nested.method();
    ;

    const vm = try interpret_without_teardown(std.testing.allocator, source);
    defer {
        vm.destroy();
    }

    const result_str = try vm.get_string("result");
    const value = vm.gc.globals.get(result_str) orelse @panic("result not found");

    try std.testing.expect(Value.eq(value, Value.number(420)));
}

test "methods" {
    const source =
        \\class Scone {
        \\  topping(first, second) {
        \\      return "scone with " + first + " and " + second;
        \\  }
        \\}
        \\var scone = Scone();
        \\var result = scone.topping("berries", "cream");
    ;

    const vm = try interpret_without_teardown(std.testing.allocator, source);
    defer {
        vm.destroy();
    }

    const result_str = try vm.get_string("result");
    const expected_str = try vm.get_string("scone with berries and cream");
    const value = vm.gc.globals.get(result_str) orelse @panic("result not found");

    try std.testing.expect(Value.eq(value, Value.obj(expected_str.widen())));
}

test "instance get set" {
    const source =
        \\class Pair {}
        \\
        \\var pair = Pair();
        \\pair.first = 1;
        \\pair.second = 2;
        \\var result = pair.first + pair.second;
    ;

    const vm = try interpret_without_teardown(std.testing.allocator, source);
    defer {
        vm.destroy();
    }

    const result_str = try vm.get_string("result");
    const value = vm.gc.globals.get(result_str) orelse @panic("result not found");

    try std.testing.expect(Value.eq(value, Value.number(3)));
}

test "upvalue closed" {
    const source =
        \\fun makeClosure() {
        \\  var a = 1;
        \\  fun f() {
        \\    a = a + 1;
        \\    return a;
        \\  }
        \\  return f;
        \\}
        \\
        \\var closure = makeClosure();
        \\var first = closure();
        \\var anotherClosure = makeClosure();
        \\var second = anotherClosure();
        \\var third = closure();
    ;
    const vm = try interpret_without_teardown(std.testing.allocator, source);
    defer {
        vm.destroy();
    }
    const first_str = try vm.get_string("first");
    const second_str = try vm.get_string("second");
    const third_str = try vm.get_string("third");

    const value1 = vm.gc.globals.get(first_str) orelse @panic("first not found");
    const value2 = vm.gc.globals.get(second_str) orelse @panic("second not found");
    const value3 = vm.gc.globals.get(third_str) orelse @panic("third not found");

    try std.testing.expect(Value.eq(value1, Value.number(2)));
    try std.testing.expect(Value.eq(value2, Value.number(2)));
    try std.testing.expect(Value.eq(value3, Value.number(3)));
}

test "set immediate upvalue" {
    const source =
        \\fun outer() {
        \\  var x = 420;
        \\  fun inner() {
        \\    x = x + 1;
        \\    return x;
        \\   }
        \\ return inner();
        \\}
        \\var value = outer();
    ;
    const vm = try interpret_without_teardown(std.testing.allocator, source);
    defer {
        vm.destroy();
    }
    const result_str = try vm.get_string("value");
    const result = vm.gc.globals.get(result_str) orelse @panic("value not found");
    try std.testing.expect(Value.eq(result, Value.number(421)));
}

test "immediate upvalue" {
    const source =
        \\var result = "nothing";
        \\fun outer() {
        \\  var x = 420;
        \\  fun inner() {
        \\    result = x;
        \\  }
        \\  inner();
        \\}
        \\outer();
    ;
    const vm = try interpret_without_teardown(std.testing.allocator, source);
    defer {
        vm.destroy();
    }
    const result_str = try vm.get_string("result");
    const result = vm.gc.globals.get(result_str) orelse @panic("result not found");
    try std.testing.expect(Value.eq(result, Value.number(420)));
}

test "call native fn" {
    const source =
        \\var num = __testValue();
    ;
    const vm = try interpret_without_teardown(std.testing.allocator, source);
    defer {
        vm.destroy();
    }
    const result_str = try vm.get_string("num");
    const result = vm.gc.globals.get(result_str) orelse @panic("num not found");
    try std.testing.expect(Value.eq(result, Value.number(420)));
}

test "call fn" {
    const source =
        \\fun add420(num) {
        \\    return num + 420;
        \\}
        \\
        \\fun add69(num) {
        \\    return num + 69;
        \\}
        \\
        \\var num = add420(1);
        \\num = add69(num);
        \\num = add420(num);
    ;
    const vm = try interpret_without_teardown(std.testing.allocator, source);
    defer {
        vm.destroy();
    }
    const result_str = try vm.get_string("num");
    const result = vm.gc.globals.get(result_str) orelse @panic("num not found");
    try std.testing.expect(Value.eq(result, Value.number(910)));
}

test "local binary arithmetic lowers to one register instruction" {
    const vm = try create_vm(std.testing.allocator, null);
    defer vm.destroy();

    const source =
        \\{
        \\  var a = 20;
        \\  var b = 22;
        \\  print a + b;
        \\}
    ;

    var scanner = Scanner.init(source);
    var parser = Compiler.init_parser();
    var compiler = try Compiler.init(vm.gc, null, &scanner, &parser, null, FunctionType.Script);
    const function = (try compiler.compile()) orelse return error.CompileError;

    var found_add = false;
    for (function.chunk.code.items) |raw| {
        if (Instruction.opcode(raw) != Opcode.Add) continue;
        found_add = true;
        try std.testing.expectEqual(@as(u8, 3), Instruction.a(raw));
        try std.testing.expectEqual(@as(u8, 1), Instruction.b(raw));
        try std.testing.expectEqual(@as(u8, 2), Instruction.c(raw));
    }
    try std.testing.expect(found_add);
}

test "register VM preserves left-to-right values across side effects" {
    const source =
        \\fun probe() {
        \\    var value = 1;
        \\    fun mutate() {
        \\        value = 10;
        \\        return 2;
        \\    }
        \\    return value + mutate();
        \\}
        \\var result = probe();
    ;

    const vm = try interpret_without_teardown(std.testing.allocator, source);
    defer vm.destroy();

    const result_name = try vm.get_string("result");
    const result = vm.gc.globals.get(result_name) orelse @panic("result not found");
    try std.testing.expect(Value.eq(result, Value.number(3)));
}

test "register VM keeps nested call windows contiguous" {
    const source =
        \\fun id(x) { return x; }
        \\fun add(a, b) { return a + b; }
        \\fun compute() {
        \\    var bias = 10;
        \\    return bias + add(id(1), id(2)) * 3;
        \\}
        \\var result = compute();
    ;

    const vm = try interpret_without_teardown(std.testing.allocator, source);
    defer vm.destroy();

    const result_name = try vm.get_string("result");
    const result = vm.gc.globals.get(result_name) orelse @panic("result not found");
    try std.testing.expect(Value.eq(result, Value.number(19)));
}

test "if condition" {
    const source =
        \\var result = "not yet";
        \\if (true) { result = "it worked"; } else { result = "it did not work"; }
    ;
    const vm = try interpret_without_teardown(std.testing.allocator, source);
    defer {
        vm.destroy();
    }
    const expected_str = try vm.get_string("it worked");
    const result_str = try vm.get_string("result");
    const result = vm.gc.globals.get(result_str) orelse @panic("result not found");
    try std.testing.expect(Value.eq(result, Value.obj(expected_str.widen())));
}

test "for loop" {
    const source =
        \\var result = 1;
        \\for (var i = 0; i < 3; i = i + 1) {
        \\    result = result * 2;
        \\}
    ;
    const vm = try interpret_without_teardown(std.testing.allocator, source);
    defer {
        vm.destroy();
    }
    const result_str = try vm.get_string("result");
    const i_str = try vm.get_string("i");

    const result = vm.gc.globals.get(result_str) orelse @panic("result not found");
    try std.testing.expect(Value.eq(result, Value.number(8)));

    const i_val = vm.gc.globals.get(i_str) orelse Value.nil();
    try std.testing.expect(Value.eq(i_val, Value.nil()));
}

test "while loop" {
    const source =
        \\var i = 0;
        \\var result = 1;
        \\while (i < 3) {
        \\    result = result * 2;
        \\    i = i + 1;
        \\}
    ;
    const vm = try interpret_without_teardown(std.testing.allocator, source);
    defer {
        vm.destroy();
    }
    const result_str = try vm.get_string("result");
    const i_str = try vm.get_string("i");

    const i_val = vm.gc.globals.get(i_str) orelse @panic("i not found");
    try std.testing.expect(Value.eq(i_val, Value.number(3)));

    const result = vm.gc.globals.get(result_str) orelse @panic("result not found");
    try std.testing.expect(Value.eq(result, Value.number(8)));
}

test "using variable in its own initializer fails" {
    const source =
        \\var a = "outer";
        \\{
        \\    var a = a;
        \\}
    ;
    try std.testing.expectError(
        InterpretError.CompileError,
        interpret(std.testing.allocator, source),
    );
}

test "nested scope variables" {
    const source =
        \\{
        \\  var a = "outer";
        \\  {
        \\      var a = "inner";
        \\  }
        \\}
    ;
    try interpret(std.testing.allocator, source);
}


test "Lox truthiness accepts numbers and strings" {
    const source =
        \\var result = 0;
        \\if (0) result = result + 1;
        \\if ("") result = result + 1;
    ;

    const vm = try interpret_without_teardown(std.testing.allocator, source);
    defer vm.destroy();

    const result_name = try vm.get_string("result");
    const result = vm.gc.globals.get(result_name) orelse @panic("result not found");
    try std.testing.expect(Value.eq(result, Value.number(2)));
}

test "object equality is identity based and type safe" {
    const source =
        \\class Box {}
        \\var a = Box();
        \\var same = a == a;
        \\var different = a == Box();
    ;

    const vm = try interpret_without_teardown(std.testing.allocator, source);
    defer vm.destroy();

    const same_name = try vm.get_string("same");
    const different_name = try vm.get_string("different");
    try std.testing.expect(Value.eq(vm.gc.globals.get(same_name).?, Value.boolean(true)));
    try std.testing.expect(Value.eq(vm.gc.globals.get(different_name).?, Value.boolean(false)));
}

test "a closure may reference the same upvalue more than once" {
    const source =
        \\fun outer() {
        \\  var x = 21;
        \\  fun inner() { return x + x; }
        \\  return inner;
        \\}
        \\var result = outer()();
    ;

    const vm = try interpret_without_teardown(std.testing.allocator, source);
    defer vm.destroy();

    const result_name = try vm.get_string("result");
    try std.testing.expect(Value.eq(vm.gc.globals.get(result_name).?, Value.number(42)));
}

test "negation writes the correct register result" {
    const source =
        \\var result = -1 + 2;
    ;

    const vm = try interpret_without_teardown(std.testing.allocator, source);
    defer vm.destroy();

    const result_name = try vm.get_string("result");
    try std.testing.expect(Value.eq(vm.gc.globals.get(result_name).?, Value.number(1)));
}


test "empty source compiles and runs" {
    try interpret(std.testing.allocator, "");
}

test "one VM preserves globals across separate compilations" {
    const vm = try create_vm(std.testing.allocator, null);
    defer vm.destroy();

    try compile_and_run(vm, "var persistent = 40;");
    try compile_and_run(vm, "persistent = persistent + 2;");

    const name = try vm.get_string("persistent");
    const value = vm.gc.globals.get(name) orelse @panic("persistent not found");
    try std.testing.expect(Value.eq(value, Value.number(42)));
}

test "runtime error closes open upvalues before REPL stack reset" {
    const vm = try create_vm(std.testing.allocator, null);
    defer vm.destroy();

    const first =
        \\var saved;
        \\fun outer() {
        \\  var x = 41;
        \\  fun inner() { return x + 1; }
        \\  saved = inner;
        \\  missingGlobal;
        \\}
        \\outer();
    ;

    try std.testing.expectError(InterpretError.RuntimeError, compile_and_run(vm, first));
    try compile_and_run(vm, "var result = saved();");

    const name = try vm.get_string("result");
    const value = vm.gc.globals.get(name) orelse @panic("result not found");
    try std.testing.expect(Value.eq(value, Value.number(42)));
}

test "major compacting GC preserves closures, classes and closed upvalues" {
    const vm = try create_vm(std.testing.allocator, null);
    defer vm.destroy();

    const source =
        \\class Counter {
        \\  init(start) { this.value = start; }
        \\  makeStep(delta) {
        \\    var captured = delta;
        \\    fun step() {
        \\      this.value = this.value + captured;
        \\      return this.value;
        \\    }
        \\    return step;
        \\  }
        \\}
        \\var counter = Counter(40);
        \\var saved = counter.makeStep(1);
    ;

    try compile_and_run(vm, source);
    try vm.gc.collect();
    try compile_and_run(vm, "var compactedResult = saved();");

    const name = try vm.get_string("compactedResult");
    try std.testing.expect(Value.eq(vm.gc.globals.get(name).?, Value.number(41)));
}

test "minor GC remembered set preserves old instance to young value" {
    const vm = try create_vm(std.testing.allocator, null);
    defer vm.destroy();

    try compile_and_run(vm,
        \\class Box {}
        \\var box = Box();
    );

    // Make Box, its class and the instance old and compacted first.
    try vm.gc.collect();

    // This stores a newly compiled young string into an already-old instance.
    // Once the script closure dies, the remembered-set edge is the only heap
    // path that a young-only collection must scan from `box` to its field value.
    try compile_and_run(vm, "box.value = \"young-survivor\";");
    try vm.gc.collect_minor();

    try compile_and_run(vm, "var rememberedResult = box.value;");
    const result_name = try vm.get_string("rememberedResult");
    const expected = try vm.get_string("young-survivor");
    try std.testing.expect(Value.eq(vm.gc.globals.get(result_name).?, Value.obj(expected.widen())));
}

test "young survivors promote after configured minor collections" {
    const vm = try create_vm(std.testing.allocator, null);
    defer vm.destroy();

    try compile_and_run(vm, "class Keeper {} var keeper = Keeper();");

    var i: u8 = 0;
    while (i < @max(@as(u8, 1), @import("conf.zig").GC_PROMOTION_AGE)) : (i += 1) {
        try vm.gc.collect_minor();
    }

    const name = try vm.get_string("keeper");
    const keeper = vm.gc.globals.get(name).?.as_obj().?;
    try std.testing.expectEqual(Obj.Generation.Old, keeper.generation);
}

test "minor GC remembered set preserves old closed upvalue to young value" {
    const vm = try create_vm(std.testing.allocator, null);
    defer vm.destroy();

    try compile_and_run(vm,
        \\var setCaptured;
        \\var getCaptured;
        \\fun makeClosures() {
        \\  var captured = nil;
        \\  fun setter(value) { captured = value; }
        \\  fun getter() { return captured; }
        \\  setCaptured = setter;
        \\  getCaptured = getter;
        \\}
        \\makeClosures();
    );

    // Move the closures and their shared, already-closed upvalue to old space.
    try vm.gc.collect();

    // SET_UPVALUE creates the important old -> young edge here.
    try compile_and_run(vm, "setCaptured(\"young-upvalue\");");
    try vm.gc.collect_minor();

    try compile_and_run(vm, "var upvalueResult = getCaptured();");
    const result_name = try vm.get_string("upvalueResult");
    const expected = try vm.get_string("young-upvalue");
    try std.testing.expect(Value.eq(vm.gc.globals.get(result_name).?, Value.obj(expected.widen())));
}
