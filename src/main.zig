const std = @import("std");

// === Value ===
const Value = union(enum) {
    int: i64,
    float: f64,
    string: []const u8,

    pub fn format(self: Value, writer: anytype) !void {
        switch (self) {
            .int => |v| {
                var num_buf: [32]u8 = undefined;
                const s = formatInt(v, &num_buf);
                try writer.writeAll(s);
            },
            .float => |v| {
                var num_buf: [64]u8 = undefined;
                const s = formatFloat(v, &num_buf);
                try writer.writeAll(s);
            },
            .string => |v| {
                try writer.writeAll("\"");
                try writer.writeAll(v);
                try writer.writeAll("\"");
            },
        }
    }
};

// === Stack ===
const Stack = struct {
    items: [256]Value = undefined,
    top: usize = 0,

    pub fn push(self: *Stack, val: Value) !void {
        if (self.top >= 256) return error.StackOverflow;
        self.items[self.top] = val;
        self.top += 1;
    }

    pub fn pop(self: *Stack) !Value {
        if (self.top == 0) return error.StackUnderflow;
        self.top -= 1;
        return self.items[self.top];
    }

    pub fn peek(self: *Stack) !Value {
        if (self.top == 0) return error.StackUnderflow;
        return self.items[self.top - 1];
    }

    pub fn depth(self: *Stack) usize {
        return self.top;
    }

    pub fn display(self: *Stack, writer: anytype) !void {
        try writer.writeAll("<");
        var num_buf: [32]u8 = undefined;
        const s = formatUint(self.top, &num_buf);
        try writer.writeAll(s);
        try writer.writeAll("> ");
        for (self.items[0..self.top]) |item| {
            try item.format(writer);
            try writer.writeAll(" ");
        }
    }
};

// === Dictionary ===
const MAX_WORDS = 256;
const MAX_BODY_TOKENS = 4096;

const Word = struct {
    name: []const u8,
    body: []const []const u8, // slice into token pool
};

const Dictionary = struct {
    // Storage for word names
    name_buf: [8192]u8 = undefined,
    name_pos: usize = 0,

    // Storage for token strings
    token_buf: [32768]u8 = undefined,
    token_pos: usize = 0,

    // Token slice pool: stores start/len pairs
    token_slices: [MAX_BODY_TOKENS]TokenSlice = undefined,
    token_slice_pos: usize = 0,

    // Words
    words: [MAX_WORDS]StoredWord = undefined,
    count: usize = 0,

    const TokenSlice = struct { start: usize, len: usize };

    const StoredWord = struct {
        name_start: usize,
        name_len: usize,
        body_start: usize, // index into token_slices
        body_len: usize, // number of tokens
    };

    pub fn define(self: *Dictionary, name: []const u8, tokens: []const []const u8) !void {
        if (self.count >= MAX_WORDS) return error.DictionaryFull;

        // Check for redefinition - overwrite if exists
        for (self.words[0..self.count]) |*w| {
            const existing_name = self.name_buf[w.name_start .. w.name_start + w.name_len];
            if (std.mem.eql(u8, existing_name, name)) {
                // Overwrite body (old body space is wasted but that's ok)
                w.body_start = self.token_slice_pos;
                w.body_len = tokens.len;
                for (tokens) |tok| {
                    try self.storeToken(tok);
                }
                return;
            }
        }

        // Store name
        if (self.name_pos + name.len > self.name_buf.len) return error.DictionaryFull;
        const name_start = self.name_pos;
        @memcpy(self.name_buf[self.name_pos .. self.name_pos + name.len], name);
        self.name_pos += name.len;

        // Store body tokens
        const body_start = self.token_slice_pos;
        for (tokens) |tok| {
            try self.storeToken(tok);
        }

        self.words[self.count] = StoredWord{
            .name_start = name_start,
            .name_len = name.len,
            .body_start = body_start,
            .body_len = tokens.len,
        };
        self.count += 1;
    }

    fn storeToken(self: *Dictionary, tok: []const u8) !void {
        if (self.token_slice_pos >= MAX_BODY_TOKENS) return error.DictionaryFull;
        if (self.token_pos + tok.len > self.token_buf.len) return error.DictionaryFull;

        const start = self.token_pos;
        @memcpy(self.token_buf[self.token_pos .. self.token_pos + tok.len], tok);
        self.token_pos += tok.len;

        self.token_slices[self.token_slice_pos] = TokenSlice{ .start = start, .len = tok.len };
        self.token_slice_pos += 1;
    }

    pub fn find(self: *Dictionary, name: []const u8) ?[]const TokenSlice {
        // Search backwards (latest definition wins)
        var i: usize = self.count;
        while (i > 0) {
            i -= 1;
            const w = self.words[i];
            const wname = self.name_buf[w.name_start .. w.name_start + w.name_len];
            if (std.mem.eql(u8, wname, name)) {
                return self.token_slices[w.body_start .. w.body_start + w.body_len];
            }
        }
        return null;
    }

    pub fn getTokenStr(self: *Dictionary, ts: TokenSlice) []const u8 {
        return self.token_buf[ts.start .. ts.start + ts.len];
    }

    pub fn listWords(self: *Dictionary, writer: anytype) !void {
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const w = self.words[i];
            try writer.writeAll(self.name_buf[w.name_start .. w.name_start + w.name_len]);
            try writer.writeAll(" ");
        }
        if (self.count > 0) try writer.writeAll("\n");
    }
};

