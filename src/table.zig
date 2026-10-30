const std = @import("std");
const Allocator = std.mem.Allocator;
const Obj = @import("obj.zig");
const Value = @import("value.zig").Value;

const Table = @This();

count: usize = 0,
entries: ?[]Entry = null,

pub const Entry = struct {
    key: ?*Obj.String = null,
    val: Value = Value.nil(),
};

pub fn init() Table {
    return .{};
}

pub inline fn allocatedBytes(self: *const Table) usize {
    return if (self.entries) |entries| entries.len * @sizeOf(Entry) else 0;
}

pub fn free(self: *Table, allocator: Allocator) void {
    if (self.entries) |entries| allocator.free(entries);
    self.* = .{};
}

pub fn hash_string(key: [*]const u8, len: u32) u32 {
    var hash: u32 = 2166136261;
    for (key[0..@as(usize, len)]) |c| {
        hash ^= c;
        hash *%= 16777619;
    }
    return hash;
}

pub fn get(self: *const Table, key: *Obj.String) ?Value {
    if (self.count == 0) return null;
    const entries = self.entries orelse return null;
    const entry = find_entry_impl(entries, key);
    if (entry.key == null) return null;
    return entry.val;
}

/// Returns true when `key` did not previously exist in the table.
pub fn insert(self: *Table, allocator: Allocator, key: *Obj.String, val: Value) !bool {
    const capacity = if (self.entries) |entries| entries.len else 0;
    // Keep the load factor at or below 75% without floating-point arithmetic.
    if ((self.count + 1) * 4 > capacity * 3) {
        const new_capacity: usize = if (capacity < 8) 8 else capacity * 2;
        try self.adjust_capacity(allocator, new_capacity);
    }

    const entries = self.entries.?;
    const entry = find_entry_impl(entries, key);
    const is_new_key = entry.key == null;
    if (is_new_key and entry.val.as_nil() != null) self.count += 1;

    entry.key = key;
    entry.val = val;
    return is_new_key;
}

pub fn add_all(self: *const Table, allocator: Allocator, to: *Table) !void {
    const entries = self.entries orelse return;
    for (entries) |entry| {
        if (entry.key) |key| _ = try to.insert(allocator, key, entry.val);
    }
}

pub fn delete(self: *Table, key: *Obj.String) bool {
    if (self.count == 0) return false;
    const entries = self.entries orelse return false;
    const entry = find_entry_impl(entries, key);
    if (entry.key == null) return false;

    entry.key = null;
    entry.val = Value.boolean(true); // Tombstone.
    return true;
}

pub fn find_string(self: *const Table, chars: [*]const u8, len: u32, hash: u32) ?*Obj.String {
    if (self.count == 0) return null;
    const entries = self.entries orelse return null;
    var index: usize = @as(usize, hash) & (entries.len - 1);

    while (true) {
        const entry = &entries[index];
        if (entry.key) |key| {
            if (key.len == len and key.hash == hash and
                std.mem.eql(u8, key.chars[0..@as(usize, key.len)], chars[0..@as(usize, len)]))
            {
                return key;
            }
        } else if (entry.val.as_nil() != null) {
            return null;
        }

        index = (index + 1) & (entries.len - 1);
    }
}

fn find_entry_impl(entries: []Entry, key: *Obj.String) *Entry {
    var index: usize = @as(usize, key.hash) & (entries.len - 1);
    var tombstone: ?*Entry = null;

    while (true) {
        const entry = &entries[index];
        if (entry.key == null) {
            if (entry.val.as_nil() != null) return tombstone orelse entry;
            if (tombstone == null) tombstone = entry;
        } else if (entry.key == key) {
            return entry;
        }
        index = (index + 1) & (entries.len - 1);
    }
}

fn adjust_capacity(self: *Table, allocator: Allocator, new_capacity: usize) !void {
    std.debug.assert(std.math.isPowerOfTwo(new_capacity));

    const new_entries = try allocator.alloc(Entry, new_capacity);
    for (new_entries) |*entry| entry.* = .{};

    var new_count: usize = 0;
    if (self.entries) |old_entries| {
        for (old_entries) |entry| {
            const key = entry.key orelse continue;
            const dest = find_entry_impl(new_entries, key);
            dest.key = key;
            dest.val = entry.val;
            new_count += 1;
        }
        allocator.free(old_entries);
    }

    self.entries = new_entries;
    self.count = new_count;
}

pub fn debugPrint(self: *const Table, name: []const u8) void {
    const entries = self.entries orelse return;
    std.debug.print("== begin {s} ==\n", .{name});
    for (entries) |entry| {
        const key = entry.key orelse continue;
        std.debug.print("{s}: ", .{key.as_string()});
        entry.val.debugPrint();
        std.debug.print(", ", .{});
    }
    std.debug.print("\n== end {s} ==\n", .{name});
}
