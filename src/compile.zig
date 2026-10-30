const std = @import("std");
const Allocator = std.mem.Allocator;

const Scanner = @import("scanner.zig");
const Token = Scanner.Token;
const TokenType = Scanner.TokenType;

const bytecode = @import("chunk.zig");
const Chunk = bytecode.Chunk;
const Opcode = bytecode.Opcode;
const Instruction = bytecode.Instruction;

const Value = @import("value.zig").Value;
const Conf = @import("conf.zig");
const GC = @import("gc.zig");
const Obj = @import("obj.zig");

const REGISTER_COUNT: usize = @as(usize, std.math.maxInt(u8)) + 1;

const Precedence = enum {
    None,
    Assignment,
    Or,
    And,
    Equality,
    Comparison,
    Term,
    Factor,
    Unary,
    Call,
    Primary,
};

pub const Local = struct {
    name: Token,
    depth: i32,
    is_captured: bool,
    reg: u8,
};

pub const Upvalue = struct {
    index: u8,
    is_local: bool,
};

const Expr = struct {
    reg: u8,
    is_temp: bool,

    inline fn borrowed(reg: u8) Expr {
        return .{ .reg = reg, .is_temp = false };
    }

    inline fn temporary(reg: u8) Expr {
        return .{ .reg = reg, .is_temp = true };
    }
};

pub const FunctionType = enum { Function, Method, Script, Initializer };

pub const ClassCompiler = struct {
    enclosing: ?*ClassCompiler,
    has_superclass: bool = false,
};

