const std = @import("std");
const Conf = @import("conf.zig");
const Obj = @import("obj.zig");
const Table = @import("table.zig");
const Value = @import("value.zig").Value;
const CallFrameStack = @import("vm.zig").CallFrameStack;

const Allocator = std.mem.Allocator;
const GC = @This();
const PROMOTION_AGE: u8 = @max(@as(u8, 1), Conf.GC_PROMOTION_AGE);

/// Old-space arena. Object headers/bodies are packed contiguously while their
/// variable-sized payloads (tables, chunks, string bytes, closure upvalue arrays)
/// remain separately allocated and are owned by the containing object.
const Arena = struct {
    // u128 gives every arena a stable 16-byte base alignment, enough for all
    // current Lox object layouts. Individual objects are aligned again inside it.
    storage: []u128,
    used: usize = 0,

    fn init(allocator: Allocator, requested_bytes: usize) !Arena {
        const word_size = @sizeOf(u128);
        const words = @max(@as(usize, 1), (requested_bytes + word_size - 1) / word_size);
        return .{ .storage = try allocator.alloc(u128, words) };
    }

    fn deinit(self: *Arena, allocator: Allocator) void {
        allocator.free(self.storage);
        self.* = undefined;
    }

    inline fn capacityBytes(self: *const Arena) usize {
        return self.storage.len * @sizeOf(u128);
    }

    fn create(self: *Arena, comptime T: type) ?*T {
        comptime {
            if (@alignOf(T) > @alignOf(u128)) @compileError("Lox object alignment exceeds old-space arena alignment");
        }
        const alignment = @alignOf(T);
        const aligned = (self.used + alignment - 1) & ~(alignment - 1);
        if (aligned + @sizeOf(T) > self.capacityBytes()) return null;

        const base: [*]u8 = @ptrCast(self.storage.ptr);
        const ptr: *T = @ptrCast(@alignCast(base + aligned));
        self.used = aligned + @sizeOf(T);
        return ptr;
    }
};

inner_allocator: Allocator,
init_string: *Obj.String,

// Young objects are individually allocated and linked intrusively. Old objects
// live inside compact arenas and are indexed separately because they cannot be
// individually freed.
young_list: ?*Obj = null,
old_objects: std.ArrayList(*Obj) = .empty,
old_arenas: std.ArrayList(Arena) = .empty,

open_upvalues: ?*Obj.Upvalue = null,
interned_strings: Table = Table.init(),
globals: Table = Table.init(),
gray_stack: std.ArrayList(*Obj) = .empty,
remembered: std.ArrayList(*Obj) = .empty,
call_frames: ?*CallFrameStack = null,

bytes_allocated: usize = 0,
young_bytes: usize = 0,
old_bytes: usize = 0,
next_major: usize = 4 * 1024 * 1024,
minor_requested: bool = false,
major_requested: bool = false,
collection_requested: bool = false,
scan_all_old_on_minor: bool = false,
enabled: bool = false,

pub fn init(self: *GC, allocator: Allocator, comptime run_gc: bool) !void {
    self.* = .{
        .inner_allocator = allocator,
        .init_string = undefined,
    };

    // The initial interned string is created before VM roots exist.
    self.enabled = false;
    self.init_string = try self.copy_string("init".ptr, @intCast("init".len));
    self.enabled = run_gc;
    if (run_gc) self.scheduleFromCurrentUsage();
}

pub inline fn as_allocator(self: *GC) Allocator {
    return self.inner_allocator;
}

pub fn patch_allocator(self: *GC) void {
    self.enabled = true;
    self.scheduleFromCurrentUsage();
}

pub fn pause(self: *GC) bool {
    const was_enabled = self.enabled;
    self.enabled = false;
    return was_enabled;
}

pub fn restore(self: *GC, enabled: bool) void {
    self.enabled = enabled;
    if (enabled) self.scheduleFromCurrentUsage();
}

/// Moving collections happen only here (or through the explicit collect APIs),
/// never from an allocation. Allocating opcodes call this only after publishing
/// newly-created values into VM-visible roots. Non-allocating dispatch therefore
/// pays no GC polling cost.
pub inline fn safepoint(self: *GC) !void {
    if (self.collection_requested) {
        @branchHint(.unlikely);
        try self.safepointSlow();
    }
}

fn safepointSlow(self: *GC) !void {
    if (!self.enabled) return;
    if (self.major_requested) {
        try self.collectMajor();
    } else if (self.minor_requested) {
        try self.collectMinor();
        if (self.major_requested) try self.collectMajor();
    }
    self.collection_requested = self.minor_requested or self.major_requested;
}

pub fn collect(self: *GC) !void {
    if (!self.enabled) return;
    try self.collectMajor();
}

pub fn collect_minor(self: *GC) !void {
    if (!self.enabled) return;
    try self.collectMinor();
}