// === Interpreter ===
const LoopFrame = struct {
    index: i64,
    limit: i64,
};

const Interpreter = struct {
    stack: Stack = Stack{},
    dict: Dictionary = Dictionary{},
    string_buf: [4096]u8 = undefined,
    string_pos: usize = 0,
    stdout: std.fs.File,
    call_depth: usize = 0,
    compile_buf: [4096]u8 = undefined,
    loop_stack: [32]LoopFrame = undefined,
    loop_depth: usize = 0,
    // Multi-line word definition state
    compiling: bool = false,
    compile_name: [64]u8 = undefined,
    compile_name_len: usize = 0,
    compile_tokens: [256][]const u8 = undefined,
    compile_tok_count: usize = 0,
    compile_line_buf: [8192]u8 = undefined,
    compile_line_pos: usize = 0,
    const MAX_CALL_DEPTH = 64;

    pub fn init(stdout: std.fs.File) Interpreter {
        return Interpreter{ .stdout = stdout };
    }

    pub fn execLine(self: *Interpreter, line: []const u8) !bool {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0) return true;

        // If we're in the middle of compiling a multi-line word
        if (self.compiling) {
            return self.compileAddLine(trimmed);
        }

        // Check for word definition start: : name ...
        if (trimmed.len >= 1 and trimmed[0] == ':') {
            return self.compileStart(trimmed);
        }

        return self.execTokens(trimmed);
    }

    fn compileStart(self: *Interpreter, line: []const u8) !bool {
        // Parse ": name ..."
        var i: usize = 1; // skip ':'
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}

        const name_start = i;
        while (i < line.len and line[i] != ' ' and line[i] != '\t') : (i += 1) {}
        const name = line[name_start..i];

        if (name.len == 0) {
            try self.stdout.writeAll("error: missing word name after ':'\n");
            return true;
        }

        // Store name
        if (name.len > self.compile_name.len) {
            try self.stdout.writeAll("error: word name too long\n");
            return true;
        }
        @memcpy(self.compile_name[0..name.len], name);
        self.compile_name_len = name.len;
        self.compile_tok_count = 0;
        self.compile_line_pos = 0;
        self.compiling = true;

        // Process rest of the line
        if (i < line.len) {
            return self.compileAddLine(line[i..]);
        }
        return true;
    }

    fn compileAddLine(self: *Interpreter, line: []const u8) !bool {
        var i: usize = 0;

        while (i < line.len) {
            while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
            if (i >= line.len) break;

            // Handle ." ... "
            if (i + 1 < line.len and line[i] == '.' and line[i + 1] == '"') {
                i += 2;
                if (i < line.len and line[i] == ' ') i += 1;
                const str_start = i;
                while (i < line.len and line[i] != '"') : (i += 1) {}
                const str_content = line[str_start..i];
                if (i < line.len) i += 1;

                const prefix = "._\"";
                const suffix = "\"";
                const total = prefix.len + str_content.len + suffix.len;
                if (self.compile_line_pos + total > self.compile_line_buf.len or self.compile_tok_count >= 256) {
                    try self.stdout.writeAll("error: word body too long\n");
                    self.compiling = false;
                    return true;
                }
                const pos = self.compile_line_pos;
                @memcpy(self.compile_line_buf[pos .. pos + prefix.len], prefix);
                @memcpy(self.compile_line_buf[pos + prefix.len .. pos + prefix.len + str_content.len], str_content);
                @memcpy(self.compile_line_buf[pos + prefix.len + str_content.len .. pos + total], suffix);
                self.compile_tokens[self.compile_tok_count] = self.compile_line_buf[pos .. pos + total];
                self.compile_tok_count += 1;
                self.compile_line_pos += total;
                continue;
            }

            // Handle s" ... "
            if (i + 1 < line.len and line[i] == 's' and line[i + 1] == '"') {
                i += 2;
                if (i < line.len and line[i] == ' ') i += 1;
                const str_start = i;
                while (i < line.len and line[i] != '"') : (i += 1) {}
                const str_content = line[str_start..i];
                if (i < line.len) i += 1;

                const prefix = "s_\"";
                const suffix = "\"";
                const total = prefix.len + str_content.len + suffix.len;
                if (self.compile_line_pos + total > self.compile_line_buf.len or self.compile_tok_count >= 256) {
                    try self.stdout.writeAll("error: word body too long\n");
                    self.compiling = false;
                    return true;
                }
                const pos = self.compile_line_pos;
                @memcpy(self.compile_line_buf[pos .. pos + prefix.len], prefix);
                @memcpy(self.compile_line_buf[pos + prefix.len .. pos + prefix.len + str_content.len], str_content);
                @memcpy(self.compile_line_buf[pos + prefix.len + str_content.len .. pos + total], suffix);
                self.compile_tokens[self.compile_tok_count] = self.compile_line_buf[pos .. pos + total];
                self.compile_tok_count += 1;
                self.compile_line_pos += total;
                continue;
            }

            // Comment: backslash skips rest of line
            if (line[i] == '\\') break;

            // Paren comment: ( ... ) or (comment)
            if (line[i] == '(') {
                i += 1;
                while (i < line.len and line[i] != ')') : (i += 1) {}
                if (i < line.len) i += 1;
                continue;
            }

            const ts = i;
            while (i < line.len and line[i] != ' ' and line[i] != '\t') : (i += 1) {}
            const tok = line[ts..i];

            if (std.mem.eql(u8, tok, ";")) {
                // End of definition
                self.compiling = false;
                const name = self.compile_name[0..self.compile_name_len];
                self.dict.define(name, self.compile_tokens[0..self.compile_tok_count]) catch {
                    try self.stdout.writeAll("error: dictionary full\n");
                    return true;
                };
                return true;
            }

            // Copy token to compile buffer
            if (self.compile_line_pos + tok.len > self.compile_line_buf.len or self.compile_tok_count >= 256) {
                try self.stdout.writeAll("error: word body too long\n");
                self.compiling = false;
                return true;
            }
            const pos = self.compile_line_pos;
            @memcpy(self.compile_line_buf[pos .. pos + tok.len], tok);
            self.compile_tokens[self.compile_tok_count] = self.compile_line_buf[pos .. pos + tok.len];
            self.compile_tok_count += 1;
            self.compile_line_pos += tok.len;
        }

        return true;
    }

    fn execTokens(self: *Interpreter, text: []const u8) !bool {
        var i: usize = 0;

        while (i < text.len) {
            // Skip whitespace
            while (i < text.len and (text[i] == ' ' or text[i] == '\t')) : (i += 1) {}
            if (i >= text.len) break;

            // Comment: backslash skips rest of line
            if (text[i] == '\\') break;

            // Paren comment: ( ... ) or (comment)
            if (text[i] == '(') {
                i += 1;
                while (i < text.len and text[i] != ')') : (i += 1) {}
                if (i < text.len) i += 1;
                continue;
            }

            // String literal: ." ... "
            if (i + 1 < text.len and text[i] == '.' and text[i + 1] == '"') {
                i += 2;
                if (i < text.len and text[i] == ' ') i += 1;
                const start = i;
                while (i < text.len and text[i] != '"') : (i += 1) {}
                try self.stdout.writeAll(text[start..i]);
                if (i < text.len) i += 1;
                continue;
            }

            // String push: s" ... "
            if (i + 1 < text.len and text[i] == 's' and text[i + 1] == '"') {
                i += 2;
                if (i < text.len and text[i] == ' ') i += 1;
                const start = i;
                while (i < text.len and text[i] != '"') : (i += 1) {}
                const str = text[start..i];
                if (self.string_pos + str.len > self.string_buf.len) {
                    try self.stdout.writeAll("error: string buffer full\n");
                } else {
                    @memcpy(self.string_buf[self.string_pos .. self.string_pos + str.len], str);
                    try self.stack.push(Value{ .string = self.string_buf[self.string_pos .. self.string_pos + str.len] });
                    self.string_pos += str.len;
                }
                if (i < text.len) i += 1;
                continue;
            }

            // Regular token
            const ts = i;
            while (i < text.len and text[i] != ' ' and text[i] != '\t') : (i += 1) {}
            const token = text[ts..i];

            const should_continue = try self.execToken(token);
            if (!should_continue) return false;
        }
        return true;
    }

    fn execToken(self: *Interpreter, token: []const u8) !bool {
        // Encoded print string: ._"content"
        if (token.len >= 4 and token[0] == '.' and token[1] == '_' and token[2] == '"' and token[token.len - 1] == '"') {
            try self.stdout.writeAll(token[3 .. token.len - 1]);
            return true;
        }

        // Encoded push string: s_"content"
        if (token.len >= 4 and token[0] == 's' and token[1] == '_' and token[2] == '"' and token[token.len - 1] == '"') {
            const str = token[3 .. token.len - 1];
            if (self.string_pos + str.len > self.string_buf.len) {
                try self.stdout.writeAll("error: string buffer full\n");
            } else {
                @memcpy(self.string_buf[self.string_pos .. self.string_pos + str.len], str);
                try self.stack.push(Value{ .string = self.string_buf[self.string_pos .. self.string_pos + str.len] });
                self.string_pos += str.len;
            }
            return true;
        }

        // bye
        if (std.mem.eql(u8, token, "bye")) {
            try self.stdout.writeAll("Goodbye!\n");
            return false;
        }

        // Built-in words
        if (std.mem.eql(u8, token, ".")) {
            const val = self.stack.pop() catch {
                try self.stdout.writeAll("error: stack underflow\n");
                return true;
            };
            try val.format(self.stdout);
            try self.stdout.writeAll(" ");
        } else if (std.mem.eql(u8, token, ".s")) {
            try self.stack.display(self.stdout);
            try self.stdout.writeAll("\n");
        } else if (std.mem.eql(u8, token, "drop")) {
            _ = self.stack.pop() catch {
                try self.stdout.writeAll("error: stack underflow\n");
                return true;
            };
        } else if (std.mem.eql(u8, token, "dup")) {
            const val = self.stack.peek() catch {
                try self.stdout.writeAll("error: stack underflow\n");
                return true;
            };
            self.stack.push(val) catch {
                try self.stdout.writeAll("error: stack overflow\n");
            };
        } else if (std.mem.eql(u8, token, "swap")) {
            if (self.stack.depth() < 2) {
                try self.stdout.writeAll("error: stack underflow\n");
                return true;
            }
            const b = self.stack.pop() catch unreachable;
            const a = self.stack.pop() catch unreachable;
            self.stack.push(b) catch {};
            self.stack.push(a) catch {};
        } else if (std.mem.eql(u8, token, "over")) {
            if (self.stack.depth() < 2) {
                try self.stdout.writeAll("error: stack underflow\n");
                return true;
            }
            const b = self.stack.pop() catch unreachable;
            const a = self.stack.peek() catch unreachable;
            self.stack.push(b) catch {};
            self.stack.push(a) catch {};
        } else if (std.mem.eql(u8, token, "rot")) {
            if (self.stack.depth() < 3) {
                try self.stdout.writeAll("error: stack underflow\n");
                return true;
            }
            const c = self.stack.pop() catch unreachable;
            const b = self.stack.pop() catch unreachable;
            const a = self.stack.pop() catch unreachable;
            self.stack.push(b) catch {};
            self.stack.push(c) catch {};
            self.stack.push(a) catch {};
        } else if (std.mem.eql(u8, token, "cr")) {
            try self.stdout.writeAll("\n");
        } else if (std.mem.eql(u8, token, "clear")) {
            self.stack.top = 0;
        } else if (std.mem.eql(u8, token, ">float") or std.mem.eql(u8, token, "s>f")) {
            const val = self.stack.pop() catch {
                try self.stdout.writeAll("error: stack underflow\n");
                return true;
            };
            const f: f64 = switch (val) {
                .int => |v| @floatFromInt(v),
                .float => |v| v,
                .string => {
                    try self.stdout.writeAll("error: cannot convert string to float\n");
                    self.stack.push(val) catch {};
                    return true;
                },
            };
            self.stack.push(Value{ .float = f }) catch {};
        } else if (std.mem.eql(u8, token, "words")) {
            try self.dict.listWords(self.stdout);
        } else if (token.len == 1 and (token[0] == '+' or token[0] == '-' or token[0] == '*' or token[0] == '/')) {
            doArith(&self.stack, token[0]) catch |err| {
                switch (err) {
                    error.StackUnderflow => try self.stdout.writeAll("error: stack underflow\n"),
                    error.DivisionByZero => try self.stdout.writeAll("error: division by zero\n"),
                    error.TypeError => try self.stdout.writeAll("error: type error\n"),
                    else => try self.stdout.writeAll("error\n"),
                }
            };
        } else if (parseValue(token)) |val| {
            self.stack.push(val) catch {
                try self.stdout.writeAll("error: stack overflow\n");
            };
        } else if (self.dict.find(token)) |body| {
            // Execute user-defined word
            if (self.call_depth >= MAX_CALL_DEPTH) {
                try self.stdout.writeAll("error: call stack overflow\n");
                return true;
            }
            self.call_depth += 1;
            defer self.call_depth -= 1;

            var pc: usize = 0;
            const cont = try self.execBody(body, &pc);
            if (!cont) return false;
        } else if (std.mem.eql(u8, token, "i")) {
            if (self.loop_depth == 0) {
                try self.stdout.writeAll("error: 'i' outside loop\n");
                return true;
            }
            try self.stack.push(Value{ .int = self.loop_stack[self.loop_depth - 1].index });
        } else if (std.mem.eql(u8, token, "j")) {
            if (self.loop_depth < 2) {
                try self.stdout.writeAll("error: 'j' needs nested loop\n");
                return true;
            }
            try self.stack.push(Value{ .int = self.loop_stack[self.loop_depth - 2].index });
        } else if (std.mem.eql(u8, token, "=")) {
            try self.cmpOp(.eq);
        } else if (std.mem.eql(u8, token, "<>")) {
            try self.cmpOp(.neq);
        } else if (std.mem.eql(u8, token, "<")) {
            try self.cmpOp(.lt);
        } else if (std.mem.eql(u8, token, ">")) {
            try self.cmpOp(.gt);
        } else if (std.mem.eql(u8, token, "<=")) {
            try self.cmpOp(.le);
        } else if (std.mem.eql(u8, token, ">=")) {
            try self.cmpOp(.ge);
        } else if (std.mem.eql(u8, token, "0=")) {
            const val = self.stack.pop() catch {
                try self.stdout.writeAll("error: stack underflow\n");
                return true;
            };
            const is_zero: i64 = switch (val) {
                .int => |v| if (v == 0) @as(i64, -1) else 0,
                .float => |v| if (v == 0.0) @as(i64, -1) else 0,
                .string => 0,
            };
            self.stack.push(Value{ .int = is_zero }) catch {};
        } else if (std.mem.eql(u8, token, "not") or std.mem.eql(u8, token, "invert")) {
            const val = self.stack.pop() catch {
                try self.stdout.writeAll("error: stack underflow\n");
                return true;
            };
            switch (val) {
                .int => |v| self.stack.push(Value{ .int = if (v == 0) -1 else 0 }) catch {},
                else => {
                    try self.stdout.writeAll("error: type error\n");
                },
            }
        } else if (std.mem.eql(u8, token, "mod")) {
            const b = self.stack.pop() catch {
                try self.stdout.writeAll("error: stack underflow\n");
                return true;
            };
            const a = self.stack.pop() catch {
                try self.stdout.writeAll("error: stack underflow\n");
                return true;
            };
            if (a == .int and b == .int) {
                if (b.int == 0) {
                    try self.stdout.writeAll("error: division by zero\n");
                } else {
                    self.stack.push(Value{ .int = @mod(a.int, b.int) }) catch {};
                }
            } else {
                try self.stdout.writeAll("error: type error\n");
            }
        } else if (std.mem.eql(u8, token, "negate")) {
            const val = self.stack.pop() catch {
                try self.stdout.writeAll("error: stack underflow\n");
                return true;
            };
            switch (val) {
                .int => |v| self.stack.push(Value{ .int = -v }) catch {},
                .float => |v| self.stack.push(Value{ .float = -v }) catch {},
                .string => try self.stdout.writeAll("error: type error\n"),
            }
        } else if (std.mem.eql(u8, token, "abs")) {
            const val = self.stack.pop() catch {
                try self.stdout.writeAll("error: stack underflow\n");
                return true;
            };
            switch (val) {
                .int => |v| self.stack.push(Value{ .int = if (v < 0) -v else v }) catch {},
                .float => |v| self.stack.push(Value{ .float = if (v < 0) -v else v }) catch {},
                .string => try self.stdout.writeAll("error: type error\n"),
            }
        } else {
            try self.stdout.writeAll("unknown word: ");
            try self.stdout.writeAll(token);
            try self.stdout.writeAll("\n");
        }
        return true;
    }

    fn cmpOp(self: *Interpreter, op: enum { eq, neq, lt, gt, le, ge }) !void {
        const b = self.stack.pop() catch {
            try self.stdout.writeAll("error: stack underflow\n");
            return;
        };
        const a = self.stack.pop() catch {
            try self.stdout.writeAll("error: stack underflow\n");
            return;
        };

        // Promote to float if needed
        const result: bool = blk: {
            if (a == .string or b == .string) {
                if (a == .string and b == .string) {
                    const cmp = std.mem.order(u8, a.string, b.string);
                    break :blk switch (op) {
                        .eq => cmp == .eq,
                        .neq => cmp != .eq,
                        .lt => cmp == .lt,
                        .gt => cmp == .gt,
                        .le => cmp == .lt or cmp == .eq,
                        .ge => cmp == .gt or cmp == .eq,
                    };
                }
                try self.stdout.writeAll("error: type error\n");
                return;
            }

            if (a == .float or b == .float) {
                const fa: f64 = switch (a) {
                    .int => |v| @floatFromInt(v),
                    .float => |v| v,
                    .string => unreachable,
                };
                const fb: f64 = switch (b) {
                    .int => |v| @floatFromInt(v),
                    .float => |v| v,
                    .string => unreachable,
                };
                break :blk switch (op) {
                    .eq => fa == fb,
                    .neq => fa != fb,
                    .lt => fa < fb,
                    .gt => fa > fb,
                    .le => fa <= fb,
                    .ge => fa >= fb,
                };
            }

            const ia = a.int;
            const ib = b.int;
            break :blk switch (op) {
                .eq => ia == ib,
                .neq => ia != ib,
                .lt => ia < ib,
                .gt => ia > ib,
                .le => ia <= ib,
                .ge => ia >= ib,
            };
        };

        // Forth convention: -1 = true, 0 = false
        self.stack.push(Value{ .int = if (result) -1 else 0 }) catch {};
    }

    fn execBody(self: *Interpreter, body: []const Dictionary.TokenSlice, pc: *usize) anyerror!bool {
        while (pc.* < body.len) {
            const tok_str = self.dict.getTokenStr(body[pc.*]);
            pc.* += 1;

            // do: start a loop
            if (std.mem.eql(u8, tok_str, "do")) {
                const start_val = self.stack.pop() catch {
                    try self.stdout.writeAll("error: stack underflow\n");
                    return true;
                };
                const limit_val = self.stack.pop() catch {
                    try self.stdout.writeAll("error: stack underflow\n");
                    return true;
                };
                const start_i = switch (start_val) {
                    .int => |v| v,
                    else => {
                        try self.stdout.writeAll("error: do expects integers\n");
                        return true;
                    },
                };
                const limit_i = switch (limit_val) {
                    .int => |v| v,
                    else => {
                        try self.stdout.writeAll("error: do expects integers\n");
                        return true;
                    },
                };

                if (self.loop_depth >= 32) {
                    try self.stdout.writeAll("error: loop stack overflow\n");
                    return true;
                }

                self.loop_stack[self.loop_depth] = LoopFrame{ .index = start_i, .limit = limit_i };
                self.loop_depth += 1;

                const do_pc = pc.*; // save position after 'do'

                while (true) {
                    const frame = &self.loop_stack[self.loop_depth - 1];
                    if (frame.index >= frame.limit) break;

                    pc.* = do_pc; // rewind to body start
                    const cont = try self.execBody(body, pc);
                    if (!cont) {
                        self.loop_depth -= 1;
                        return false;
                    }
                }

                // Skip past matching loop/+loop if we broke out
                // pc should already be past the loop token from the last iteration
                // But if we never entered the loop, we need to skip the body
                if (self.loop_stack[self.loop_depth - 1].index >= self.loop_stack[self.loop_depth - 1].limit) {
                    // If we never entered or just finished, skip to matching loop/+loop
                    // Only needed if index >= limit from the start
                    if (start_i >= limit_i) {
                        var depth: usize = 1;
                        while (pc.* < body.len) {
                            const skip_tok = self.dict.getTokenStr(body[pc.*]);
                            pc.* += 1;
                            if (std.mem.eql(u8, skip_tok, "do")) {
                                depth += 1;
                            } else if (std.mem.eql(u8, skip_tok, "loop") or std.mem.eql(u8, skip_tok, "+loop")) {
                                depth -= 1;
                                if (depth == 0) break;
                            }
                        }
                    }
                }

                self.loop_depth -= 1;
                continue;
            }

            // loop: increment counter and signal end of loop body
            if (std.mem.eql(u8, tok_str, "loop")) {
                if (self.loop_depth > 0) {
                    self.loop_stack[self.loop_depth - 1].index += 1;
                }
                return true; // return to do's execBody call
            }

            // +loop: add TOS to counter
            if (std.mem.eql(u8, tok_str, "+loop")) {
                const step = self.stack.pop() catch {
                    try self.stdout.writeAll("error: stack underflow\n");
                    return true;
                };
                const step_i = switch (step) {
                    .int => |v| v,
                    else => {
                        try self.stdout.writeAll("error: +loop expects integer\n");
                        return true;
                    },
                };
                if (self.loop_depth > 0) {
                    self.loop_stack[self.loop_depth - 1].index += step_i;
                }
                return true;
            }

            // if: pop stack, if false skip to matching else/then
            if (std.mem.eql(u8, tok_str, "if")) {
                const cond = self.stack.pop() catch {
                    try self.stdout.writeAll("error: stack underflow\n");
                    return true;
                };
                const is_true = switch (cond) {
                    .int => |v| v != 0,
                    .float => |v| v != 0.0,
                    .string => |v| v.len > 0,
                };

                if (is_true) {
                    // Execute until else or then
                    const cont = try self.execBody(body, pc);
                    if (!cont) return false;
                } else {
                    // Skip to else or then
                    var depth: usize = 1;
                    while (pc.* < body.len) {
                        const skip_tok = self.dict.getTokenStr(body[pc.*]);
                        pc.* += 1;
                        if (std.mem.eql(u8, skip_tok, "if")) {
                            depth += 1;
                        } else if (std.mem.eql(u8, skip_tok, "else") and depth == 1) {
                            // Execute else branch
                            const cont = try self.execBody(body, pc);
                            if (!cont) return false;
                            break;
                        } else if (std.mem.eql(u8, skip_tok, "then")) {
                            depth -= 1;
                            if (depth == 0) break;
                        }
                    }
                }
                continue;
            }

            // else: we got here from true branch, skip to then
            if (std.mem.eql(u8, tok_str, "else")) {
                var depth: usize = 1;
                while (pc.* < body.len) {
                    const skip_tok = self.dict.getTokenStr(body[pc.*]);
                    pc.* += 1;
                    if (std.mem.eql(u8, skip_tok, "if")) {
                        depth += 1;
                    } else if (std.mem.eql(u8, skip_tok, "then")) {
                        depth -= 1;
                        if (depth == 0) break;
                    }
                }
                return true; // return to parent
            }

            // then: end of if block
            if (std.mem.eql(u8, tok_str, "then")) {
                return true; // return to parent
            }

            const should_continue = try self.execToken(tok_str);
            if (!should_continue) return false;
        }
        return true;
    }
};

