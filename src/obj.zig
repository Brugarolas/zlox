const std = @import("std");
const Conf = @import("conf.zig");
const Chunk = @import("chunk.zig").Chunk;
const GC = @import("gc.zig");
const Value = @import("value.zig").Value;
const Table = @import("table.zig");
const Allocator = std.mem.Allocator;

const Obj = @This();

pub const Type = enum {
    String,
    Function,
    NativeFunction,
    Closure,
    Upvalue,
    Class,
    Instance,
    BoundMethod,

    pub fn obj_struct(comptime self: Type) type {
        return switch (self) {
            .String => String,
            .Function => Function,
            .NativeFunction => NativeFunction,
            .Closure => Closure,
            .Upvalue => Upvalue,
            .Class => Class,
            .Instance => Instance,
            .BoundMethod => BoundMethod,
        };
    }

    pub fn from_obj(comptime ObjType: type) Type {
        return from_obj_safe(ObjType) orelse @compileError("invalid Lox object type");
    }

    pub fn from_obj_safe(comptime ObjType: type) ?Type {
        return switch (ObjType) {
            String => .String,
            Function => .Function,
            NativeFunction => .NativeFunction,
            Closure => .Closure,
            Upvalue => .Upvalue,
            Class => .Class,
            Instance => .Instance,
            BoundMethod => .BoundMethod,
            else => null,
        };
    }
};

pub const Generation = enum(u8) { Young, Old };

type: Type,
is_marked: bool = false,
generation: Generation = .Young,
age: u8 = 0,
in_remembered: bool = false,
is_forwarded: bool = false,
// Young-list link in steady state; forwarding pointer while an object moves.
next: ?*Obj = null,

inline fn uncheckedNarrow(self: *Obj, comptime ParentType: type) *ParentType {
    const parent: *ParentType = @fieldParentPtr("obj", self);
    return parent;
}

pub inline fn narrow(self: *Obj, comptime ParentType: type) *ParentType {
    if (comptime Conf.SAFE_OBJ_CAST) {
        if (self.type != Type.from_obj(ParentType)) @panic("invalid Lox object cast");
    }
    return self.uncheckedNarrow(ParentType);
}

pub inline fn safe_narrow(self: *Obj, comptime ParentType: type) ?*ParentType {
    if (self.type != Type.from_obj(ParentType)) return null;
    return self.uncheckedNarrow(ParentType);
}

pub inline fn is(self: *const Obj, comptime ParentType: type) bool {
    return self.type == Type.from_obj(ParentType);
}

pub fn debugPrint(self: *Obj) void {
    switch (self.type) {
        inline else => |ty| self.narrow(Type.obj_struct(ty)).debugPrint(),
    }
}

pub fn write(self: *Obj, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (self.type) {
        inline else => |ty| try self.narrow(Type.obj_struct(ty)).write(writer),
    }
}

pub const String = struct {
    obj: Obj,
    len: u32,
    hash: u32,
    chars: [*]const u8,

    pub inline fn as_string(self: *const String) []const u8 {
        return self.chars[0..@as(usize, self.len)];
    }

    pub inline fn widen(self: *String) *Obj {
        return @ptrCast(self);
    }

    pub fn debugPrint(self: *String) void {
        std.debug.print("{s}", .{self.as_string()});
    }

    pub fn write(self: *String, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(self.as_string());
    }
};

pub const Function = struct {
    obj: Obj,
    arity: u8 = 0,
    upvalue_count: usize = 0,
    max_registers: u16 = 1,
    name: ?*String = null,
    chunk: Chunk,

    pub fn init(self: *Function, allocator: Allocator) !void {
        self.arity = 0;
        self.upvalue_count = 0;
        self.max_registers = 1;
        self.name = null;
        self.chunk = try Chunk.init(allocator);
    }

    pub inline fn widen(self: *Function) *Obj {
        return @ptrCast(self);
    }

    pub fn debugPrint(self: *Function) void {
        if (self.name) |name| {
            std.debug.print("<fn {s}>", .{name.as_string()});
        } else {
            std.debug.print("<script>", .{});
        }
    }

    pub fn write(self: *Function, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.name) |name| {
            try writer.print("<fn {s}>", .{name.as_string()});
        } else {
            try writer.writeAll("<script>");
        }
    }

    pub inline fn name_str(self: *const Function) []const u8 {
        return if (self.name) |name| name.as_string() else "script";
    }
};

