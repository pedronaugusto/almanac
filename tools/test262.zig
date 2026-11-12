//! Transcribes test262's Temporal cases into almanac's testdata, once, as text: no JavaScript runs.
//! `test262 <test262 checkout> <commit> <output directory>` writes `temporal.json` there (`bay dev
//! test262 -Dtest262=<checkout>`).
//!
//! test262's Temporal tests repeat a small set of shapes, and this reads exactly those: `const` and
//! `let` bindings of literals, `new Temporal.<Type>(...)` and `Temporal.<Type>.from(...)`, object
//! and array literals (property shorthand among them), array destructuring with defaults, loops over
//! a table (`table.forEach((row) => ...)`, `for (const row of table) ...`), and the assertions
//! `TemporalHelpers.assertDuration` / `assertPlainDate` / `assertPlainDateTime` / `assertPlainTime`,
//! `assert.sameValue(<value>.epochNanoseconds, <bigint>)`, `assert.sameValue(<call>, <number>)` and
//! `assert.throws(RangeError, () => <call>)`. A call it records is a method of a Temporal value
//! (`from`, `until`, `since`, `round`, `add`, `subtract`, `total`) whose receiver and arguments it
//! could evaluate. Anything else it passes over; the files it reads no case from are counted.
const std = @import("std");
const Allocator = std.mem.Allocator;

// Tokens.

const Tag = enum { identifier, string, number, bigint, template, punct, end };

const Token = struct {
    tag: Tag,
    /// The token's text; for a string, its value.
    text: []const u8,
};

const Lexer = struct {
    a: Allocator,
    src: []const u8,
    at: usize = 0,

    fn skip(l: *Lexer) void {
        while (l.at < l.src.len) {
            const c = l.src[l.at];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                l.at += 1;
            } else if (std.mem.startsWith(u8, l.src[l.at..], "//")) {
                l.at = std.mem.findScalarPos(u8, l.src, l.at, '\n') orelse l.src.len;
            } else if (std.mem.startsWith(u8, l.src[l.at..], "/*")) {
                l.at = if (std.mem.findPos(u8, l.src, l.at + 2, "*/")) |e| e + 2 else l.src.len;
            } else break;
        }
    }

    fn next(l: *Lexer) Allocator.Error!Token {
        l.skip();
        if (l.at >= l.src.len) return .{ .tag = .end, .text = "" };
        const start = l.at;
        const c = l.src[l.at];
        if (std.ascii.isAlphabetic(c) or c == '_' or c == '$' or c >= 0x80) {
            while (l.at < l.src.len and (std.ascii.isAlphanumeric(l.src[l.at]) or l.src[l.at] == '_' or l.src[l.at] == '$' or l.src[l.at] >= 0x80)) l.at += 1;
            return .{ .tag = .identifier, .text = l.src[start..l.at] };
        }
        if (std.ascii.isDigit(c) or (c == '.' and l.at + 1 < l.src.len and std.ascii.isDigit(l.src[l.at + 1]))) {
            while (l.at < l.src.len and (std.ascii.isAlphanumeric(l.src[l.at]) or l.src[l.at] == '.' or l.src[l.at] == '_')) l.at += 1;
            // As JSON writes a number: no separators, a digit before the point.
            var t: std.ArrayList(u8) = .empty;
            if (c == '.') try t.append(l.a, '0');
            for (l.src[start..l.at]) |d| if (d != '_') try t.append(l.a, d);
            if (t.items[t.items.len - 1] == 'n') return .{ .tag = .bigint, .text = t.items[0 .. t.items.len - 1] };
            return .{ .tag = .number, .text = t.items };
        }
        if (c == '"' or c == '\'') return l.string(c);
        if (c == '`') {
            l.at += 1;
            while (l.at < l.src.len and l.src[l.at] != '`') : (l.at += 1) {
                if (l.src[l.at] == '\\') l.at += 1;
            }
            l.at += 1;
            return .{ .tag = .template, .text = l.src[start..@min(l.at, l.src.len)] };
        }
        const three = [_][]const u8{ "...", "===", "!==" };
        for (three) |p| if (std.mem.startsWith(u8, l.src[l.at..], p)) {
            l.at += 3;
            return .{ .tag = .punct, .text = p };
        };
        const two = [_][]const u8{ "=>", "==", "!=", "<=", ">=", "&&", "||", "++", "--", "+=", "-=", "**", "?." };
        for (two) |p| if (std.mem.startsWith(u8, l.src[l.at..], p)) {
            l.at += 2;
            return .{ .tag = .punct, .text = p };
        };
        l.at += 1;
        return .{ .tag = .punct, .text = l.src[start..l.at] };
    }

    fn string(l: *Lexer, quote: u8) Allocator.Error!Token {
        l.at += 1;
        var out: std.ArrayList(u8) = .empty;
        while (l.at < l.src.len and l.src[l.at] != quote) {
            const c = l.src[l.at];
            if (c != '\\') {
                try out.append(l.a, c);
                l.at += 1;
                continue;
            }
            const n = l.src[l.at + 1];
            l.at += 2;
            switch (n) {
                'n' => try out.append(l.a, '\n'),
                't' => try out.append(l.a, '\t'),
                '0' => try out.append(l.a, 0),
                'u' => {
                    var cp: u21 = 0;
                    if (l.src[l.at] == '{') {
                        const close = std.mem.findScalarPos(u8, l.src, l.at, '}').?;
                        cp = std.fmt.parseInt(u21, l.src[l.at + 1 .. close], 16) catch 0xFFFD;
                        l.at = close + 1;
                    } else {
                        cp = std.fmt.parseInt(u21, l.src[l.at .. l.at + 4], 16) catch 0xFFFD;
                        l.at += 4;
                    }
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(cp, &buf) catch 0;
                    try out.appendSlice(l.a, buf[0..len]);
                },
                else => try out.append(l.a, n),
            }
        }
        l.at += 1;
        return .{ .tag = .string, .text = out.items };
    }
};