// === Arithmetic ===
fn doArith(stack: *Stack, op: u8) !void {
    const b = try stack.pop();
    const a = try stack.pop();

    if (a == .float or b == .float) {
        const fa: f64 = switch (a) {
            .int => |v| @floatFromInt(v),
            .float => |v| v,
            .string => return error.TypeError,
        };
        const fb: f64 = switch (b) {
            .int => |v| @floatFromInt(v),
            .float => |v| v,
            .string => return error.TypeError,
        };
        const result: f64 = switch (op) {
            '+' => fa + fb,
            '-' => fa - fb,
            '*' => fa * fb,
            '/' => if (fb == 0) return error.DivisionByZero else fa / fb,
            else => return error.TypeError,
        };
        try stack.push(Value{ .float = result });
    } else {
        const ia: i64 = a.int;
        const ib: i64 = b.int;
        const result: i64 = switch (op) {
            '+' => ia + ib,
            '-' => ia - ib,
            '*' => ia * ib,
            '/' => if (ib == 0) return error.DivisionByZero else @divTrunc(ia, ib),
            else => return error.TypeError,
        };
        try stack.push(Value{ .int = result });
    }
}

// === Number formatting ===
fn formatInt(v: i64, buf: []u8) []const u8 {
    var i: usize = 0;
    var val = v;
    if (val < 0) {
        buf[0] = '-';
        i = 1;
        val = -val;
    }
    if (val == 0) {
        buf[i] = '0';
        return buf[0 .. i + 1];
    }
    var tmp: [20]u8 = undefined;
    var t: usize = 0;
    var uval: u64 = @intCast(if (val < 0) -val else val);
    while (uval > 0) {
        tmp[t] = @intCast('0' + (uval % 10));
        uval /= 10;
        t += 1;
    }
    var j: usize = t;
    while (j > 0) {
        j -= 1;
        buf[i] = tmp[j];
        i += 1;
    }
    return buf[0..i];
}

