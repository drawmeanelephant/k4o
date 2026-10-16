//! date math — knap 0.6.0 filter group.
//!
//! `date` stringifies the input JS-style (objects serialize to JSON, arrays
//! comma-join) and parses it like the oracle's bundled dayjs: a relaxed
//! numeric regex first (local-time fields, `new Date` overflow semantics),
//! then a `Date.parse`-style fallback for month-name, US, RFC-2822 and
//! zoned ISO forms. An optional second parameter is a strict input format
//! (customParseFormat token table plus a format round-trip check). The
//! output format is the dayjs token set — `[literal]` escapes,
//! calendar/time tokens, ordinals, week numbers, epoch `X`/`x`, `Z`/`ZZ`
//! offsets; `z`, `zzz` and `gggg` throw in the oracle and are fatal here.
//!
//! `date_modify:"±N unit"` adds/subtracts a single interval: year and month
//! clamp to the month length, week/day shift the calendar date, and
//! hour/minute/second shift the instant. Output is `YYYY-MM-DD`.
//!
//! `duration` reads an integer-prefix seconds count or `PnYnMnDTnHnMnS`
//! (year = 365d, month = 30d) and formats `H HH m mm s ss`; the default is
//! `HH:mm:ss` at one hour or more, else `mm:ss`.
//!
//! Local time is real machine-local time: a TZif reader (`TZ` env or
//! /etc/localtime) with POSIX-rules evaluation past the last transition.

const std = @import("std");
const builtin = @import("builtin");
const filters = @import("../filters.zig");
const parse = @import("../parse.zig");
const engine = @import("../engine.zig");

const Interp = filters.Interp;
const Value = filters.Value;
const Error = filters.Error;

pub const names = [_][]const u8{
    "date",
    "date_modify",
    "duration",
};

pub fn apply(
    it: *Interp,
    call: parse.FilterCall,
    input: *const Value,
) Error!?*const Value {
    if (std.mem.eql(u8, call.name, "date")) return dateFilter(it, call, input);
    if (std.mem.eql(u8, call.name, "date_modify")) return dateModify(it, call, input);
    if (std.mem.eql(u8, call.name, "duration")) return durationFilter(it, call, input);
    return null;
}

// --------------------------------------------------------------------
// Input coercion: scalars as JS String, arrays comma-join, objects
// serialize to compact JSON. Null and empty text pass through silently.

fn inputText(it: *Interp, input: *const Value) Error![]const u8 {
    return switch (input.*) {
        .null => "",
        .string, .number_string => |s| s,
        .bool => |b| if (b) "true" else "false",
        .integer => |i| try std.fmt.allocPrint(it.alloc, "{d}", .{i}),
        .float => |f| try engine.jsFloat(it.alloc, f),
        .array => try filters.jsToString(it.alloc, input),
        .object => blk: {
            var buf = std.Io.Writer.Allocating.init(it.alloc);
            try it.jsStringify(input, &buf);
            break :blk buf.written();
        },
    };
}

/// Param text with the pair splice (`a":"b`) the oracle applies to
/// `filter:"x":"y"` argument syntax.
fn argText(it: *Interp, call: parse.FilterCall, i: usize) Error!?[]const u8 {
    if (i >= call.params.len) return null;
    return switch (call.params[i]) {
        .value => |e| try filters.jsToString(it.alloc, try it.evalParam(e)),
        .pair => |pr| blk: {
            const k = try filters.jsToString(it.alloc, try it.evalParam(pr.key));
            const v = try filters.jsToString(it.alloc, try it.evalParam(pr.value));
            break :blk try std.fmt.allocPrint(it.alloc, "{s}\":\"{s}", .{ k, v });
        },
        .arrow => return filters.badArg(it, call, "filter '{s}' does not take an arrow argument", .{call.name}),
    };
}

// --------------------------------------------------------------------
// Civil <-> epoch math (Howard Hinnant's days-from-civil). `m` is 1-based
// and `d` may overflow past the month end — matching `new Date`
// normalization (Dec 32 rolls into January).

fn daysFromCivil(y_in: i64, m_in: i64, d: i64) i64 {
    const y = y_in + @divFloor(m_in - 1, 12);
    const m = @mod(m_in - 1, 12) + 1;
    const era_y = if (m <= 2) y - 1 else y;
    const era = @divFloor(era_y, 400);
    const yoe = era_y - era * 400;
    const mp = if (m > 2) m - 3 else m + 9;
    const doy = @divTrunc(153 * mp + 2, 5) + (d - 1);
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

const Ymd = struct { y: i64, m: u8, d: u8 };

fn civilFromDays(z: i64) Ymd {
    const zz = z + 719468;
    const era = @divFloor(zz, 146097);
    const doe = zz - era * 146097;
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp = @divTrunc(5 * doy + 2, 153);
    const d = doy - @divTrunc(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{ .y = if (m <= 2) y + 1 else y, .m = @intCast(m), .d = @intCast(d) };
}

/// Fields of an instant as read on a wall clock (UTC or a chosen offset).
const Wall = struct {
    year: i64,
    month0: i64,
    day: i64,
    wday: i64, // Sunday = 0
    hour: i64,
    minute: i64,
    second: i64,
    ms: i64,
};

fn wallFromMs(ms: i64) Wall {
    const days = @divFloor(ms, 86400000);
    const sod = ms - days * 86400000;
    const c = civilFromDays(days);
    return .{
        .year = c.y,
        .month0 = c.m - 1,
        .day = c.d,
        .wday = @mod(days + 4, 7),
        .hour = @divTrunc(sod, 3600000),
        .minute = @mod(@divTrunc(sod, 60000), 60),
        .second = @mod(@divTrunc(sod, 1000), 60),
        .ms = @mod(sod, 1000),
    };
}

/// `new Date(y, m, d, h, mi, s, ms)` treated as a UTC instant — including
/// the 0..99 -> 1900+ year rule and free overflow of every field.
fn utcMs(year: i64, month0: i64, day: i64, h: i64, mi: i64, s: i64, ms: i64) i64 {
    const y = if (year >= 0 and year <= 99) year + 1900 else year;
    return daysFromCivil(y, month0 + 1, day) * 86400000 + h * 3600000 + mi * 60000 + s * 1000 + ms;
}

// --------------------------------------------------------------------
// Local timezone: TZif reader + POSIX tail rules, resolved once per
// filter call. Falls back to UTC when nothing is readable.

const PosixRule = struct {
    month: u8 = 0, // Mm.w.d form
    week: u8 = 0,
    wday: u8 = 0,
    jday: i32 = -1, // Jn (1-365, skips Feb 29)
    yday: i32 = -1, // n  (0-365)
    secs: i32 = 7200, // local time of day, may exceed 24h or be negative
};

const Posix = struct {
    std_off: i32, // seconds EAST of Greenwich
    dst: ?Dst = null,

    const Dst = struct {
        off: i32,
        start: PosixRule,
        end: PosixRule,
    };
};

const Zone = struct {
    transitions: []i64 = &.{}, // epoch seconds, ascending
    trans_type: []u8 = &.{},
    types: []TtInfo = &.{},
    footer: ?Posix = null,
    fixed: i32 = 0,

    const TtInfo = struct { off: i32, dst: bool };

    fn offsetAt(self: *const Zone, sec: i64) i32 {
        if (self.types.len == 0) return self.fixed;
        if (self.transitions.len == 0) {
            if (self.footer) |p| return self.posixOffset(p, sec);
            return self.types[0].off;
        }
        // Binary search for the last transition <= sec.
        var lo: usize = 0;
        var hi: usize = self.transitions.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.transitions[mid] <= sec) lo = mid + 1 else hi = mid;
        }
        if (lo == 0) {
            // Before the first transition: the first standard-time type,
            // else the first type (LMT in practice).
            for (self.types) |t| {
                if (!t.dst) return t.off;
            }
            return self.types[0].off;
        }
        if (lo < self.transitions.len) return self.types[self.trans_type[lo - 1]].off;
        if (self.footer) |p| return self.posixOffset(p, sec);
        return self.types[self.trans_type[lo - 1]].off;
    }

    /// Day-of-year a POSIX rule lands on for `year` (0 = Jan 1).
    fn ruleDoy(year: i64, r: PosixRule) i64 {
        if (r.jday >= 0) {
            const leap = @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
            return r.jday - 1 + @intFromBool(leap and r.jday >= 60);
        }
        if (r.yday >= 0) return r.yday;
        const first = daysFromCivil(year, r.month, 1);
        const wd: i64 = @mod(first + 4, 7);
        var day = 1 + @mod(@as(i64, r.wday) - wd, 7) + (@as(i64, r.week) - 1) * 7;
        // Week 5 means "last": fall back a week when it runs off the month.
        const dim = daysFromCivil(year, r.month + 1, 1) - first;
        if (day > dim) day -= 7;
        return day - 1;
    }

    fn posixOffset(self: *const Zone, p: Posix, sec: i64) i32 {
        _ = self;
        const dst = p.dst orelse return p.std_off;
        const year = wallFromMs(sec * 1000).year;
        // The start instant is stamped in the offset in effect before it
        // (standard), the end in daylight time.
        const start_utc = (daysFromCivil(year, 1, 1) + ruleDoy(year, dst.start)) * 86400 +
            dst.start.secs - p.std_off;
        const end_utc = (daysFromCivil(year, 1, 1) + ruleDoy(year, dst.end)) * 86400 +
            dst.end.secs - dst.off;
        const in_dst = if (start_utc < end_utc)
            sec >= start_utc and sec < end_utc
        else
            sec >= start_utc or sec < end_utc;
        return if (in_dst) dst.off else p.std_off;
    }
};

