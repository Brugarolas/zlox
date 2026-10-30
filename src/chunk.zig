const std = @import("std");
const Value = @import("value.zig").Value;
const Obj = @import("obj.zig");
const Allocator = std.mem.Allocator;

/// The register VM uses one fixed-width 32-bit word per instruction.
///
/// Encoding:
///   bits  0.. 7: opcode
///   bits  8..15: A
///   bits 16..23: B
///   bits 24..31: C
///
/// Most instructions use A/B/C as register or small-immediate operands. Jumps use
/// B:C as a signed 16-bit relative displacement. Keeping decode fixed-width avoids
/// the byte-at-a-time operand traffic of the original stack VM and makes dispatch
/// substantially friendlier to the CPU front-end.
pub const Opcode = enum(u8) {
    Return,
    ReturnNil,
    Move,
    LoadConstant,
    LoadNil,
    LoadTrue,
    LoadFalse,
    Negate,
    Not,
    Equal,
    Greater,
    Less,
    Add,
    Subtract,
    Multiply,
    Divide,
    Print,
    DefineGlobal,
    GetGlobal,
    SetGlobal,
    JumpIfFalse,
    Jump,
    Call,
    Closure,
    CaptureLocal,
    CaptureUpvalue,
    GetUpvalue,
    SetUpvalue,
    CloseUpvalue,
    Class,
    GetProperty,
    SetProperty,
    Method,
    Invoke,
    Inherit,
    GetSuper,
    InvokeSuper,
};

pub const Instruction = struct {
    pub inline fn abc(op: Opcode, a_: u8, b_: u8, c_: u8) u32 {
        return @as(u32, @backingInt(op)) |
            (@as(u32, a_) << 8) |
            (@as(u32, b_) << 16) |
            (@as(u32, c_) << 24);
    }

    pub inline fn ab(op: Opcode, a_: u8, b_: u8) u32 {
        return abc(op, a_, b_, 0);
    }

    pub inline fn aOnly(op: Opcode, a_: u8) u32 {
        return abc(op, a_, 0, 0);
    }

    pub inline fn simple(op: Opcode) u32 {
        return abc(op, 0, 0, 0);
    }

    pub inline fn jump(op: Opcode, condition_reg: u8, displacement: i16) u32 {
        const bits: u16 = @bitCast(displacement);
        return abc(op, condition_reg, @truncate(bits >> 8), @truncate(bits));
    }

    pub inline fn opcode(raw: u32) Opcode {
        return @fromBackingInt(@as(u8, @truncate(raw)));
    }

    pub inline fn a(raw: u32) u8 {
        return @truncate(raw >> 8);
    }

    pub inline fn b(raw: u32) u8 {
        return @truncate(raw >> 16);
    }

    pub inline fn c(raw: u32) u8 {
        return @truncate(raw >> 24);
    }

    pub inline fn jumpOffset(raw: u32) i16 {
        const bits = (@as(u16, b(raw)) << 8) | @as(u16, c(raw));
        return @bitCast(bits);
    }
};

