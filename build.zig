const std = @import("std");
const sdk = @import("paper_portal_sdk");

pub fn build(b: *std.Build) void {
    const app = sdk.addPortalApp(b, .{
        .local_sdk_path = "../zig-sdk",
        .export_symbol_names = &.{
            "pp_init",
            "pp_tick",
            "pp_on_gesture",
        },
    });

    _ = sdk.addPortalPackage(b, app.exe, .{
        .manifest = .{
            .id = "bd55bbdc-41ec-497a-a02f-f3a1ba25dac0",
            .name = "XTC Reader",
            .version = "0.1.0",
        },
    });

    // CLI tool runnable on host computer for examining xtc files.
    const xtci_mod = b.createModule(.{
        .root_source_file = b.path("src/main_xtci.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseFast,
        .strip = false,
    });
    const xtci_exe = b.addExecutable(.{
        .name = "xtci",
        .root_module = xtci_mod,
    });
    const install_xtci = b.addInstallArtifact(xtci_exe, .{});
    b.getInstallStep().dependOn(&install_xtci.step);

    const xtci_step = b.step("xtci", "Build/install xtci CLI");
    xtci_step.dependOn(&install_xtci.step);

    const run_xtci = b.addRunArtifact(xtci_exe);
    if (b.args) |args| run_xtci.addArgs(args);
    const run_xtci_step = b.step("run-xtci", "Run xtci CLI");
    run_xtci_step.dependOn(&run_xtci.step);

    // Set up unit tests that can be run on host computer.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main_test.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .strip = false,
    });
    const tests = b.addTest(.{
        .name = "unit_tests",
        .root_module = test_mod,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}

fn dirExists(b: *std.Build, rel: []const u8) bool {
    std.Io.Dir.cwd().access(b.graph.io, rel, .{}) catch return false;
    return true;
}
