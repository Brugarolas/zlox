const std = @import("std");

pub const TokenType = enum {
    LeftParen,
    RightParen,
    LeftBrace,
    RightBrace,
    Comma,
    Dot,
    Minus,
    Plus,
    Semicolon,
    Slash,
    Star,

    Bang,
    BangEqual,
    Equal,
    EqualEqual,
    Greater,
    GreaterEqual,
    Less,
    LessEqual,

    Identifier,
    String,
    Number,

    And,
    Class,
    Else,
    False,
    For,
    Fun,
    If,
    Nil,
    Or,
    Print,
    Return,
    Super,
    This,
    True,
    Var,
    While,

    Error,
    Eof,

    pub inline fn name(self: TokenType) []const u8 {
        return @tagName(self);
    }
};

pub const Token = struct {
    type: TokenType,
    line: u32,
    len: u32,
    content: [*]const u8,

    pub fn debugPrint(self: Token) void {
        std.debug.print("Token{{type: {s}, content: \"{s}\"}}", .{
            @tagName(self.type),
            self.content[0..self.len],
        });
    }

    pub fn synthetic(text: []const u8) Token {
        return .{
            .type = .Identifier,
            .line = 0,
            .len = @intCast(text.len),
            .content = text.ptr,
        };
    }
};

const Scanner = @This();

source: []const u8,
start: usize = 0,
current: usize = 0,
line: u32 = 1,

pub fn init(source: []const u8) Scanner {
    return .{ .source = source };
}

pub fn scan(self: *Scanner) void {
    var previous_line: u32 = 0;

    while (true) {
        const token = self.scan_token();
        if (token.line != previous_line) {
            previous_line = token.line;
            std.debug.print("line {d}: ", .{previous_line});
        }

        token.debugPrint();
        std.debug.print("\n", .{});

        if (token.type == .Eof) break;
    }
}

pub fn scan_token(self: *Scanner) Token {
    self.skip_whitespace();
    self.start = self.current;

    if (self.is_at_end()) return self.make_token(.Eof);

    const c = self.advance();
    if (is_digit(c)) return self.number();
    if (is_alpha(c)) return self.identifier();

    return switch (c) {
        '(' => self.make_token(.LeftParen),
        ')' => self.make_token(.RightParen),
        '{' => self.make_token(.LeftBrace),
        '}' => self.make_token(.RightBrace),
        ';' => self.make_token(.Semicolon),
        ',' => self.make_token(.Comma),
        '.' => self.make_token(.Dot),
        '-' => self.make_token(.Minus),
        '+' => self.make_token(.Plus),
        '/' => self.make_token(.Slash),
        '*' => self.make_token(.Star),
        '!' => if (self.match('=')) self.make_token(.BangEqual) else self.make_token(.Bang),
        '=' => if (self.match('=')) self.make_token(.EqualEqual) else self.make_token(.Equal),
        '<' => if (self.match('=')) self.make_token(.LessEqual) else self.make_token(.Less),
        '>' => if (self.match('=')) self.make_token(.GreaterEqual) else self.make_token(.Greater),
        '"' => self.string(),
        else => self.error_token("Unexpected character."),
    };
}

fn string(self: *Scanner) Token {
    while (!self.is_at_end() and self.peek() != '"') {
        if (self.peek() == '\n') self.line += 1;
        _ = self.advance();
    }

    if (self.is_at_end()) return self.error_token("Unterminated string.");

    _ = self.advance();
    return self.make_token(.String);
}

fn number(self: *Scanner) Token {
    while (is_digit(self.peek())) _ = self.advance();

    if (self.peek() == '.' and is_digit(self.peek_next())) {
        _ = self.advance();
        while (is_digit(self.peek())) _ = self.advance();
    }

    return self.make_token(.Number);
}

fn identifier(self: *Scanner) Token {
    while (is_alpha(self.peek()) or is_digit(self.peek())) _ = self.advance();
    return self.make_token(self.identifier_type());
}

