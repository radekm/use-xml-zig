//! Randomised tests: generated and corrupted documents, random sequences of API calls.
//!
//! `zig build test` runs a fixed number of iterations with a fixed seed. The test
//! "fuzz: raw bytes" is also a coverage-guided fuzz test: `zig build test --fuzz`.
//!
//! Every input must either parse or fail with `error.InvalidXml` and filled-in diagnostics.
//! For parsed documents, random extraction calls check the usage rules:
//! - each attribute / child name / text can be requested once, then `error.AlreadyUsed`,
//! - every other error (except `OutOfMemory`) is recorded in `doc.diagnostics()`,
//! - `expectAllUsed()` succeeds exactly when `unused()` yields nothing,
//! - after `ignoreAll()` on every visited element, everything is used.
//! The testing allocator detects leaks, double frees and use after free.

const std = @import("std");
const t = std.testing;
const Allocator = std.mem.Allocator;
const Document = @import("Document.zig");
const Elem = @import("Elem.zig");
const ParseDiagnostics = @import("ParseDiagnostics.zig");
const Timestamp = @import("Timestamp.zig");
const parse = @import("parse.zig");

/// Number of iterations of the deterministic random test. Keep `zig build test` fast in Debug.
const iterations = 2000;
const random_seed = 0x75e_c0de;

// ------------------------------------------------------------------ generator

const names = [_][]const u8{ "a", "b", "c", "x:a", "y:a", "item", "p:b", "č", "xmlns", "xmlns:p", "_", "a.b", "a-1", "xml:lang", "z" };
const valid_pieces = [_][]const u8{
    "hello",                " ",                    "\n",   "\r\n", "\r",    "\t",  "&amp;",                "&lt;", "&gt;", "&apos;", "&quot;", "&#65;",                          "&#x41;",               "&#x10FFFF;",
    "ž",
    "😀",
    "123",                  "-5",                   "1.5",  "true", "false", "red", "2021-05-31T23:12:04Z", "x",    "ab",   "&#13;",  "&#x20;", "2021-05-31T23:12:04.123456789Z", "9999-12-31T23:59:59Z", "0000-01-01T00:00:00Z",
    "18446744073709551616", "-9223372036854775808", "+007", "1",    "0",     "-0",  "255",                  "256",
};
const text_pieces = [_][]const u8{
    "hello",      " ",        "\n",   "\r\n",       "\r",             "\t",      "&amp;",                "&lt;",                           "&gt;",                 "&apos;",               "&quot;",               "&#65;",                "&#x41;",
    "&#x10FFFF;", "&#xD800;", "&#0;", "&#x110000;", "&#99999999999;", "&bogus;", "&;",                   "&#;",                            "&#x;",                 "&",                    "]]>",                  "]]",
    "ž",
    "😀",
    "123",        "-5",       "1.5",  "true",       "false",          "red",     "2021-05-31T23:12:04Z", "2021-05-31T23:12:04.123456789Z", "9999-12-31T23:59:59Z", "0000-01-01T00:00:00Z", "18446744073709551616", "-9223372036854775808", "+007",
    "\xff",       "\xc3",     "\x00", "\x01",       "\xef\xbf\xbe",   "&#13;",   "&#x20;",               "&#10;",
};

