const std = @import("std");
const ppsdk = @import("paper_portal_sdk");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{ .cpu_arch = .wasm32, .os_tag = .wasi },
    });
    const optimize = std.builtin.OptimizeMode.ReleaseSmall;

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = true,
    });
    root_mod.export_symbol_names = &.{
        "pp_contract_version",
        "pp_init",
        "pp_alloc",
        "pp_free",
        "pp_on_gesture",
    };

    const exe = b.addExecutable(.{
        .name = "main",
        .root_module = root_mod,
    });

    _ = ppsdk.addWasmUpload(b, exe, .{});

    _ = ppsdk.addWasmPortalPackage(b, exe, .{
        .manifest = .{
            .id = "00000000-0000-0000-0000-000000000000",
            .name = "Zig App Template",
            .version = "0.0.0",
        },
    });

    const sdk_dep = b.dependency("paper_portal_sdk", .{});
    const sdk = b.createModule(.{
        .root_source_file = sdk_dep.path("sdk.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("paper_portal_sdk", sdk);

    exe.stack_size = 32 * 1024;
    exe.initial_memory = 512 * 1024;
    exe.max_memory = 1024 * 1024;

    b.installArtifact(exe);
}
