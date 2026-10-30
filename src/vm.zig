const std = @import("std");
const builtin = @import("builtin");
const bytecode = @import("chunk.zig");
const Opcode = bytecode.Opcode;
const Instruction = bytecode.Instruction;
const Value = @import("value.zig").Value;
const Conf = @import("conf.zig");
const Obj = @import("obj.zig");
const GC = @import("gc.zig");
const native_fns = @import("native_fns.zig");

const Allocator = std.mem.Allocator;
const Self = @This();

pub const FRAMES_MAX: usize = 64;
pub const REGISTERS_PER_FRAME: usize = @as(usize, std.math.maxInt(u8)) + 1;
pub const REGISTER_STACK_MAX: usize = FRAMES_MAX * REGISTERS_PER_FRAME;

pub const CallFrame = struct {
    closure: *Obj.Closure,
    ip: [*]const u32,
    registers: [*]Value,

    pub inline fn fetch(self: *CallFrame) u32 {
        const instruction = self.ip[0];
        self.ip += 1;
        return instruction;
    }

    pub inline fn constant(self: *const CallFrame, index: u8) Value {
        return self.closure.function.chunk.constants.items[index];
    }

    pub inline fn stringConstant(self: *const CallFrame, index: u8) *Obj.String {
        return self.constant(index).as_obj().?.narrow(Obj.String);
    }

    /// Returns the number of live register roots at the current suspension point.
    /// The compiler records this beside each instruction, so GC pays this lookup
    /// only while collecting; the dispatch loop does not maintain a runtime top.
    pub fn rootTop(self: *const CallFrame) usize {
        const function = self.closure.function;
        const code = function.chunk.code.items;
        if (code.len == 0) return @as(usize, function.arity) + 1;

        const begin = @intFromPtr(code.ptr);
        const current = @intFromPtr(self.ip);
        const word_index = (current - begin) / @sizeOf(u32);
        if (word_index == 0) return @as(usize, function.arity) + 1;

        const executed = word_index - 1;
        if (executed < function.chunk.root_tops.items.len) {
            const encoded = function.chunk.root_tops.items[executed];
            return if (encoded == 0) REGISTERS_PER_FRAME else @as(usize, encoded);
        }
        return @as(usize, function.arity) + 1;
    }
};

pub const CallFrameStack = struct {
    stack: [FRAMES_MAX]CallFrame,
    count: usize = 0,
};

pub const RegisterStack = struct {
    stack: [REGISTER_STACK_MAX]Value,
};

pub const InterpretError = error{
    CompileError,
    RuntimeError,
};

allocator: Allocator,
gc: *GC,
call_frames: CallFrameStack,
registers: RegisterStack,
output: ?*std.Io.Writer = null,

pub fn create(allocator: Allocator, gc: *GC, output: ?*std.Io.Writer) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    self.allocator = allocator;
    self.gc = gc;
    self.call_frames.count = 0;
    @memset(self.registers.stack[0..], Value.nil());
    self.output = output;

    self.gc.call_frames = &self.call_frames;

    try self.define_native("clock", native_fns.clock);
    if (builtin.is_test) try self.define_native("__testValue", native_fns.test_value);
    return self;
}

pub fn destroy(self: *Self) void {
    const allocator = self.allocator;
    const gc = self.gc;
    gc.free_objects();
    allocator.destroy(gc);
    allocator.destroy(self);
}

pub fn prepare_script(self: *Self, closure: *Obj.Closure) void {
    self.reset_register_stack();
    self.registers.stack[0] = Value.obj(closure.widen());
    self.call_frames.stack[0] = .{
        .closure = closure,
        .ip = closure.function.chunk.code.items.ptr,
        .registers = self.registers.stack[0..].ptr,
    };
    self.call_frames.count = 1;
}

