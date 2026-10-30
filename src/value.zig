const std = @import("std");
const Obj = @import("obj.zig");

pub const Type = enum { Nil, Bool, Number, Obj };

pub const Value = union(Type) {
    Nil: void,
    Bool: bool,
    Number: f64,
    Obj: *Obj,

    pub fn debugPrint(self: Value) void {
        switch (self) {
            .Nil => std.debug.print("nil", .{}),
            .Bool => |value| std.debug.print("{}", .{value}),
            .Number => |value| std.debug.print("{d}", .{value}),
            .Obj => |object| object.debugPrint(),
        }
    }

    pub fn write(self: Value, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .Nil => try writer.writeAll("nil"),
            .Bool => |value| try writer.print("{}", .{value}),
            .Number => |value| try writer.print("{d}", .{value}),
            .Obj => |object| try object.write(writer),
        }
    }

    pub fn eq(a: Value, b: Value) bool {
        return switch (a) {
            .Nil => switch (b) {
                .Nil => true,
                else => false,
            },
            .Bool => |av| switch (b) {
                .Bool => |bv| av == bv,
                else => false,
            },
            .Number => |av| switch (b) {
                .Number => |bv| av == bv,
                else => false,
            },
            // All heap objects use identity equality. Strings are interned, so this
            // also provides Lox string value equality without a byte comparison.
            .Obj => |av| switch (b) {
                .Obj => |bv| av == bv,
                else => false,
            },
        };
    }

    pub inline fn is_falsey(self: Value) bool {
        return switch (self) {
            .Nil => true,
            .Bool => |value| !value,
            else => false,
        };
    }

    pub inline fn boolean(value: bool) Value {
        return .{ .Bool = value };
    }

    pub inline fn nil() Value {
        return .{ .Nil = {} };
    }

    pub inline fn number(value: f64) Value {
        return .{ .Number = value };
    }

    pub inline fn obj(object: *Obj) Value {
        return .{ .Obj = object };
    }

    pub inline fn as_boolean(self: Value) ?bool {
        return switch (self) {
            .Bool => |value| value,
            else => null,
        };
    }

    pub inline fn as_nil(self: Value) ?void {
        return switch (self) {
            .Nil => {},
            else => null,
        };
    }

    pub inline fn as_number(self: Value) ?f64 {
        return switch (self) {
            .Number => |value| value,
            else => null,
        };
    }

    pub inline fn as_obj(self: Value) ?*Obj {
        return switch (self) {
            .Obj => |object| object,
            else => null,
        };
    }

    pub inline fn as_obj_narrowed(self: Value, comptime ParentType: type) ?*ParentType {
        const object = self.as_obj() orelse return null;
        return object.safe_narrow(ParentType);
    }
};

test "Lox truthiness" {
    try std.testing.expect(Value.nil().is_falsey());
    try std.testing.expect(Value.boolean(false).is_falsey());
    try std.testing.expect(!Value.boolean(true).is_falsey());
    try std.testing.expect(!Value.number(0).is_falsey());
}
