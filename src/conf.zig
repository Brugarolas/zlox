const opts = @import("build_options");

pub const PRINT_CODE_AFTER_COMPILE = opts.PRINT_CODE_AFTER_COMPILE;
pub const TRACING = opts.TRACING;
pub const SAFE_OBJ_CAST = opts.SAFE_OBJ_CAST;
pub const DEBUG_STRESS_GC = opts.DEBUG_STRESS_GC;
pub const DEBUG_LOG_GC = opts.DEBUG_LOG_GC;
pub const GC_HEAP_GROW_FACTOR = opts.GC_HEAP_GROW_FACTOR;

pub const GC_NURSERY_BYTES = opts.GC_NURSERY_BYTES;
pub const GC_PROMOTION_AGE = opts.GC_PROMOTION_AGE;
pub const GC_OLD_ARENA_BYTES = opts.GC_OLD_ARENA_BYTES;
