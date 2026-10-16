const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Red-green verification knob (see README.md -> Verification):
    //   normal (default) | passthrough | markdown
    const mode_str = b.option(
        []const u8,
        "engine-mode",
        "Engine behavior for red-green verification: normal (default) | passthrough | markdown",
    ) orelse "normal";
    if (!std.mem.eql(u8, mode_str, "normal") and
        !std.mem.eql(u8, mode_str, "passthrough") and
        !std.mem.eql(u8, mode_str, "noeval") and
        !std.mem.eql(u8, mode_str, "markdown"))
    {
        std.debug.print("error: unknown -Dengine-mode '{s}' (expected normal, passthrough, or markdown)\n", .{mode_str});
        std.process.exit(1);
    }

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "engine_mode", mode_str);
    build_options.addOption([]const u8, "version", packageVersion(b));
    const build_options_mod = build_options.createModule();

    const engine_mod = b.addModule("k4o", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    engine_mod.addImport("build_options", build_options_mod);

    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "k4o", .module = engine_mod },
            .{ .name = "build_options", .module = build_options_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "k4o",
        .root_module = cli_mod,
    });
    b.installArtifact(exe);

    const tests_mod = b.createModule(.{
        .root_source_file = b.path("tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "k4o", .module = engine_mod },
            .{ .name = "build_options", .module = build_options_mod },
        },
    });
    const tests = b.addTest(.{
        .root_module = tests_mod,
    });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run the test suite");
    test_step.dependOn(&run_tests.step);
}

/// Reads `.version = "..."` from build.zig.zon at configure time (single
/// source of truth for the version string).
fn packageVersion(b: *std.Build) []const u8 {
    const marker = ".version = \"";
    const zon = std.Io.Dir.readFileAlloc(.cwd(), b.graph.io, "build.zig.zon", b.allocator, .limited(1 << 20)) catch return "0.0.0";
    const start = std.mem.indexOf(u8, zon, marker) orelse return "0.0.0";
    const rest = zon[start + marker.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return "0.0.0";
    return b.dupe(rest[0..end]);
}