const posix_env = builtin.os.tag == .linux or builtin.os.tag == .macos or
    builtin.os.tag == .freebsd or builtin.os.tag == .netbsd or
    builtin.os.tag == .openbsd or builtin.os.tag == .dragonfly or
    builtin.os.tag == .solaris or builtin.os.tag == .illumos;

const have_libc = builtin.link_libc or builtin.os.tag == .macos;

fn sysClose(fd: std.posix.fd_t) void {
    if (comptime have_libc) {
        _ = std.c.close(fd);
    } else if (comptime builtin.os.tag == .linux) {
        _ = std.os.linux.close(fd);
    }
}

fn readFileAbs(alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
    if (comptime !posix_env) return null;
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{}, 0) catch return null;
    defer sysClose(fd);
    var buf = std.ArrayList(u8).empty;
    var chunk: [8192]u8 = undefined;
    while (true) {
        const n = std.posix.read(fd, &chunk) catch return null;
        if (n == 0) break;
        buf.appendSlice(alloc, chunk[0..n]) catch return null;
        if (buf.items.len > 1 << 20) return null;
    }
    return buf.items;
}

fn envVar(alloc: std.mem.Allocator, key: []const u8) ?[]const u8 {
    if (comptime have_libc) {
        const k = std.fmt.allocPrintSentinel(alloc, "{s}", .{key}, 0) catch return null;
        const v = std.c.getenv(k.ptr) orelse return null;
        return std.mem.span(v);
    }
    if (comptime builtin.os.tag == .linux) {
        const raw = readFileAbs(alloc, "/proc/self/environ") orelse return null;
        var it = std.mem.splitScalar(u8, raw, 0);
        while (it.next()) |entry| {
            if (std.mem.startsWith(u8, entry, key) and entry.len > key.len and entry[key.len] == '=') {
                return entry[key.len + 1 ..];
            }
        }
    }
    return null;
}

fn nowMs() i64 {
    if (comptime have_libc) {
        var ts: std.c.timespec = undefined;
        if (std.c.clock_gettime(.REALTIME, &ts) == 0) {
            return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1000000);
        }
        return 0;
    }
    if (comptime builtin.os.tag == .linux) {
        var ts: std.os.linux.timespec = undefined;
        if (std.os.linux.clock_gettime(.REALTIME, &ts) == 0) {
            return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1000000);
        }
    }
    return 0;
}

fn be32(b: []const u8) u32 {
    return std.mem.readInt(u32, b[0..4], .big);
}

/// Parse a TZif file (v1/v2/v3). On malformed input returns null.
fn parseTzif(alloc: std.mem.Allocator, data: []const u8) ?Zone {
    if (data.len < 44 or !std.mem.eql(u8, data[0..4], "TZif")) return null;
    const ver = data[4];
    var zone = Zone{};
    var counts: []const u8 = data[20..44];
    var body = data[44..];
    var is64 = false;
    if (ver == '2' or ver == '3' or ver == '4') {
        // Skip the 32-bit block; keep only its ttinfo if no 64-bit follows.
        const tc1 = be32(counts[12..16]);
        const ty1 = be32(counts[16..20]);
        const ch1 = be32(counts[20..24]);
        const le1 = be32(counts[8..12]);
        const sw1 = be32(counts[4..8]);
        const gu1 = be32(counts[0..4]);
        const skip = tc1 * 5 + ty1 * 6 + ch1 + le1 * 8 + sw1 + gu1;
        if (body.len < skip + 44 or !std.mem.eql(u8, body[skip .. skip + 4], "TZif")) return null;
        counts = body[skip + 20 .. skip + 44];
        body = body[skip + 44 ..];
        is64 = true;
    }
    const isut = be32(counts[0..4]);
    const isstd = be32(counts[4..8]);
    const leaps = be32(counts[8..12]);
    const tcnt = be32(counts[12..16]);
    const tycnt = be32(counts[16..20]);
    const charcnt = be32(counts[20..24]);
    const trans_bytes: usize = if (is64) @as(usize, tcnt) * 8 else @as(usize, tcnt) * 4;
    const leap_bytes: usize = if (is64) 12 else 8;
    const need = @as(usize, trans_bytes) + tcnt + tycnt * 6 + charcnt + leaps * leap_bytes + isstd + isut;
    if (body.len < need) return null;

    const transitions = alloc.alloc(i64, tcnt) catch return null;
    var i: usize = 0;
    while (i < tcnt) : (i += 1) {
        const off = i * (@as(usize, if (is64) 8 else 4));
        transitions[i] = if (is64)
            std.mem.readInt(i64, body[off..][0..8], .big)
        else
            @as(i64, std.mem.readInt(i32, body[off..][0..4], .big));
    }
    const idx = body[trans_bytes .. trans_bytes + tcnt];
    const tt_start = trans_bytes + tcnt;
    const types = alloc.alloc(Zone.TtInfo, tycnt) catch return null;
    i = 0;
    while (i < tycnt) : (i += 1) {
        const t = body[tt_start + i * 6 ..];
        types[i] = .{
            .off = std.mem.readInt(i32, t[0..4], .big),
            .dst = t[4] != 0,
        };
    }
    const trans_type = alloc.dupe(u8, idx) catch return null;
    for (trans_type) |t| {
        if (t >= tycnt) return null;
    }
    zone.transitions = transitions;
    zone.trans_type = trans_type;
    zone.types = types;

    // POSIX footer for instants past the last transition.
    if (is64) {
        const tail = body[need..];
        if (tail.len >= 2 and tail[0] == '\n') {
            const end = std.mem.indexOfScalarPos(u8, tail, 1, '\n') orelse tail.len;
            if (end > 1) zone.footer = parsePosixSpec(tail[1..end]);
        }
    }
    return zone;
}

/// Parse a POSIX TZ spec: `std offset [dst [offset] [,start[/t],end[/t]]]`.
/// POSIX offsets count minutes WEST of Greenwich, so stored offsets are
/// negated into seconds-east.
fn parsePosixSpec(s_in: []const u8) ?Posix {
    var s = s_in;
    _ = skipName(&s) orelse return null;
    const std_secs = parseTzOffset(&s) orelse return null;
    var p = Posix{ .std_off = -std_secs };
    if (s.len == 0) return p;
    _ = skipName(&s) orelse return p; // no DST name -> fixed offset
    var dst_off = p.std_off + 3600;
    if (s.len > 0 and s[0] != ',') {
        dst_off = -(parseTzOffset(&s) orelse return p);
    }
    var dst = Posix.Dst{ .off = dst_off, .start = defaultStart(), .end = defaultEnd() };
    if (s.len > 0 and s[0] == ',') {
        s = s[1..];
        dst.start = parsePosixRule(&s) orelse return p;
        if (s.len == 0 or s[0] != ',') return p;
        s = s[1..];
        dst.end = parsePosixRule(&s) orelse return p;
    }
    p.dst = dst;
    return p;
}

fn defaultStart() PosixRule {
    return .{ .month = 3, .week = 2, .wday = 0 };
}

fn defaultEnd() PosixRule {
    return .{ .month = 11, .week = 1, .wday = 0 };
}

fn skipName(s: *[]const u8) ?void {
    if (s.len == 0) return null;
    if (s.*[0] == '<') {
        const close = std.mem.indexOfScalar(u8, s.*, '>') orelse return null;
        s.* = s.*[close + 1 ..];
        return;
    }
    var n: usize = 0;
    while (n < s.len and (std.ascii.isAlphabetic(s.*[n]) or s.*[n] == '+' or s.*[n] == '-')) n += 1;
    if (n < 3) return null;
    s.* = s.*[n..];
}

/// POSIX `hh[:mm[:ss]]` — positive means west of Greenwich.
fn parseTzOffset(s: *[]const u8) ?i32 {
    var i: usize = 0;
    var neg = false;
    if (i < s.len and (s.*[i] == '+' or s.*[i] == '-')) {
        neg = s.*[i] == '-';
        i += 1;
    }
    var parts: [3]i64 = .{ 0, 0, 0 };
    var np: usize = 0;
    while (np < 3) : (np += 1) {
        var v: i64 = 0;
        var nd: usize = 0;
        while (i + nd < s.len and std.ascii.isDigit(s.*[i + nd])) : (nd += 1) {
            v = v * 10 + (s.*[i + nd] - '0');
        }
        if (nd == 0) {
            if (np == 0) return null;
            break;
        }
        parts[np] = v;
        i += nd;
        if (i < s.len and s.*[i] == ':') {
            i += 1;
        } else break;
    }
    const secs = parts[0] * 3600 + parts[1] * 60 + parts[2];
    s.* = s.*[i..];
    const r: i32 = @intCast(@min(secs, 24 * 3600 * 7));
    return if (neg) -r else r;
}