const Gen = struct {
    r: std.Random,
    out: *std.ArrayList(u8),
    gpa: Allocator,
    clean: bool = false,

    fn put(g: *Gen, s: []const u8) !void {
        try g.out.appendSlice(g.gpa, s);
    }
    fn piece(g: *Gen) []const u8 {
        return if (g.clean) g.pick(&valid_pieces) else g.pick(&text_pieces);
    }
    fn pick(g: *Gen, comptime list: []const []const u8) []const u8 {
        return list[g.r.uintLessThan(usize, list.len)];
    }
    fn chance(g: *Gen, n: u32) bool {
        return g.r.uintLessThan(u32, n) == 0;
    }

    fn document(g: *Gen) !void {
        if (g.chance(10)) try g.put("\xEF\xBB\xBF");
        if (g.clean) {
            if (g.chance(3)) try g.put("<?xml version='1.0' encoding='UTF-8' standalone='no'?>");
        } else if (g.chance(3)) try g.put(g.pick(&.{
            "<?xml version=\"1.0\"?>",                  "<?xml version='1.0' encoding='UTF-8' standalone='no'?>",
            "<?xml version=\"1.1\"?>",                  "<?xml encoding=\"UTF-8\"?>",
            "<?xml version=\"2.0\"?>",                  "<?xml version=\"1.0\" encoding=\"latin1\"?>",
            "<?xml version=\"1.0\" standalone=\"x\"?>", "<?xml version=\"1.0\"",
            "<?xml ?>",                                 "<?xml version=\"1.0\"encoding=\"UTF-8\"?>",
        }));
        try g.misc();
        if (g.chance(30)) {
            // Deep nesting.
            const depth = g.r.uintLessThan(usize, 600);
            for (0..depth) |_| try g.put("<d>");
            if (g.chance(2)) try g.put("x");
            for (0..depth) |_| try g.put("</d>");
        } else {
            try g.element(0);
        }
        try g.misc();
        if (g.chance(20)) try g.put(g.pick(&.{ "<a/>", "text", "<!DOCTYPE a>", "<!x>" }));
    }

    fn misc(g: *Gen) !void {
        var n = g.r.uintLessThan(u32, 3);
        while (n > 0) {
            n -= 1;
            if (g.clean) {
                try g.put(g.pick(&.{ " ", "\n", "<!-- c -->", "<!---->", "<?pi data?>" }));
                continue;
            }
            try g.put(g.pick(&.{ " ", "\n", "<!-- c -->", "<!---->", "<?pi data?>", "<?pi?>", "<!-- a -- b -->", "<?xml version=\"1.0\"?>", "<?XmL x?>", "<!--", "<?" }));
        }
    }

    fn name(g: *Gen) []const u8 {
        return g.pick(&names);
    }

    fn attrValue(g: *Gen) !void {
        var n = g.r.uintLessThan(u32, 4);
        while (n > 0) : (n -= 1) {
            if (!g.clean and g.chance(8)) {
                try g.put(g.pick(&.{ "<", "\"", "'", ">" }));
            } else {
                try g.put(g.piece());
            }
        }
    }

    fn element(g: *Gen, depth: u32) !void {
        const n = g.name();
        try g.put("<");
        try g.put(n);
        const clean_attrs = [_][]const u8{ "a", "b", "p:c", "d", "xmlns:p", "e" };
        var na = g.r.uintLessThan(u32, 5);
        while (na > 0) : (na -= 1) {
            try g.put(if (!g.clean and g.chance(20)) "" else " ");
            try g.put(if (g.clean) clean_attrs[na] else g.name());
            try g.put(if (g.chance(10)) " = " else "=");
            const q: []const u8 = if (g.r.boolean()) "\"" else "'";
            try g.put(q);
            try g.attrValue();
            try g.put(q);
        }
        if (g.chance(4)) {
            try g.put("/>");
            return;
        }
        try g.put(">");
        const kind = g.r.uintLessThan(u32, 3);
        if (kind == 0 or depth > 6) {
            // Text-only content.
            var nt = g.r.uintLessThan(u32, 4);
            while (nt > 0) : (nt -= 1) {
                const k = g.r.uintLessThan(u32, 6);
                switch (k) {
                    0 => try g.put("<![CDATA["),
                    1 => try g.put("<!-- c -->"),
                    2 => try g.put("<?p x?>"),
                    else => {},
                }
                try g.put(g.piece());
                if (g.chance(2) or (g.clean and k == 0)) try g.put("]]>");
            }
        } else if (kind == 1) {
            var nc = g.r.uintLessThan(u32, 5);
            while (nc > 0) : (nc -= 1) {
                if (g.r.boolean()) try g.put(if (g.clean) g.pick(&.{ " ", "\n  ", "\r\n", "<!---->", "<?p?>" }) else g.pick(&.{ " ", "\n  ", "\r\n", "<!---->", "&#32;", "x", "<![CDATA[]]>" }));
                try g.element(depth + 1);
            }
            if (g.r.boolean()) try g.put("\n");
        }
        try g.put("</");
        try g.put(if (!g.clean and g.chance(30)) g.name() else n);
        if (g.chance(10)) try g.put(" ");
        try g.put(">");
    }
};