// Values.

pub const Value = union(enum) {
    string: []const u8,
    /// An integer or a decimal, as written.
    number: []const u8,
    bigint: []const u8,
    boolean: bool,
    undefined,
    array: []const Value,
    object: []const Field,
    /// `new Temporal.<Type>(args)` or `Temporal.<Type>.from(arg)`.
    temporal: Temporal,
    /// A method call on a Temporal value, unevaluated: what a case records.
    call: Call,
    /// What this reader cannot evaluate.
    unknown,
};

pub const Field = struct { key: []const u8, value: Value };
pub const Temporal = struct { type: []const u8, make: []const u8, args: []const Value };
pub const Call = struct { receiver: *const Value, method: []const u8, args: []const Value };

/// One `const`/`let` binding in scope.
const Binding = struct { name: []const u8, value: Value };

pub const Case = struct {
    path: []const u8,
    call: Call,
    expect: Expect,
};

pub const Expect = union(enum) {
    throws,
    /// The same value another call gives (`assertDurationsEqual(a, b)` and its kin).
    equal: Value,
    /// The fields of the result in test262's order for its type (assert<Kind>).
    fields: struct { kind: []const u8, values: []const []const u8 },
    epoch_ns: []const u8,
    number: []const u8,
};

const methods = [_][]const u8{ "from", "until", "since", "round", "add", "subtract", "total", "equals" };
const types = [_][]const u8{ "Duration", "Instant", "PlainDate", "PlainDateTime", "PlainTime", "ZonedDateTime" };

fn isOneOf(s: []const u8, set: []const []const u8) bool {
    for (set) |x| if (std.mem.eql(u8, s, x)) return true;
    return false;
}