pub const Chunk = struct {
    const Self = @This();

    code: std.ArrayList(u32) = .empty,
    constants: std.ArrayList(Value) = .empty,
    lines: std.ArrayList(u32) = .empty,
    root_tops: std.ArrayList(u8) = .empty,

    pub fn init(_: Allocator) Allocator.Error!Self {
        return .{};
    }

    pub fn write(self: *Self, allocator: Allocator, instruction: u32, line: u32, root_top: u16) !usize {
        if (self.code.capacity == 0) try self.code.ensureTotalCapacity(allocator, 64);
        if (self.lines.capacity == 0) try self.lines.ensureTotalCapacity(allocator, 64);
        if (self.root_tops.capacity == 0) try self.root_tops.ensureTotalCapacity(allocator, 64);
        try self.code.ensureUnusedCapacity(allocator, 1);
        try self.lines.ensureUnusedCapacity(allocator, 1);
        try self.root_tops.ensureUnusedCapacity(allocator, 1);
        const offset = self.code.items.len;
        self.code.appendAssumeCapacity(instruction);
        self.lines.appendAssumeCapacity(line);
        std.debug.assert(root_top >= 1 and root_top <= 256);
        // Zero is reserved as the compact encoding for a full 256-register root window.
        self.root_tops.appendAssumeCapacity(if (root_top == 256) 0 else @intCast(root_top));
        return offset;
    }

    pub fn free(self: *Self, allocator: Allocator) void {
        self.code.deinit(allocator);
        self.constants.deinit(allocator);
        self.lines.deinit(allocator);
        self.root_tops.deinit(allocator);
        self.* = .{};
    }

    pub fn add_constant(self: *Self, allocator: Allocator, value: Value) !usize {
        const index = self.constants.items.len;
        if (self.constants.capacity == 0) try self.constants.ensureTotalCapacity(allocator, 64);
        try self.constants.append(allocator, value);
        return index;
    }

    pub fn disassemble(self: *const Self, name: []const u8) void {
        std.debug.print("== {s} ==\n", .{name});
        var offset: usize = 0;
        while (offset < self.code.items.len) offset = self.disassemble_instruction(offset);
        std.debug.print("== end {s} ==\n", .{name});
    }

    pub fn disassemble_instruction(self: *const Self, offset: usize) usize {
        std.debug.print("{d:0>4} ", .{offset});
        if (offset > 0 and self.lines.items[offset] == self.lines.items[offset - 1]) {
            std.debug.print("   | ", .{});
        } else {
            std.debug.print("{d:4} ", .{self.lines.items[offset]});
        }

        const raw = self.code.items[offset];
        const op = Instruction.opcode(raw);
        const a = Instruction.a(raw);
        const b = Instruction.b(raw);
        const c = Instruction.c(raw);

        return switch (op) {
            .Return => reg_instruction("RETURN", a, offset),
            .ReturnNil => simple_instruction("RETURN_NIL", offset),
            .Move => two_reg_instruction("MOVE", a, b, offset),
            .LoadConstant => self.constant_instruction("LOADK", a, b, offset),
            .LoadNil => reg_instruction("LOAD_NIL", a, offset),
            .LoadTrue => reg_instruction("LOAD_TRUE", a, offset),
            .LoadFalse => reg_instruction("LOAD_FALSE", a, offset),
            .Negate => two_reg_instruction("NEGATE", a, b, offset),
            .Not => two_reg_instruction("NOT", a, b, offset),
            .Equal => three_reg_instruction("EQUAL", a, b, c, offset),
            .Greater => three_reg_instruction("GREATER", a, b, c, offset),
            .Less => three_reg_instruction("LESS", a, b, c, offset),
            .Add => three_reg_instruction("ADD", a, b, c, offset),
            .Subtract => three_reg_instruction("SUBTRACT", a, b, c, offset),
            .Multiply => three_reg_instruction("MULTIPLY", a, b, c, offset),
            .Divide => three_reg_instruction("DIVIDE", a, b, c, offset),
            .Print => reg_instruction("PRINT", a, offset),
            .DefineGlobal => self.global_instruction("DEFINE_GLOBAL", a, b, offset),
            .GetGlobal => self.global_instruction("GET_GLOBAL", a, b, offset),
            .SetGlobal => self.global_instruction("SET_GLOBAL", a, b, offset),
            .JumpIfFalse => jump_instruction("JUMP_IF_FALSE", a, Instruction.jumpOffset(raw), offset),
            .Jump => jump_instruction("JUMP", 0, Instruction.jumpOffset(raw), offset),
            .Call => call_instruction("CALL", a, b, offset),
            .Closure => self.closure_instruction(offset),
            .CaptureLocal => reg_instruction("CAPTURE_LOCAL", a, offset),
            .CaptureUpvalue => reg_instruction("CAPTURE_UPVALUE", a, offset),
            .GetUpvalue => two_reg_instruction("GET_UPVALUE", a, b, offset),
            .SetUpvalue => two_reg_instruction("SET_UPVALUE", a, b, offset),
            .CloseUpvalue => reg_instruction("CLOSE_UPVALUE", a, offset),
            .Class => self.constant_instruction("CLASS", a, b, offset),
            .GetProperty => self.named_reg_instruction("GET_PROPERTY", a, c, offset),
            .SetProperty => self.property_instruction("SET_PROPERTY", a, b, c, offset),
            .Method => self.property_instruction("METHOD", a, b, c, offset),
            .Invoke => self.invoke_instruction("INVOKE", a, b, c, offset),
            .Inherit => two_reg_instruction("INHERIT", a, b, offset),
            .GetSuper => self.property_instruction("GET_SUPER", a, b, c, offset),
            .InvokeSuper => self.invoke_instruction("INVOKE_SUPER", a, b, c, offset),
        };
    }

    fn simple_instruction(name: []const u8, offset: usize) usize {
        std.debug.print("{s}\n", .{name});
        return offset + 1;
    }

    fn reg_instruction(name: []const u8, a: u8, offset: usize) usize {
        std.debug.print("{s} R{d}\n", .{ name, a });
        return offset + 1;
    }

    fn two_reg_instruction(name: []const u8, a: u8, b: u8, offset: usize) usize {
        std.debug.print("{s} R{d}, R{d}\n", .{ name, a, b });
        return offset + 1;
    }

    fn three_reg_instruction(name: []const u8, a: u8, b: u8, c: u8, offset: usize) usize {
        std.debug.print("{s} R{d}, R{d}, R{d}\n", .{ name, a, b, c });
        return offset + 1;
    }

    fn constant_instruction(self: *const Self, name: []const u8, a: u8, constant: u8, offset: usize) usize {
        std.debug.print("{s} R{d}, K{d} (", .{ name, a, constant });
        self.constants.items[constant].debugPrint();
        std.debug.print(")\n", .{});
        return offset + 1;
    }

    fn global_instruction(self: *const Self, name: []const u8, a: u8, constant: u8, offset: usize) usize {
        std.debug.print("{s} R{d}, K{d} (", .{ name, a, constant });
        self.constants.items[constant].debugPrint();
        std.debug.print(")\n", .{});
        return offset + 1;
    }

    fn named_reg_instruction(self: *const Self, name: []const u8, reg: u8, constant: u8, offset: usize) usize {
        std.debug.print("{s} R{d}, K{d} (", .{ name, reg, constant });
        self.constants.items[constant].debugPrint();
        std.debug.print(")\n", .{});
        return offset + 1;
    }

    fn property_instruction(self: *const Self, name: []const u8, a: u8, b: u8, constant: u8, offset: usize) usize {
        std.debug.print("{s} R{d}, R{d}, K{d} (", .{ name, a, b, constant });
        self.constants.items[constant].debugPrint();
        std.debug.print(")\n", .{});
        return offset + 1;
    }

    fn call_instruction(name: []const u8, base: u8, arg_count: u8, offset: usize) usize {
        std.debug.print("{s} R{d} ({d} args)\n", .{ name, base, arg_count });
        return offset + 1;
    }

    fn invoke_instruction(self: *const Self, name: []const u8, base: u8, arg_count: u8, constant: u8, offset: usize) usize {
        std.debug.print("{s} R{d} ({d} args), K{d} (", .{ name, base, arg_count, constant });
        self.constants.items[constant].debugPrint();
        std.debug.print(")\n", .{});
        return offset + 1;
    }

    fn jump_instruction(name: []const u8, condition: u8, displacement: i16, offset: usize) usize {
        const target = @as(i64, @intCast(offset)) + 1 + @as(i64, displacement);
        if (std.mem.eql(u8, name, "JUMP_IF_FALSE")) {
            std.debug.print("{s} R{d}, {d} -> {d}\n", .{ name, condition, offset, target });
        } else {
            std.debug.print("{s} {d} -> {d}\n", .{ name, offset, target });
        }
        return offset + 1;
    }

    fn closure_instruction(self: *const Self, offset: usize) usize {
        const raw = self.code.items[offset];
        const dst = Instruction.a(raw);
        const constant = Instruction.b(raw);
        std.debug.print("CLOSURE R{d}, K{d} (", .{ dst, constant });
        self.constants.items[constant].debugPrint();
        std.debug.print(")\n", .{});

        const function = self.constants.items[constant].as_obj().?.narrow(Obj.Function);
        var cursor = offset + 1;
        var i: usize = 0;
        while (i < function.upvalue_count) : (i += 1) {
            const capture = self.code.items[cursor];
            const capture_op = Instruction.opcode(capture);
            const index = Instruction.a(capture);
            std.debug.print("{d:0>4}    |   {s} {d}\n", .{
                cursor,
                if (capture_op == .CaptureLocal) "local" else "upvalue",
                index,
            });
            cursor += 1;
        }
        return cursor;
    }
};

test "register instruction encoding" {
    const raw = Instruction.abc(.Add, 7, 11, 13);
    try std.testing.expectEqual(Opcode.Add, Instruction.opcode(raw));
    try std.testing.expectEqual(@as(u8, 7), Instruction.a(raw));
    try std.testing.expectEqual(@as(u8, 11), Instruction.b(raw));
    try std.testing.expectEqual(@as(u8, 13), Instruction.c(raw));

    const jump = Instruction.jump(.JumpIfFalse, 5, -123);
    try std.testing.expectEqual(@as(u8, 5), Instruction.a(jump));
    try std.testing.expectEqual(@as(i16, -123), Instruction.jumpOffset(jump));
}

test "root metadata compactly represents all 256 registers" {
    var chunk = try Chunk.init(std.testing.allocator);
    defer chunk.free(std.testing.allocator);

    _ = try chunk.write(
        std.testing.allocator,
        Instruction.simple(.ReturnNil),
        1,
        256,
    );
    try std.testing.expectEqual(@as(u8, 0), chunk.root_tops.items[0]);
}