const interesting = "<>&;/=\"'![]?-:\r\n \t\x00\xff\xc3\xed\x80#xX";

fn mutate(r: std.Random, gpa: Allocator, buf: *std.ArrayList(u8)) !void {
    var n = r.uintLessThan(u32, 4);
    while (n > 0) : (n -= 1) {
        if (buf.items.len == 0) {
            try buf.append(gpa, interesting[r.uintLessThan(usize, interesting.len)]);
            continue;
        }
        const pos = r.uintLessThan(usize, buf.items.len);
        switch (r.uintLessThan(u32, 6)) {
            0 => buf.items[pos] = interesting[r.uintLessThan(usize, interesting.len)],
            1 => try buf.insert(gpa, pos, interesting[r.uintLessThan(usize, interesting.len)]),
            2 => _ = buf.orderedRemove(pos),
            3 => buf.shrinkRetainingCapacity(pos),
            4 => buf.items[pos] = r.int(u8),
            5 => {
                const len = @min(buf.items.len - pos, r.uintLessThan(usize, 16));
                const copy = try gpa.dupe(u8, buf.items[pos .. pos + len]);
                defer gpa.free(copy);
                try buf.insertSlice(gpa, r.uintLessThan(usize, buf.items.len + 1), copy);
            },
            else => unreachable,
        }
    }
}

// ------------------------------------------------------------------ API exerciser

const Color = enum { red, green, blue };

const Hook = struct {
    v: []const u8,
    owned: bool = false,
    pub fn parseXml(s: []const u8) error{TooLong}!Hook {
        if (s.len > 3) return error.TooLong;
        return .{ .v = s };
    }
    pub fn parseXmlAlloc(gpa: Allocator, s: []const u8) error{ OutOfMemory, TooLong }!Hook {
        if (s.len > 5) return error.TooLong;
        return .{ .v = try gpa.dupe(u8, s), .owned = true };
    }
};

fn pLen(s: []const u8) error{Bad}!usize {
    if (s.len == 2) return error.Bad;
    return s.len;
}
fn pNoErr(s: []const u8) usize {
    return s.len;
}
fn pAlloc(gpa: Allocator, s: []const u8) error{ OutOfMemory, Bad }![]u8 {
    if (s.len == 1) return error.Bad;
    return gpa.dupe(u8, s);
}
fn pOom(s: []const u8) error{OutOfMemory}!usize {
    if (s.len == 3) return error.OutOfMemory;
    return s.len;
}

const UseKey = struct { elem: *Elem, kind: u8, name: []const u8 };