pub fn run(self: *Self) !void {
    try self.gc.safepoint();
    var frame = &self.call_frames.stack[self.call_frames.count - 1];

    while (true) {
        if (comptime Conf.TRACING) self.trace(frame);

        const raw = frame.fetch();
        const op = Instruction.opcode(raw);
        const a = Instruction.a(raw);
        const b = Instruction.b(raw);
        const c = Instruction.c(raw);

        switch (op) {
            .Return => {
                const result = frame.registers[a];
                const base = frame.registers;
                self.close_upvalues(base);
                self.call_frames.count -= 1;

                if (self.call_frames.count == 0) {
                    return;
                }

                base[0] = result;
                frame = &self.call_frames.stack[self.call_frames.count - 1];
            },
            .ReturnNil => {
                const base = frame.registers;
                self.close_upvalues(base);
                self.call_frames.count -= 1;

                if (self.call_frames.count == 0) {
                    return;
                }

                base[0] = Value.nil();
                frame = &self.call_frames.stack[self.call_frames.count - 1];
            },
            .Move => frame.registers[a] = frame.registers[b],
            .LoadConstant => frame.registers[a] = frame.constant(b),
            .LoadNil => frame.registers[a] = Value.nil(),
            .LoadTrue => frame.registers[a] = Value.boolean(true),
            .LoadFalse => frame.registers[a] = Value.boolean(false),
            .Negate => {
                const number = frame.registers[b].as_number() orelse {
                    self.runtime_error("Operand must be a number.");
                    return error.RuntimeError;
                };
                frame.registers[a] = Value.number(-number);
            },
            .Not => frame.registers[a] = Value.boolean(frame.registers[b].is_falsey()),
            .Equal => frame.registers[a] = Value.boolean(Value.eq(frame.registers[b], frame.registers[c])),
            .Greater => if (!self.binary_number(frame, a, b, c, .Greater)) return error.RuntimeError,
            .Less => if (!self.binary_number(frame, a, b, c, .Less)) return error.RuntimeError,
            .Add => {
                const left = frame.registers[b];
                const right = frame.registers[c];
                if (left.as_obj_narrowed(Obj.String) != null and right.as_obj_narrowed(Obj.String) != null) {
                    try self.concatenate(frame, a, b, c);
                } else if (!self.binary_number(frame, a, b, c, .Add)) {
                    return error.RuntimeError;
                }
            },
            .Subtract => if (!self.binary_number(frame, a, b, c, .Subtract)) return error.RuntimeError,
            .Multiply => if (!self.binary_number(frame, a, b, c, .Multiply)) return error.RuntimeError,
            .Divide => if (!self.binary_number(frame, a, b, c, .Divide)) return error.RuntimeError,
            .Print => {
                if (self.output) |writer| {
                    try frame.registers[a].write(writer);
                    try writer.writeAll("\n");
                }
            },
            .DefineGlobal => {
                _ = try self.gc.globals.insert(self.gc.as_allocator(), frame.stringConstant(b), frame.registers[a]);
            },
            .GetGlobal => {
                const name = frame.stringConstant(b);
                frame.registers[a] = self.gc.globals.get(name) orelse {
                    self.runtime_error_fmt("Undefined variable '{s}'.", .{name.as_string()});
                    return error.RuntimeError;
                };
            },
            .SetGlobal => {
                const name = frame.stringConstant(b);
                if (try self.gc.globals.insert(self.gc.as_allocator(), name, frame.registers[a])) {
                    _ = self.gc.globals.delete(name);
                    self.runtime_error_fmt("Undefined variable '{s}'.", .{name.as_string()});
                    return error.RuntimeError;
                }
            },
            .JumpIfFalse => {
                if (frame.registers[a].is_falsey()) add_ip_offset(frame, Instruction.jumpOffset(raw));
            },
            .Jump => add_ip_offset(frame, Instruction.jumpOffset(raw)),
            .Call => {
                const base = frame.registers + @as(usize, a);
                if (!(try self.call_value(base[0], b, base))) return error.RuntimeError;
                frame = &self.call_frames.stack[self.call_frames.count - 1];
            },
            .Closure => {
                const function = frame.constant(b).as_obj().?.narrow(Obj.Function);
                const closure = try Obj.Closure.init(self.gc, function);
                frame.registers[a] = Value.obj(closure.widen());

                var i: usize = 0;
                while (i < closure.upvalues.len) : (i += 1) {
                    const capture = frame.fetch();
                    const capture_index = Instruction.a(capture);
                    closure.upvalues[i] = switch (Instruction.opcode(capture)) {
                        .CaptureLocal => try self.capture_upvalue(&frame.registers[capture_index]),
                        .CaptureUpvalue => frame.closure.upvalues[capture_index].?,
                        else => unreachable,
                    };
                }
                try self.gc.safepoint();
            },
            .CaptureLocal, .CaptureUpvalue => unreachable,
            .GetUpvalue => {
                const upvalue = frame.closure.upvalues[b].?;
                frame.registers[a] = upvalue.location.*;
            },
            .SetUpvalue => {
                const upvalue = frame.closure.upvalues[b].?;
                const value = frame.registers[a];
                upvalue.location.* = value;
                if (upvalue.location == &upvalue.closed) self.gc.write_barrier_value(upvalue.widen(), value);
            },
            .CloseUpvalue => self.close_upvalues(&frame.registers[a]),
            .Class => {
                const class = try Obj.Class.init(self.gc, frame.stringConstant(b));
                frame.registers[a] = Value.obj(class.widen());
                try self.gc.safepoint();
            },
            .GetProperty => {
                const receiver = frame.registers[a];
                const instance = receiver.as_obj_narrowed(Obj.Instance) orelse {
                    self.runtime_error("Only instances have properties.");
                    return error.RuntimeError;
                };
                const name = frame.stringConstant(c);

                if (instance.fields.get(name)) |value| {
                    frame.registers[a] = value;
                } else if (!(try self.bind_method(instance.class, name, receiver, &frame.registers[a]))) {
                    self.runtime_error_fmt("Undefined property '{s}'.", .{name.as_string()});
                    return error.RuntimeError;
                }
            },
            .SetProperty => {
                const instance = frame.registers[a].as_obj_narrowed(Obj.Instance) orelse {
                    self.runtime_error("Only instances have fields.");
                    return error.RuntimeError;
                };
                const name = frame.stringConstant(c);
                const field_value = frame.registers[b];
                const table_bytes_before = instance.fields.allocatedBytes();
                _ = try instance.fields.insert(self.gc.as_allocator(), name, field_value);
                const table_bytes_after = instance.fields.allocatedBytes();
                self.gc.account_table_resize(instance.widen(), table_bytes_before, table_bytes_after);
                self.gc.write_barrier_obj(instance.widen(), name.widen());
                self.gc.write_barrier_value(instance.widen(), field_value);
                frame.registers[a] = field_value;
                if (table_bytes_after > table_bytes_before) try self.gc.safepoint();
            },
            .Method => {
                const class = frame.registers[a].as_obj_narrowed(Obj.Class).?;
                const name = frame.stringConstant(c);
                const method = frame.registers[b];
                const table_bytes_before = class.methods.allocatedBytes();
                _ = try class.methods.insert(self.gc.as_allocator(), name, method);
                const table_bytes_after = class.methods.allocatedBytes();
                self.gc.account_table_resize(class.widen(), table_bytes_before, table_bytes_after);
                self.gc.write_barrier_obj(class.widen(), name.widen());
                self.gc.write_barrier_value(class.widen(), method);
                if (table_bytes_after > table_bytes_before) try self.gc.safepoint();
            },
            .Invoke => {
                const base = frame.registers + @as(usize, a);
                const name = frame.stringConstant(c);
                if (!(try self.invoke(name, b, base))) return error.RuntimeError;
                frame = &self.call_frames.stack[self.call_frames.count - 1];
            },
            .Inherit => {
                const subclass = frame.registers[a].as_obj_narrowed(Obj.Class).?;
                const superclass = frame.registers[b].as_obj_narrowed(Obj.Class) orelse {
                    self.runtime_error("Superclass must be a class.");
                    return error.RuntimeError;
                };
                const table_bytes_before = subclass.methods.allocatedBytes();
                try superclass.methods.add_all(self.gc.as_allocator(), &subclass.methods);
                const table_bytes_after = subclass.methods.allocatedBytes();
                self.gc.account_table_resize(subclass.widen(), table_bytes_before, table_bytes_after);
                self.gc.remember_object_if_needed(subclass.widen());
                if (table_bytes_after > table_bytes_before) try self.gc.safepoint();
            },
            .GetSuper => {
                const superclass = frame.registers[b].as_obj_narrowed(Obj.Class).?;
                const name = frame.stringConstant(c);
                const receiver = frame.registers[a];
                if (!(try self.bind_method(superclass, name, receiver, &frame.registers[a]))) {
                    self.runtime_error_fmt("Undefined property '{s}'.", .{name.as_string()});
                    return error.RuntimeError;
                }
            },
            .InvokeSuper => {
                const base = frame.registers + @as(usize, a);
                const superclass = base[@as(usize, b) + 1].as_obj_narrowed(Obj.Class).?;
                const name = frame.stringConstant(c);
                if (!self.invoke_from_class(superclass, name, b, base)) return error.RuntimeError;
                frame = &self.call_frames.stack[self.call_frames.count - 1];
            },
        }
    }
}