fn formatUint(v: usize, buf: []u8) []const u8 {
    if (v == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    var tmp: [20]u8 = undefined;
    var t: usize = 0;
    var val = v;
    while (val > 0) {
        tmp[t] = @intCast('0' + (val % 10));
        val /= 10;
        t += 1;
    }
    var i: usize = 0;
    var j: usize = t;
    while (j > 0) {
        j -= 1;
        buf[i] = tmp[j];
        i += 1;
    }
    return buf[0..i];
}

fn formatFloat(v: f64, buf: []u8) []const u8 {
    var i: usize = 0;
    var val = v;
    if (val < 0) {
        buf[0] = '-';
        i = 1;
        val = -val;
    }

    const int_part: u64 = @intFromFloat(val);

    var int_buf: [20]u8 = undefined;
    const int_str = formatUint(int_part, &int_buf);
    for (int_str) |c| {
        buf[i] = c;
        i += 1;
    }

    buf[i] = '.';
    i += 1;

    const max_dec = 12;
    const frac = val - @as(f64, @floatFromInt(int_part));
    var scale: f64 = 1.0;
    for (0..max_dec) |_| scale *= 10.0;
    var frac_int: u64 = @intFromFloat(@round(frac * scale));

    var dec_buf: [12]u8 = undefined;
    var d: usize = max_dec;
    while (d > 0) {
        d -= 1;
        dec_buf[d] = @intCast('0' + (frac_int % 10));
        frac_int /= 10;
    }

    var last: usize = max_dec;
    while (last > 1) {
        if (dec_buf[last - 1] != '0') break;
        last -= 1;
    }
    for (dec_buf[0..last]) |c| {
        buf[i] = c;
        i += 1;
    }

    return buf[0..i];
}

// === Parsing ===
fn parseValue(token: []const u8) ?Value {
    var is_neg = false;
    var start: usize = 0;
    if (token.len > 0 and token[0] == '-') {
        is_neg = true;
        start = 1;
    }
    if (start < token.len) {
        var all_digits = true;
        var has_dot = false;
        for (token[start..]) |c| {
            if (c == '.' and !has_dot) {
                has_dot = true;
            } else if (c < '0' or c > '9') {
                all_digits = false;
                break;
            }
        }
        if (all_digits) {
            if (has_dot) {
                const val = parseFloat(token);
                if (val) |v| return Value{ .float = v };
            } else {
                const val = parseInt(token[start..]);
                if (val) |v| {
                    return Value{ .int = if (is_neg) -@as(i64, @intCast(v)) else @as(i64, @intCast(v)) };
                }
            }
        }
    }
    return null;
}

fn parseInt(s: []const u8) ?u64 {
    var result: u64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        result = result * 10 + (c - '0');
    }
    return result;
}