fn scheduleFromCurrentUsage(self: *GC) void {
    // Compilation runs with GC paused and mutates only young objects. Recount the
    // nursery to capture chunk/constant growth without touching old space.
    self.recomputeYoungBytes();
    self.bytes_allocated = self.young_bytes +| self.old_bytes;
    if (comptime Conf.DEBUG_STRESS_GC) {
        self.major_requested = true;
        self.collection_requested = true;
        return;
    }
    if (self.young_bytes >= Conf.GC_NURSERY_BYTES) self.minor_requested = true;
    if (self.bytes_allocated >= self.next_major) self.major_requested = true;
    self.collection_requested = self.minor_requested or self.major_requested;
}

fn scheduleAllocation(self: *GC, incoming_bytes: usize) void {
    if (!self.enabled) return;
    if (comptime Conf.DEBUG_STRESS_GC) {
        self.major_requested = true;
        self.collection_requested = true;
        return;
    }
    if (self.young_bytes +| incoming_bytes >= Conf.GC_NURSERY_BYTES) self.minor_requested = true;
    if (self.bytes_allocated +| incoming_bytes >= self.next_major) self.major_requested = true;
    self.collection_requested = self.minor_requested or self.major_requested;
}

pub fn alloc_obj(self: *GC, comptime ParentType: type) !*ParentType {
    comptime {
        if (Obj.Type.from_obj_safe(ParentType) == null) @compileError("alloc_obj requires a Lox object type");
    }

    self.scheduleAllocation(@sizeOf(ParentType));
    const ptr = try self.inner_allocator.create(ParentType);
    ptr.obj = .{
        .type = Obj.Type.from_obj(ParentType),
        .is_marked = false,
        .generation = .Young,
        .age = 0,
        .in_remembered = false,
        .is_forwarded = false,
        .next = self.young_list,
    };
    self.young_list = ptr.widen();
    self.bytes_allocated +|= @sizeOf(ParentType);
    self.young_bytes +|= @sizeOf(ParentType);

    if (comptime Conf.DEBUG_LOG_GC) {
        std.debug.print("[gc] young allocate {d} bytes as {s} at {*}\n", .{
            @sizeOf(ParentType), @tagName(ptr.obj.type), ptr,
        });
    }
    return ptr;
}

pub fn copy_string(self: *GC, chars: [*]const u8, len: u32) !*Obj.String {
    const hash = Table.hash_string(chars, len);
    if (self.interned_strings.find_string(chars, len, hash)) |interned| return interned;

    self.scheduleAllocation(@as(usize, len));
    const owned = try self.inner_allocator.alloc(u8, @as(usize, len));
    errdefer self.inner_allocator.free(owned);
    @memcpy(owned, chars[0..@as(usize, len)]);
    return self.alloc_string(owned.ptr, len, hash);
}

pub fn take_string(self: *GC, chars: [*]const u8, len: usize) !*Obj.String {
    const len_u32: u32 = @intCast(len);
    const hash = Table.hash_string(chars, len_u32);
    if (self.interned_strings.find_string(chars, len_u32, hash)) |interned| {
        self.inner_allocator.free(@constCast(chars[0..len]));
        return interned;
    }
    self.scheduleAllocation(len);
    errdefer self.inner_allocator.free(@constCast(chars[0..len]));
    return self.alloc_string(chars, len_u32, hash);
}

fn alloc_string(self: *GC, chars: [*]const u8, len: u32, hash: u32) !*Obj.String {
    const string = try self.alloc_obj(Obj.String);
    errdefer {
        std.debug.assert(self.young_list != null and self.young_list.? == string.widen());
        self.young_list = string.obj.next;
        self.bytes_allocated -|= @sizeOf(Obj.String);
        self.young_bytes -|= @sizeOf(Obj.String);
        self.inner_allocator.destroy(string);
    }

    string.len = len;
    string.hash = hash;
    string.chars = chars;
    _ = try self.interned_strings.insert(self.inner_allocator, string, Value.nil());

    self.bytes_allocated +|= @as(usize, len);
    self.young_bytes +|= @as(usize, len);
    return string;
}

/// Accounts separately allocated payload owned by a GC object. This is used for
/// payloads whose allocator cannot itself trigger a moving collection. Collection
/// is merely scheduled here and will run at the next VM safepoint.
pub fn account_external_payload(self: *GC, holder: *Obj, bytes: usize) void {
    if (bytes == 0) return;
    if (holder.generation == .Young) {
        self.young_bytes +|= bytes;
    } else {
        self.old_bytes +|= bytes;
    }
    self.bytes_allocated +|= bytes;
    self.scheduleAfterAllocation();
}

/// Updates GC accounting after a Class/Instance hash table grows. Tables do not
/// shrink during normal Lox execution, so only the positive delta matters.
pub fn account_table_resize(self: *GC, holder: *Obj, before_bytes: usize, after_bytes: usize) void {
    if (after_bytes <= before_bytes) return;
    self.account_external_payload(holder, after_bytes - before_bytes);
}