inline fn add_ip_offset(frame: *CallFrame, offset: i16) void {
    if (offset >= 0) {
        frame.ip += @intCast(offset);
    } else {
        frame.ip -= @intCast(-@as(i32, offset));
    }
}

fn trace(self: *Self, frame: *CallFrame) void {
    const root_top = frame.rootTop();
    const base_index = (@intFromPtr(frame.registers) - @intFromPtr(&self.registers.stack[0])) / @sizeOf(Value);
    std.debug.print("        REGS(base={d}, roots={d}): [", .{ base_index, root_top });
    var i: usize = 0;
    while (i < root_top) : (i += 1) {
        std.debug.print(" R{d}=", .{i});
        frame.registers[i].debugPrint();
    }
    std.debug.print(" ]\n", .{});

    const function = frame.closure.function;
    const begin = @intFromPtr(function.chunk.code.items.ptr);
    const current = @intFromPtr(frame.ip);
    const offset = (current - begin) / @sizeOf(u32);
    if (offset < function.chunk.code.items.len) _ = function.chunk.disassemble_instruction(offset);
}

fn concatenate(self: *Self, frame: *CallFrame, dst: u8, lhs: u8, rhs: u8) !void {
    const b = frame.registers[rhs].as_obj_narrowed(Obj.String).?;
    const a = frame.registers[lhs].as_obj_narrowed(Obj.String).?;
    const new_len = @as(usize, a.len) + @as(usize, b.len);
    const new_chars = try self.gc.as_allocator().alloc(u8, new_len);
    errdefer self.gc.as_allocator().free(new_chars);

    @memcpy(new_chars[0..a.len], a.as_string());
    @memcpy(new_chars[a.len..], b.as_string());
    const string = try self.gc.take_string(new_chars.ptr, new_len);
    frame.registers[dst] = Value.obj(string.widen());
    try self.gc.safepoint();
}

