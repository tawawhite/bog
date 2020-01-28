const std = @import("std");
const mem = std.mem;
const tokenizer = @import("tokenizer.zig");
const Token = tokenizer.Token;
const TokenList = tokenizer.TokenList;
const TokenIndex = tokenizer.TokenIndex;
const Allocator = mem.Allocator;
const TypeId = @import("value.zig").TypeId;
const ast = @import("ast.zig");
const Node = ast.Node;

pub const Compiler = struct {
    builder: *Builder,
    tokens: TokenList,

    const Value = union(enum) {
        /// result of continue, break, return and assignmnet; cannot exist at runtime
        Empty,
        Rt: RegRef,

        None,
        Int: i64,
        Num: f64,
        Bool: bool,
        Str: []const u8,
    };

    fn makeRuntime(self: *Compiler, res: RegRef, val: Value) !void {
        return switch (val) {
            .Empty => unreachable,
            .Rt => |v| {
                std.debug.assert(v == res);
                return v;
            },
            .None => try self.builder.constNone(res),
            .Int => |v| try self.builder.constInt(res, v),
            .Num => |v| try self.builder.constNum(res, v),
            .Bool => |v| try self.builder.constBool(res, v),
            .Str => |v| try self.builder.constStr(res, v),
        };
    }

    const Result = union(enum) {
        Rt: RegRef,
        Lval,
        Value,
        Discarded,
    };

    fn genNode(self: *Compiler, node: *Node, res: *Result) !Value {
        switch (node.id) {
            .Grouped => try self.genNode(@fieldParentPtr(Node.Grouped, "base", node).expr, res),
            .Literal => try self.genLiteral(@fieldParentPtr(Node.Literal, "base", node), res),
            .Block => try self.genBlock(@fieldParentPtr(Node.ListTupleMapBlock, "base", node), res),
            .Prefix => try self.genPrefix(@fieldParentPtr(Node.Prefix, "base", node), res),
            .Let => @panic("TODO: Let"),
            .Fn => @panic("TODO: Fn"),
            .Identifier => @panic("TODO: Identifier"),
            .Prefix => @panic("TODO: Prefix"),
            .Infix => @panic("TODO: Infix"),
            .TypeInfix => @panic("TODO: TypeInfix"),
            .Suffix => @panic("TODO: Suffix"),
            .Import => @panic("TODO: Import"),
            .Error => @panic("TODO: Error"),
            .List => @panic("TODO: List"),
            .Tuple => @panic("TODO: Tuple"),
            .Map => @panic("TODO: Map"),
            .Catch => @panic("TODO: Catch"),
            .If => @panic("TODO: If"),
            .For => @panic("TODO: For"),
            .While => @panic("TODO: While"),
            .Match => @panic("TODO: Match"),
            .Jump => @panic("TODO: Jump"),
            .MapItem,
            .MatchCatchAll,
            .MatchLet,
            .MatchCase,
            .Unwrap,
            .Discard,
            => unreachable,
        }
    }

    fn genBlock(self: *Compiler, node: *Node.ListTupleMapBlock, res: Result) !Value {
        if (res == .Lval) {
            // try adderr("cannot assign to block")
            return error.CompileError;
        }
        var it = node.values.iterator(0);
        while (it.next()) |n| {
            if (it.peek() == null) {
                return self.genNode(n, res);
            }
            try self.genNode(n, Result.Discarded);
        }
    }

    fn errIfEmpty(self: *Compiler, val: Value) !void {
        if (val == .Empty) {
            // try adderr("expected value")
            return error.CompileError;
        }
    }

    fn genPrefix(self: *Compiler, node: *Node.Prefix, res: *Result) !Value {
        if (res == .Lval) {
            // try adderr("cannot assign to expression")
            return error.CompileError;
        }
        const r_val = try self.genNode(node.rhs, Result.Value);
        try self.handleEmpty(r_val);
        if (r_val == .Rt) {
            const result_loc = if (res == .Rt) res.Rt else @panic("TODO: create result loc");
            return Value{ .Rt = self.builder.prefix(result_loc, node.op, r_val.Rt) };
        }
        const ret_val = switch (node.op) {
            .BoolNot => blk: {
                // TODO try self.ensureBoolean(r_val);
                break :blk Value{.Bool = !r_val.Bool};
            },
            .BitNot => blk: {
                // TODO try self.ensureInteger(r_val);
                break :blk Value{.Int = ~r_val.Int};
            },
            .Minus => blk: {
                // TODO try self.ensureNumeric(r_val);
                if (r_val == .Int) {
                    break :blk Value{.Int -r_val.Int};
                } else {
                    break :blk Value{.Num -r_val.Num};
                }
            },
            .Plus => blk: {
                // TODO try self.ensureNumeric(r_val);
                break :blk r_val;
            },
            // errors are runtime only currently, so ret_val does not need to be checked
            .Try => ret_val,
        };
        if (res == .Rt) {
            return Value{ .Rt = self.makeRuntime(ret_val) };
        }
        // if res == .Discard or .Value nothing needs to be done
        return ret_val;
    }

    fn genLiteral(self: *Compiler, node: *Node.Literal, res: *Result) !Value {
        switch (res) {
            .Lval => {
                // try adderr("cannot assign to literal")
                return error.CompileError;
            },
            .Some => return switch (node.kind) {
                .Int => .{ .Int = try self.parseInt(node.tok) },
                .True => .{ .Bool = true },
                .False => .{ .Bool = false },
                .None => Value.None,
                .Str => @panic("TODO: genStr"),
                .Num => @panic("TODO: genNum"),
            },
            .None => {
                // literal not used
            },
        }
    }

    fn tokenSlice(self: *Compiler, token: TokenIndex) Token.Id {
        const tok = self.tokens.at(token);
        return self.source[tok.start..tok.end];
    }

    fn parseInt(self: *Compiler, tok: TokenIndex) !i64 {
        var buf = self.tokenSlice(tok);
        var radix: u8 = if (buf.len > 2) switch (buf[2]) {
            'x' => 16,
            'b' => 2,
            'o' => 8,
            else => 10,
        } else 10;
        if (radix != 10) buf = buf[2..];
        var x: i64 = 0;

        for (buf) |c| {
            const digit = switch (c) {
                '0'...'9' => c - '0',
                'A'...'Z' => c - 'A' + 10,
                'a'...'z' => c - 'a' + 10,
                '_' => continue,
                else => unreachable,
            };

            x = math.mul(i64, x, radix) catch {
                // try self.adderr();
                return error.CompileError;
            };
            x += digit;
        }

        return x;
    }
};