fn scheduleAfterAllocation(self: *GC) void {
    if (!self.enabled) return;
    if (comptime Conf.DEBUG_STRESS_GC) {
        self.major_requested = true;
    } else {
        if (self.young_bytes >= Conf.GC_NURSERY_BYTES) self.minor_requested = true;
        if (self.bytes_allocated >= self.next_major) self.major_requested = true;
    }
    self.collection_requested = self.minor_requested or self.major_requested;
}

// -----------------------------------------------------------------------------
// Write barrier
// -----------------------------------------------------------------------------

pub inline fn write_barrier_obj(self: *GC, holder: *Obj, child: ?*Obj) void {
    const target = child orelse return;
    if (holder.generation == .Old and target.generation == .Young) self.remember(holder);
}

pub inline fn write_barrier_value(self: *GC, holder: *Obj, value: Value) void {
    if (value.as_obj()) |child| self.write_barrier_obj(holder, child);
}

/// Used after bulk writes (for example inheritance copying a method table).
pub fn remember_object_if_needed(self: *GC, holder: *Obj) void {
    if (holder.generation == .Old and self.objectHasYoungReference(holder)) self.remember(holder);
}

fn remember(self: *GC, holder: *Obj) void {
    if (holder.in_remembered) return;
    self.remembered.append(self.inner_allocator, holder) catch {
        // Correctness fallback if growing the remembered set fails: scan all old
        // objects in subsequent minor collections.
        self.scan_all_old_on_minor = true;
        return;
    };
    holder.in_remembered = true;
}

// -----------------------------------------------------------------------------
// Minor collection: mark young, sweep dead, promote survivors, repair pointers.
// -----------------------------------------------------------------------------

fn collectMinor(self: *GC) !void {
    self.minor_requested = false;
    const before = self.young_bytes;
    if (comptime Conf.DEBUG_LOG_GC) {
        std.debug.print("-- minor gc begin ({d} young bytes)\n", .{before});
    }

    const young_count = self.countYoung();
    var promoted_sources: std.ArrayList(*Obj) = .empty;
    defer promoted_sources.deinit(self.inner_allocator);

    // Reserve every collection-side structure before changing mark state. After
    // this point minor collection is allocation-free except optional promotion
    // arena growth, whose failure simply leaves that survivor young.
    try promoted_sources.ensureTotalCapacity(self.inner_allocator, young_count);
    try self.old_objects.ensureUnusedCapacity(self.inner_allocator, young_count);
    self.gray_stack.items.len = 0;
    try self.gray_stack.ensureTotalCapacity(self.inner_allocator, young_count);

    try self.markYoungRoots();
    if (self.scan_all_old_on_minor) {
        for (self.old_objects.items) |holder| try self.markYoungChildren(holder);
    } else {
        for (self.remembered.items) |holder| try self.markYoungChildren(holder);
    }
    try self.traceYoung();

    // Weak intern entries must be removed while dead young String headers are
    // still valid (Table.delete needs the string hash).
    self.removeDeadYoungInterns();

    var new_young: ?*Obj = null;
    var current = self.young_list;
    while (current) |object| {
        const next = object.next;
        if (!object.is_marked) {
            self.freeYoungObject(object);
        } else {
            object.is_marked = false;
            const next_age = object.age +| 1;
            if (next_age >= PROMOTION_AGE) {
                if (self.promoteObject(object)) |promoted| {
                    object.is_forwarded = true;
                    object.next = promoted;
                    promoted_sources.appendAssumeCapacity(object);
                } else |_| {
                    object.age = @min(next_age, PROMOTION_AGE - 1);
                    object.next = new_young;
                    new_young = object;
                }
            } else {
                object.age = next_age;
                object.next = new_young;
                new_young = object;
            }
        }
        current = next;
    }
    self.young_list = new_young;

    if (promoted_sources.items.len != 0) {
        self.fixRootsAndWeakTables();

        // Young survivors may point to promoted siblings.
        current = self.young_list;
        while (current) |object| : (current = object.next) self.fixObjectFields(object);

        // Newly promoted objects can point to other promoted objects; repair their
        // fields even when they are not (yet) in the remembered set.
        for (promoted_sources.items) |source| self.fixObjectFields(forwardObj(source).?);

        // Old holders that can point into the nursery are exactly the remembered
        // set unless the allocation-free fallback was activated.
        if (self.scan_all_old_on_minor) {
            for (self.old_objects.items) |holder| self.fixObjectFields(holder);
        } else {
            for (self.remembered.items) |holder| self.fixObjectFields(holder);
        }

        self.rebuildRememberedAfterPromotion(promoted_sources.items);
        for (promoted_sources.items) |source| self.destroyHeaderOnly(source);
    } else {
        self.rebuildRememberedAfterPromotion(&[_]*Obj{});
    }
    // Keep a minor collection proportional to nursery + remembered set. Old-space
    // accounting is maintained incrementally, so do not rescan the full old heap.
    self.recomputeYoungBytes();
    self.bytes_allocated = self.young_bytes +| self.old_bytes;

    if (self.bytes_allocated >= self.next_major) self.major_requested = true;
    self.collection_requested = self.minor_requested or self.major_requested;
    if (comptime Conf.DEBUG_LOG_GC) {
        std.debug.print("-- minor gc end: reclaimed {d}, {d} young bytes remain\n", .{
            before -| self.young_bytes, self.young_bytes,
        });
    }
}