inline fn binary_number(self: *Self, frame: *CallFrame, dst: u8, lhs: u8, rhs: u8, comptime op: Opcode) bool {
    const b = frame.registers[rhs].as_number() orelse {
        self.runtime_error("Operands must be numbers.");
        return false;
    };
    const a = frame.registers[lhs].as_number() orelse {
        self.runtime_error("Operands must be numbers.");
        return false;
    };

    frame.registers[dst] = switch (op) {
        .Add => Value.number(a + b),
        .Subtract => Value.number(a - b),
        .Multiply => Value.number(a * b),
        .Divide => Value.number(a / b),
        .Less => Value.boolean(a < b),
        .Greater => Value.boolean(a > b),
        else => unreachable,
    };
    return true;
}

fn capture_upvalue(self: *Self, local: *Value) !*Obj.Upvalue {
    var previous: ?*Obj.Upvalue = null;
    var current = self.gc.open_upvalues;

    while (current) |upvalue| {
        if (@intFromPtr(upvalue.location) <= @intFromPtr(local)) break;
        previous = upvalue;
        current = upvalue.next;
    }

    if (current) |upvalue| {
        if (upvalue.location == local) return upvalue;
    }

    const created = try self.gc.alloc_obj(Obj.Upvalue);
    created.init(local);
    created.next = current;

    if (previous) |upvalue| {
        upvalue.next = created;
    } else {
        self.gc.open_upvalues = created;
    }
    return created;
}

fn close_upvalues(self: *Self, last: [*]Value) void {
    while (self.gc.open_upvalues) |upvalue| {
        if (@intFromPtr(upvalue.location) < @intFromPtr(last)) break;
        upvalue.closed = upvalue.location.*;
        upvalue.location = &upvalue.closed;
        self.gc.write_barrier_value(upvalue.widen(), upvalue.closed);
        self.gc.open_upvalues = upvalue.next;
    }
}

fn bind_method(
    self: *Self,
    class: *Obj.Class,
    name: *Obj.String,
    receiver: Value,
    dst: *Value,
) !bool {
    const method = class.methods.get(name) orelse return false;
    const closure = method.as_obj_narrowed(Obj.Closure).?;
    const bound = try Obj.BoundMethod.init(self.gc, receiver, closure);
    dst.* = Value.obj(bound.widen());
    try self.gc.safepoint();
    return true;
}

fn call_value(self: *Self, callee: Value, arg_count: u8, base: [*]Value) !bool {
    const object = callee.as_obj() orelse {
        self.runtime_error("Can only call functions and classes.");
        return false;
    };

    switch (object.type) {
        .BoundMethod => {
            const bound = object.narrow(Obj.BoundMethod);
            base[0] = bound.receiver;
            return self.call(bound.method, arg_count, base);
        },
        .Class => {
            const class = object.narrow(Obj.Class);
            const instance = try Obj.Instance.init(self.gc, class);
            base[0] = Value.obj(instance.widen());

            if (class.methods.get(self.gc.init_string)) |initializer| {
                const ok = self.call(initializer.as_obj_narrowed(Obj.Closure).?, arg_count, base);
                try self.gc.safepoint();
                return ok;
            }
            if (arg_count != 0) {
                self.runtime_error_fmt("Expected 0 arguments but got {d}.", .{arg_count});
                return false;
            }
            try self.gc.safepoint();
            return true;
        },
        .Closure => return self.call(object.narrow(Obj.Closure), arg_count, base),
        .NativeFunction => {
            const native = object.narrow(Obj.NativeFunction);
            const args = base[1 .. @as(usize, arg_count) + 1];
            base[0] = native.function(arg_count, args);
            return true;
        },
        else => {
            self.runtime_error("Can only call functions and classes.");
            return false;
        },
    }
}