fn parsePosixRule(s: *[]const u8) ?PosixRule {
    var s_ = s.*;
    var r = PosixRule{};
    if (s_.len == 0) return null;
    if (s_[0] == 'J') {
        s_ = s_[1..];
        r.jday = @intCast(parseUint(&s_) orelse return null);
        if (r.jday < 1 or r.jday > 365) return null;
    } else if (s_[0] == 'M') {
        s_ = s_[1..];
        r.month = @intCast(parseUint(&s_) orelse return null);
        if (s_.len == 0 or s_[0] != '.') return null;
        s_ = s_[1..];
        r.week = @intCast(parseUint(&s_) orelse return null);
        if (s_.len == 0 or s_[0] != '.') return null;
        s_ = s_[1..];
        r.wday = @intCast(parseUint(&s_) orelse return null);
        if (r.month < 1 or r.month > 12 or r.week < 1 or r.week > 5 or r.wday > 6) return null;
    } else {
        r.yday = @intCast(parseUint(&s_) orelse return null);
        if (r.yday > 365) return null;
    }
    if (s_.len > 0 and s_[0] == '/') {
        s_ = s_[1..];
        r.secs = parseTzOffset(&s_) orelse return null;
    }
    s.* = s_;
    return r;
}

fn parseUint(s: *[]const u8) ?i64 {
    var i: usize = 0;
    var v: i64 = 0;
    while (i < s.len and std.ascii.isDigit(s.*[i])) : (i += 1) {
        v = v * 10 + (s.*[i] - '0');
    }
    if (i == 0) return null;
    defer s.* = s.*[i..];
    return v;
}

const zoneinfo_dirs = [_][]const u8{
    "/usr/share/zoneinfo",
    "/var/db/timezone/zoneinfo",
    "/usr/lib/zoneinfo",
    "/etc/zoneinfo",
};

fn loadZone(alloc: std.mem.Allocator) Zone {
    if (envVar(alloc, "TZ")) |tz_env| {
        var v = std.mem.trim(u8, tz_env, " \t\r\n");
        if (v.len > 0 and v[0] == ':') v = v[1..];
        if (v.len == 0) return .{};
        if (v[0] == '/') {
            if (readFileAbs(alloc, v)) |data| {
                if (parseTzif(alloc, data)) |z| return z;
            }
        } else {
            for (zoneinfo_dirs) |dir| {
                const path = std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, v }) catch continue;
                if (readFileAbs(alloc, path)) |data| {
                    if (parseTzif(alloc, data)) |z| return z;
                }
            }
            if (parsePosixSpec(v)) |p| {
                var z = Zone{};
                z.footer = p;
                return z;
            }
        }
        return .{};
    }
    if (readFileAbs(alloc, "/etc/localtime")) |data| {
        if (parseTzif(alloc, data)) |z| return z;
    }
    return .{};
}

/// `new Date(y,m,...)` local-time construction: resolve the offset for the
/// naive wall time, converging on the offset in effect at the answer. On a
/// spring-forward gap the clock moves forward; on a fall-back overlap the
/// first (pre-transition) reading wins, matching JS.
fn localMs(zone: *const Zone, year: i64, month0: i64, day: i64, h: i64, mi: i64, s: i64, ms: i64) i64 {
    const naive = utcMs(year, month0, day, h, mi, s, ms);
    const target = wallFromMs(naive); // normalized (fields may overflow)
    const off0 = @as(i64, zone.offsetAt(@divFloor(naive, 1000)));
    var off = off0;
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const t = naive - off * 1000;
        const w = wallFromMs(t + off * 1000);
        if (w.year == target.year and w.month0 == target.month0 and w.day == target.day and
            w.hour == target.hour and w.minute == target.minute and w.second == target.second and
            w.ms == target.ms) return t;
        const off2 = @as(i64, zone.offsetAt(@divFloor(t, 1000)));
        if (off2 == off) break;
        off = off2;
    }
    // Spring-forward gap: JS shifts forward to the first guess.
    return naive - off0 * 1000;
}

fn adjustedYear(y: i64) i64 {
    return if (y >= 0 and y <= 99) y + 1900 else y;
}

// --------------------------------------------------------------------
// Lenient parse: bundled-dayjs regex, then a Date.parse-style fallback.

const months_short = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
const months_full = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
const weekdays_full = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };

const ParseResult = union(enum) { local: Wall, instant: i64 };

/// `/^(\d{4})[-/]?(\d{1,2})?[-/]?(\d{0,2})[Tt\s]*(\d{1,2})?:?(\d{1,2})?:?(\d{1,2})?[.:]?(\d+)?$/`
fn dayjsRegexParse(t: []const u8) ?Wall {
    var i: usize = 0;
    if (t.len < 4) return null;
    var year: i64 = 0;
    while (i < 4) : (i += 1) {
        if (!std.ascii.isDigit(t[i])) return null;
        year = year * 10 + (t[i] - '0');
    }
    var month: i64 = 1;
    var day: i64 = 1;
    var h: i64 = 0;
    var mi: i64 = 0;
    var s: i64 = 0;
    var ms: i64 = 0;

    if (i < t.len and (t[i] == '-' or t[i] == '/')) i += 1;
    var nd: usize = 0;
    while (i + nd < t.len and nd < 2 and std.ascii.isDigit(t[i + nd])) nd += 1;
    if (nd > 0) {
        month = std.fmt.parseInt(i64, t[i .. i + nd], 10) catch return null;
        i += nd;
        if (i < t.len and (t[i] == '-' or t[i] == '/')) i += 1;
        nd = 0;
        while (i + nd < t.len and nd < 2 and std.ascii.isDigit(t[i + nd])) nd += 1;
        if (nd > 0) {
            day = std.fmt.parseInt(i64, t[i .. i + nd], 10) catch return null;
            i += nd;
        }
    }
    while (i < t.len and (t[i] == 'T' or t[i] == 't' or t[i] == ' ' or t[i] == '\t' or t[i] == '\r' or t[i] == '\n' or t[i] == '\x0b' or t[i] == '\x0c')) i += 1;
    // HH[:MM[:SS[.fff]]] — every group optional, separators optional.
    nd = 0;
    while (i + nd < t.len and nd < 2 and std.ascii.isDigit(t[i + nd])) nd += 1;
    if (nd > 0) {
        h = std.fmt.parseInt(i64, t[i .. i + nd], 10) catch return null;
        i += nd;
        if (i < t.len and t[i] == ':') i += 1;
        nd = 0;
        while (i + nd < t.len and nd < 2 and std.ascii.isDigit(t[i + nd])) nd += 1;
        if (nd > 0) {
            mi = std.fmt.parseInt(i64, t[i .. i + nd], 10) catch return null;
            i += nd;
            if (i < t.len and t[i] == ':') i += 1;
            nd = 0;
            while (i + nd < t.len and nd < 2 and std.ascii.isDigit(t[i + nd])) nd += 1;
            if (nd > 0) {
                s = std.fmt.parseInt(i64, t[i .. i + nd], 10) catch return null;
                i += nd;
            }
        }
    }
    if (i < t.len and (t[i] == '.' or t[i] == ':')) {
        i += 1;
        var digits: usize = 0;
        var val: i64 = 0;
        while (i + digits < t.len and std.ascii.isDigit(t[i + digits])) : (digits += 1) {
            if (digits < 3) val = val * 10 + (t[i + digits] - '0');
        }
        ms = val;
        i += digits;
    }
    if (i != t.len) return null;
    return .{
        .year = year,
        .month0 = month - 1,
        .day = day,
        .wday = 0,
        .hour = h,
        .minute = mi,
        .second = s,
        .ms = ms,
    };
}

const tz_names = [_]struct { name: []const u8, min: i32 }{
    .{ .name = "gmt", .min = 0 },
    .{ .name = "ut", .min = 0 },
    .{ .name = "utc", .min = 0 },
    .{ .name = "z", .min = 0 },
    .{ .name = "est", .min = -300 },
    .{ .name = "edt", .min = -240 },
    .{ .name = "cst", .min = -360 },
    .{ .name = "cdt", .min = -300 },
    .{ .name = "mst", .min = -420 },
    .{ .name = "mdt", .min = -360 },
    .{ .name = "pst", .min = -480 },
    .{ .name = "pdt", .min = -420 },
};

fn monthIndex(word: []const u8) ?i64 {
    if (word.len < 3) return null;
    for (months_full, 0..) |m, idx| {
        if (word.len <= m.len and std.ascii.eqlIgnoreCase(word, m[0..word.len])) return @intCast(idx);
    }
    return null;
}

fn weekdayIndex(word: []const u8) bool {
    for (weekdays_full) |w| {
        if (word.len >= 3 and word.len <= w.len and std.ascii.eqlIgnoreCase(word, w[0..word.len])) return true;
    }
    return false;
}

fn tzNameOffset(word: []const u8) ?i32 {
    for (tz_names) |t| {
        if (std.ascii.eqlIgnoreCase(word, t.name)) return t.min;
    }
    return null;
}

