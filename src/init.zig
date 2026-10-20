//! k4o init: idempotent agent scaffolding.
//!
//! Drops knap teaching files into the working dir so an agent can pull
//! knap-into-context when doing knap work, without a training-data
//! dependency. Three rules are load-bearing:
//!
//!  - Look for poop; if nah, take a poop. Only create files that do not
//!    exist.
//!  - Never overwrite an existing file, modified or not — existence is the
//!    test, and no manifest, checksums or modification detective work. The
//!    one exception is supersession: a file that carries init's own marker
//!    at an *older* version is archived, not replaced (and never deleted).
//!  - Archives are timestamped directories that nothing ever expires; the
//!    output names where the old copy went.
//!
//! A file is init's own iff its first line is the embedded marker
//! `<!-- k4o init <name> v<N> -->`; anything else — including a user-edited
//! teaching file with the marker stripped — is left untouched forever.

const std = @import("std");

/// Version of the teaching-file set. Bump when content is superseded; older
/// on-disk copies are archived and rewritten.
pub const set_version: u32 = 7;

pub const marker_prefix = "<!-- k4o init ";
pub const marker_suffix = " -->";
pub const archive_dir_name = "k4o-archive";

/// Files init manages, in drop order. The marker line inside `content` must
/// name the same file and version (asserted by tests).
pub const FileDef = struct {
    name: []const u8,
    version: u32,
    content: []const u8,
};

pub const files = [_]FileDef{
    .{ .name = "knap-tour.md", .version = 6, .content = @embedFile("init/knap-tour.md") },
    .{ .name = "knap-templates.md", .version = 6, .content = @embedFile("init/knap-templates.md") },
    .{ .name = "knap-examples.md", .version = 6, .content = @embedFile("init/knap-examples.md") },
    .{ .name = "knap-gotchas.md", .version = 6, .content = @embedFile("init/knap-gotchas.md") },
};

pub const Action = enum {
    /// Did not exist: written.
    created,
    /// Exists with the current marker: untouched.
    up_to_date,
    /// Exists without a recognizable current-set marker: untouched, forever.
    left_untouched,
    /// Exists with an older marker: old copy archived, new copy written.
    archived,
};

pub const Report = struct {
    file: []const u8,
    action: Action,
    /// Version found on disk, when the file carried a parseable marker.
    disk_version: ?u32 = null,
    /// Version written (only for `.archived`; set to the file's own
    /// FileDef version so mixed-version sets report accurately).
    to_version: ?u32 = null,
    /// Relative path of the archived old copy (only for `.archived`).
    archive_path: ?[]const u8 = null,
};

pub const MarkerInfo = struct {
    name: []const u8,
    version: u32,
};

/// Parses the marker line `<!-- k4o init <name> v<N> -->` if `content`
/// starts with one. Anything else — absent, malformed, different marker —
/// returns null, which means "not ours".
pub fn parseMarker(content: []const u8) ?MarkerInfo {
    const line_end = std.mem.indexOfScalar(u8, content, '\n') orelse content.len;
    const line = content[0..line_end];
    if (!std.mem.startsWith(u8, line, marker_prefix)) return null;
    if (!std.mem.endsWith(u8, line, marker_suffix)) return null;
    const middle = line[marker_prefix.len .. line.len - marker_suffix.len];
    const split = std.mem.lastIndexOfScalar(u8, middle, ' ') orelse return null;
    const name = middle[0..split];
    const ver = middle[split + 1 ..];
    if (name.len == 0 or ver.len < 2 or ver[0] != 'v') return null;
    const version = std.fmt.parseInt(u32, ver[1..], 10) catch return null;
    return .{ .name = name, .version = version };
}

pub const Decision = enum { create, up_to_date, left_untouched, archive_and_write };

/// What to do with one file, given its existence and its marker (null when
/// the file is absent or not ours). Pure; the scaffold loop just executes it.
pub fn decide(exists: bool, marker: ?MarkerInfo, def: FileDef) Decision {
    if (!exists) return .create;
    const m = marker orelse return .left_untouched;
    if (!std.mem.eql(u8, m.name, markerName(def.name))) return .left_untouched;
    if (m.version == def.version) return .up_to_date;
    if (m.version < def.version) return .archive_and_write;
    // Newer than this build ships: a downgrade. Leave it; never clobber.
    return .left_untouched;
}

/// The name as it appears inside the marker: the file name without its
/// extension, so `knap-tour.md` is marked `knap-tour`.
pub fn markerName(file_name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, file_name, '.') orelse file_name.len;
    return file_name[0..dot];
}