fn promoteObject(self: *GC, source: *Obj) !*Obj {
    const destination = try self.cloneIntoOld(source);
    destination.generation = .Old;
    destination.age = PROMOTION_AGE;
    destination.is_marked = false;
    destination.in_remembered = false;
    destination.is_forwarded = false;
    destination.next = null;

    self.old_objects.appendAssumeCapacity(destination);
    self.old_bytes +|= objectApproximateBytes(source);
    return destination;
}

// -----------------------------------------------------------------------------
// Major collection: full mark + copying compaction into one fresh old arena.
// -----------------------------------------------------------------------------

fn collectMajor(self: *GC) !void {
    self.major_requested = false;
    self.minor_requested = false;
    const before = self.bytes_allocated;
    if (comptime Conf.DEBUG_LOG_GC) {
        std.debug.print("-- major gc begin ({d} bytes)\n", .{before});
    }

    var total_count = self.old_objects.items.len;
    var young_count: usize = 0;
    var worst_case_compact_bytes: usize = 0;

    var young = self.young_list;
    while (young) |object| : (young = object.next) {
        young_count += 1;
        total_count += 1;
        worst_case_compact_bytes +|= objectStructSize(object.type) + @alignOf(u128);
    }
    for (self.old_objects.items) |object| {
        worst_case_compact_bytes +|= objectStructSize(object.type) + @alignOf(u128);
    }

    // Allocate all temporary storage before marking. Once marks change, major GC
    // cannot fail: evacuation, pointer fixup and commit are allocation-free.
    var new_objects: std.ArrayList(*Obj) = .empty;
    errdefer new_objects.deinit(self.inner_allocator);
    try new_objects.ensureTotalCapacity(self.inner_allocator, total_count);

    var young_sources: std.ArrayList(*Obj) = .empty;
    defer young_sources.deinit(self.inner_allocator);
    try young_sources.ensureTotalCapacity(self.inner_allocator, young_count);

    var new_arenas: std.ArrayList(Arena) = .empty;
    errdefer {
        for (new_arenas.items) |*arena| arena.deinit(self.inner_allocator);
        new_arenas.deinit(self.inner_allocator);
    }
    try new_arenas.ensureTotalCapacity(self.inner_allocator, 1);
    if (total_count != 0) {
        const arena = try Arena.init(self.inner_allocator, @max(Conf.GC_OLD_ARENA_BYTES, worst_case_compact_bytes));
        new_arenas.appendAssumeCapacity(arena);
    }

    self.gray_stack.items.len = 0;
    try self.gray_stack.ensureTotalCapacity(self.inner_allocator, total_count);

    try self.markAllRoots();
    try self.traceAll();
    self.removeDeadInterns();

    // All allocations needed by compaction have succeeded. From this point to
    // commit, the operation is allocation-free and therefore cannot fail.
    young = self.young_list;
    while (young) |source| {
        const next = source.next;
        young_sources.appendAssumeCapacity(source);
        if (source.is_marked) {
            const destination = self.cloneIntoArenasNoFail(source, &new_arenas);
            source.is_forwarded = true;
            source.next = destination;
            new_objects.appendAssumeCapacity(destination);
        }
        young = next;
    }

    for (self.old_objects.items) |source| {
        if (!source.is_marked) continue;
        const destination = self.cloneIntoArenasNoFail(source, &new_arenas);
        source.is_forwarded = true;
        source.next = destination;
        new_objects.appendAssumeCapacity(destination);
    }

    self.fixRootsAndWeakTables();
    for (new_objects.items) |object| self.fixObjectFields(object);

    // Dead old objects own external payloads even though their object bodies are
    // arena memory. Release those payloads before freeing the old arenas.
    for (self.old_objects.items) |source| {
        if (!source.is_marked) self.releasePayload(source);
    }

    // Every young header was individually allocated. Live payload ownership was
    // transferred to its compacted copy; dead objects are destroyed normally.
    for (young_sources.items) |source| {
        if (source.is_marked) {
            self.destroyHeaderOnly(source);
        } else {
            self.releasePayload(source);
            self.destroyHeaderOnly(source);
        }
    }

    for (self.old_arenas.items) |*arena| arena.deinit(self.inner_allocator);
    self.old_arenas.deinit(self.inner_allocator);
    self.old_objects.deinit(self.inner_allocator);

    self.old_arenas = new_arenas;
    self.old_objects = new_objects;
    self.young_list = null;
    // Ownership moved into self; disable errdefers for these local containers.
    new_arenas = .empty;
    new_objects = .empty;

    self.remembered.items.len = 0;
    self.scan_all_old_on_minor = false;
    for (self.old_objects.items) |object| {
        object.is_marked = false;
        object.is_forwarded = false;
        object.in_remembered = false;
        object.generation = .Old;
        object.age = PROMOTION_AGE;
        object.next = null;
    }

    self.young_bytes = 0;
    self.old_bytes = 0;
    for (self.old_objects.items) |object| self.old_bytes +|= objectApproximateBytes(object);
    self.bytes_allocated = self.old_bytes;

    const growth = @max(@as(usize, 2), Conf.GC_HEAP_GROW_FACTOR);
    self.next_major = @max(@as(usize, 4 * 1024 * 1024), self.bytes_allocated *| growth);
    self.collection_requested = false;

    if (comptime Conf.DEBUG_LOG_GC) {
        std.debug.print("-- major gc end: reclaimed ~{d}, {d} bytes remain, next major {d}\n", .{
            before -| self.bytes_allocated, self.bytes_allocated, self.next_major,
        });
    }
}