const Ex = struct {
    r: std.Random,
    gpa: Allocator,
    doc: *Document,
    elems: std.ArrayList(*Elem) = .empty,
    used: std.ArrayList(UseKey) = .empty,
    failing: std.testing.FailingAllocator,

    fn deinit(x: *Ex) void {
        x.elems.deinit(x.gpa);
        x.used.deinit(x.gpa);
    }

    fn wasUsed(x: *Ex, e: *Elem, kind: u8, n: []const u8) bool {
        for (x.used.items) |u| {
            if (u.elem == e and u.kind == kind and std.mem.eql(u8, u.name, n)) return true;
        }
        return false;
    }

    fn pickName(x: *Ex, e: *Elem, kind: u8) []const u8 {
        if (kind == 0 and e.attrs.len > 0 and x.r.boolean()) return e.attrs[x.r.uintLessThan(usize, e.attrs.len)].local_name;
        if (kind == 1 and e.groups.len > 0 and x.r.boolean()) return e.groups[x.r.uintLessThan(usize, e.groups.len)].local_name;
        return names[x.r.uintLessThan(usize, names.len)];
    }

    fn allocator(x: *Ex) Allocator {
        if (x.r.uintLessThan(u32, 3) == 0) {
            x.failing = .init(x.gpa, .{ .fail_index = x.r.uintLessThan(usize, 2) });
            return x.failing.allocator();
        }
        return x.gpa;
    }

    /// Checks the result of one lookup against the "at most once" rule.
    fn check(x: *Ex, e: *Elem, kind: u8, n: []const u8, err: ?anyerror) !void {
        const before = x.wasUsed(e, kind, n);
        if (before) {
            if (err == null or err.? != error.AlreadyUsed or x.doc.diagnostics().kind != .already_used) {
                std.debug.print("expected AlreadyUsed for kind {d} name '{s}' got {?}\n", .{ kind, n, err });
                return error.TestUnexpectedResult;
            }
            return;
        }
        if (err) |er| {
            if (er == error.AlreadyUsed) {
                std.debug.print("unexpected AlreadyUsed for kind {d} name '{s}'\n", .{ kind, n });
                return error.TestUnexpectedResult;
            }
            // Every error must be recorded (diagnostics are cleared before each call).
            const recorded = x.doc.diagnostics().kind;
            if (recorded == .none) return error.TestUnexpectedResult;
            const oom_kind = recorded == .document_out_of_memory or recorded == .value_out_of_memory;
            if ((er == error.OutOfMemory) != oom_kind) return error.TestUnexpectedResult;
            try x.fmt(x.doc.diagnostics());
        }
        // Names are compared by value; for kind 0/1 the lookup is by local name.
        try x.used.append(x.gpa, .{ .elem = e, .kind = kind, .name = n });
    }

    fn fmt(x: *Ex, v: anytype) !void {
        _ = x;
        var buf: [64]u8 = undefined;
        var w: std.Io.Writer.Discarding = .init(&buf);
        try w.writer.print("{f}", .{v});
    }

    fn addElem(x: *Ex, e: *Elem) !void {
        for (x.elems.items) |o| if (o == e) return;
        try x.elems.append(x.gpa, e);
    }

    fn attrOp(x: *Ex, e: *Elem, n: []const u8) !void {
        const op = x.r.uintLessThan(u32, 20);
        var err: ?anyerror = null;
        switch (op) {
            0 => _ = e.attr([]const u8, n) catch |er| {
                err = er;
            },
            1 => _ = e.attr(u8, n) catch |er| {
                err = er;
            },
            2 => _ = e.attr(i64, n) catch |er| {
                err = er;
            },
            3 => _ = e.attr(f64, n) catch |er| {
                err = er;
            },
            4 => _ = e.attr(bool, n) catch |er| {
                err = er;
            },
            5 => _ = e.attr(Color, n) catch |er| {
                err = er;
            },
            6 => _ = e.attr(Timestamp, n) catch |er| {
                err = er;
            },
            7 => _ = e.attr(Hook, n) catch |er| {
                err = er;
            },
            8 => _ = e.attrOpt(u1, n) catch |er| {
                err = er;
            },
            9 => _ = e.attrOpt(f32, n) catch |er| {
                err = er;
            },
            10 => _ = e.attrWith(n, pLen) catch |er| {
                err = er;
            },
            11 => _ = e.attrOptWith(n, pNoErr) catch |er| {
                err = er;
            },
            12 => _ = e.attrWith(n, parse.oneOf(&.{ "red", "x" })) catch |er| {
                err = er;
            },
            13 => {
                const a = x.allocator();
                if (e.attrAlloc(a, []const u8, n)) |s| a.free(s) else |er| err = er;
            },
            14 => {
                const a = x.allocator();
                if (e.attrOptAlloc(a, []const u8, n)) |s| {
                    if (s) |v| a.free(v);
                } else |er| err = er;
            },
            15 => {
                const a = x.allocator();
                if (e.attrAlloc(a, Hook, n)) |h| a.free(h.v) else |er| err = er;
            },
            16 => {
                const a = x.allocator();
                if (e.attrAllocWith(a, n, pAlloc)) |s| a.free(s) else |er| err = er;
            },
            17 => {
                const a = x.allocator();
                if (e.attrOptAllocWith(a, n, pAlloc)) |s| {
                    if (s) |v| a.free(v);
                } else |er| err = er;
            },
            18 => _ = e.attrWith(n, pOom) catch |er| {
                err = er;
            },
            19 => _ = e.attrOpt(u64, n) catch |er| {
                err = er;
            },
            else => unreachable,
        }
        try x.check(e, 0, n, err);
    }

    fn childOp(x: *Ex, e: *Elem, n: []const u8) !void {
        var err: ?anyerror = null;
        switch (x.r.uintLessThan(u32, 3)) {
            0 => if (e.child(n)) |c| try x.addElem(c) else |er| {
                err = er;
            },
            1 => if (e.childOpt(n)) |c| {
                if (c) |cc| try x.addElem(cc);
            } else |er| {
                err = er;
            },
            2 => if (e.children(n)) |cs| {
                for (cs) |c| try x.addElem(c);
            } else |er| {
                err = er;
            },
            else => unreachable,
        }
        try x.check(e, 1, n, err);
    }

    fn textOp(x: *Ex, e: *Elem) !void {
        var err: ?anyerror = null;
        switch (x.r.uintLessThan(u32, 9)) {
            0 => _ = e.text([]const u8) catch |er| {
                err = er;
            },
            1 => _ = e.text(i32) catch |er| {
                err = er;
            },
            2 => _ = e.text(Timestamp) catch |er| {
                err = er;
            },
            3 => _ = e.text(Color) catch |er| {
                err = er;
            },
            4 => _ = e.textWith(pLen) catch |er| {
                err = er;
            },
            5 => {
                const a = x.allocator();
                if (e.textAlloc(a, []const u8)) |s| a.free(s) else |er| err = er;
            },
            6 => {
                const a = x.allocator();
                if (e.textAllocWith(a, pAlloc)) |s| a.free(s) else |er| err = er;
            },
            7 => _ = e.text(f64) catch |er| {
                err = er;
            },
            8 => {
                const a = x.allocator();
                if (e.textAlloc(a, Hook)) |h| a.free(h.v) else |er| err = er;
            },
            else => unreachable,
        }
        try x.check(e, 2, "", err);
    }

    fn run(x: *Ex) !void {
        try x.elems.append(x.gpa, x.doc.root());
        var steps = x.r.uintLessThan(u32, 60);
        while (steps > 0) : (steps -= 1) {
            // Internal: clear the diagnostics, so that `check` sees only what this call recorded.
            x.doc.ctx.diag = .{};
            const e = x.elems.items[x.r.uintLessThan(usize, x.elems.items.len)];
            switch (x.r.uintLessThan(u32, 12)) {
                0, 1, 2 => try x.attrOp(e, x.pickName(e, 0)),
                3, 4, 5 => try x.childOp(e, x.pickName(e, 1)),
                6, 7 => try x.textOp(e),
                8 => if (x.r.uintLessThan(u32, 4) == 0) {
                    e.ignoreAll();
                    // Everything is used now.
                    for (e.attrs) |a| try x.used.append(x.gpa, .{ .elem = e, .kind = 0, .name = a.local_name });
                    for (e.groups) |g| try x.used.append(x.gpa, .{ .elem = e, .kind = 1, .name = g.local_name });
                    try x.used.append(x.gpa, .{ .elem = e, .kind = 2, .name = "" });
                },
                9 => {
                    var it = x.doc.unused();
                    while (it.next()) |u| try x.fmt(u);
                },
                10 => {
                    const all_used = if (x.doc.expectAllUsed()) |_| true else |_| false;
                    var it = x.doc.unused();
                    if (all_used != (it.next() == null)) return error.TestUnexpectedResult;
                    try x.fmt(x.doc.diagnostics());
                },
                11 => {
                    try x.fmt(e.path());
                    _ = e.name();
                    _ = e.index();
                    if (e.parent()) |p| _ = p.name();
                },
                else => unreachable,
            }
        }
        // Ignoring every visited element must make everything used.
        for (x.elems.items) |e| e.ignoreAll();
        x.doc.expectAllUsed() catch |er| {
            var buf: [256]u8 = undefined;
            std.debug.print("after ignoreAll: {} {s}\n", .{ er, std.fmt.bufPrint(&buf, "{f}", .{x.doc.diagnostics()}) catch "?" });
            return er;
        };
    }
};