/// The `new Date(str)` fallback: month names, weekday names (skipped),
/// US-style number dates, colon-separated times, am/pm, zone names and
/// numeric offsets. Numeric fields out of range fail rather than roll
/// over — except times, where oversized minutes/seconds read as 00.
fn v8Parse(s_in: []const u8) ?ParseResult {
    const s = std.mem.trim(u8, s_in, " \t\r\n\x0b\x0c");
    var nums: [4]i64 = undefined;
    var nnum: usize = 0;
    var month: i64 = -1;
    var day: i64 = -1;
    var year: i64 = -1;
    var hour: i64 = -1;
    var minute: i64 = 0;
    var second: i64 = 0;
    var ms: i64 = 0;
    var pm: i8 = 0; // 1 am, 2 pm
    var tzmin: ?i32 = null;
    var saw_time = false;
    var saw_iso_t = false;
    var i: usize = 0;
    var prev_was_num = false;

    while (i < s.len) {
        const c = s[i];
        if (std.ascii.isDigit(c)) {
            var j = i;
            var v: i64 = 0;
            while (j < s.len and std.ascii.isDigit(s[j])) : (j += 1) v = v * 10 + (s[j] - '0');
            if (j < s.len and s[j] == ':') {
                // Time run: h:mm[:ss[.frac]] — V8 fraction-of-second ms.
                if (v >= 24) return null;
                hour = v;
                saw_time = true;
                j += 1;
                var nd: usize = 0;
                var mv: i64 = 0;
                while (j + nd < s.len and std.ascii.isDigit(s[j + nd])) : (nd += 1) mv = mv * 10 + (s[j + nd] - '0');
                minute = if (nd == 0) 0 else if (mv > 59) 0 else mv;
                j += nd;
                if (j < s.len and s[j] == ':') {
                    j += 1;
                    nd = 0;
                    var sv: i64 = 0;
                    while (j + nd < s.len and std.ascii.isDigit(s[j + nd])) : (nd += 1) sv = sv * 10 + (s[j + nd] - '0');
                    second = if (nd == 0) 0 else if (sv > 59) 0 else sv;
                    j += nd;
                    if (j < s.len and (s[j] == '.' or s[j] == ',')) {
                        j += 1;
                        var frac: i64 = 0;
                        var scale: i64 = 100;
                        var fd: usize = 0;
                        while (j + fd < s.len and std.ascii.isDigit(s[j + fd])) : (fd += 1) {
                            if (scale > 0) {
                                frac += (s[j + fd] - '0') * scale;
                                scale = @divTrunc(scale, 10);
                            }
                        }
                        ms = frac;
                        j += fd;
                    }
                }
                i = j;
                prev_was_num = false;
                continue;
            }
            if (nnum >= nums.len) return null;
            nums[nnum] = v;
            nnum += 1;
            i = j;
            prev_was_num = true;
            continue;
        }
        if (std.ascii.isAlphabetic(c)) {
            var j = i;
            while (j < s.len and std.ascii.isAlphabetic(s[j])) : (j += 1) {}
            const word = s[i..j];
            const is_iso_t = word.len == 1 and (word[0] == 'T' or word[0] == 't') and !saw_time;
            if (prev_was_num and !is_iso_t and tzNameOffset(word) == null) return null; // "10pm", "01abc"
            if (monthIndex(word)) |m| {
                month = m;
            } else if (weekdayIndex(word)) {
                // skipped
            } else if (std.ascii.eqlIgnoreCase(word, "am")) {
                pm = 1;
            } else if (std.ascii.eqlIgnoreCase(word, "pm")) {
                pm = 2;
            } else if (word.len == 1 and (word[0] == 'T' or word[0] == 't')) {
                if (saw_time) return null;
                saw_iso_t = true;
            } else if (tzNameOffset(word)) |off| {
                if (saw_iso_t and saw_time and (word.len != 1 or word[0] != 'Z' and word[0] != 'z')) return null; // T-form rejects zone names
                tzmin = off;
            } else {
                return null;
            }
            i = j;
            prev_was_num = false;
            continue;
        }
        if ((c == '+' or c == '-')) {
            // Signed digits after a time are a zone offset; otherwise the
            // sign is a separator and the digits land in the date pool.
            var j = i + 1;
            var v: i64 = 0;
            var nd: usize = 0;
            while (j + nd < s.len and std.ascii.isDigit(s[j + nd])) : (nd += 1) v = v * 10 + (s[j + nd] - '0');
            const neg = c == '-';
            const signed_time = nd > 0 and j + nd < s.len and s[j + nd] == ':';
            if (saw_time and nd > 0 and (signed_time or nd == 4 or nd == 2)) {
                var tmin = v;
                if (signed_time) {
                    j += nd + 1;
                    var mm: i64 = 0;
                    var md: usize = 0;
                    while (j + md < s.len and std.ascii.isDigit(s[j + md])) : (md += 1) mm = mm * 10 + (s[j + md] - '0');
                    tmin = v * 60 + mm;
                    j += md;
                } else {
                    tmin = @divTrunc(v, 100) * 60 + @mod(v, 100);
                    j += nd;
                }
                tzmin = @intCast(if (neg) -tmin else tmin);
                i = j;
                prev_was_num = false;
                continue;
            }
            if (signed_time) return null; // offset before a time is rejected
            if (nnum >= nums.len) return null;
            nums[nnum] = v;
            nnum += 1;
            i = j + nd;
            prev_was_num = true;
            continue;
        }
        // Every other byte is a separator (space, comma, dot, colon,
        // slash is folded into digit handling above).
        i += 1;
        prev_was_num = false;
    }

    if (nnum == 0 and month < 0) return null; // no date components at all

    // Assign the collected date numbers.
    if (month >= 0) {
        for (nums[0..nnum]) |n| {
            if (day < 0 and n <= 31) {
                day = n;
            } else if (year < 0) {
                year = n;
            } else return null;
        }
    } else switch (nnum) {
        1 => {
            const n = nums[0];
            if (n == 0) {
                year = 0;
            } else if (n <= 12) {
                month = n - 1;
            } else if (n <= 31) {
                return null; // ambiguous bare number
            } else {
                year = n;
            }
        },
        2 => {
            if (nums[0] > 31) {
                year = nums[0];
                month = nums[1] - 1;
            } else {
                month = nums[0] - 1;
                day = nums[1];
            }
        },
        3 => {
            if (nums[0] > 31 or nums[0] >= 1000) {
                year = nums[0];
                month = nums[1] - 1;
                day = nums[2];
            } else {
                month = nums[0] - 1;
                day = nums[1];
                year = nums[2];
            }
        },
        else => return null,
    }

    if (month < 0) month = 0;
    if (day < 0) day = 1;
    if (year < 0) year = 2001;
    // The parse-side 2-digit year pivot: <50 -> 2000s, 50-99 -> 1900s.
    if (year >= 0 and year < 50) year += 2000 else if (year < 100) year += 1900;

    if (month < 0 or month > 11 or day < 1 or day > 31) return null;
    if (pm != 0) {
        if (hour < 0) return null;
        if (pm == 2 and hour < 12) hour += 12;
        if (pm == 1 and hour == 12) hour = 0;
    }
    if (hour < 0) hour = 0;

    if (tzmin) |off| {
        return .{ .instant = utcMs(year, month, day, hour, minute, second, ms) - @as(i64, off) * 60000 };
    }
    return .{ .local = .{
        .year = year,
        .month0 = month,
        .day = day,
        .wday = 0,
        .hour = hour,
        .minute = minute,
        .second = second,
        .ms = ms,
    } };
}

fn parseLenient(text: []const u8, zone: *const Zone) ?i64 {
    const t = std.mem.trim(u8, text, " \t\r\n\x0b\x0c");
    if (t.len == 0) return null;
    const ends_z = t[t.len - 1] == 'Z' or t[t.len - 1] == 'z';
    if (!ends_z) {
        if (dayjsRegexParse(t)) |w| {
            return localMs(zone, w.year, w.month0, w.day, w.hour, w.minute, w.second, w.ms);
        }
    }
    const r = v8Parse(t) orelse return null;
    return switch (r) {
        .instant => |ms| ms,
        .local => |w| localMs(zone, w.year, w.month0, w.day, w.hour, w.minute, w.second, w.ms),
    };
}

// --------------------------------------------------------------------
// Strict parse: dayjs customParseFormat — token table, default filling
// from the current date, zone offsets, meridiem, and the strict
// round-trip re-format check.

const StrictFields = struct {
    year: ?i64 = null,
    month: ?i64 = null, // 1-12
    day: ?i64 = null,
    week: ?i64 = null,
    hour: ?i64 = null,
    minute: ?i64 = null,
    second: ?i64 = null,
    ms: ?i64 = null,
    zone_min: ?i32 = null,
    pm: ?bool = null,
    epoch_ms: ?i64 = null,
};

const StrictTok = struct {
    kind: enum { lit, tok },
    lit: []const u8 = "",
    id: u8 = 0, // for tok: a token id
    len: u8 = 0,
};

const localized_presets = [_]struct { name: []const u8, fmt: []const u8 }{
    .{ .name = "LTS", .fmt = "h:mm:ss A" },
    .{ .name = "LT", .fmt = "h:mm A" },
    .{ .name = "LLLL", .fmt = "dddd, MMMM D, YYYY h:mm A" },
    .{ .name = "LLL", .fmt = "MMMM D, YYYY h:mm A" },
    .{ .name = "LL", .fmt = "MMMM D, YYYY" },
    .{ .name = "L", .fmt = "MM/DD/YYYY" },
    .{ .name = "llll", .fmt = "ddd, MMM D, YYYY h:mm A" },
    .{ .name = "lll", .fmt = "MMM D, YYYY h:mm A" },
    .{ .name = "ll", .fmt = "MMM D, YYYY" },
    .{ .name = "l", .fmt = "M/D/YYYY" },
};