// -----------------------------------------------------------------------------
// Marking
// -----------------------------------------------------------------------------

fn markYoungRoots(self: *GC) !void {
    if (self.call_frames) |frames| {
        var i: usize = 0;
        while (i < frames.count) : (i += 1) {
            const frame = &frames.stack[i];
            try self.markYoungObj(frame.closure.widen());
            const root_top = frame.rootTop();
            for (frame.registers[0..root_top]) |value| try self.markYoungValue(value);
        }
    }

    var upvalue = self.open_upvalues;
    while (upvalue) |current| : (upvalue = current.next) try self.markYoungObj(current.widen());

    try self.markYoungTable(&self.globals);
    try self.markYoungObj(self.init_string.widen());
}

fn markAllRoots(self: *GC) !void {
    if (self.call_frames) |frames| {
        var i: usize = 0;
        while (i < frames.count) : (i += 1) {
            const frame = &frames.stack[i];
            try self.markObj(frame.closure.widen());
            const root_top = frame.rootTop();
            for (frame.registers[0..root_top]) |value| try self.markValue(value);
        }
    }

    var upvalue = self.open_upvalues;
    while (upvalue) |current| : (upvalue = current.next) try self.markObj(current.widen());

    try self.markTable(&self.globals);
    try self.markObj(self.init_string.widen());
}

fn markYoungValue(self: *GC, value: Value) !void {
    if (value.as_obj()) |object| try self.markYoungObj(object);
}

fn markYoungObj(self: *GC, object: ?*Obj) !void {
    const obj = object orelse return;
    if (obj.generation != .Young or obj.is_marked) return;
    obj.is_marked = true;
    self.gray_stack.appendAssumeCapacity(obj);
}

fn markValue(self: *GC, value: Value) !void {
    if (value.as_obj()) |object| try self.markObj(object);
}

fn markObj(self: *GC, object: ?*Obj) !void {
    const obj = object orelse return;
    if (obj.is_marked) return;
    obj.is_marked = true;
    self.gray_stack.appendAssumeCapacity(obj);
}

fn markYoungTable(self: *GC, table: *const Table) !void {
    const entries = table.entries orelse return;
    for (entries) |entry| {
        if (entry.key) |key| try self.markYoungObj(key.widen());
        try self.markYoungValue(entry.val);
    }
}

fn markTable(self: *GC, table: *const Table) !void {
    const entries = table.entries orelse return;
    for (entries) |entry| {
        if (entry.key) |key| try self.markObj(key.widen());
        try self.markValue(entry.val);
    }
}

fn traceYoung(self: *GC) !void {
    while (self.gray_stack.items.len != 0) {
        const object = self.gray_stack.pop().?;
        try self.markYoungChildren(object);
    }
}

fn traceAll(self: *GC) !void {
    while (self.gray_stack.items.len != 0) {
        const object = self.gray_stack.pop().?;
        try self.markAllChildren(object);
    }
}

fn markYoungChildren(self: *GC, object: *Obj) !void {
    switch (object.type) {
        .String, .NativeFunction => {},
        .Function => {
            const function = object.narrow(Obj.Function);
            if (function.name) |name| try self.markYoungObj(name.widen());
            for (function.chunk.constants.items) |value| try self.markYoungValue(value);
        },
        .Closure => {
            const closure = object.narrow(Obj.Closure);
            try self.markYoungObj(closure.function.widen());
            for (closure.upvalues) |maybe_upvalue| if (maybe_upvalue) |upvalue| try self.markYoungObj(upvalue.widen());
        },
        .Upvalue => try self.markYoungValue(object.narrow(Obj.Upvalue).closed),
        .Class => {
            const class = object.narrow(Obj.Class);
            try self.markYoungObj(class.name.widen());
            try self.markYoungTable(&class.methods);
        },
        .Instance => {
            const instance = object.narrow(Obj.Instance);
            try self.markYoungObj(instance.class.widen());
            try self.markYoungTable(&instance.fields);
        },
        .BoundMethod => {
            const bound = object.narrow(Obj.BoundMethod);
            try self.markYoungValue(bound.receiver);
            try self.markYoungObj(bound.method.widen());
        },
    }
}