fn oneInput(gpa: Allocator, input: []const u8, seed: u64) !void {
    var pd: ParseDiagnostics = .{};
    const max_depth: u32 = if (seed % 7 == 0) 100_000 else if (seed % 11 == 0) 0 else 256;
    var doc = Document.parse(gpa, input, .{ .diagnostics = &pd, .max_depth = max_depth }) catch |err| switch (err) {
        error.InvalidXml => {
            if (pd.message.len == 0 or pd.line == 0 or pd.column == 0) return error.TestUnexpectedResult;
            var buf: [256]u8 = undefined;
            _ = try std.fmt.bufPrint(&buf, "{f}", .{pd});
            return;
        },
        error.OutOfMemory => return,
    };
    defer doc.deinit();
    if (pd.message.len != 0) return error.TestUnexpectedResult;
    var prng = std.Random.DefaultPrng.init(seed);
    var ex: Ex = .{ .r = prng.random(), .gpa = gpa, .doc = &doc, .failing = undefined };
    defer ex.deinit();
    try ex.run();
}

fn parseOnly(gpa: Allocator, input: []const u8) !void {
    var doc = Document.parse(gpa, input, .{}) catch |err| switch (err) {
        error.InvalidXml => return,
        else => return err,
    };
    doc.deinit();
}