pub const Compiler = struct {
    const Self = @This();

    gc: *GC,
    enclosing: ?*Self,
    class_compiler: ?*ClassCompiler,
    scanner: *Scanner,
    parser: *Parser,
    function: *Obj.Function,
    function_ty: FunctionType,
    local_count: usize,
    register_top: u16,
    scope_depth: i32,
    upvalues: [REGISTER_COUNT]Upvalue,
    locals: [REGISTER_COUNT]Local,

    const PrefixFn = *const fn (*Self, bool) Allocator.Error!Expr;
    const InfixFn = *const fn (*Self, Expr, bool) Allocator.Error!Expr;

    const ParseRule = struct {
        prefix: ?PrefixFn = null,
        infix: ?InfixFn = null,
        precedence: Precedence = .None,
    };
    const ParseRuleTable = std.EnumArray(TokenType, ParseRule);

    const rules = ParseRuleTable.init(.{
        .LeftParen = ParseRule{ .prefix = Self.grouping, .infix = Self.call, .precedence = .Call },
        .RightParen = ParseRule{},
        .LeftBrace = ParseRule{},
        .RightBrace = ParseRule{},
        .Comma = ParseRule{},
        .Dot = ParseRule{ .infix = Self.dot, .precedence = .Call },
        .Minus = ParseRule{ .prefix = Self.unary, .infix = Self.binary, .precedence = .Term },
        .Plus = ParseRule{ .infix = Self.binary, .precedence = .Term },
        .Semicolon = ParseRule{},
        .Slash = ParseRule{ .infix = Self.binary, .precedence = .Factor },
        .Star = ParseRule{ .infix = Self.binary, .precedence = .Factor },
        .Bang = ParseRule{ .prefix = Self.unary },
        .BangEqual = ParseRule{ .infix = Self.binary, .precedence = .Equality },
        .Equal = ParseRule{},
        .EqualEqual = ParseRule{ .infix = Self.binary, .precedence = .Equality },
        .Greater = ParseRule{ .infix = Self.binary, .precedence = .Comparison },
        .GreaterEqual = ParseRule{ .infix = Self.binary, .precedence = .Comparison },
        .Less = ParseRule{ .infix = Self.binary, .precedence = .Comparison },
        .LessEqual = ParseRule{ .infix = Self.binary, .precedence = .Comparison },
        .Identifier = ParseRule{ .prefix = Self.variable },
        .String = ParseRule{ .prefix = Self.string },
        .Number = ParseRule{ .prefix = Self.number },
        .And = ParseRule{ .infix = Self.and_, .precedence = .And },
        .Class = ParseRule{},
        .Else = ParseRule{},
        .False = ParseRule{ .prefix = Self.literal },
        .For = ParseRule{},
        .Fun = ParseRule{},
        .If = ParseRule{},
        .Nil = ParseRule{ .prefix = Self.literal },
        .Or = ParseRule{ .infix = Self.or_, .precedence = .Or },
        .Print = ParseRule{},
        .Return = ParseRule{},
        .Super = ParseRule{ .prefix = Self.super },
        .This = ParseRule{ .prefix = Self.this },
        .True = ParseRule{ .prefix = Self.literal },
        .Var = ParseRule{},
        .While = ParseRule{},
        .Error = ParseRule{},
        .Eof = ParseRule{},
    });

    pub fn init(
        gc: *GC,
        enclosing: ?*Self,
        scanner: *Scanner,
        parser: *Parser,
        class_compiler: ?*ClassCompiler,
        function_ty: FunctionType,
    ) Allocator.Error!Self {
        const function = try gc.alloc_obj(Obj.Function);
        try function.init(gc.as_allocator());

        var self = Self{
            .gc = gc,
            .enclosing = enclosing,
            .class_compiler = class_compiler,
            .scanner = scanner,
            .parser = parser,
            .function = function,
            .function_ty = function_ty,
            .locals = undefined,
            .upvalues = undefined,
            .local_count = 0,
            .register_top = 0,
            .scope_depth = 0,
        };

        if (function_ty != .Script) {
            self.function.name = try gc.copy_string(parser.previous.content, parser.previous.len);
        }

        const local_name = switch (function_ty) {
            .Method, .Initializer => "this",
            .Function, .Script => "",
        };
        self.locals[0] = .{
            .name = Token.synthetic(local_name),
            .depth = 0,
            .is_captured = false,
            .reg = 0,
        };
        self.local_count = 1;
        self.register_top = 1;
        self.function.max_registers = 1;
        return self;
    }

    pub fn init_parser() Parser {
        return Parser.init();
    }

    pub fn compile(self: *Self) Allocator.Error!?*Obj.Function {
        self.advance();
        while (!self.match_tok(.Eof)) try self.declaration();

        const function = try self.end();
        return if (self.parser.had_error) null else function;
    }

    // ---------------------------------------------------------------------
    // Register allocation and bytecode emission
    // ---------------------------------------------------------------------

    fn alloc_register(self: *Self) u8 {
        if (self.register_top >= @as(u16, @intCast(REGISTER_COUNT))) {
            self.report_error("Too many registers in one function.");
            return 0;
        }

        const reg: u8 = @intCast(self.register_top);
        self.register_top += 1;
        if (self.register_top > self.function.max_registers) {
            self.function.max_registers = self.register_top;
        }
        return reg;
    }

    inline fn release_temp(self: *Self, reg: u8) void {
        if (@as(usize, reg) >= self.local_count and self.register_top == @as(u16, reg) + 1) {
            self.register_top -= 1;
        }
    }

    inline fn release_expr(self: *Self, expr: Expr) void {
        if (expr.is_temp) self.release_temp(expr.reg);
    }

    fn ensure_temp(self: *Self, expr: Expr) Allocator.Error!Expr {
        if (expr.is_temp) return expr;
        const dst = self.alloc_register();
        _ = try self.emit(Instruction.ab(.Move, dst, expr.reg));
        return Expr.temporary(dst);
    }

    fn append_call_operand(self: *Self, expr: Expr, expected: u8) Allocator.Error!u8 {
        if (expr.is_temp) {
            if (expr.reg != expected) {
                self.report_error("Internal compiler error: non-contiguous call operand.");
            }
            return expr.reg;
        }

        const dst = self.alloc_register();
        if (dst != expected) self.report_error("Internal compiler error: non-contiguous call operand.");
        _ = try self.emit(Instruction.ab(.Move, dst, expr.reg));
        return dst;
    }

    inline fn discard_temporaries(self: *Self) void {
        self.register_top = @intCast(self.local_count);
    }

    fn emit(self: *Self, raw: u32) Allocator.Error!usize {
        return self.current_chunk().write(
            self.gc.as_allocator(),
            raw,
            self.parser.previous.line,
            self.register_top,
        );
    }

    fn emit_with_root_top(self: *Self, raw: u32, root_top: u16) Allocator.Error!usize {
        return self.current_chunk().write(
            self.gc.as_allocator(),
            raw,
            self.parser.previous.line,
            root_top,
        );
    }

    fn remove_last_instruction(self: *Self, expected_offset: usize) void {
        const chunk = self.current_chunk();
        std.debug.assert(chunk.code.items.len == expected_offset + 1);
        std.debug.assert(chunk.lines.items.len == chunk.code.items.len);
        std.debug.assert(chunk.root_tops.items.len == chunk.code.items.len);
        chunk.code.items.len -= 1;
        chunk.lines.items.len -= 1;
        chunk.root_tops.items.len -= 1;
    }

    fn emit_jump(self: *Self, op: Opcode, condition: u8) Allocator.Error!usize {
        return self.emit(Instruction.jump(op, condition, 0));
    }

    fn patch_jump(self: *Self, offset: usize) void {
        const delta = @as(i64, @intCast(self.current_chunk().code.items.len)) -
            @as(i64, @intCast(offset)) - 1;
        if (delta > std.math.maxInt(i16)) {
            self.report_error("Too much code to jump over.");
            return;
        }

        const old = self.current_chunk().code.items[offset];
        self.current_chunk().code.items[offset] = Instruction.jump(
            Instruction.opcode(old),
            Instruction.a(old),
            @intCast(delta),
        );
    }

    fn emit_loop(self: *Self, loop_start: usize) Allocator.Error!void {
        const current = self.current_chunk().code.items.len;
        const delta = @as(i64, @intCast(loop_start)) - @as(i64, @intCast(current)) - 1;
        if (delta < std.math.minInt(i16)) {
            self.report_error("Loop body too large.");
            return;
        }
        _ = try self.emit(Instruction.jump(.Jump, 0, @intCast(delta)));
    }

    fn emit_return(self: *Self) Allocator.Error!void {
        if (self.function_ty == .Initializer) {
            _ = try self.emit(Instruction.aOnly(.Return, 0));
        } else {
            _ = try self.emit(Instruction.simple(.ReturnNil));
        }
    }

    fn emit_constant(self: *Self, value: Value) Allocator.Error!Expr {
        const dst = self.alloc_register();
        const constant = try self.make_constant(value);
        _ = try self.emit(Instruction.ab(.LoadConstant, dst, constant));
        return Expr.temporary(dst);
    }

    fn make_constant(self: *Self, value: Value) Allocator.Error!u8 {
        const chunk = self.current_chunk();
        for (chunk.constants.items, 0..) |existing, index| {
            if (Value.eq(existing, value)) return @intCast(index);
        }

        if (chunk.constants.items.len > std.math.maxInt(u8)) {
            self.report_error("Too many constants in one chunk.");
            return 0;
        }

        return @intCast(try chunk.add_constant(self.gc.as_allocator(), value));
    }

    inline fn current_chunk(self: *Self) *Chunk {
        return &self.function.chunk;
    }

    fn end(self: *Self) Allocator.Error!*Obj.Function {
        try self.emit_return();
        const function = self.function;
        if (comptime Conf.PRINT_CODE_AFTER_COMPILE) {
            self.current_chunk().disassemble(if (function.name) |name| name.as_string() else "script");
        }
        return function;
    }

    // ---------------------------------------------------------------------
    // Statements and declarations
    // ---------------------------------------------------------------------

    fn begin_scope(self: *Self) void {
        self.scope_depth += 1;
    }

    fn end_scope(self: *Self) Allocator.Error!void {
        self.scope_depth -= 1;
        self.discard_temporaries();

        while (self.local_count > 0 and self.locals[self.local_count - 1].depth > self.scope_depth) {
            const local = self.locals[self.local_count - 1];
            if (local.is_captured) _ = try self.emit(Instruction.aOnly(.CloseUpvalue, local.reg));
            self.local_count -= 1;
            self.register_top = @intCast(self.local_count);
        }
    }

    fn expression(self: *Self) Allocator.Error!Expr {
        return self.parse_precedence(.Assignment);
    }

    fn block(self: *Self) Allocator.Error!void {
        while (!self.check(.RightBrace) and !self.check(.Eof)) try self.declaration();
        self.consume(.RightBrace, "Expect '}' after block.");
    }

    fn func(self: *Self, function_type: FunctionType) Allocator.Error!u8 {
        var compiler = try Self.init(self.gc, self, self.scanner, self.parser, self.class_compiler, function_type);
        compiler.begin_scope();

        compiler.consume(.LeftParen, "Expect '(' after function name.");
        if (!compiler.check(.RightParen)) {
            while (true) {
                if (compiler.function.arity == std.math.maxInt(u8)) {
                    compiler.error_at_current("Cannot have more than 255 parameters.");
                } else {
                    compiler.function.arity += 1;
                }

                try compiler.parse_parameter("Expect parameter name.");
                compiler.mark_initialized();
                if (!compiler.match_tok(.Comma)) break;
            }
        }
        compiler.consume(.RightParen, "Expect ')' after function name.");
        compiler.consume(.LeftBrace, "Expect '{' after function name.");
        try compiler.block();

        const function_obj = try compiler.end();
        const dst = self.alloc_register();
        const constant = try self.make_constant(Value.obj(function_obj.widen()));
        _ = try self.emit(Instruction.ab(.Closure, dst, constant));

        var i: usize = 0;
        while (i < function_obj.upvalue_count) : (i += 1) {
            const upvalue = compiler.upvalues[i];
            _ = try self.emit(Instruction.aOnly(
                if (upvalue.is_local) .CaptureLocal else .CaptureUpvalue,
                upvalue.index,
            ));
        }
        return dst;
    }

    fn method(self: *Self, class_reg: u8) Allocator.Error!void {
        self.consume(.Identifier, "Expect method name.");
        const name = try self.identifier_constant(&self.parser.previous);

        const ty: FunctionType = if (std.mem.eql(
            u8,
            self.parser.previous.content[0..self.parser.previous.len],
            "init",
        )) .Initializer else .Method;

        const method_reg = try self.func(ty);
        _ = try self.emit_with_root_top(
            Instruction.abc(.Method, class_reg, method_reg, name),
            self.register_top,
        );
        self.release_temp(method_reg);
    }

    fn class_declaration(self: *Self) Allocator.Error!void {
        self.consume(.Identifier, "Expect class name.");
        const class_name = self.parser.previous;
        const name_constant = try self.identifier_constant(&class_name);
        self.declare_variable();
        if (self.scope_depth > 0) {
            const class_local = self.locals[self.local_count - 1].reg;
            _ = try self.emit(Instruction.aOnly(.LoadNil, class_local));
        }

        const class_value = self.alloc_register();
        _ = try self.emit(Instruction.ab(.Class, class_value, name_constant));
        try self.define_variable(name_constant, class_value);

        var class_compiler = ClassCompiler{ .enclosing = self.class_compiler };
        self.class_compiler = &class_compiler;
        defer self.class_compiler = class_compiler.enclosing;

        if (self.match_tok(.Less)) {
            self.consume(.Identifier, "Expect superclass name.");
            if (identifiers_equal(&class_name, &self.parser.previous)) {
                self.report_error("A class cannot inherit from itself.");
            }

            const superclass = try self.variable(false);
            self.begin_scope();

            var superclass_reg: u8 = undefined;
            if (superclass.is_temp and
                @as(usize, superclass.reg) == self.local_count and
                self.register_top == @as(u16, superclass.reg) + 1)
            {
                // Promote the temporary directly into the synthetic local.
                superclass_reg = superclass.reg;
                self.add_local_from_temp(Token.synthetic("super"), superclass_reg);
            } else {
                self.add_local(Token.synthetic("super"));
                superclass_reg = self.locals[self.local_count - 1].reg;
                _ = try self.emit(Instruction.ab(.Move, superclass_reg, superclass.reg));
                self.release_expr(superclass);
            }
            self.mark_initialized();

            const subclass = try self.named_variable(&class_name, false);
            _ = try self.emit(Instruction.ab(.Inherit, subclass.reg, superclass_reg));
            self.release_expr(subclass);
            class_compiler.has_superclass = true;
        }

        const class_value_expr = try self.named_variable(&class_name, false);
        self.consume(.LeftBrace, "Expect '{' before class body.");
        while (!self.check(.RightBrace) and !self.check(.Eof)) try self.method(class_value_expr.reg);
        self.consume(.RightBrace, "Expect '}' before class body.");
        self.release_expr(class_value_expr);

        if (class_compiler.has_superclass) try self.end_scope();
    }

    fn fn_declaration(self: *Self) Allocator.Error!void {
        const global = try self.parse_variable("Expect function name.");
        self.mark_initialized();
        const closure_reg = try self.func(.Function);
        try self.define_variable(global, closure_reg);
    }

    fn var_declaration(self: *Self) Allocator.Error!void {
        const global = try self.parse_variable("Expect variable name.");
        if (self.match_tok(.Equal)) {
            const value = try self.expression();
            self.consume(.Semicolon, "Expect ';' after variable declaration.");
            try self.define_variable(global, value.reg);
            return;
        }

        self.consume(.Semicolon, "Expect ';' after variable declaration.");
        if (self.scope_depth > 0) {
            // parse_variable() already initialized the reserved local register to nil.
            self.mark_initialized();
            self.discard_temporaries();
            return;
        }

        const value_reg = self.alloc_register();
        _ = try self.emit(Instruction.aOnly(.LoadNil, value_reg));
        try self.define_variable(global, value_reg);
    }

    fn declaration(self: *Self) Allocator.Error!void {
        if (self.match_tok(.Class)) {
            try self.class_declaration();
        } else if (self.match_tok(.Fun)) {
            try self.fn_declaration();
        } else if (self.match_tok(.Var)) {
            try self.var_declaration();
        } else {
            try self.statement();
        }

        if (self.parser.panic_mode) self.synchronize();
    }

    fn statement(self: *Self) Allocator.Error!void {
        if (self.match_tok(.Print)) {
            try self.print_statement();
        } else if (self.match_tok(.For)) {
            try self.for_statement();
        } else if (self.match_tok(.If)) {
            try self.if_statement();
        } else if (self.match_tok(.Return)) {
            try self.return_statement();
        } else if (self.match_tok(.While)) {
            try self.while_statement();
        } else if (self.match_tok(.LeftBrace)) {
            self.begin_scope();
            try self.block();
            try self.end_scope();
        } else {
            try self.expression_statement();
        }
    }

    fn expression_statement(self: *Self) Allocator.Error!void {
        _ = try self.expression();
        self.consume(.Semicolon, "Expect ';' after expression.");
        self.discard_temporaries();
    }

    fn if_statement(self: *Self) Allocator.Error!void {
        self.consume(.LeftParen, "Expect '(' after 'if'.");
        const condition = try self.expression();
        self.consume(.RightParen, "Expect ')' after condition.");

        const then_jump = try self.emit_jump(.JumpIfFalse, condition.reg);
        self.discard_temporaries();
        try self.statement();

        const else_jump = try self.emit_jump(.Jump, 0);
        self.patch_jump(then_jump);
        if (self.match_tok(.Else)) try self.statement();
        self.patch_jump(else_jump);
    }

    fn print_statement(self: *Self) Allocator.Error!void {
        const value = try self.expression();
        self.consume(.Semicolon, "Expect ';' after value.");
        _ = try self.emit(Instruction.aOnly(.Print, value.reg));
        self.discard_temporaries();
    }

    fn return_statement(self: *Self) Allocator.Error!void {
        if (self.function_ty == .Script) self.report_error("Cannot return from top-level code.");

        if (self.match_tok(.Semicolon)) {
            try self.emit_return();
            return;
        }

        if (self.function_ty == .Initializer) {
            self.report_error("Cannot return a value from an initializer.");
        }

        const value = try self.expression();
        self.consume(.Semicolon, "Expect ';' after return value.");
        _ = try self.emit(Instruction.aOnly(.Return, value.reg));
        self.discard_temporaries();
    }

    fn for_statement(self: *Self) Allocator.Error!void {
        self.begin_scope();
        self.consume(.LeftParen, "Expect '(' after 'for'.");

        if (self.match_tok(.Semicolon)) {
            // No initializer.
        } else if (self.match_tok(.Var)) {
            try self.var_declaration();
        } else {
            try self.expression_statement();
        }

        var loop_start = self.current_chunk().code.items.len;
        var exit_jump: ?usize = null;

        if (!self.match_tok(.Semicolon)) {
            const condition = try self.expression();
            self.consume(.Semicolon, "Expect ';' after loop condition.");
            exit_jump = try self.emit_jump(.JumpIfFalse, condition.reg);
            self.discard_temporaries();
        }

        if (!self.match_tok(.RightParen)) {
            const body_jump = try self.emit_jump(.Jump, 0);
            const increment_start = self.current_chunk().code.items.len;
            _ = try self.expression();
            self.discard_temporaries();
            self.consume(.RightParen, "Expect ')' after for clauses.");

            try self.emit_loop(loop_start);
            loop_start = increment_start;
            self.patch_jump(body_jump);
        }

        try self.statement();
        try self.emit_loop(loop_start);
        if (exit_jump) |jump| self.patch_jump(jump);
        try self.end_scope();
    }

    fn while_statement(self: *Self) Allocator.Error!void {
        const loop_start = self.current_chunk().code.items.len;
        self.consume(.LeftParen, "Expect '(' after 'while'.");
        const condition = try self.expression();
        self.consume(.RightParen, "Expect ')' after condition.");

        const exit_jump = try self.emit_jump(.JumpIfFalse, condition.reg);
        self.discard_temporaries();
        try self.statement();
        try self.emit_loop(loop_start);
        self.patch_jump(exit_jump);
    }

    // ---------------------------------------------------------------------
    // Expressions
    // ---------------------------------------------------------------------

    fn grouping(self: *Self, can_assign: bool) Allocator.Error!Expr {
        _ = can_assign;
        const value = try self.expression();
        self.consume(.RightParen, "Expect ')' after expression.");
        return value;
    }

    fn unary(self: *Self, can_assign: bool) Allocator.Error!Expr {
        _ = can_assign;
        const token_type = self.parser.previous.type;
        const operand = try self.parse_precedence(.Unary);
        const dst = if (operand.is_temp) operand.reg else self.alloc_register();
        _ = try self.emit(Instruction.ab(
            switch (token_type) {
                .Minus => .Negate,
                .Bang => .Not,
                else => unreachable,
            },
            dst,
            operand.reg,
        ));
        return Expr.temporary(dst);
    }

    fn binary(self: *Self, left: Expr, can_assign: bool) Allocator.Error!Expr {
        _ = can_assign;
        const operator_type = self.parser.previous.type;
        const rule = Self.get_rule(operator_type);
        const next_precedence: Precedence = @fromBackingInt(@backingInt(rule.precedence) + 1);

        // Preserve left-to-right evaluation semantics. A borrowed local is
        // snapshotted before parsing the right operand because that operand may
        // call code or assign to the local. If parsing the right operand emits no
        // bytecode and simply borrows another local, the snapshot is provably
        // unnecessary and is removed again. Thus `a + b` lowers to one ADD while
        // `a + mutateA()` still observes the original value of `a`.
        var snapshot_offset: ?usize = null;
        const left_value = if (left.is_temp) left else blk: {
            const dst = self.alloc_register();
            snapshot_offset = try self.emit(Instruction.ab(.Move, dst, left.reg));
            break :blk Expr.temporary(dst);
        };
        const dst = left_value.reg;
        const right_start = self.current_chunk().code.items.len;
        const right = try self.parse_precedence(next_precedence);

        var lhs_reg = left_value.reg;
        if (snapshot_offset) |offset| {
            if (!right.is_temp and self.current_chunk().code.items.len == right_start) {
                self.remove_last_instruction(offset);
                lhs_reg = left.reg;
            }
        }

        switch (operator_type) {
            .BangEqual => {
                _ = try self.emit(Instruction.abc(.Equal, dst, lhs_reg, right.reg));
                _ = try self.emit(Instruction.ab(.Not, dst, dst));
            },
            .EqualEqual => _ = try self.emit(Instruction.abc(.Equal, dst, lhs_reg, right.reg)),
            .Greater => _ = try self.emit(Instruction.abc(.Greater, dst, lhs_reg, right.reg)),
            .GreaterEqual => {
                _ = try self.emit(Instruction.abc(.Less, dst, lhs_reg, right.reg));
                _ = try self.emit(Instruction.ab(.Not, dst, dst));
            },
            .Less => _ = try self.emit(Instruction.abc(.Less, dst, lhs_reg, right.reg)),
            .LessEqual => {
                _ = try self.emit(Instruction.abc(.Greater, dst, lhs_reg, right.reg));
                _ = try self.emit(Instruction.ab(.Not, dst, dst));
            },
            .Plus => _ = try self.emit(Instruction.abc(.Add, dst, lhs_reg, right.reg)),
            .Minus => _ = try self.emit(Instruction.abc(.Subtract, dst, lhs_reg, right.reg)),
            .Star => _ = try self.emit(Instruction.abc(.Multiply, dst, lhs_reg, right.reg)),
            .Slash => _ = try self.emit(Instruction.abc(.Divide, dst, lhs_reg, right.reg)),
            else => unreachable,
        }

        self.release_expr(right);
        return Expr.temporary(dst);
    }

    fn call(self: *Self, callee_expr: Expr, can_assign: bool) Allocator.Error!Expr {
        _ = can_assign;
        const callee = try self.ensure_temp(callee_expr);
        const arg_count = try self.argument_list(callee.reg);

        // CALL may perform an allocation before a child frame exists (for
        // example when invoking a class). Keep the complete call window rooted
        // for the instruction's safepoint. Once CALL completes, only R[callee]
        // remains live as the result.
        const call_root_top = self.register_top;
        _ = try self.emit_with_root_top(Instruction.ab(.Call, callee.reg, arg_count), call_root_top);
        self.register_top = @as(u16, callee.reg) + 1;
        return callee;
    }

    fn dot(self: *Self, receiver_expr: Expr, can_assign: bool) Allocator.Error!Expr {
        const receiver = try self.ensure_temp(receiver_expr);
        self.consume(.Identifier, "Expect property name after '.'.");
        const name = try self.identifier_constant(&self.parser.previous);

        if (can_assign and self.match_tok(.Equal)) {
            const value = try self.expression();
            _ = try self.emit_with_root_top(
                Instruction.abc(.SetProperty, receiver.reg, value.reg, name),
                self.register_top,
            );
            self.release_expr(value);
            self.register_top = @as(u16, receiver.reg) + 1;
            return receiver;
        }

        if (self.match_tok(.LeftParen)) {
            const arg_count = try self.argument_list(receiver.reg);
            const call_root_top = self.register_top;
            _ = try self.emit_with_root_top(
                Instruction.abc(.Invoke, receiver.reg, arg_count, name),
                call_root_top,
            );
            self.register_top = @as(u16, receiver.reg) + 1;
            return receiver;
        }

        _ = try self.emit(Instruction.abc(.GetProperty, receiver.reg, 0, name));
        return receiver;
    }

    fn parse_precedence(self: *Self, precedence: Precedence) Allocator.Error!Expr {
        self.advance();
        const prefix_rule = Self.get_rule(self.parser.previous.type).prefix orelse {
            self.report_error("Expect expression.");
            const dst = self.alloc_register();
            _ = try self.emit(Instruction.aOnly(.LoadNil, dst));
            return Expr.temporary(dst);
        };

        const can_assign = @backingInt(precedence) <= @backingInt(Precedence.Assignment);
        var left = try prefix_rule(self, can_assign);
        const precedence_int = @backingInt(precedence);

        while (precedence_int <= @backingInt(Self.get_rule(self.parser.current.type).precedence)) {
            self.advance();
            const infix_rule = Self.get_rule(self.parser.previous.type).infix orelse
                @panic("missing infix parse rule");
            left = try infix_rule(self, left, can_assign);
        }

        if (can_assign and self.match_tok(.Equal)) self.report_error("Invalid assignment target.");
        return left;
    }

    fn argument_list(self: *Self, base: u8) Allocator.Error!u8 {
        var arg_count: usize = 0;
        if (!self.check(.RightParen)) {
            while (true) {
                const argument = try self.expression();

                if (arg_count == std.math.maxInt(u8)) {
                    self.report_error("Can't have more than 255 arguments.");
                    self.release_expr(argument);
                } else {
                    const expected_u16 = @as(u16, base) + 1 + @as(u16, @intCast(arg_count));
                    if (expected_u16 > std.math.maxInt(u8)) {
                        self.report_error("Call requires more than 256 registers.");
                        self.release_expr(argument);
                    } else {
                        _ = try self.append_call_operand(argument, @intCast(expected_u16));
                    }
                    arg_count += 1;
                }

                if (!self.match_tok(.Comma)) break;
            }
        }
        self.consume(.RightParen, "Expect ')' after arguments.");
        return @intCast(@min(arg_count, @as(usize, std.math.maxInt(u8))));
    }

    fn and_(self: *Self, left_expr: Expr, can_assign: bool) Allocator.Error!Expr {
        _ = can_assign;
        const left = try self.ensure_temp(left_expr);
        const end_jump = try self.emit_jump(.JumpIfFalse, left.reg);
        const right = try self.parse_precedence(.And);
        if (right.reg != left.reg) _ = try self.emit(Instruction.ab(.Move, left.reg, right.reg));
        self.release_expr(right);
        self.patch_jump(end_jump);
        return left;
    }

    fn or_(self: *Self, left_expr: Expr, can_assign: bool) Allocator.Error!Expr {
        _ = can_assign;
        const left = try self.ensure_temp(left_expr);
        const else_jump = try self.emit_jump(.JumpIfFalse, left.reg);
        const end_jump = try self.emit_jump(.Jump, 0);
        self.patch_jump(else_jump);

        const right = try self.parse_precedence(.Or);
        if (right.reg != left.reg) _ = try self.emit(Instruction.ab(.Move, left.reg, right.reg));
        self.release_expr(right);
        self.patch_jump(end_jump);
        return left;
    }

    fn number(self: *Self, can_assign: bool) Allocator.Error!Expr {
        _ = can_assign;
        const value = std.fmt.parseFloat(f64, self.parser.previous.content[0..self.parser.previous.len]) catch {
            self.error_at(self.parser.previous, "Invalid number");
            return self.emit_constant(Value.number(0));
        };
        return self.emit_constant(Value.number(value));
    }

    fn literal(self: *Self, can_assign: bool) Allocator.Error!Expr {
        _ = can_assign;
        const dst = self.alloc_register();
        _ = try self.emit(Instruction.aOnly(switch (self.parser.previous.type) {
            .True => .LoadTrue,
            .False => .LoadFalse,
            .Nil => .LoadNil,
            else => unreachable,
        }, dst));
        return Expr.temporary(dst);
    }

    fn string(self: *Self, can_assign: bool) Allocator.Error!Expr {
        _ = can_assign;
        const obj_string = try self.gc.copy_string(
            self.parser.previous.content + 1,
            self.parser.previous.len - 2,
        );
        return self.emit_constant(Value.obj(obj_string.widen()));
    }

    fn variable(self: *Self, can_assign: bool) Allocator.Error!Expr {
        return self.named_variable(&self.parser.previous, can_assign);
    }

    fn named_variable(self: *Self, name: *const Token, can_assign: bool) Allocator.Error!Expr {
        const local_index = self.resolve_local_index(name);
        var kind: enum { Local, Upvalue, Global } = undefined;
        var index: u8 = undefined;

        if (local_index != -1) {
            kind = .Local;
            index = self.locals[@intCast(local_index)].reg;
        } else {
            const upvalue = self.resolve_upvalue(name);
            if (upvalue != -1) {
                kind = .Upvalue;
                index = @intCast(upvalue);
            } else {
                kind = .Global;
                index = try self.identifier_constant(name);
            }
        }

        if (can_assign and self.match_tok(.Equal)) {
            const value = try self.expression();
            switch (kind) {
                .Local => {
                    if (index != value.reg) _ = try self.emit(Instruction.ab(.Move, index, value.reg));
                },
                .Upvalue => _ = try self.emit(Instruction.ab(.SetUpvalue, value.reg, index)),
                .Global => _ = try self.emit(Instruction.ab(.SetGlobal, value.reg, index)),
            }
            return value;
        }

        if (kind == .Local) return Expr.borrowed(index);

        const dst = self.alloc_register();
        switch (kind) {
            .Local => unreachable,
            .Upvalue => _ = try self.emit(Instruction.ab(.GetUpvalue, dst, index)),
            .Global => _ = try self.emit(Instruction.ab(.GetGlobal, dst, index)),
        }
        return Expr.temporary(dst);
    }

    fn this(self: *Self, can_assign: bool) Allocator.Error!Expr {
        _ = can_assign;
        if (self.class_compiler == null) {
            self.report_error("Can't use 'this' outside of a class.");
        }
        return self.variable(false);
    }

    fn super(self: *Self, can_assign: bool) Allocator.Error!Expr {
        _ = can_assign;
        if (self.class_compiler) |class_compiler| {
            if (!class_compiler.has_superclass) {
                self.report_error("Can't use 'super' in a class with no superclass.");
            }
        } else {
            self.report_error("Can't use 'super' outside of a class.");
        }

        self.consume(.Dot, "Expect '.' after 'super'.");
        self.consume(.Identifier, "Expect superclass method name.");
        const name = try self.identifier_constant(&self.parser.previous);

        const this_token = Token.synthetic("this");
        const super_token = Token.synthetic("super");
        const receiver = try self.ensure_temp(try self.named_variable(&this_token, false));

        if (self.match_tok(.LeftParen)) {
            const arg_count = try self.argument_list(receiver.reg);
            const superclass = try self.named_variable(&super_token, false);
            const expected_u16 = @as(u16, receiver.reg) + @as(u16, arg_count) + 1;
            if (expected_u16 > std.math.maxInt(u8)) {
                self.report_error("super call requires more than 256 registers.");
            } else {
                _ = try self.append_call_operand(superclass, @intCast(expected_u16));
            }

            const call_root_top = self.register_top;
            _ = try self.emit_with_root_top(
                Instruction.abc(.InvokeSuper, receiver.reg, arg_count, name),
                call_root_top,
            );
            self.register_top = @as(u16, receiver.reg) + 1;
            return receiver;
        }

        const superclass = try self.named_variable(&super_token, false);
        _ = try self.emit(Instruction.abc(.GetSuper, receiver.reg, superclass.reg, name));
        self.release_expr(superclass);
        return receiver;
    }

    // ---------------------------------------------------------------------
    // Variables / closures
    // ---------------------------------------------------------------------

    fn parse_variable(self: *Self, error_message: []const u8) Allocator.Error!u8 {
        self.consume(.Identifier, error_message);
        self.declare_variable();
        if (self.scope_depth > 0) {
            // The slot becomes part of the GC root window before its initializer is
            // evaluated. Initialize it eagerly so a moving collection can never see
            // an inactive/stale pointer from an older use of the register stack.
            const local = self.locals[self.local_count - 1].reg;
            _ = try self.emit(Instruction.aOnly(.LoadNil, local));
            return 0;
        }
        return self.identifier_constant(&self.parser.previous);
    }

    fn parse_parameter(self: *Self, error_message: []const u8) Allocator.Error!void {
        self.consume(.Identifier, error_message);
        self.declare_variable();
        // Parameter registers are populated by the caller, so unlike an ordinary
        // local declaration they must not be overwritten with nil at function entry.
    }

    fn define_variable(self: *Self, global: u8, value: u8) Allocator.Error!void {
        if (self.scope_depth > 0) {
            const local = self.locals[self.local_count - 1].reg;
            if (local != value) _ = try self.emit(Instruction.ab(.Move, local, value));
            self.mark_initialized();
            self.discard_temporaries();
            return;
        }

        const root_top = @as(u16, @intCast(self.local_count));
        _ = try self.emit_with_root_top(
            Instruction.ab(.DefineGlobal, value, global),
            @max(root_top, @as(u16, value) + 1),
        );
        self.discard_temporaries();
    }

    fn declare_variable(self: *Self) void {
        if (self.scope_depth == 0) return;

        const name = self.parser.previous;
        var i = self.local_count;
        while (i > 0) {
            i -= 1;
            const local = self.locals[i];
            if (local.depth != -1 and local.depth < self.scope_depth) break;
            if (identifiers_equal(&name, &local.name)) {
                self.report_error("Already a variable with this name in this scope.");
            }
        }
        self.add_local(name);
    }

    fn mark_initialized(self: *Self) void {
        if (self.scope_depth == 0) return;
        self.locals[self.local_count - 1].depth = self.scope_depth;
    }

    fn add_local(self: *Self, name: Token) void {
        if (self.local_count == self.locals.len) {
            self.report_error("Too many local variables in function.");
            return;
        }
        if (self.register_top != @as(u16, @intCast(self.local_count))) {
            self.report_error("Internal compiler error: local allocated with live temporaries.");
            self.discard_temporaries();
        }

        const reg = self.alloc_register();
        self.locals[self.local_count] = .{
            .name = name,
            .depth = -1,
            .is_captured = false,
            .reg = reg,
        };
        self.local_count += 1;
    }

    fn add_local_from_temp(self: *Self, name: Token, reg: u8) void {
        if (self.local_count == self.locals.len) {
            self.report_error("Too many local variables in function.");
            return;
        }
        if (@as(u16, reg) + 1 != self.register_top or @as(usize, reg) != self.local_count) {
            self.report_error("Internal compiler error: cannot promote temporary to local.");
            return;
        }

        self.locals[self.local_count] = .{
            .name = name,
            .depth = -1,
            .is_captured = false,
            .reg = reg,
        };
        self.local_count += 1;
    }

    fn resolve_local_index(self: *Self, name: *const Token) i32 {
        var i = self.local_count;
        while (i > 0) {
            i -= 1;
            const local = self.locals[i];
            if (identifiers_equal(name, &local.name)) {
                if (local.depth == -1) {
                    self.report_error("Can't read local variable in its own initializer.");
                }
                return @intCast(i);
            }
        }
        return -1;
    }

    fn resolve_upvalue(self: *Self, name: *const Token) i32 {
        const enclosing = self.enclosing orelse return -1;

        const local_index = enclosing.resolve_local_index(name);
        if (local_index != -1) {
            const local = &enclosing.locals[@intCast(local_index)];
            local.is_captured = true;
            return self.add_upvalue(local.reg, true);
        }

        const upvalue = enclosing.resolve_upvalue(name);
        if (upvalue != -1) return self.add_upvalue(@intCast(upvalue), false);
        return -1;
    }

    fn add_upvalue(self: *Self, index: u8, is_local: bool) i32 {
        const upvalue_count = self.function.upvalue_count;
        var i: usize = 0;
        while (i < upvalue_count) : (i += 1) {
            const upvalue = &self.upvalues[i];
            if (upvalue.index == index and upvalue.is_local == is_local) return @intCast(i);
        }

        if (upvalue_count == self.upvalues.len) {
            self.report_error("Too many closure variables in function.");
            return 0;
        }

        self.upvalues[upvalue_count] = .{ .is_local = is_local, .index = index };
        self.function.upvalue_count += 1;
        return @intCast(upvalue_count);
    }

    fn identifier_constant(self: *Self, name: *const Token) Allocator.Error!u8 {
        const string_obj = try self.gc.copy_string(name.content, name.len);
        return self.make_constant(Value.obj(string_obj.widen()));
    }

    fn identifiers_equal(a: *const Token, b: *const Token) bool {
        return std.mem.eql(u8, a.content[0..a.len], b.content[0..b.len]);
    }

    // ---------------------------------------------------------------------
    // Parser utilities
    // ---------------------------------------------------------------------

    fn get_rule(token_type: TokenType) ParseRule {
        return rules.get(token_type);
    }

    fn consume(self: *Self, comptime token_type: TokenType, message: []const u8) void {
        if (self.parser.current.type == token_type) {
            self.advance();
        } else {
            self.error_at_current(message);
        }
    }

    fn advance(self: *Self) void {
        self.parser.previous = self.parser.current;
        while (true) {
            const token = self.scanner.scan_token();
            if (token.type != .Error) {
                self.parser.current = token;
                break;
            }
            self.error_at(token, token.content[0..token.len]);
        }
    }

    fn match_tok(self: *Self, ty: TokenType) bool {
        if (!self.check(ty)) return false;
        self.advance();
        return true;
    }

    fn check(self: *Self, ty: TokenType) bool {
        return self.parser.current.type == ty;
    }

    fn error_at_current(self: *Self, message: []const u8) void {
        self.error_at(self.parser.current, message);
    }

    fn report_error(self: *Self, message: []const u8) void {
        self.error_at(self.parser.previous, message);
    }

    fn error_at(self: *Self, token: Token, message: []const u8) void {
        if (self.parser.panic_mode) return;
        self.parser.panic_mode = true;

        std.debug.print("[line {d}] Error", .{token.line});
        if (token.type == .Eof) {
            std.debug.print(" at end", .{});
        } else if (token.type != .Error) {
            std.debug.print(" at '{s}'", .{token.content[0..token.len]});
        }
        std.debug.print(": {s}\n", .{message});
        self.parser.had_error = true;
    }

    fn synchronize(self: *Self) void {
        self.parser.panic_mode = false;
        while (self.parser.current.type != .Eof) {
            if (self.parser.previous.type == .Semicolon) return;
            switch (self.parser.current.type) {
                .Class, .Fun, .Var, .For, .If, .While, .Print, .Return => return,
                else => {},
            }
            self.advance();
        }
    }
};

const Parser = struct {
    current: Token,
    previous: Token,
    had_error: bool = false,
    panic_mode: bool = false,

    pub fn init() Parser {
        return .{ .current = undefined, .previous = undefined };
    }
};