fn markAllChildren(self: *GC, object: *Obj) !void {
    switch (object.type) {
        .String, .NativeFunction => {},
        .Function => {
            const function = object.narrow(Obj.Function);
            if (function.name) |name| try self.markObj(name.widen());
            for (function.chunk.constants.items) |value| try self.markValue(value);
        },
        .Closure => {
            const closure = object.narrow(Obj.Closure);
            try self.markObj(closure.function.widen());
            for (closure.upvalues) |maybe_upvalue| if (maybe_upvalue) |upvalue| try self.markObj(upvalue.widen());
        },
        .Upvalue => try self.markValue(object.narrow(Obj.Upvalue).closed),
        .Class => {
            const class = object.narrow(Obj.Class);
            try self.markObj(class.name.widen());
            try self.markTable(&class.methods);
        },
        .Instance => {
            const instance = object.narrow(Obj.Instance);
            try self.markObj(instance.class.widen());
            try self.markTable(&instance.fields);
        },
        .BoundMethod => {
            const bound = object.narrow(Obj.BoundMethod);
            try self.markValue(bound.receiver);
            try self.markObj(bound.method.widen());
        },
    }
}

// -----------------------------------------------------------------------------
// Moving/fixup
// -----------------------------------------------------------------------------

fn cloneIntoOld(self: *GC, source: *Obj) !*Obj {
    return switch (source.type) {
        inline else => |ty| self.cloneTyped(source, &self.old_arenas, Obj.Type.obj_struct(ty)),
    };
}

fn cloneIntoArenasNoFail(self: *GC, source: *Obj, arenas: *std.ArrayList(Arena)) *Obj {
    _ = self;
    return switch (source.type) {
        inline else => |ty| cloneTypedNoFail(source, arenas, Obj.Type.obj_struct(ty)),
    };
}

fn cloneTyped(self: *GC, source: *Obj, arenas: *std.ArrayList(Arena), comptime T: type) !*Obj {
    const src = source.narrow(T);
    const dst = try self.allocOldSlot(arenas, T);
    dst.* = src.*;
    normalizeMovedObject(src, dst);
    return dst.widen();
}

fn cloneTypedNoFail(source: *Obj, arenas: *std.ArrayList(Arena), comptime T: type) *Obj {
    const src = source.narrow(T);
    const dst = arenas.items[0].create(T) orelse unreachable;
    dst.* = src.*;
    normalizeMovedObject(src, dst);
    return dst.widen();
}

fn normalizeMovedObject(src: anytype, dst: anytype) void {
    if (comptime @TypeOf(src.*) == Obj.Upvalue) {
        const was_closed = src.location == &src.closed;
        if (was_closed) dst.location = &dst.closed;
    }
    dst.obj.generation = .Old;
    dst.obj.is_marked = false;
    dst.obj.age = PROMOTION_AGE;
    dst.obj.in_remembered = false;
    dst.obj.is_forwarded = false;
    dst.obj.next = null;
}

fn allocOldSlot(self: *GC, arenas: *std.ArrayList(Arena), comptime T: type) !*T {
    if (arenas.items.len != 0) {
        if (arenas.items[arenas.items.len - 1].create(T)) |ptr| return ptr;
    }

    var arena = try Arena.init(self.inner_allocator, @max(Conf.GC_OLD_ARENA_BYTES, @sizeOf(T) + @alignOf(T)));
    errdefer arena.deinit(self.inner_allocator);
    try arenas.append(self.inner_allocator, arena);
    return arenas.items[arenas.items.len - 1].create(T) orelse unreachable;
}

fn forwardObj(object: ?*Obj) ?*Obj {
    const obj = object orelse return null;
    return if (obj.is_forwarded) obj.next.? else obj;
}

fn forwardValue(value: Value) Value {
    return switch (value) {
        .Obj => |object| Value.obj(forwardObj(object).?),
        else => value,
    };
}

fn fixRootsAndWeakTables(self: *GC) void {
    if (self.call_frames) |frames| {
        var i: usize = 0;
        while (i < frames.count) : (i += 1) {
            const frame = &frames.stack[i];
            // Compute the root window before forwarding the closure. The old
            // function/chunk header remains valid until pointer fixup completes.
            const root_top = frame.rootTop();
            for (frame.registers[0..root_top]) |*value| value.* = forwardValue(value.*);
            frame.closure = forwardObj(frame.closure.widen()).?.narrow(Obj.Closure);
        }
    }

    self.fixOpenUpvalueList();
    self.fixTable(&self.globals);
    self.fixTable(&self.interned_strings);
    self.init_string = forwardObj(self.init_string.widen()).?.narrow(Obj.String);
}