/// Reads one test file's statements, records its cases.
const Reader = struct {
    a: Allocator,
    tokens: []const Token,
    at: usize = 0,
    scope: std.ArrayList(Binding) = .empty,
    cases: *std.ArrayList(Case),
    path: []const u8,

    fn peek(r: *const Reader) Token {
        return r.tokens[@min(r.at, r.tokens.len - 1)];
    }

    fn peekAt(r: *const Reader, ahead: usize) Token {
        return r.tokens[@min(r.at + ahead, r.tokens.len - 1)];
    }

    fn is(r: *const Reader, text: []const u8) bool {
        const t = r.peek();
        return (t.tag == .punct or t.tag == .identifier) and std.mem.eql(u8, t.text, text);
    }

    fn eat(r: *Reader, text: []const u8) bool {
        if (!r.is(text)) return false;
        r.at += 1;
        return true;
    }

    fn lookup(r: *const Reader, name: []const u8) Value {
        var i = r.scope.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, r.scope.items[i].name, name)) return r.scope.items[i].value;
        }
        return .unknown;
    }

    /// Skips to the token after the bracket closing the one at the cursor.
    fn skipBalanced(r: *Reader) void {
        var depth: usize = 0;
        while (r.peek().tag != .end) {
            const t = r.peek();
            r.at += 1;
            if (t.tag != .punct) continue;
            if (std.mem.eql(u8, t.text, "(") or std.mem.eql(u8, t.text, "[") or std.mem.eql(u8, t.text, "{")) depth += 1;
            if (std.mem.eql(u8, t.text, ")") or std.mem.eql(u8, t.text, "]") or std.mem.eql(u8, t.text, "}")) {
                if (depth <= 1) return;
                depth -= 1;
            }
        }
    }

    /// Skips one statement: to its `;` or the end of its block, at depth zero.
    fn skipStatement(r: *Reader) void {
        var depth: usize = 0;
        while (r.peek().tag != .end) {
            const t = r.peek();
            if (t.tag == .punct) {
                if (std.mem.eql(u8, t.text, "(") or std.mem.eql(u8, t.text, "[") or std.mem.eql(u8, t.text, "{")) depth += 1;
                if (std.mem.eql(u8, t.text, ")") or std.mem.eql(u8, t.text, "]") or std.mem.eql(u8, t.text, "}")) {
                    if (depth == 0) return;
                    depth -= 1;
                    if (depth == 0 and std.mem.eql(u8, t.text, "}")) {
                        r.at += 1;
                        _ = r.eat(";");
                        return;
                    }
                }
                if (depth == 0 and std.mem.eql(u8, t.text, ";")) {
                    r.at += 1;
                    return;
                }
            }
            r.at += 1;
        }
    }

    // Expressions.

    fn expression(r: *Reader) Allocator.Error!Value {
        var v = try r.unary();
        // A binary operator, a conditional: past what this reader evaluates.
        while (r.peek().tag == .punct and isOneOf(r.peek().text, &.{ "+", "-", "*", "/", "%", "===", "!==", "==", "!=", "<", ">", "<=", ">=", "&&", "||", "?", "**" })) {
            r.at += 1;
            _ = try r.unary();
            v = .unknown;
        }
        return v;
    }

    fn unary(r: *Reader) Allocator.Error!Value {
        if (r.eat("-")) {
            const v = try r.unary();
            return switch (v) {
                .number => |n| .{ .number = try std.fmt.allocPrint(r.a, "-{s}", .{n}) },
                .bigint => |n| .{ .bigint = try std.fmt.allocPrint(r.a, "-{s}", .{n}) },
                else => .unknown,
            };
        }
        if (r.eat("+")) return r.unary();
        if (r.eat("!") or r.eat("typeof") or r.eat("void")) {
            _ = try r.unary();
            return .unknown;
        }
        return r.postfix(try r.primary());
    }

    fn primary(r: *Reader) Allocator.Error!Value {
        const t = r.peek();
        switch (t.tag) {
            .string => {
                r.at += 1;
                return .{ .string = t.text };
            },
            .number => {
                r.at += 1;
                return .{ .number = t.text };
            },
            .bigint => {
                r.at += 1;
                return .{ .bigint = t.text };
            },
            .template => {
                r.at += 1;
                // A template with no substitution is a string.
                if (std.mem.findScalar(u8, t.text, '$') == null) return .{ .string = t.text[1 .. t.text.len - 1] };
                return .unknown;
            },
            .identifier => {
                if (std.mem.eql(u8, t.text, "new")) {
                    r.at += 1;
                    return r.construct();
                }
                r.at += 1;
                if (std.mem.eql(u8, t.text, "true")) return .{ .boolean = true };
                if (std.mem.eql(u8, t.text, "false")) return .{ .boolean = false };
                if (std.mem.eql(u8, t.text, "undefined")) return .undefined;
                if (std.mem.eql(u8, t.text, "Temporal") and r.is(".")) {
                    r.at += 1;
                    const ty = r.peek().text;
                    r.at += 1;
                    if (r.eat(".") and r.eat("from") and r.is("(")) {
                        const args = try r.arguments();
                        if (!isOneOf(ty, &types)) return .unknown;
                        return .{ .temporal = .{ .type = ty, .make = "from", .args = args } };
                    }
                    return .unknown;
                }
                // An arrow function's parameters, or a name.
                if (r.is("=>")) {
                    r.at += 1;
                    r.skipArrowBody();
                    return .unknown;
                }
                return r.lookup(t.text);
            },
            .punct => {
                if (r.eat("(")) {
                    // A parenthesized expression, or an arrow function's parameters.
                    const save = r.at;
                    r.at -= 1;
                    r.skipBalanced();
                    if (r.is("=>")) {
                        r.at += 1;
                        r.skipArrowBody();
                        return .unknown;
                    }
                    r.at = save;
                    const v = try r.expression();
                    _ = r.eat(")");
                    return v;
                }
                if (r.is("[")) return r.array();
                if (r.is("{")) return r.object();
                r.at += 1;
                return .unknown;
            },
            .end => return .unknown,
        }
    }

    fn skipArrowBody(r: *Reader) void {
        if (r.is("{")) {
            r.skipBalanced();
        } else {
            _ = r.expression() catch {};
        }
    }

    fn construct(r: *Reader) Allocator.Error!Value {
        if (!r.eat("Temporal") or !r.eat(".")) {
            r.skipStatementExpression();
            return .unknown;
        }
        const ty = r.peek().text;
        r.at += 1;
        if (!r.is("(")) return .unknown;
        const args = try r.arguments();
        if (!isOneOf(ty, &types)) return .unknown;
        return .{ .temporal = .{ .type = ty, .make = "new", .args = args } };
    }

    fn skipStatementExpression(r: *Reader) void {
        while (r.peek().tag == .identifier or r.is(".")) r.at += 1;
        if (r.is("(")) r.skipBalanced();
    }

    fn arguments(r: *Reader) Allocator.Error![]const Value {
        var list: std.ArrayList(Value) = .empty;
        _ = r.eat("(");
        while (!r.is(")") and r.peek().tag != .end) {
            if (r.eat("...")) {
                const spread = try r.expression();
                switch (spread) {
                    .array => |items| try list.appendSlice(r.a, items),
                    else => try list.append(r.a, .unknown),
                }
            } else try list.append(r.a, try r.expression());
            if (!r.eat(",")) break;
        }
        _ = r.eat(")");
        return list.items;
    }

    fn array(r: *Reader) Allocator.Error!Value {
        var list: std.ArrayList(Value) = .empty;
        _ = r.eat("[");
        while (!r.is("]") and r.peek().tag != .end) {
            if (r.is(",")) {
                try list.append(r.a, .undefined);
                r.at += 1;
                continue;
            }
            if (r.eat("...")) {
                switch (try r.expression()) {
                    .array => |items| try list.appendSlice(r.a, items),
                    else => try list.append(r.a, .unknown),
                }
            } else try list.append(r.a, try r.expression());
            if (!r.eat(",")) break;
        }
        _ = r.eat("]");
        return .{ .array = list.items };
    }

    fn object(r: *Reader) Allocator.Error!Value {
        var list: std.ArrayList(Field) = .empty;
        var whole = true;
        _ = r.eat("{");
        while (!r.is("}") and r.peek().tag != .end) {
            const k = r.peek();
            if (k.tag == .identifier or k.tag == .string or k.tag == .number) {
                r.at += 1;
                if (r.eat(":")) {
                    try list.append(r.a, .{ .key = k.text, .value = try r.expression() });
                } else if (r.is(",") or r.is("}")) {
                    // Shorthand: `{ smallestUnit }`.
                    try list.append(r.a, .{ .key = k.text, .value = r.lookup(k.text) });
                } else {
                    // A method or a getter: past this reader.
                    whole = false;
                    while (!r.is(",") and !r.is("}") and r.peek().tag != .end) {
                        if (r.is("(") or r.is("{") or r.is("[")) r.skipBalanced() else r.at += 1;
                    }
                }
            } else {
                whole = false;
                if (r.is("[") or r.is("(") or r.is("{")) r.skipBalanced() else r.at += 1;
                while (!r.is(",") and !r.is("}") and r.peek().tag != .end) {
                    if (r.is("(") or r.is("{") or r.is("[")) r.skipBalanced() else r.at += 1;
                }
            }
            if (!r.eat(",")) break;
        }
        _ = r.eat("}");
        if (!whole) return .unknown;
        return .{ .object = list.items };
    }

    fn postfix(r: *Reader, base: Value) Allocator.Error!Value {
        var v = base;
        while (true) {
            if (r.is(".") or r.is("?.")) {
                r.at += 1;
                const name = r.peek().text;
                r.at += 1;
                if (r.is("(")) {
                    const args = try r.arguments();
                    v = try r.method(v, name, args);
                } else {
                    v = r.property(v, name);
                }
            } else if (r.is("[")) {
                r.at += 1;
                const index = try r.expression();
                _ = r.eat("]");
                v = switch (v) {
                    .array => |items| switch (index) {
                        .number => |n| blk: {
                            const i = std.fmt.parseInt(usize, n, 10) catch break :blk .unknown;
                            break :blk if (i < items.len) items[i] else .undefined;
                        },
                        else => .unknown,
                    },
                    else => .unknown,
                };
            } else if (r.is("(")) {
                _ = try r.arguments();
                v = .unknown;
            } else break;
        }
        return v;
    }

    fn method(r: *Reader, receiver: Value, name: []const u8, args: []const Value) Allocator.Error!Value {
        if (receiver == .temporal or receiver == .call) {
            if (isOneOf(name, &methods)) {
                const boxed = try r.a.create(Value);
                boxed.* = receiver;
                return .{ .call = .{ .receiver = boxed, .method = name, .args = args } };
            }
        }
        return .unknown;
    }

    fn property(r: *Reader, v: Value, name: []const u8) Value {
        if (v == .array and std.mem.eql(u8, name, "length")) return .{ .number = std.fmt.allocPrint(r.a, "{d}", .{v.array.len}) catch return .unknown };
        return switch (v) {
            .object => |fields| for (fields) |f| {
                if (std.mem.eql(u8, f.key, name)) break f.value;
            } else .undefined,
            // `<call>.epochNanoseconds`: kept as the call, read by sameValue.
            .call => v,
            else => .unknown,
        };
    }

    // Statements.

    fn statements(r: *Reader, until_close: bool) Allocator.Error!void {
        while (r.peek().tag != .end) {
            if (until_close and r.is("}")) return;
            const before = r.at;
            try r.statement();
            // A stray closing bracket is past every statement: step over it.
            if (r.at == before) r.at += 1;
        }
    }

    fn statement(r: *Reader) Allocator.Error!void {
        const t = r.peek();
        if (t.tag == .identifier and (std.mem.eql(u8, t.text, "const") or std.mem.eql(u8, t.text, "let") or std.mem.eql(u8, t.text, "var"))) {
            r.at += 1;
            while (true) {
                try r.declaration();
                if (!r.eat(",")) break;
            }
            _ = r.eat(";");
            return;
        }
        if (t.tag == .identifier and std.mem.eql(u8, t.text, "for")) return r.forOf();
        if (t.tag == .identifier and std.mem.eql(u8, t.text, "TemporalHelpers") and r.peekAt(1).tag == .punct and std.mem.eql(u8, r.peekAt(1).text, ".")) {
            const name = r.peekAt(2).text;
            if (std.mem.startsWith(u8, name, "assert") and r.peekAt(3).tag == .punct and std.mem.eql(u8, r.peekAt(3).text, "(")) {
                r.at += 3;
                const args = try r.arguments();
                _ = r.eat(";");
                return r.helper(name, args);
            }
        }
        if (t.tag == .identifier and std.mem.eql(u8, t.text, "assert")) {
            // `assert(a.equals(b))`: a case of a equal to b.
            if (r.peekAt(1).tag == .punct and std.mem.eql(u8, r.peekAt(1).text, "(")) {
                r.at += 1;
                const args = try r.arguments();
                _ = r.eat(";");
                if (args.len > 0) try r.equalsCase(args[0]);
                return;
            }
            if (r.peekAt(2).tag == .identifier and std.mem.eql(u8, r.peekAt(2).text, "throws")) return r.throws();
            if (r.peekAt(2).tag == .identifier and std.mem.eql(u8, r.peekAt(2).text, "sameValue")) {
                r.at += 3;
                const args = try r.arguments();
                _ = r.eat(";");
                return r.sameValue(args);
            }
        }
        if (r.is("{")) {
            r.at += 1;
            const depth = r.scope.items.len;
            try r.statements(true);
            _ = r.eat("}");
            r.scope.shrinkRetainingCapacity(depth);
            return;
        }
        // `name.key = <expression>;`: an object binding takes the field; any other, unknown.
        if (t.tag == .identifier and r.peekAt(1).tag == .punct and std.mem.eql(u8, r.peekAt(1).text, ".") and
            r.peekAt(2).tag == .identifier and r.peekAt(3).tag == .punct and std.mem.eql(u8, r.peekAt(3).text, "="))
        {
            const key = r.peekAt(2).text;
            r.at += 4;
            const value = try r.expression();
            _ = r.eat(";");
            const updated: Value = switch (r.lookup(t.text)) {
                .object => |fields| blk: {
                    var list: std.ArrayList(Field) = .empty;
                    var replaced = false;
                    for (fields) |f| {
                        if (std.mem.eql(u8, f.key, key)) {
                            try list.append(r.a, .{ .key = key, .value = value });
                            replaced = true;
                        } else try list.append(r.a, f);
                    }
                    if (!replaced) try list.append(r.a, .{ .key = key, .value = value });
                    break :blk .{ .object = list.items };
                },
                else => .unknown,
            };
            try r.scope.append(r.a, .{ .name = t.text, .value = updated });
            return;
        }
        // `name = <expression>;`: the binding takes the new value.
        if (t.tag == .identifier and r.peekAt(1).tag == .punct and std.mem.eql(u8, r.peekAt(1).text, "=")) {
            r.at += 2;
            const value = try r.expression();
            _ = r.eat(";");
            try r.scope.append(r.a, .{ .name = t.text, .value = value });
            return;
        }
        // `[...].forEach((row) => { ... })`.
        if (r.is("[")) {
            const start = r.at;
            const table = try r.array();
            if (r.is(".") and std.mem.eql(u8, r.peekAt(1).text, "forEach")) {
                r.at += 2;
                return r.forEachOf(table);
            }
            r.at = start;
        }
        // `table.forEach((row) => { ... })`.
        if (t.tag == .identifier and r.peekAt(1).tag == .punct and std.mem.eql(u8, r.peekAt(1).text, ".") and std.mem.eql(u8, r.peekAt(2).text, "forEach")) {
            return r.forEach();
        }
        r.skipStatement();
    }

    fn declaration(r: *Reader) Allocator.Error!void {
        if (r.is("[")) {
            const pattern_at = r.at;
            r.skipBalanced();
            if (!r.eat("=")) return;
            const value = try r.expression();
            const end = r.at;
            r.at = pattern_at;
            try r.destructure(value);
            r.at = end;
            return;
        }
        if (r.is("{")) {
            r.skipBalanced();
            if (r.eat("=")) _ = try r.expression();
            return;
        }
        const name = r.peek().text;
        r.at += 1;
        const value: Value = if (r.eat("=")) try r.expression() else .undefined;
        try r.scope.append(r.a, .{ .name = name, .value = value });
    }

    /// Binds an array pattern at the cursor (`[a, b = 0, ...rest]`) to `value`, the cursor after it.
    fn destructure(r: *Reader, value: Value) Allocator.Error!void {
        const items: []const Value = switch (value) {
            .array => |x| x,
            else => &.{},
        };
        _ = r.eat("[");
        var i: usize = 0;
        while (!r.is("]") and r.peek().tag != .end) : (i += 1) {
            if (r.is(",")) {
                r.at += 1;
                continue;
            }
            if (r.eat("...")) {
                const name = r.peek().text;
                r.at += 1;
                try r.scope.append(r.a, .{ .name = name, .value = if (value == .array) .{ .array = items[@min(i, items.len)..] } else .unknown });
                break;
            }
            if (r.is("[")) {
                try r.destructure(if (i < items.len) items[i] else .unknown);
            } else {
                const name = r.peek().text;
                r.at += 1;
                var v: Value = if (value != .array) .unknown else if (i < items.len) items[i] else .undefined;
                if (r.eat("=")) {
                    const default = try r.expression();
                    if (v == .undefined) v = default;
                }
                try r.scope.append(r.a, .{ .name = name, .value = v });
            }
            if (!r.eat(",")) break;
        }
        _ = r.eat("]");
    }

    /// `for (let i = a; i < b; i++) <body>`, `a` and `b` integers or an array's length: the body
    /// read once per value of `i`.
    fn forCount(r: *Reader) Allocator.Error!bool {
        const start = r.at;
        if (!(r.eat("let") or r.eat("var"))) return false;
        const name = r.peek().text;
        r.at += 1;
        if (!r.eat("=")) {
            r.at = start;
            return false;
        }
        const from = try r.expression();
        const ok_head = r.eat(";") and r.eat(name) and r.eat("<");
        const to = if (ok_head) try r.expression() else Value.unknown;
        const ok_tail = r.eat(";") and r.eat(name) and r.eat("++") and r.eat(")");
        if (!ok_head or !ok_tail or from != .number or to != .number) {
            r.at = start;
            return false;
        }
        const low = std.fmt.parseInt(i64, from.number, 10) catch return false;
        const high = std.fmt.parseInt(i64, to.number, 10) catch return false;
        const body_at = r.at;
        r.skipBody();
        const end = r.at;
        var i = low;
        while (i < high and i - low < 1000) : (i += 1) {
            const depth = r.scope.items.len;
            try r.scope.append(r.a, .{ .name = name, .value = .{ .number = try std.fmt.allocPrint(r.a, "{d}", .{i}) } });
            r.at = body_at;
            try r.body();
            r.scope.shrinkRetainingCapacity(depth);
        }
        r.at = end;
        return true;
    }

    /// `for (const <pattern> of <table>) <body>`: the body read once per row.
    fn forOf(r: *Reader) Allocator.Error!void {
        r.at += 1;
        if (!r.eat("(")) return r.skipStatement();
        if (try r.forCount()) return;
        _ = r.eat("const") or r.eat("let") or r.eat("var");
        const pattern_at = r.at;
        if (r.is("[")) r.skipBalanced() else r.at += 1;
        if (!r.eat("of")) {
            r.at = pattern_at;
            r.at -= 1;
            while (!r.is("(")) r.at -= 1;
            r.skipBalanced();
            r.skipBody();
            return;
        }
        const table = try r.expression();
        _ = r.eat(")");
        const body_at = r.at;
        r.skipBody();
        const end = r.at;
        if (table == .array) for (table.array) |row| {
            const depth = r.scope.items.len;
            r.at = pattern_at;
            try r.bindParameter(row);
            r.at = body_at;
            try r.body();
            r.scope.shrinkRetainingCapacity(depth);
        };
        r.at = end;
    }

    fn bindParameter(r: *Reader, row: Value) Allocator.Error!void {
        if (r.is("[")) return r.destructure(row);
        const name = r.peek().text;
        r.at += 1;
        try r.scope.append(r.a, .{ .name = name, .value = row });
    }

    fn skipBody(r: *Reader) void {
        if (r.is("{")) r.skipBalanced() else r.skipStatement();
    }

    fn body(r: *Reader) Allocator.Error!void {
        if (r.eat("{")) {
            try r.statements(true);
            _ = r.eat("}");
        } else if (r.peek().tag == .identifier and (std.mem.eql(u8, r.peek().text, "TemporalHelpers") or std.mem.eql(u8, r.peek().text, "assert"))) {
            try r.statement();
        } else {
            r.skipStatement();
        }
    }

    /// `table.forEach((<pattern>) => <body>)`.
    fn forEach(r: *Reader) Allocator.Error!void {
        const table = r.lookup(r.peek().text);
        r.at += 3;
        return r.forEachOf(table);
    }

    /// The `(callback)` of a `forEach` over `table`, the cursor at its `(`.
    fn forEachOf(r: *Reader, table: Value) Allocator.Error!void {
        if (!r.eat("(")) return r.skipStatement();
        // `function (row) { ... }`, as an arrow function.
        const old_style = r.eat("function");
        const open = r.eat("(");
        const pattern_at = r.at;
        if (r.is("[")) r.skipBalanced() else r.at += 1;
        // A second parameter (the index) is passed over.
        if (r.eat(",")) r.at += 1;
        if (open) _ = r.eat(")");
        if (!(old_style and r.is("{")) and !r.eat("=>")) {
            r.at = pattern_at;
            while (!r.is(";") and r.peek().tag != .end) {
                if (r.is("(") or r.is("{") or r.is("[")) r.skipBalanced() else r.at += 1;
            }
            _ = r.eat(";");
            return;
        }
        const body_at = r.at;
        if (r.is("{")) r.skipBalanced() else {
            _ = try r.expression();
        }
        const end = r.at;
        if (table == .array) for (table.array) |row| {
            const depth = r.scope.items.len;
            r.at = pattern_at;
            try r.bindParameter(row);
            r.at = body_at;
            if (r.is("{")) {
                try r.body();
            } else {
                // An expression body: one assertion.
                try r.statement();
            }
            r.scope.shrinkRetainingCapacity(depth);
        };
        r.at = end;
        _ = r.eat(")");
        _ = r.eat(";");
    }

    // Assertions.

    fn record(r: *Reader, value: Value, expect: Expect) Allocator.Error!void {
        // `Temporal.<Type>.from(x)` is a call too: of the type itself.
        const call: Value = switch (value) {
            .temporal => |t| if (std.mem.eql(u8, t.make, "from")) blk: {
                const type_value = try r.a.create(Value);
                type_value.* = .{ .temporal = .{ .type = t.type, .make = "type", .args = &.{} } };
                break :blk .{ .call = .{ .receiver = type_value, .method = "from", .args = t.args } };
            } else return,
            else => value,
        };
        if (call != .call) return;
        if (!known(call)) return;
        try r.cases.append(r.a, .{ .path = r.path, .call = call.call, .expect = expect });
    }

    fn helper(r: *Reader, name: []const u8, args: []const Value) Allocator.Error!void {
        // Two instants or zoned values equal: the second, made from its nanoseconds, gives them.
        if ((std.mem.eql(u8, name, "assertZonedDateTimesEqual") or std.mem.eql(u8, name, "assertInstantsEqual")) and args.len >= 2) {
            switch (args[1]) {
                .temporal => |t| if (std.mem.eql(u8, t.make, "new") and t.args.len > 0 and t.args[0] == .bigint) {
                    try r.record(args[0], .{ .epoch_ns = t.args[0].bigint });
                    return;
                },
                else => {},
            }
        }
        // Two values equal: the second, whatever it is, gives the first.
        const equals = [_][]const u8{ "assertDurationsEqual", "assertPlainDatesEqual", "assertPlainDateTimesEqual", "assertPlainTimesEqual", "assertZonedDateTimesEqual", "assertInstantsEqual" };
        if (isOneOf(name, &equals) and args.len >= 2) {
            if (known(args[1]) and (args[1] == .call or args[1] == .temporal)) try r.record(args[0], .{ .equal = args[1] });
            return;
        }
        const kinds = [_][]const u8{ "assertDuration", "assertPlainDate", "assertPlainDateTime", "assertPlainTime" };
        if (!isOneOf(name, &kinds) or args.len < 2) return;
        var values: std.ArrayList([]const u8) = .empty;
        for (args[1..], 1..) |v, i| switch (v) {
            .number => |n| try values.append(r.a, n),
            // The month code, and the message.
            .string => {},
            .undefined => break,
            // The last argument is the message, whatever it is; a field this reader cannot evaluate
            // drops the case.
            else => if (i == args.len - 1) break else return,
        };
        try r.record(args[0], .{ .fields = .{ .kind = name, .values = values.items } });
    }

    /// `a.equals(b)` asserted true: a case of `a` whose value is `b`'s.
    fn equalsCase(r: *Reader, v: Value) Allocator.Error!void {
        if (v != .call or !std.mem.eql(u8, v.call.method, "equals") or v.call.args.len < 1) return;
        const other = v.call.args[0];
        if (known(other) and (other == .call or other == .temporal)) try r.record(v.call.receiver.*, .{ .equal = other });
    }

    fn sameValue(r: *Reader, args: []const Value) Allocator.Error!void {
        if (args.len < 2) return;
        if (args[1] == .boolean and args[1].boolean) return r.equalsCase(args[0]);
        switch (args[1]) {
            .bigint => |n| try r.record(args[0], .{ .epoch_ns = n }),
            .number => |n| if (args[0] == .call and std.mem.eql(u8, args[0].call.method, "total")) try r.record(args[0], .{ .number = n }),
            else => {},
        }
    }

    /// `assert.throws(RangeError, () => <call>)`.
    fn throws(r: *Reader) Allocator.Error!void {
        const start = r.at;
        r.at += 3;
        _ = r.eat("(");
        if (!r.eat("RangeError") or !r.eat(",")) {
            r.at = start;
            return r.skipStatement();
        }
        var call: Value = .unknown;
        const old_style = r.eat("function");
        if (r.eat("(") and r.eat(")") and (old_style or r.eat("=>"))) {
            // A block of one expression statement is that expression.
            if (r.eat("{")) {
                call = try r.expression();
                _ = r.eat(";");
                if (!r.is("}")) call = .unknown;
            } else call = try r.expression();
        }
        r.at = start;
        r.skipStatement();
        try r.record(call, .throws);
    }
};