fn invoke_from_class(self: *Self, class: *Obj.Class, name: *Obj.String, arg_count: u8, base: [*]Value) bool {
    const method = class.methods.get(name) orelse {
        self.runtime_error_fmt("Undefined property '{s}'.", .{name.as_string()});
        return false;
    };
    return self.call(method.as_obj_narrowed(Obj.Closure).?, arg_count, base);
}

fn invoke(self: *Self, name: *Obj.String, arg_count: u8, base: [*]Value) !bool {
    const instance = base[0].as_obj_narrowed(Obj.Instance) orelse {
        self.runtime_error("Only instances have methods.");
        return false;
    };

    if (instance.fields.get(name)) |value| {
        base[0] = value;
        return self.call_value(value, arg_count, base);
    }
    return self.invoke_from_class(instance.class, name, arg_count, base);
}

fn call(self: *Self, closure: *Obj.Closure, arg_count: u8, base: [*]Value) bool {
    if (arg_count != closure.function.arity) {
        self.runtime_error_fmt("Expected {d} arguments but got {d}.", .{ closure.function.arity, arg_count });
        return false;
    }
    if (self.call_frames.count == FRAMES_MAX) {
        self.runtime_error("Call frame overflow.");
        return false;
    }

    const register_stack_base = @intFromPtr(&self.registers.stack[0]);
    const base_addr = @intFromPtr(base);
    const base_index = (base_addr - register_stack_base) / @sizeOf(Value);
    if (base_index + @as(usize, closure.function.max_registers) > REGISTER_STACK_MAX) {
        self.runtime_error("Register stack overflow.");
        return false;
    }

    const frame = &self.call_frames.stack[self.call_frames.count];
    self.call_frames.count += 1;
    frame.* = .{
        .closure = closure,
        .ip = closure.function.chunk.code.items.ptr,
        .registers = base,
    };
    return true;
}

pub fn get_string(self: *Self, string: []const u8) !*Obj.String {
    return self.gc.copy_string(string.ptr, @intCast(string.len));
}

fn runtime_error(self: *Self, message: []const u8) void {
    std.debug.print("Runtime error: {s}\n", .{message});
    self.print_stack_trace();
    self.close_all_open_upvalues();
    self.reset_register_stack();
}

fn runtime_error_fmt(self: *Self, comptime fmt: []const u8, args: anytype) void {
    std.debug.print("Runtime error: " ++ fmt ++ "\n", args);
    self.print_stack_trace();
    self.close_all_open_upvalues();
    self.reset_register_stack();
}

fn close_all_open_upvalues(self: *Self) void {
    if (self.gc.open_upvalues == null) return;
    self.close_upvalues(self.registers.stack[0..].ptr);
}

fn print_stack_trace(self: *Self) void {
    var i = self.call_frames.count;
    while (i > 0) {
        i -= 1;
        const frame = &self.call_frames.stack[i];
        const function = frame.closure.function;
        const begin = @intFromPtr(function.chunk.code.items.ptr);
        const current = @intFromPtr(frame.ip);
        const word_offset = (current - begin) / @sizeOf(u32);
        const instruction = if (word_offset == 0) 0 else word_offset - 1;
        const line = if (instruction < function.chunk.lines.items.len)
            function.chunk.lines.items[instruction]
        else
            0;

        if (function.name) |name| {
            std.debug.print("[line {d}] in {s}()\n", .{ line, name.as_string() });
        } else {
            std.debug.print("[line {d}] in script\n", .{line});
        }
    }
}

fn define_native(self: *Self, name: []const u8, function: Obj.NativeFunction.NativeFn) !void {
    const name_obj = try self.gc.copy_string(name.ptr, @intCast(name.len));
    const native = try self.gc.alloc_obj(Obj.NativeFunction);
    native.init(function);
    _ = try self.gc.globals.insert(self.gc.as_allocator(), name_obj, Value.obj(native.widen()));
}

fn reset_register_stack(self: *Self) void {
    self.call_frames.count = 0;
    self.gc.open_upvalues = null;
}