fn fixOpenUpvalueList(self: *GC) void {
    const old_head = self.open_upvalues;
    self.open_upvalues = if (old_head) |head| forwardObj(head.widen()).?.narrow(Obj.Upvalue) else null;

    var source = old_head;
    while (source) |upvalue| {
        const source_next = upvalue.next;
        const destination = forwardObj(upvalue.widen()).?.narrow(Obj.Upvalue);
        destination.next = if (source_next) |next| forwardObj(next.widen()).?.narrow(Obj.Upvalue) else null;
        source = source_next;
    }
}

fn fixObjectFields(self: *GC, object: *Obj) void {
    switch (object.type) {
        .String, .NativeFunction => {},
        .Function => {
            const function = object.narrow(Obj.Function);
            if (function.name) |name| function.name = forwardObj(name.widen()).?.narrow(Obj.String);
            for (function.chunk.constants.items) |*value| value.* = forwardValue(value.*);
        },
        .Closure => {
            const closure = object.narrow(Obj.Closure);
            closure.function = forwardObj(closure.function.widen()).?.narrow(Obj.Function);
            for (closure.upvalues) |*maybe_upvalue| {
                if (maybe_upvalue.*) |upvalue| maybe_upvalue.* = forwardObj(upvalue.widen()).?.narrow(Obj.Upvalue);
            }
        },
        .Upvalue => {
            const upvalue = object.narrow(Obj.Upvalue);
            upvalue.closed = forwardValue(upvalue.closed);
        },
        .Class => {
            const class = object.narrow(Obj.Class);
            class.name = forwardObj(class.name.widen()).?.narrow(Obj.String);
            self.fixTable(&class.methods);
        },
        .Instance => {
            const instance = object.narrow(Obj.Instance);
            instance.class = forwardObj(instance.class.widen()).?.narrow(Obj.Class);
            self.fixTable(&instance.fields);
        },
        .BoundMethod => {
            const bound = object.narrow(Obj.BoundMethod);
            bound.receiver = forwardValue(bound.receiver);
            bound.method = forwardObj(bound.method.widen()).?.narrow(Obj.Closure);
        },
    }
}

fn fixTable(_: *GC, table: *Table) void {
    const entries = table.entries orelse return;
    for (entries) |*entry| {
        if (entry.key) |key| entry.key = forwardObj(key.widen()).?.narrow(Obj.String);
        entry.val = forwardValue(entry.val);
    }
}

// -----------------------------------------------------------------------------
// Remembered-set maintenance / weak intern table
// -----------------------------------------------------------------------------

fn objectHasYoungReference(self: *GC, object: *Obj) bool {
    _ = self;
    return switch (object.type) {
        .String, .NativeFunction => false,
        .Function => blk: {
            const function = object.narrow(Obj.Function);
            if (function.name) |name| {
                if (name.obj.generation == .Young) break :blk true;
            }
            for (function.chunk.constants.items) |value| {
                if (valuePointsYoung(value)) break :blk true;
            }
            break :blk false;
        },
        .Closure => blk: {
            const closure = object.narrow(Obj.Closure);
            if (closure.function.obj.generation == .Young) break :blk true;
            for (closure.upvalues) |maybe| {
                if (maybe) |upvalue| {
                    if (upvalue.obj.generation == .Young) break :blk true;
                }
            }
            break :blk false;
        },
        .Upvalue => valuePointsYoung(object.narrow(Obj.Upvalue).closed),
        .Class => blk: {
            const class = object.narrow(Obj.Class);
            if (class.name.obj.generation == .Young) break :blk true;
            break :blk tableHasYoungReference(&class.methods);
        },
        .Instance => blk: {
            const instance = object.narrow(Obj.Instance);
            if (instance.class.obj.generation == .Young) break :blk true;
            break :blk tableHasYoungReference(&instance.fields);
        },
        .BoundMethod => blk: {
            const bound = object.narrow(Obj.BoundMethod);
            break :blk valuePointsYoung(bound.receiver) or bound.method.obj.generation == .Young;
        },
    };
}

fn valuePointsYoung(value: Value) bool {
    const object = value.as_obj() orelse return false;
    return object.generation == .Young;
}

fn tableHasYoungReference(table: *const Table) bool {
    const entries = table.entries orelse return false;
    for (entries) |entry| {
        if (entry.key) |key| {
            if (key.obj.generation == .Young) return true;
        }
        if (valuePointsYoung(entry.val)) return true;
    }
    return false;
}

fn rebuildRememberedAfterPromotion(self: *GC, promoted_sources: []const *Obj) void {
    if (self.scan_all_old_on_minor) return;

    // Existing remembered objects remain useful while they still reference young.
    var write: usize = 0;
    for (self.remembered.items) |holder| {
        if (self.objectHasYoungReference(holder)) {
            self.remembered.items[write] = holder;
            write += 1;
        } else {
            holder.in_remembered = false;
        }
    }
    self.remembered.items.len = write;

    // Only newly promoted objects need a first old->young inspection.
    for (promoted_sources) |source| {
        const holder = forwardObj(source).?;
        if (!holder.in_remembered and self.objectHasYoungReference(holder)) self.remember(holder);
    }
}