/// Tokenize a strict parse format: `[literal]`, separator runs
/// `[-_:/.,()\s]+`, L-presets, and the token alternation; everything else
/// drops out of the stream entirely (JS `.match` semantics).
fn strictTokens(alloc: std.mem.Allocator, fmt: []const u8) Error![]StrictTok {
    var expanded = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < fmt.len) {
        if (fmt[i] == '[') {
            const close = std.mem.indexOfScalarPos(u8, fmt, i + 1, ']') orelse fmt.len;
            try expanded.appendSlice(alloc, fmt[i..@min(close + 1, fmt.len)]);
            i = @min(close + 1, fmt.len);
            continue;
        }
        var matched = false;
        for (localized_presets) |p| {
            if (std.mem.startsWith(u8, fmt[i..], p.name)) {
                try expanded.appendSlice(alloc, p.fmt);
                i += p.name.len;
                matched = true;
                break;
            }
        }
        if (!matched) {
            try expanded.append(alloc, fmt[i]);
            i += 1;
        }
    }
    // Note: L-presets inside [...] literals expand in dayjs too (replace
    // runs before bracket handling).

    var toks = std.ArrayList(StrictTok).empty;
    i = 0;
    const e = expanded.items;
    while (i < e.len) {
        const c = e[i];
        if (c == '[') {
            const close = std.mem.indexOfScalarPos(u8, e, i + 1, ']') orelse {
                try toks.append(alloc, .{ .kind = .lit, .lit = e[i .. i + 1] });
                i += 1;
                continue;
            };
            try toks.append(alloc, .{ .kind = .lit, .lit = e[i + 1 .. close] });
            i = close + 1;
            continue;
        }
        if (isStrictSep(c)) {
            var j = i;
            while (j < e.len and isStrictSep(e[j])) j += 1;
            try toks.append(alloc, .{ .kind = .lit, .lit = e[i..j] });
            i = j;
            continue;
        }
        if (strictTokenAt(e[i..])) |t| {
            try toks.append(alloc, t);
            i += t.len;
            continue;
        }
        i += 1; // unmatched char: dropped from the token stream
    }
    return toks.items;
}

fn isStrictSep(c: u8) bool {
    return switch (c) {
        '-', '_', ':', '/', '.', ',', '(', ')', ' ', '\t', '\r', '\n', 0x0b, 0x0c => true,
        else => false,
    };
}

/// `(A|a|Q|YYYY|YY?|ww?|MM?M?M?|Do|DD?|hh?|HH?|mm?|ss?|S{1,3}|z|ZZ?)` —
/// longest alternatives first where ambiguous.
fn strictTokenAt(s: []const u8) ?StrictTok {
    if (s.len == 0) return null;
    const c0 = s[0];
    const two = if (s.len > 1) s[1] else 0;
    switch (c0) {
        'A', 'a' => return .{ .kind = .tok, .id = c0, .len = 1 },
        'Q' => return .{ .kind = .tok, .id = 'Q', .len = 1 },
        'X', 'x' => return .{ .kind = .tok, .id = c0, .len = 1 },
        'Y' => {
            if (std.mem.startsWith(u8, s, "YYYY")) return .{ .kind = .tok, .id = 'Y', .len = 4 };
            if (two == 'Y') return .{ .kind = .tok, .id = 'y', .len = 2 };
            return .{ .kind = .tok, .id = 'Y', .len = 1 }; // Y = [+-]?\d+
        },
        'w' => {
            if (two == 'w') return .{ .kind = .tok, .id = 'w', .len = 2 };
            return .{ .kind = .tok, .id = 'w', .len = 1 };
        },
        'M' => {
            var n: usize = 1;
            while (n < 4 and n < s.len and s[n] == 'M') n += 1;
            return .{ .kind = .tok, .id = 'M', .len = @intCast(n) };
        },
        'D' => {
            if (two == 'o') return .{ .kind = .tok, .id = 'o', .len = 2 };
            if (two == 'D') return .{ .kind = .tok, .id = 'D', .len = 2 };
            return .{ .kind = .tok, .id = 'D', .len = 1 };
        },
        'h', 'H', 'm', 's' => {
            const id: u8 = c0;
            if (two == c0) return .{ .kind = .tok, .id = id, .len = 2 };
            return .{ .kind = .tok, .id = id, .len = 1 };
        },
        'S' => {
            var n: usize = 1;
            while (n < 3 and n < s.len and s[n] == 'S') n += 1;
            return .{ .kind = .tok, .id = 'S', .len = @intCast(n) };
        },
        'z' => return .{ .kind = .lit, .lit = s[0..1] }, // 'z' is literal in parse
        'Z' => {
            if (two == 'Z') return .{ .kind = .tok, .id = 'Z', .len = 2 };
            return .{ .kind = .tok, .id = 'Z', .len = 1 };
        },
        else => return null,
    }
}

/// One strict-parse token's match at or after `r` in `e` — regexes are
/// unanchored, matching the plugin's `exec(e.slice(r))`. Returns the
/// matched text and records the field.
const NumWord = union(enum) { num: i64, word: []const u8 };

fn strictMatch(e: []const u8, r: usize, tok: StrictTok, f: *StrictFields) ?NumWord {
    const hay = e[@min(r, e.len)..];
    switch (tok.id) {
        'S' => {
            const want: usize = tok.len;
            const m = matchDigits(hay, want, want) orelse return null;
            f.ms = m.value * switch (want) {
                1 => @as(i64, 100),
                2 => 10,
                else => 1,
            };
            return .{ .word = hay[m.start..m.end] };
        },
        's', 'm', 'H', 'h', 'D', 'w' => {
            const m = matchDigits(hay, tok.len, 2) orelse return null;
            const v = m.value;
            switch (tok.id) {
                's' => f.second = v,
                'm' => f.minute = v,
                'H', 'h' => f.hour = v,
                'D' => f.day = v,
                'w' => f.week = v,
                else => unreachable,
            }
            return .{ .word = hay[m.start..m.end] };
        },
        'M' => {
            if (tok.len <= 2) {
                const m = matchDigits(hay, tok.len, 2) orelse return null;
                f.month = m.value;
                return .{ .word = hay[m.start..m.end] };
            }
            const m = matchNumWord(hay) orelse return null;
            const w = hay[m.start..m.end];
            if (tok.len == 3) {
                for (months_short, 0..) |name, idx| {
                    if (std.ascii.eqlIgnoreCase(w, name)) {
                        f.month = @intCast(idx + 1);
                        return .{ .word = w };
                    }
                }
            } else {
                for (months_full, 0..) |name, idx| {
                    if (std.ascii.eqlIgnoreCase(w, name)) {
                        f.month = @intCast(idx + 1);
                        return .{ .word = w };
                    }
                }
            }
            return null;
        },
        'o' => { // Do: word containing digits
            const m = matchNumWord(hay) orelse return null;
            const w = hay[m.start..m.end];
            var di: usize = 0;
            while (di < w.len and !std.ascii.isDigit(w[di])) di += 1;
            var dj = di;
            var dv: i64 = 0;
            while (dj < w.len and std.ascii.isDigit(w[dj])) : (dj += 1) dv = dv * 10 + (w[dj] - '0');
            if (dj == di) return null;
            f.day = dv;
            var k: i64 = 1;
            while (k <= 31) : (k += 1) {
                var nb: [8]u8 = undefined;
                const o = std.fmt.bufPrint(&nb, "{d}{s}", .{ k, ordinalSuffix(k) }) catch unreachable;
                if (std.mem.eql(u8, o, w)) f.day = k;
            }
            return .{ .word = w };
        },
        'Y' => {
            if (tok.len == 4) {
                const m = matchDigits(hay, 4, 4) orelse return null;
                f.year = m.value;
                return .{ .word = hay[m.start..m.end] };
            }
            // Y: [+-]?\d+
            const idx = std.mem.indexOfAny(u8, hay, "+-0123456789") orelse return null;
            var j = idx;
            var neg = false;
            if (hay[j] == '+' or hay[j] == '-') {
                neg = hay[j] == '-';
                j += 1;
            }
            var nd: usize = 0;
            var v: i64 = 0;
            while (j + nd < hay.len and std.ascii.isDigit(hay[j + nd])) : (nd += 1) v = v * 10 + (hay[j + nd] - '0');
            if (nd == 0) return null;
            f.year = if (neg) -v else v;
            return .{ .word = hay[idx .. j + nd] };
        },
        'y' => { // YY: \d\d -> pivot at 68
            const m = matchDigits(hay, 2, 2) orelse return null;
            f.year = m.value + (if (m.value > 68) @as(i64, 1900) else 2000);
            return .{ .word = hay[m.start..m.end] };
        },
        'A', 'a' => {
            const m = matchNumWord(hay) orelse return null;
            const w = hay[m.start..m.end];
            f.pm = std.mem.eql(u8, w, if (tok.id == 'a') "pm" else "PM");
            return .{ .word = w };
        },
        'Z' => {
            // /[+-]\d\d:?(\d\d)?|Z/ — offset alternative tried first.
            var idx: usize = 0;
            while (idx < hay.len) : (idx += 1) {
                const c = hay[idx];
                if ((c == '+' or c == '-') and idx + 2 < hay.len and
                    std.ascii.isDigit(hay[idx + 1]) and std.ascii.isDigit(hay[idx + 2]))
                {
                    var j = idx + 3;
                    var mm: i32 = 0;
                    var end = j;
                    if (j < hay.len and hay[j] == ':') j += 1;
                    var nd: usize = 0;
                    while (j + nd < hay.len and nd < 2 and std.ascii.isDigit(hay[j + nd])) : (nd += 1) {}
                    if (nd == 2) {
                        mm = @intCast(std.fmt.parseInt(i64, hay[j .. j + 2], 10) catch return null);
                        end = j + 2;
                    }
                    const hh: i32 = @intCast(std.fmt.parseInt(i64, hay[idx + 1 .. idx + 3], 10) catch return null);
                    var off = hh * 60 + mm;
                    if (off != 0 and hay[idx] == '+') off = -off;
                    f.zone_min = off;
                    return .{ .word = hay[idx..end] };
                }
                if (c == 'Z') {
                    f.zone_min = 0;
                    return .{ .word = hay[idx .. idx + 1] };
                }
            }
            return null;
        },
        'Q' => {
            const m = matchDigits(hay, 1, 1) orelse return null;
            f.month = 3 * (m.value - 1) + 1;
            return .{ .word = hay[m.start..m.end] };
        },
        'X' => { // epoch seconds
            const m = matchDigits(hay, 1, 20) orelse return null;
            f.epoch_ms = m.value * 1000;
            return .{ .word = hay[m.start..m.end] };
        },
        'x' => { // epoch milliseconds
            const m = matchDigits(hay, 1, 20) orelse return null;
            f.epoch_ms = m.value;
            return .{ .word = hay[m.start..m.end] };
        },
        else => return null,
    }
}