fn match(self: *Scanner, expected: u8) bool {
    if (self.is_at_end() or self.source[self.current] != expected) return false;
    self.current += 1;
    return true;
}

fn make_token(self: *const Scanner, token_type: TokenType) Token {
    const slice = self.source[self.start..self.current];
    return .{
        .type = token_type,
        .line = self.line,
        .len = @intCast(slice.len),
        .content = slice.ptr,
    };
}

fn error_token(self: *const Scanner, message: []const u8) Token {
    return .{
        .type = .Error,
        .line = self.line,
        .len = @intCast(message.len),
        .content = message.ptr,
    };
}

inline fn is_at_end(self: *const Scanner) bool {
    return self.current >= self.source.len;
}

inline fn advance(self: *Scanner) u8 {
    const c = self.source[self.current];
    self.current += 1;
    return c;
}

inline fn peek(self: *const Scanner) u8 {
    if (self.is_at_end()) return 0;
    return self.source[self.current];
}

inline fn peek_next(self: *const Scanner) u8 {
    if (self.current + 1 >= self.source.len) return 0;
    return self.source[self.current + 1];
}

fn skip_whitespace(self: *Scanner) void {
    while (!self.is_at_end()) {
        switch (self.peek()) {
            ' ', '\r', '\t' => _ = self.advance(),
            '\n' => {
                self.line += 1;
                _ = self.advance();
            },
            '/' => {
                if (self.peek_next() != '/') return;
                while (!self.is_at_end() and self.peek() != '\n') _ = self.advance();
            },
            else => return,
        }
    }
}

inline fn is_digit(c: u8) bool {
    return c >= '0' and c <= '9';
}

inline fn is_alpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        c == '_';
}

fn identifier_type(self: *const Scanner) TokenType {
    const text = self.source[self.start..self.current];
    if (text.len == 0) return .Identifier;

    return switch (text[0]) {
        'a' => self.check_keyword(1, "nd", .And),
        'c' => self.check_keyword(1, "lass", .Class),
        'e' => self.check_keyword(1, "lse", .Else),
        'f' => if (text.len > 1) switch (text[1]) {
            'a' => self.check_keyword(2, "lse", .False),
            'o' => self.check_keyword(2, "r", .For),
            'u' => self.check_keyword(2, "n", .Fun),
            else => .Identifier,
        } else .Identifier,
        'i' => self.check_keyword(1, "f", .If),
        'n' => self.check_keyword(1, "il", .Nil),
        'o' => self.check_keyword(1, "r", .Or),
        'p' => self.check_keyword(1, "rint", .Print),
        'r' => self.check_keyword(1, "eturn", .Return),
        's' => self.check_keyword(1, "uper", .Super),
        't' => if (text.len > 1) switch (text[1]) {
            'h' => self.check_keyword(2, "is", .This),
            'r' => self.check_keyword(2, "ue", .True),
            else => .Identifier,
        } else .Identifier,
        'v' => self.check_keyword(1, "ar", .Var),
        'w' => self.check_keyword(1, "hile", .While),
        else => .Identifier,
    };
}

fn check_keyword(self: *const Scanner, start_index: usize, rest: []const u8, token_type: TokenType) TokenType {
    const text = self.source[self.start..self.current];
    if (text.len != start_index + rest.len) return .Identifier;
    if (!std.mem.eql(u8, text[start_index..], rest)) return .Identifier;
    return token_type;
}

test "empty source is safe" {
    var scanner = Scanner.init("");
    try std.testing.expectEqual(TokenType.Eof, scanner.scan_token().type);
}

test "scanner recognizes keywords and operators" {
    var scanner = Scanner.init("class Foo { fun bar() { return this != nil; } }");
    const expected = [_]TokenType{
        .Class, .Identifier, .LeftBrace, .Fun, .Identifier, .LeftParen, .RightParen,
        .LeftBrace, .Return, .This, .BangEqual, .Nil, .Semicolon, .RightBrace,
        .RightBrace, .Eof,
    };
    for (expected) |token_type| {
        try std.testing.expectEqual(token_type, scanner.scan_token().type);
    }
}