pub const NativeFunction = struct {
    obj: Obj,
    function: NativeFn,

    pub const NativeFn = *const fn (u8, []Value) Value;

    pub fn init(self: *NativeFunction, function: NativeFn) void {
        self.function = function;
    }

    pub inline fn widen(self: *NativeFunction) *Obj {
        return @ptrCast(self);
    }

    pub fn debugPrint(_: *NativeFunction) void {
        std.debug.print("<native fn>", .{});
    }

    pub fn write(_: *NativeFunction, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll("<native fn>");
    }
};

pub const Closure = struct {
    obj: Obj,
    function: *Function,
    upvalues: []?*Upvalue,

    pub fn init(gc: *GC, function: *Function) !*Closure {
        const upvalues = try gc.as_allocator().alloc(?*Upvalue, function.upvalue_count);
        @memset(upvalues, null);
        errdefer gc.as_allocator().free(upvalues);

        const ptr = try gc.alloc_obj(Closure);
        ptr.function = function;
        ptr.upvalues = upvalues;
        gc.account_external_payload(ptr.widen(), upvalues.len * @sizeOf(?*Upvalue));
        return ptr;
    }

    pub inline fn upvalues_len(self: *const Closure) usize {
        return self.upvalues.len;
    }

    pub inline fn widen(self: *Closure) *Obj {
        return @ptrCast(self);
    }

    pub fn debugPrint(self: *Closure) void {
        self.function.debugPrint();
    }

    pub fn write(self: *Closure, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try self.function.write(writer);
    }
};

pub const Upvalue = struct {
    obj: Obj,
    location: *Value,
    closed: Value = Value.nil(),
    next: ?*Upvalue = null,

    pub fn init(self: *Upvalue, value: *Value) void {
        self.location = value;
        self.closed = Value.nil();
        self.next = null;
    }

    pub inline fn widen(self: *Upvalue) *Obj {
        return @ptrCast(self);
    }

    pub fn debugPrint(_: *Upvalue) void {
        std.debug.print("upvalue", .{});
    }

    pub fn write(_: *Upvalue, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll("upvalue");
    }
};

pub const Class = struct {
    obj: Obj,
    name: *String,
    methods: Table,

    pub fn init(gc: *GC, name: *String) !*Class {
        const ptr = try gc.alloc_obj(Class);
        ptr.name = name;
        ptr.methods = Table.init();
        return ptr;
    }

    pub inline fn widen(self: *Class) *Obj {
        return @ptrCast(self);
    }

    pub fn debugPrint(self: *Class) void {
        std.debug.print("{s}", .{self.name.as_string()});
    }

    pub fn write(self: *Class, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(self.name.as_string());
    }
};

pub const Instance = struct {
    obj: Obj,
    class: *Class,
    fields: Table,

    pub fn init(gc: *GC, class: *Class) !*Instance {
        const ptr = try gc.alloc_obj(Instance);
        ptr.class = class;
        ptr.fields = Table.init();
        return ptr;
    }

    pub inline fn widen(self: *Instance) *Obj {
        return @ptrCast(self);
    }

    pub fn debugPrint(self: *Instance) void {
        std.debug.print("{s} instance", .{self.class.name.as_string()});
    }

    pub fn write(self: *Instance, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{s} instance", .{self.class.name.as_string()});
    }
};

pub const BoundMethod = struct {
    obj: Obj,
    receiver: Value,
    method: *Closure,

    pub fn init(gc: *GC, receiver: Value, method: *Closure) !*BoundMethod {
        const ptr = try gc.alloc_obj(BoundMethod);
        ptr.receiver = receiver;
        ptr.method = method;
        return ptr;
    }

    pub inline fn widen(self: *BoundMethod) *Obj {
        return @ptrCast(self);
    }

    pub fn debugPrint(self: *BoundMethod) void {
        self.method.debugPrint();
    }

    pub fn write(self: *BoundMethod, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try self.method.write(writer);
    }
};