const Match = struct { start: usize, end: usize, value: i64 };

fn matchDigits(hay: []const u8, min: usize, max: usize) ?Match {
    var idx: usize = 0;
    while (idx < hay.len) : (idx += 1) {
        if (!std.ascii.isDigit(hay[idx])) continue;
        var nd: usize = 0;
        while (idx + nd < hay.len and nd < max and std.ascii.isDigit(hay[idx + nd])) nd += 1;
        if (nd >= min) {
            return .{
                .start = idx,
                .end = idx + nd,
                .value = std.fmt.parseInt(i64, hay[idx .. idx + nd], 10) catch return null,
            };
        }
        idx += nd; // run too short — keep scanning past it
    }
    return null;
}

/// `/\d*[^-_:/,()\s\d]+/` — optional digits then a non-separator word.
fn matchNumWord(hay: []const u8) ?Match {
    var idx: usize = 0;
    while (idx < hay.len) : (idx += 1) {
        if (isStrictSep(hay[idx])) continue;
        var j = idx;
        while (j < hay.len and std.ascii.isDigit(hay[j])) j += 1;
        const wstart = j;
        while (j < hay.len and !std.ascii.isDigit(hay[j]) and !isStrictSep(hay[j])) j += 1;
        if (j > wstart) return .{ .start = idx, .end = j, .value = 0 };
        if (j > idx) return null; // digits only — regex requires the word
        idx = j;
    }
    return null;
}

fn ordinalText(n: i64, buf: *[4]u8) error{OutOfMemory}![]const u8 {
    const t = @mod(n, 100);
    const suf_idx: usize = blk: {
        const a = @mod(t - 20, 10);
        if (a >= 0 and a <= 3) break :blk @intCast(a);
        if (t >= 0 and t <= 3) break :blk @intCast(t);
        break :blk 0;
    };
    const suf_arr = [_][]const u8{ "th", "st", "nd", "rd" };
    const suf = suf_arr[suf_idx];
    _ = buf;
    return suf;
}

fn ordinalSuffix(n: i64) []const u8 {
    const t = @mod(n, 100);
    const a = @mod(t - 20, 10);
    const suf_arr = [_][]const u8{ "th", "st", "nd", "rd" };
    if (a >= 0 and a <= 3) return suf_arr[@intCast(a)];
    if (t >= 0 and t <= 3) return suf_arr[@intCast(t)];
    return "th";
}

/// Remove the first occurrence of `needle` in `e` — `String.replace` with
/// a string pattern semantics.
fn replaceFirst(alloc: std.mem.Allocator, e: []const u8, needle: []const u8) Error![]const u8 {
    const idx = std.mem.indexOf(u8, e, needle) orelse return e;
    return try std.fmt.allocPrint(alloc, "{s}{s}", .{ e[0..idx], e[idx + needle.len ..] });
}

/// customParseFormat: tokenize the format, consume the input through the
/// token table, fill defaults from "now", then strict-check by re-format.
fn strictParse(it: *Interp, call: parse.FilterCall, text: []const u8, fmt: []const u8, zone: *const Zone) Error!?i64 {
    const toks = try strictTokens(it.alloc, fmt);
    var fields = StrictFields{};
    var e: []const u8 = text;
    var r: usize = 0;
    for (toks) |tok| {
        switch (tok.kind) {
            .lit => r += tok.lit.len,
            .tok => {
                const m = strictMatch(e, r, tok, &fields) orelse return null;
                e = try replaceFirst(it.alloc, e, m.word);
            },
        }
    }
    // Meridiem.
    if (fields.pm) |afternoon| {
        const h = fields.hour orelse 0;
        if (afternoon) {
            if (h < 12) fields.hour = h + 12;
        } else if (h == 12) {
            fields.hour = 0;
        }
    }
    // Defaults come from the current date when absent.
    const now = wallFromMs(nowMs() + @as(i64, zone.offsetAt(@divFloor(nowMs(), 1000))) * 1000);
    const year = fields.year orelse now.year;
    var month0: i64 = 0;
    if (!(fields.year != null and fields.month == null)) {
        month0 = if (fields.month) |m| m - 1 else now.month0;
    }
    const day = fields.day orelse
        (if (fields.year == null and fields.month == null) now.day else 1);

    var ms: i64 = undefined;
    if (fields.epoch_ms) |ep| {
        ms = ep;
    } else if (fields.zone_min) |off| {
        ms = utcMs(year, month0, day, fields.hour orelse 0, fields.minute orelse 0, fields.second orelse 0, fields.ms orelse 0) + @as(i64, off) * 60000;
    } else {
        ms = localMs(zone, year, month0, day, fields.hour orelse 0, fields.minute orelse 0, fields.second orelse 0, fields.ms orelse 0);
    }
    // The 'w' setter: shift the date so its locale week matches.
    if (fields.week) |w| {
        const cur = localeWeek(zone, ms);
        ms += 7 * (w - cur) * 86400000;
    }
    // Strict mode round-trips: the result must re-format back to the input.
    const rt = try formatDate(it, call, fmt, ms, zone);
    if (!std.mem.eql(u8, rt, text)) return null;
    return ms;
}

// --------------------------------------------------------------------
// Output format: advancedFormat replacements first (their `[x]`-wrapped
// results survive the second scan), then the base dayjs token regex.

fn isLeap(y: i64) bool {
    return @mod(y, 4) == 0 and (@mod(y, 100) != 0 or @mod(y, 400) == 0);
}

/// Locale week ('en': weeks start Sunday, week 1 holds Jan 1) — the
/// weekOfYear plugin algorithm, including the late-December year-rollover
/// check and diff-through-DST-adjusted milliseconds.
fn localeWeek(zone: *const Zone, ms: i64) i64 {
    const w = wallFromMs(ms + @as(i64, zone.offsetAt(@divFloor(ms, 1000))) * 1000);
    if (w.month0 == 11 and w.day > 25) {
        const next_jan1 = localMs(zone, w.year + 1, 0, 1, 0, 0, 0, 0);
        const sat_days = daysFromCivil(w.year, w.month0 + 1, w.day) + (6 - w.wday);
        const end_week = localMs(zone, civilFromDays(sat_days).y, civilFromDays(sat_days).m - 1, civilFromDays(sat_days).d, 23, 59, 59, 999);
        if (next_jan1 < end_week) return 1;
    }
    const jan1 = localMs(zone, w.year, 0, 1, 0, 0, 0, 0);
    const jan1_w = wallFromMs(jan1);
    const sun_days = daysFromCivil(jan1_w.year, jan1_w.month0 + 1, jan1_w.day) - jan1_w.wday;
    const sc = civilFromDays(sun_days);
    const year_start_week = localMs(zone, sc.y, sc.m - 1, sc.d, 0, 0, 0, 0) - 1;
    const off_diff = (roundQuarter(zone.offsetAt(@divFloor(year_start_week, 1000))) - roundQuarter(zone.offsetAt(@divFloor(ms, 1000)))) * 60000;
    const diff = @as(f64, @floatFromInt(ms - year_start_week - off_diff)) / 604800000.0;
    if (diff < 0) {
        // o < 0: recurse on the start of this week.
        const this_sun = localMs(zone, civilFromDays(daysFromCivil(w.year, w.month0 + 1, w.day) - w.wday).y, civilFromDays(daysFromCivil(w.year, w.month0 + 1, w.day) - w.wday).m - 1, civilFromDays(daysFromCivil(w.year, w.month0 + 1, w.day) - w.wday).d, 0, 0, 0, 0);
        return localeWeek(zone, this_sun);
    }
    return @intFromFloat(@ceil(diff));
}

fn roundQuarter(off_sec: i64) i64 {
    // 15 * -round(getTimezoneOffset()/15): getTimezoneOffset is truncated
    // minutes of the negated offset.
    const gmt_min = @divTrunc(-off_sec, 60);
    const q = @divTrunc(gmt_min, 15);
    const rem = @mod(gmt_min, 15);
    const rounded = if (@abs(rem) >= 8) q + @intFromBool(gmt_min > 0) - @intFromBool(gmt_min < 0) else q;
    return -15 * rounded;
}

fn isoWeekFields(zone: *const Zone, ms: i64) struct { year: i64, week: i64 } {
    const off = @as(i64, zone.offsetAt(@divFloor(ms, 1000))) * 1000;
    const w = wallFromMs(ms + off);
    const iso_wd = if (w.wday == 0) @as(i64, 7) else w.wday;
    const thursday_days = daysFromCivil(w.year, w.month0 + 1, w.day) + (4 - iso_wd);
    const iso_year = civilFromDays(thursday_days).y;
    const jan1 = daysFromCivil(iso_year, 1, 1);
    const jan1_wd: i64 = @mod(jan1 + 4, 7);
    const jan1_iso = if (jan1_wd == 0) @as(i64, 7) else jan1_wd;
    var adjust = 4 - jan1_iso;
    if (jan1_iso > 4) adjust += 7;
    const week1_thu = jan1 + adjust;
    return .{ .year = iso_year, .week = @divFloor(thursday_days - week1_thu, 7) + 1 };
}