fn parseFloat(s: []const u8) ?f64 {
    var result: f64 = 0;
    var frac: f64 = 0;
    var frac_div: f64 = 1;
    var in_frac = false;
    var is_neg = false;
    var start: usize = 0;
    if (s.len > 0 and s[0] == '-') {
        is_neg = true;
        start = 1;
    }
    for (s[start..]) |c| {
        if (c == '.') {
            in_frac = true;
            continue;
        }
        if (c < '0' or c > '9') return null;
        if (in_frac) {
            frac_div *= 10;
            frac += @as(f64, @floatFromInt(c - '0')) / frac_div;
        } else {
            result = result * 10 + @as(f64, @floatFromInt(c - '0'));
        }
    }
    const val = result + frac;
    return if (is_neg) -val else val;
}

// === Main ===
pub fn main() !void {
    const stdout = std.fs.File.stdout();

    var interp = Interpreter.init(stdout);

    // Process command-line arguments (file args)
    const args = std.process.argsAlloc(std.heap.page_allocator) catch {
        try stdout.writeAll("error: failed to read args\n");
        return;
    };
    defer std.process.argsFree(std.heap.page_allocator, args);

    var skip_rc = false;
    var interactive = false;
    var file_args: [64][]const u8 = undefined;
    var file_count: usize = 0;

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--no-rc") or std.mem.eql(u8, arg, "-n")) {
            skip_rc = true;
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--interactive")) {
            interactive = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try stdout.writeAll("Usage: zf [options] [file...]\n");
            try stdout.writeAll("Options:\n");
            try stdout.writeAll("  -i, --interactive  Enter REPL after running files\n");
            try stdout.writeAll("  -n, --no-rc        Skip loading ~/.zfrc\n");
            try stdout.writeAll("  -h, --help         Show this help\n");
            return;
        } else {
            if (file_count < 64) {
                file_args[file_count] = arg;
                file_count += 1;
            }
        }
    }

    if (file_count > 0) {
        if (!skip_rc) {
            if (std.posix.getenv("HOME")) |home| {
                var rc_path_buf: [256]u8 = undefined;
                const rc_path_len = home.len + 6;
                if (rc_path_len <= rc_path_buf.len) {
                    @memcpy(rc_path_buf[0..home.len], home);
                    @memcpy(rc_path_buf[home.len .. home.len + 6], "/.zfrc");
                    _ = execFile(&interp, rc_path_buf[0..rc_path_len]) catch {};
                }
            }
        }
        // Execute files
        for (file_args[0..file_count]) |arg| {
            const ran = execFile(&interp, arg) catch |err| {
                try stdout.writeAll("error: cannot open file: ");
                try stdout.writeAll(arg);
                switch (err) {
                    error.FileNotFound => try stdout.writeAll(" (not found)"),
                    error.AccessDenied => try stdout.writeAll(" (access denied)"),
                    else => try stdout.writeAll(" (unknown error)"),
                }
                try stdout.writeAll("\n");
                continue;
            };
            if (!ran) return; // bye was called
        }
        if (!interactive) return; // exit after running files (no REPL)
    }

    // Load ~/.zfrc if it exists
    if (!skip_rc) if (std.posix.getenv("HOME")) |home| {
        var rc_path_buf: [256]u8 = undefined;
        const rc_path_len = home.len + 6; // "/.zfrc"
        if (rc_path_len <= rc_path_buf.len) {
            @memcpy(rc_path_buf[0..home.len], home);
            @memcpy(rc_path_buf[home.len .. home.len + 6], "/.zfrc");
            _ = execFile(&interp, rc_path_buf[0..rc_path_len]) catch {};
        }
    };

    // Interactive REPL
    try stdout.writeAll("zf - a Forth in Zig\n");

    const stdin = std.fs.File.stdin();
    var buf: [1024]u8 = undefined;

    while (true) {
        if (interp.compiling) {
            try stdout.writeAll("  ] ");
        } else {
            try stdout.writeAll("zf> ");
        }

        const line = readLine(stdin, &buf) catch {
            try stdout.writeAll("\nGoodbye!\n");
            return;
        };

        if (line) |input| {
            const should_continue = try interp.execLine(input);
            if (!should_continue) return;
        } else {
            try stdout.writeAll("\nGoodbye!\n");
            return;
        }
    }
}

fn execFile(interp: *Interpreter, path: []const u8) !bool {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var buf: [4096]u8 = undefined;

    while (true) {
        const line = readLine(file, &buf) catch return true;
        if (line) |input| {
            // Skip comment lines (backslash)
            const trimmed = std.mem.trim(u8, input, &std.ascii.whitespace);
            if (trimmed.len > 0 and trimmed[0] == '\\') continue;

            const should_continue = try interp.execLine(input);
            if (!should_continue) return false;
        } else {
            return true; // EOF
        }
    }
}

fn readLine(file: std.fs.File, buf: []u8) !?[]const u8 {
    var i: usize = 0;
    while (i < buf.len) {
        const bytes_read = file.read(buf[i .. i + 1]) catch |err| return err;
        if (bytes_read == 0) {
            if (i == 0) return null;
            return buf[0..i];
        }
        if (buf[i] == '\n') {
            return buf[0..i];
        }
        i += 1;
    }
    return buf[0..buf.len];
}