fn removeDeadYoungInterns(self: *GC) void {
    const entries = self.interned_strings.entries orelse return;
    for (entries) |entry| {
        const key = entry.key orelse continue;
        if (key.obj.generation == .Young and !key.obj.is_marked) _ = self.interned_strings.delete(key);
    }
}

fn removeDeadInterns(self: *GC) void {
    const entries = self.interned_strings.entries orelse return;
    for (entries) |entry| {
        const key = entry.key orelse continue;
        if (!key.obj.is_marked) _ = self.interned_strings.delete(key);
    }
}

// -----------------------------------------------------------------------------
// Destruction/accounting
// -----------------------------------------------------------------------------

fn freeYoungObject(self: *GC, object: *Obj) void {
    const approx = objectApproximateBytes(object);
    self.releasePayload(object);
    self.destroyHeaderOnly(object);
    self.young_bytes -|= approx;
    self.bytes_allocated -|= approx;
}

fn releasePayload(self: *GC, object: *Obj) void {
    if (comptime Conf.DEBUG_LOG_GC) {
        std.debug.print("[gc] release {s} payload at {*}\n", .{ @tagName(object.type), object });
    }

    switch (object.type) {
        .String => {
            const string = object.narrow(Obj.String);
            self.inner_allocator.free(@constCast(string.chars[0..@as(usize, string.len)]));
        },
        .Function => object.narrow(Obj.Function).chunk.free(self.inner_allocator),
        .NativeFunction, .Upvalue, .BoundMethod => {},
        .Closure => self.inner_allocator.free(object.narrow(Obj.Closure).upvalues),
        .Class => object.narrow(Obj.Class).methods.free(self.inner_allocator),
        .Instance => object.narrow(Obj.Instance).fields.free(self.inner_allocator),
    }
}

fn destroyHeaderOnly(self: *GC, object: *Obj) void {
    std.debug.assert(object.generation == .Young or object.is_forwarded);
    switch (object.type) {
        inline else => |ty| self.inner_allocator.destroy(object.narrow(Obj.Type.obj_struct(ty))),
    }
}

fn objectStructSize(ty: Obj.Type) usize {
    return switch (ty) {
        inline else => |tag| @sizeOf(Obj.Type.obj_struct(tag)),
    };
}

fn objectApproximateBytes(object: *Obj) usize {
    var bytes = objectStructSize(object.type);
    switch (object.type) {
        .String => bytes +|= @as(usize, object.narrow(Obj.String).len),
        .Closure => bytes +|= object.narrow(Obj.Closure).upvalues.len * @sizeOf(?*Obj.Upvalue),
        .Function => {
            const chunk = &object.narrow(Obj.Function).chunk;
            bytes +|= chunk.code.capacity * @sizeOf(u32);
            bytes +|= chunk.lines.capacity * @sizeOf(u32);
            bytes +|= chunk.root_tops.capacity * @sizeOf(u8);
            bytes +|= chunk.constants.capacity * @sizeOf(Value);
        },
        .Class => if (object.narrow(Obj.Class).methods.entries) |entries| bytes +|= entries.len * @sizeOf(Table.Entry),
        .Instance => if (object.narrow(Obj.Instance).fields.entries) |entries| bytes +|= entries.len * @sizeOf(Table.Entry),
        else => {},
    }
    return bytes;
}

fn countYoung(self: *const GC) usize {
    var count: usize = 0;
    var object = self.young_list;
    while (object) |current| : (object = current.next) count += 1;
    return count;
}

fn recomputeYoungBytes(self: *GC) void {
    var total: usize = 0;
    var object = self.young_list;
    while (object) |current| : (object = current.next) total +|= objectApproximateBytes(current);
    self.young_bytes = total;
}

pub fn free_objects(self: *GC) void {
    self.globals.free(self.inner_allocator);
    self.interned_strings.free(self.inner_allocator);

    var young = self.young_list;
    while (young) |object| {
        const next = object.next;
        self.releasePayload(object);
        self.destroyHeaderOnly(object);
        young = next;
    }
    self.young_list = null;

    for (self.old_objects.items) |object| self.releasePayload(object);
    for (self.old_arenas.items) |*arena| arena.deinit(self.inner_allocator);

    self.old_objects.deinit(self.inner_allocator);
    self.old_arenas.deinit(self.inner_allocator);
    self.remembered.deinit(self.inner_allocator);
    self.gray_stack.deinit(self.inner_allocator);

    self.open_upvalues = null;
    self.call_frames = null;
    self.bytes_allocated = 0;
    self.young_bytes = 0;
    self.old_bytes = 0;
}