const month_names_short = months_short;
const month_names_full = months_full;
const wday_full = weekdays_full;

fn padInto(out: *std.ArrayList(u8), alloc: std.mem.Allocator, v: i64, width: usize) Error!void {
    var buf: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable;
    if (s.len < width) {
        var pad = width - s.len;
        while (pad > 0) : (pad -= 1) try out.append(alloc, '0');
    }
    try out.appendSlice(alloc, s);
}

fn formatDate(it: *Interp, call: parse.FilterCall, fmt_in: []const u8, ms: i64, zone: *const Zone) Error![]const u8 {
    const fmt = if (fmt_in.len == 0) "YYYY-MM-DDTHH:mm:ssZ" else fmt_in;
    const off_sec = @as(i64, zone.offsetAt(@divFloor(ms, 1000)));
    const w = wallFromMs(ms + off_sec * 1000);
    const alloc = it.alloc;

    // Pass 1: the advancedFormat substitutions.
    var p1 = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < fmt.len) {
        const c = fmt[i];
        if (c == '[') {
            if (std.mem.indexOfScalarPos(u8, fmt, i + 1, ']')) |close| {
                if (close > i + 1) {
                    try p1.appendSlice(alloc, fmt[i .. close + 1]);
                    i = close + 1;
                    continue;
                }
            }
            try p1.append(alloc, c);
            i += 1;
            continue;
        }
        const rest = fmt[i..];
        if (std.mem.startsWith(u8, rest, "Q")) {
            try padInto(&p1, alloc, @divTrunc(w.month0, 3) + 1, 0);
            i += 1;
        } else if (std.mem.startsWith(u8, rest, "wo")) {
            const n = localeWeek(zone, ms);
            var nb: [24]u8 = undefined;
            const ns = std.fmt.bufPrint(&nb, "{d}", .{n}) catch unreachable;
            try p1.append(alloc, '[');
            try p1.appendSlice(alloc, ns);
            try p1.appendSlice(alloc, ordinalSuffix(n));
            try p1.append(alloc, ']');
            i += 2;
        } else if (std.mem.startsWith(u8, rest, "ww")) {
            try padInto(&p1, alloc, localeWeek(zone, ms), 2);
            i += 2;
        } else if (std.mem.startsWith(u8, rest, "w")) {
            try padInto(&p1, alloc, localeWeek(zone, ms), 0);
            i += 1;
        } else if (std.mem.startsWith(u8, rest, "WW")) {
            try padInto(&p1, alloc, isoWeekFields(zone, ms).week, 2);
            i += 2;
        } else if (std.mem.startsWith(u8, rest, "W")) {
            try padInto(&p1, alloc, isoWeekFields(zone, ms).week, 0);
            i += 1;
        } else if (std.mem.startsWith(u8, rest, "zzz")) {
            return filters.failAt(it, call.offset, "filter 'date' failed: format token 'zzz' is not supported (needs a timezone plugin)", .{});
        } else if (std.mem.startsWith(u8, rest, "z")) {
            return filters.failAt(it, call.offset, "filter 'date' failed: format token 'z' is not supported (needs a timezone plugin)", .{});
        } else if (std.mem.startsWith(u8, rest, "gggg")) {
            return filters.failAt(it, call.offset, "filter 'date' failed: format token 'gggg' is not supported (needs a locale week-year plugin)", .{});
        } else if (std.mem.startsWith(u8, rest, "GGGG")) {
            try padInto(&p1, alloc, isoWeekFields(zone, ms).year, 4);
            i += 4;
        } else if (std.mem.startsWith(u8, rest, "Do")) {
            var nb: [24]u8 = undefined;
            const ns = std.fmt.bufPrint(&nb, "{d}", .{w.day}) catch unreachable;
            try p1.append(alloc, '[');
            try p1.appendSlice(alloc, ns);
            try p1.appendSlice(alloc, ordinalSuffix(w.day));
            try p1.append(alloc, ']');
            i += 2;
        } else if (std.mem.startsWith(u8, rest, "X")) {
            try p1.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{d}", .{@divFloor(ms, 1000)}));
            i += 1;
        } else if (std.mem.startsWith(u8, rest, "x")) {
            try p1.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{d}", .{ms}));
            i += 1;
        } else if (std.mem.startsWith(u8, rest, "k")) {
            const kk = std.mem.startsWith(u8, rest, "kk");
            try padInto(&p1, alloc, if (w.hour == 0) 24 else w.hour, if (kk) 2 else 0);
            i += if (kk) 2 else 1;
        } else if (std.mem.startsWith(u8, rest, "S")) {
            try p1.append(alloc, 'S'); // literal: replaced by itself
            i += 1;
        } else {
            try p1.append(alloc, c);
            i += 1;
        }
    }

    // Pass 2: the base dayjs regex over the substituted string.
    var out = std.ArrayList(u8).empty;
    const src = p1.items;
    i = 0;
    const disp_min = roundQuarter(off_sec);
    while (i < src.len) {
        const c = src[i];
        const rest = src[i..];
        if (c == '[') {
            if (std.mem.indexOfScalarPos(u8, src, i + 1, ']')) |close| {
                if (close > i + 1) {
                    try out.appendSlice(alloc, src[i + 1 .. close]);
                    i = close + 1;
                    continue;
                }
            }
            try out.append(alloc, c);
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, rest, "YYYY")) {
            try padInto(&out, alloc, w.year, 4);
            i += 4;
        } else if (std.mem.startsWith(u8, rest, "YY")) {
            var nb: [24]u8 = undefined;
            const ns = std.fmt.bufPrint(&nb, "{d}", .{w.year}) catch unreachable;
            try out.appendSlice(alloc, if (ns.len > 2) ns[ns.len - 2 ..] else ns);
            i += 2;
        } else if (c == 'M') {
            var n: usize = 0;
            while (n < 4 and i + n < src.len and src[i + n] == 'M') n += 1;
            switch (n) {
                1 => try padInto(&out, alloc, w.month0 + 1, 0),
                2 => try padInto(&out, alloc, w.month0 + 1, 2),
                3 => try out.appendSlice(alloc, month_names_short[@intCast(w.month0)]),
                else => try out.appendSlice(alloc, month_names_full[@intCast(w.month0)]),
            }
            i += n;
        } else if (c == 'D' and i + 1 < src.len and src[i + 1] == 'D') {
            try padInto(&out, alloc, w.day, 2);
            i += 2;
        } else if (c == 'D') {
            try padInto(&out, alloc, w.day, 0);
            i += 1;
        } else if (c == 'd') {
            var n: usize = 0;
            while (n < 4 and i + n < src.len and src[i + n] == 'd') n += 1;
            switch (n) {
                1 => try padInto(&out, alloc, w.wday, 0),
                2 => try out.appendSlice(alloc, wday_full[@intCast(w.wday)][0..2]),
                3 => try out.appendSlice(alloc, wday_full[@intCast(w.wday)][0..3]),
                else => try out.appendSlice(alloc, wday_full[@intCast(w.wday)]),
            }
            i += n;
        } else if (c == 'H' or c == 'h') {
            const doubled = i + 1 < src.len and src[i + 1] == c;
            const v = if (c == 'H') w.hour else blk: {
                const h12 = @mod(w.hour, 12);
                break :blk if (h12 == 0) @as(i64, 12) else h12;
            };
            try padInto(&out, alloc, v, if (doubled) 2 else 0);
            i += if (doubled) 2 else 1;
        } else if (c == 'a' or c == 'A') {
            const upper = c == 'A';
            const am = w.hour < 12;
            try out.appendSlice(alloc, if (am) (if (upper) "AM" else "am") else (if (upper) "PM" else "pm"));
            i += 1;
        } else if (c == 'm' or c == 's') {
            const doubled = i + 1 < src.len and src[i + 1] == c;
            const v = if (c == 'm') w.minute else w.second;
            try padInto(&out, alloc, v, if (doubled) 2 else 0);
            i += if (doubled) 2 else 1;
        } else if (std.mem.startsWith(u8, rest, "Z")) {
            const doubled = std.mem.startsWith(u8, rest, "ZZ");
            const sign: u8 = if (disp_min < 0) '-' else '+';
            const a = @abs(disp_min);
            try out.append(alloc, sign);
            try padInto(&out, alloc, @intCast(@divTrunc(a, 60)), 2);
            if (!doubled) try out.append(alloc, ':');
            try padInto(&out, alloc, @intCast(@mod(a, 60)), 2);
            i += if (doubled) 2 else 1;
        } else if (std.mem.startsWith(u8, rest, "SSS")) {
            try padInto(&out, alloc, w.ms, 3);
            i += 3;
        } else {
            try out.append(alloc, c);
            i += 1;
        }
    }
    return out.items;
}

// --------------------------------------------------------------------
// The filters.