test "random generated and corrupted documents with random API use" {
    const gpa = t.allocator;
    var prng = std.Random.DefaultPrng.init(random_seed);
    const r = prng.random();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    for (0..iterations) |i| {
        buf.clearRetainingCapacity();
        var g: Gen = .{ .r = r, .out = &buf, .gpa = gpa, .clean = r.boolean() };
        try g.document();
        if (!g.clean or r.uintLessThan(u32, 4) == 0) try mutate(r, gpa, &buf);
        const input_seed = r.int(u64);
        oneInput(gpa, buf.items, input_seed) catch |err| {
            std.debug.print("iteration {d}, seed {d}, input: \"{f}\"\n", .{ i, input_seed, std.zig.fmtString(buf.items) });
            return err;
        };
        // Occasionally test every allocation failure during parsing.
        if (buf.items.len < 200 and r.uintLessThan(u32, 50) == 0) {
            try t.checkAllAllocationFailures(gpa, parseOnly, .{buf.items});
        }
    }
}

test "fuzz: raw bytes" {
    try t.fuzz({}, struct {
        fn testOne(_: void, smith: *t.Smith) anyerror!void {
            var buf: [512]u8 = undefined;
            const len = smith.slice(&buf);
            const seed = smith.value(u64);
            try oneInput(t.allocator, buf[0..len], seed);
        }
    }.testOne, .{ .corpus = &.{
        "<a x=\"1\"><b>t</b><b/><![CDATA[x]]></a>",
        "<?xml version=\"1.0\"?><a>&amp;&#x41;\r\n</a>",
        "<p:a xmlns:p=\"u\" p:x='1' y='&lt;'><c/><!-- c --></p:a>",
    } });
}