/// Whether a value was evaluated through: no unknown anywhere in it.
fn known(v: Value) bool {
    return switch (v) {
        .unknown => false,
        .array => |items| for (items) |x| {
            if (!known(x)) break false;
        } else true,
        .object => |fields| for (fields) |f| {
            if (!known(f.value)) break false;
        } else true,
        .temporal => |t| for (t.args) |x| {
            if (!known(x)) break false;
        } else true,
        .call => |c| known(c.receiver.*) and for (c.args) |x| {
            if (!known(x)) break false;
        } else true,
        else => true,
    };
}

// Writing.

fn writeString(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\t' => try w.writeAll("\\t"),
        0...8, 11, 12, 14...31 => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

fn writeValue(w: *std.Io.Writer, v: Value) std.Io.Writer.Error!void {
    switch (v) {
        .string => |s| try writeString(w, s),
        .number => |n| try w.print("{{\"number\":\"{s}\"}}", .{n}),
        .bigint => |n| try w.print("{{\"bigint\":\"{s}\"}}", .{n}),
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .undefined => try w.writeAll("null"),
        .array => |items| {
            try w.writeByte('[');
            for (items, 0..) |x, i| {
                if (i > 0) try w.writeByte(',');
                try writeValue(w, x);
            }
            try w.writeByte(']');
        },
        .object => |fields| {
            try w.writeAll("{\"object\":{");
            for (fields, 0..) |f, i| {
                if (i > 0) try w.writeByte(',');
                try writeString(w, f.key);
                try w.writeByte(':');
                try writeValue(w, f.value);
            }
            try w.writeAll("}}");
        },
        .temporal => |t| {
            try w.print("{{\"temporal\":\"{s}\",\"make\":\"{s}\",\"args\":", .{ t.type, t.make });
            try writeValue(w, .{ .array = t.args });
            try w.writeByte('}');
        },
        .call => |c| {
            try w.writeAll("{\"receiver\":");
            try writeValue(w, c.receiver.*);
            try w.print(",\"method\":\"{s}\",\"args\":", .{c.method});
            try writeValue(w, .{ .array = c.args });
            try w.writeByte('}');
        },
        .unknown => unreachable,
    }
}

fn writeCase(w: *std.Io.Writer, c: Case) std.Io.Writer.Error!void {
    try w.writeAll("{\"path\":");
    try writeString(w, c.path);
    try w.writeAll(",\"call\":");
    try writeValue(w, .{ .call = c.call });
    try w.writeAll(",\"expect\":");
    switch (c.expect) {
        .throws => try w.writeAll("\"throws\""),
        .equal => |v| {
            try w.writeAll("{\"equal\":");
            try writeValue(w, v);
            try w.writeByte('}');
        },
        .fields => |f| {
            try w.print("{{\"kind\":\"{s}\",\"fields\":[", .{f.kind});
            for (f.values, 0..) |x, i| {
                if (i > 0) try w.writeByte(',');
                try w.writeAll(x);
            }
            try w.writeAll("]}");
        },
        .epoch_ns => |n| try w.print("{{\"epoch_ns\":\"{s}\"}}", .{n}),
        .number => |n| try w.print("{{\"number\":\"{s}\"}}", .{n}),
    }
    try w.writeByte('}');
}

/// Why a file gave no case. A file of JavaScript's object protocol (property and getter
/// observation, the order options are read in, TypeError for JavaScript types, prototypes and
/// descriptors, functions as options, calendar eras) asks nothing of a Zig API; any other file is
/// applicable, and unread.
fn classify(name: []const u8, body: []const u8) []const u8 {
    const protocol_names = [_][]const u8{
        "wrong-type",          "nan",             "non-integer", "infinity",       "undefined",                 "observable",    "order-of-operations", "order",
        "prop-desc",           "length.js",       "name.js",     "builtin",        "not-a-constructor",         "subclass",      "branding",            "get-property",
        "prototype-pollution", "may-be-function", "tostring",    "valueof",        "era",                       "proto",         "non-object",          "primitive",
        "argument-number",     "argument-object", "-object.js",  "options-object", "precision-exact-numerical", "negative-zero",
    };
    for (protocol_names) |p| if (std.mem.find(u8, name, p) != null) return "not applicable: JavaScript's object protocol";
    // "years" and "year" naming one option: almanac takes a `Unit`.
    if (std.mem.find(u8, name, "plurals-accepted") != null) return "not applicable: unit names as JavaScript strings";
    const protocol_body = [_][]const u8{
        "Object.defineProperty", "Symbol",              "Proxy",                            "getOwnPropertyDescriptor",         ".prototype",    "Reflect.",       "observeProperty",
        "propertyBagObserver",   "compareArray(actual", "checkSubclass",                    "getPrototypeOf",                   "isConstructor", "verifyProperty", ".call(",
        "valueOf",               "toString()",          "TemporalHelpers.calendarObserver", "TemporalHelpers.timeZoneObserver",
    };
    for (protocol_body) |p| if (std.mem.find(u8, body, p) != null) return "not applicable: JavaScript's object protocol";
    const range_error = std.mem.find(u8, body, "RangeError") != null;
    const asserts = std.mem.find(u8, body, "sameValue") != null or std.mem.find(u8, body, "TemporalHelpers.assert") != null;
    if (std.mem.find(u8, body, "TypeError") != null and !range_error and !asserts) return "not applicable: a TypeError for a JavaScript type";
    return "applicable, unread";
}

/// The directories read: each type's `from` and its arithmetic.
const directories = [_][]const u8{ "from", "prototype/until", "prototype/since", "prototype/round", "prototype/add", "prototype/subtract", "prototype/total" };

/// The cases of every file read, one per line, with the files that gave none.
pub fn transcribe(gpa: Allocator, io: std.Io, root: std.Io.Dir, commit: []const u8) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var cases: std.ArrayList(Case) = .empty;
    const Unread = struct { path: []const u8, why: []const u8 };
    var none: std.ArrayList(Unread) = .empty;
    var read: usize = 0;
    for (types) |ty| for (directories) |sub| {
        const dir_path = try std.fmt.allocPrint(a, "test/built-ins/Temporal/{s}/{s}", .{ ty, sub });
        var dir = root.openDir(io, dir_path, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var names: std.ArrayList([]const u8) = .empty;
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".js")) try names.append(a, try a.dupe(u8, entry.name));
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn less(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.order(u8, x, y) == .lt;
            }
        }.less);
        for (names.items) |name| {
            read += 1;
            const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ dir_path, name });
            const src = try dir.readFileAlloc(io, name, a, .limited(1 << 20));
            const body_start = if (std.mem.find(u8, src, "---*/")) |e| e + 5 else 0;
            var lexer: Lexer = .{ .a = a, .src = src[body_start..] };
            var tokens: std.ArrayList(Token) = .empty;
            while (true) {
                const t = try lexer.next();
                try tokens.append(a, t);
                if (t.tag == .end) break;
            }
            const before = cases.items.len;
            var r: Reader = .{ .a = a, .tokens = tokens.items, .cases = &cases, .path = path };
            try r.statements(false);
            if (cases.items.len == before) try none.append(a, .{ .path = path, .why = classify(name, src[body_start..]) });
        }
    };
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.print("{{\"commit\":\"{s}\",\"files_read\":{d},\"cases\":[\n", .{ commit, read });
    // One case per call and expectation: a loop may repeat one.
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var first = true;
    for (cases.items) |c| {
        var line: std.Io.Writer.Allocating = .init(a);
        try writeCase(&line.writer, c);
        const key = line.written();
        if ((try seen.getOrPut(a, key)).found_existing) continue;
        if (!first) try w.writeAll(",\n");
        first = false;
        try w.writeAll(key);
    }
    try w.writeAll("\n],\"files_without_cases\":[\n");
    for (none.items, 0..) |p, i| {
        if (i > 0) try w.writeAll(",\n");
        try w.writeAll("{\"path\":");
        try writeString(w, p.path);
        try w.writeAll(",\"why\":");
        try writeString(w, p.why);
        try w.writeByte('}');
    }
    try w.writeAll("\n]}\n");
    return out.toOwnedSlice();
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const args = try init.minimal.args.toSlice(arena.allocator());
    if (args.len != 4) {
        std.debug.print("usage: test262 <test262 checkout> <commit> <output directory>\n", .{});
        std.process.exit(2);
    }
    var root = try std.Io.Dir.cwd().openDir(io, args[1], .{});
    defer root.close(io);
    const json = try transcribe(gpa, io, root, args[2]);
    defer gpa.free(json);
    var out = try std.Io.Dir.cwd().openDir(io, args[3], .{});
    defer out.close(io);
    try out.writeFile(io, .{ .sub_path = "temporal.json", .data = json });
}