fn dateFilter(it: *Interp, call: parse.FilterCall, input: *const Value) Error!*const Value {
    const fmt = (try argText(it, call, 0)) orelse "YYYY-MM-DD";
    const in_fmt = try argText(it, call, 1);
    const text = try inputText(it, input);
    if (text.len == 0) return input;
    const zone = try it.alloc.create(Zone);
    zone.* = loadZone(it.alloc);
    const ms: ?i64 = if (in_fmt) |f|
        try strictParse(it, call, text, f, zone)
    else
        parseLenient(text, zone);
    if (ms == null) {
        // Bare `{{ x | date }}` has no validity guard: an unparseable
        // value renders dayjs's literal "Invalid Date". With an argument
        // present the oracle warns and passes the input through.
        if (call.params.len == 0) return it.make(.{ .string = "Invalid Date" });
        return input;
    }
    const out = try formatDate(it, call, fmt, ms.?, zone);
    return it.make(.{ .string = out });
}

const modify_units = [_][]const u8{ "year", "month", "week", "day", "hour", "minute", "second" };

fn dateModify(it: *Interp, call: parse.FilterCall, input: *const Value) Error!*const Value {
    var arg = std.ArrayList(u8).empty;
    if (call.params.len == 0) {
        return filters.badArg(it, call, "filter 'date_modify' requires a modifier (e.g., date_modify:\"+1 day\")", .{});
    }
    for (call.params, 0..) |_, i| {
        if (i > 0) try arg.append(it.alloc, ',');
        try arg.appendSlice(it.alloc, (try argText(it, call, i)).?);
    }
    const spec = arg.items;
    // ^\s*([+-])\s*(\d+)\s*(\w+)\s*$ — sign required, one modifier only.
    var i: usize = 0;
    while (i < spec.len and std.ascii.isWhitespace(spec[i])) i += 1;
    if (i >= spec.len or (spec[i] != '+' and spec[i] != '-')) {
        return filters.badArg(it, call, "filter 'date_modify' invalid format — use \"+1 day\", \"-2 weeks\", etc.", .{});
    }
    const neg = spec[i] == '-';
    i += 1;
    while (i < spec.len and std.ascii.isWhitespace(spec[i])) i += 1;
    var amount: i64 = 0;
    var nd: usize = 0;
    while (i + nd < spec.len and std.ascii.isDigit(spec[i + nd])) : (nd += 1) {
        amount = amount * 10 + (spec[i + nd] - '0');
    }
    if (nd == 0) {
        return filters.badArg(it, call, "filter 'date_modify' invalid format — use \"+1 day\", \"-2 weeks\", etc.", .{});
    }
    i += nd;
    while (i < spec.len and std.ascii.isWhitespace(spec[i])) i += 1;
    const ustart = i;
    while (i < spec.len and (std.ascii.isAlphanumeric(spec[i]) or spec[i] == '_')) i += 1;
    const unit_raw = spec[ustart..i];
    while (i < spec.len and std.ascii.isWhitespace(spec[i])) i += 1;
    if (i != spec.len or unit_raw.len == 0) {
        return filters.badArg(it, call, "filter 'date_modify' invalid format — use \"+1 day\", \"-2 weeks\", etc.", .{});
    }
    var unit: usize = modify_units.len;
    for (modify_units, 0..) |u, ui| {
        if (std.ascii.eqlIgnoreCase(unit_raw, u) or
            (unit_raw.len == u.len + 1 and std.ascii.eqlIgnoreCase(unit_raw[0 .. unit_raw.len - 1], u) and (unit_raw[unit_raw.len - 1] == 's' or unit_raw[unit_raw.len - 1] == 'S')))
        {
            unit = ui;
            break;
        }
    }
    if (unit == modify_units.len) {
        return filters.badArg(it, call, "filter 'date_modify' invalid unit \"{s}\" — use year, month, week, day, hour, minute, or second", .{unit_raw});
    }
    if (neg) amount = -amount;

    const text = try inputText(it, input);
    if (text.len == 0) return input;
    const zone = try it.alloc.create(Zone);
    zone.* = loadZone(it.alloc);
    var ms = parseLenient(text, zone) orelse return input;

    switch (unit) {
        0, 1 => { // year, month: set-field with day clamped to month length
            const w = wallFromMs(ms + @as(i64, zone.offsetAt(@divFloor(ms, 1000))) * 1000);
            var y = w.year;
            var m0 = w.month0;
            if (unit == 0) {
                y += amount;
            } else {
                const total = y * 12 + m0 + amount;
                y = @divFloor(total, 12);
                m0 = @mod(total, 12);
            }
            const dim = daysFromCivil(y, m0 + 2, 1) - daysFromCivil(y, m0 + 1, 1);
            const d = @min(w.day, dim);
            ms = localMs(zone, y, m0, d, w.hour, w.minute, w.second, w.ms);
        },
        2, 3 => { // week / day: calendar shift, time of day kept
            const w = wallFromMs(ms + @as(i64, zone.offsetAt(@divFloor(ms, 1000))) * 1000);
            const c = civilFromDays(daysFromCivil(w.year, w.month0 + 1, w.day) + amount * (if (unit == 2) @as(i64, 7) else 1));
            ms = localMs(zone, c.y, c.m - 1, c.d, w.hour, w.minute, w.second, w.ms);
        },
        4 => ms += amount * 3600000,
        5 => ms += amount * 60000,
        6 => ms += amount * 1000,
        else => unreachable,
    }

    const w = wallFromMs(ms + @as(i64, zone.offsetAt(@divFloor(ms, 1000))) * 1000);
    var out = std.ArrayList(u8).empty;
    try padInto(&out, it.alloc, w.year, 4);
    try out.append(it.alloc, '-');
    try padInto(&out, it.alloc, w.month0 + 1, 2);
    try out.append(it.alloc, '-');
    try padInto(&out, it.alloc, w.day, 2);
    return it.make(.{ .string = out.items });
}

/// `parseInt`-style prefix on the stringified input: sign, digits, stop.
fn durationSecondsText(t_in: []const u8) ?i64 {
    const t = std.mem.trim(u8, t_in, " \t\r\n\x0b\x0c");
    var i: usize = 0;
    if (i < t.len and (t[i] == '+' or t[i] == '-')) i += 1;
    var nd: usize = 0;
    var v: i64 = 0;
    while (i + nd < t.len and std.ascii.isDigit(t[i + nd])) : (nd += 1) {
        v = v * 10 + (t[i + nd] - '0');
    }
    if (nd == 0) return null;
    return if (t.len > 0 and t[0] == '-') -v else v;
}

/// `^P(\d+Y)?(\d+M)?(\d+D)?(T(\d+H)?(\d+M)?(\d+S)?)?$` — uppercase only,
/// integer components, order enforced.
fn durationIso(t: []const u8) ?i64 {
    var i: usize = 0;
    if (i >= t.len or t[i] != 'P') return null;
    i += 1;
    var total: i64 = 0;
    const units = [_]struct { ch: u8, secs: i64 }{
        .{ .ch = 'Y', .secs = 365 * 86400 },
        .{ .ch = 'M', .secs = 30 * 86400 },
        .{ .ch = 'D', .secs = 86400 },
    };
    for (units) |u| {
        var nd: usize = 0;
        var v: i64 = 0;
        while (i + nd < t.len and std.ascii.isDigit(t[i + nd])) : (nd += 1) v = v * 10 + (t[i + nd] - '0');
        if (nd > 0 and i + nd < t.len and t[i + nd] == u.ch) {
            total += v * u.secs;
            i += nd + 1;
        }
    }
    if (i < t.len and t[i] == 'T') {
        i += 1;
        const tunits = [_]struct { ch: u8, secs: i64 }{
            .{ .ch = 'H', .secs = 3600 },
            .{ .ch = 'M', .secs = 60 },
            .{ .ch = 'S', .secs = 1 },
        };
        for (tunits) |u| {
            var nd: usize = 0;
            var v: i64 = 0;
            while (i + nd < t.len and std.ascii.isDigit(t[i + nd])) : (nd += 1) v = v * 10 + (t[i + nd] - '0');
            if (nd > 0 and i + nd < t.len and t[i + nd] == u.ch) {
                total += v * u.secs;
                i += nd + 1;
            }
        }
    }
    if (i != t.len) return null;
    return total;
}

fn durationFilter(it: *Interp, call: parse.FilterCall, input: *const Value) Error!*const Value {
    const fmt = try argText(it, call, 0);
    const text = try inputText(it, input);
    if (text.len == 0) return input;

    var seconds: i64 = undefined;
    if (durationSecondsText(text)) |n| {
        seconds = n;
    } else if (durationIso(text)) |n| {
        seconds = n;
    } else {
        return input;
    }

    const hours = @divFloor(seconds, 3600);
    const h_comp = @divTrunc(seconds, 3600);
    const rem = @rem(seconds, 3600);
    const m_comp = @divTrunc(rem, 60);
    const s_comp = @rem(seconds, 60);

    const use_fmt = fmt orelse (if (h_comp >= 1) "HH:mm:ss" else "mm:ss");
    var out = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < use_fmt.len) {
        const c = use_fmt[i];
        const rest = use_fmt[i..];
        const doubled = rest.len > 1 and rest[1] == c;
        switch (c) {
            'H' => try appendDurationNum(it.alloc, &out, hours, doubled),
            'm' => try appendDurationNum(it.alloc, &out, m_comp, doubled),
            's' => try appendDurationNum(it.alloc, &out, s_comp, doubled),
            else => try out.append(it.alloc, c),
        }
        i += if (doubled and (c == 'H' or c == 'm' or c == 's')) 2 else 1;
    }
    return it.make(.{ .string = out.items });
}

fn appendDurationNum(alloc: std.mem.Allocator, out: *std.ArrayList(u8), v: i64, pad: bool) Error!void {
    var buf: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable;
    if (pad and s.len < 2) try out.append(alloc, '0');
    try out.appendSlice(alloc, s);
}
