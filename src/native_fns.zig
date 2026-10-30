const std = @import("std");
const Value = @import("value.zig").Value;

pub fn clock(arg_count: u8, args: []Value) Value {
    _ = arg_count;
    _ = args;

    // `clock()` is deliberately monotonic and sub-second, matching its purpose
    // in Lox: measuring elapsed execution time rather than telling wall time.
    const io = std.Io.Threaded.global_single_threaded.io();
    const now = std.Io.Clock.awake.now(io);
    const seconds = @as(f64, @floatFromInt(now.nanoseconds)) /
        @as(f64, @floatFromInt(std.time.ns_per_s));
    return Value.number(seconds);
}

pub fn test_value(arg_count: u8, args: []Value) Value {
    _ = arg_count;
    _ = args;
    return Value.number(420);
}