pub const ScaffoldError = error{
    OutOfMemory,
    ArchiveCollision,
} || std.Io.Dir.ReadFileError ||
    std.Io.Dir.WriteFileError ||
    std.Io.Dir.CreateDirPathError ||
    std.Io.Dir.RenameError ||
    std.Io.File.OpenError;

/// Applies the teaching-file set to `dir`, appending one Report per file.
/// Idempotent: running twice changes nothing; superseded files are archived
/// and reported with their archive path. Archives are never expired.
pub fn scaffold(
    alloc: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    reports: *std.ArrayList(Report),
) ScaffoldError!void {
    for (files) |def| {
        var exists = true;
        var marker: ?MarkerInfo = null;
        if (dir.readFileAlloc(io, def.name, alloc, .limited(64 * 1024))) |existing| {
            marker = parseMarker(existing);
        } else |e| switch (e) {
            error.FileNotFound => exists = false,
            error.StreamTooLong => {}, // big file: not one of ours
            else => |other| return other,
        }

        switch (decide(exists, marker, def)) {
            .create => {
                try dir.writeFile(io, .{ .sub_path = def.name, .data = def.content });
                try reports.append(alloc, .{ .file = def.name, .action = .created });
            },
            .up_to_date => {
                try reports.append(alloc, .{ .file = def.name, .action = .up_to_date, .disk_version = marker.?.version });
            },
            .left_untouched => {
                try reports.append(alloc, .{ .file = def.name, .action = .left_untouched, .disk_version = if (marker) |m| m.version else null });
            },
            .archive_and_write => {
                const archive_path = try archiveFile(alloc, io, dir, def.name);
                try dir.writeFile(io, .{ .sub_path = def.name, .data = def.content });
                try reports.append(alloc, .{
                    .file = def.name,
                    .action = .archived,
                    .disk_version = marker.?.version,
                    .to_version = def.version,
                    .archive_path = archive_path,
                });
            },
        }
    }
}

/// Moves `name` to `<archive_dir_name>/<UTC timestamp>/<name>`, creating the
/// timestamped directory. Same-second collisions get a `-2`, `-3`, … suffix,
/// so nothing is ever silently overwritten on the way into the archive.
fn archiveFile(
    alloc: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    name: []const u8,
) ScaffoldError![]const u8 {
    var stamp_buf: [40]u8 = undefined;
    const stamp = try utcStamp(io, &stamp_buf);
    return archiveFileWithStamp(alloc, io, dir, name, stamp);
}

/// Archives `name` under an explicit `YYYYMMDDTHHMMSSZ` stamp — the
/// injection point that makes the collision tests deterministic. The
/// destination is claimed with an exclusive create, which fails with
/// `PathAlreadyExists` instead of replacing, so a collision retries with
/// the next suffix and no archived byte is ever overwritten: the rename
/// can only ever replace the empty placeholder this call just reserved.
/// On failure the source is untouched and no placeholder is left behind.
pub fn archiveFileWithStamp(
    alloc: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    name: []const u8,
    stamp: []const u8,
) ScaffoldError![]const u8 {
    var suffix: usize = 1;
    while (suffix < 100) : (suffix += 1) {
        const sub_dir = if (suffix == 1)
            try std.fmt.allocPrint(alloc, archive_dir_name ++ "/{s}", .{stamp})
        else
            try std.fmt.allocPrint(alloc, archive_dir_name ++ "/{s}-{d}", .{ stamp, suffix });
        try dir.createDirPath(io, sub_dir);
        const target = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ sub_dir, name });
        const reserved = dir.createFile(io, target, .{ .exclusive = true }) catch |e| switch (e) {
            error.PathAlreadyExists => continue,
            else => return e,
        };
        reserved.close(io);
        dir.rename(name, dir, target, io) catch |e| {
            dir.deleteFile(io, target) catch {}; // our own empty reservation
            return e;
        };
        return target;
    }
    return error.ArchiveCollision;
}

/// `YYYYMMDDTHHMMSSZ` in UTC.
fn utcStamp(io: std.Io, buf: []u8) error{OutOfMemory}![]const u8 {
    const now = std.Io.Timestamp.now(io, .real);
    const secs: i64 = @intCast(@divFloor(now.nanoseconds, std.time.ns_per_s));
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(secs, 0)) };
    const year_day = es.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day.getHoursIntoDay(),
        day.getMinutesIntoHour(),
        day.getSecondsIntoMinute(),
    }) catch error.OutOfMemory;
}
