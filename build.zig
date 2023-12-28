const std = @import("std");
const Build = @import("std").Build;
const Target = @import("std").Target;
const CrossTarget = @import("std").zig.CrossTarget;
const Feature = @import("std").Target.Cpu.Feature;

pub fn build(b: *Build) !void {
    const kernel_options = b.addOptions();

    const obj_path_option = b.option([]const u8, "app-obj", "object file of application");
    if (obj_path_option) |_| {
        kernel_options.addOption(bool, "has_wasm", true);
    } else {
        kernel_options.addOption(bool, "has_wasm", false);
    }

    const test_option = b.option(bool, "test", "run tests");
    if (test_option) |t| {
        kernel_options.addOption(bool, "is_test", t);
    } else {
        kernel_options.addOption(bool, "is_test", false);
    }

    const log_level_option = b.option([]const u8, "log-level", "log level");
    if (log_level_option) |l| {
        kernel_options.addOption([]const u8, "log_level", l);
    } else {
        kernel_options.addOption([]const u8, "log_level", "fatal");
    }

    const fs_path_option = b.option([]const u8, "fs-path", "path to filesystem");
    if (fs_path_option) |p| {
        std.debug.print("building fs: {s}\n", .{p});
        kernel_options.addOption(bool, "has_fs", true);
    } else {
        kernel_options.addOption(bool, "has_fs", false);
    }

    const features = Target.x86.Feature;

    var disabled_features = Feature.Set.empty;
    var enabled_features = Feature.Set.empty;

    disabled_features.addFeature(@intFromEnum(features.mmx));
    disabled_features.addFeature(@intFromEnum(features.sse));
    disabled_features.addFeature(@intFromEnum(features.sse2));
    disabled_features.addFeature(@intFromEnum(features.avx));
    disabled_features.addFeature(@intFromEnum(features.avx2));
    enabled_features.addFeature(@intFromEnum(features.soft_float));

    const target = CrossTarget{ .cpu_arch = Target.Cpu.Arch.x86_64, .os_tag = Target.Os.Tag.freestanding, .cpu_features_sub = disabled_features, .cpu_features_add = enabled_features };

    const optimize = b.standardOptimizeOption(.{});

    const newlib_build_cmd = b.addSystemCommand(&[_][]const u8{"./scripts/build-newlib.sh"});
    const lwip_build_cmd = b.addSystemCommand(&[_][]const u8{"./scripts/build-lwip.sh"});

    const kernel = b.addExecutable(.{
        .name = "mewz.elf",
        .root_source_file = .{ .path = "src/main.zig" },
        .optimize = optimize,
        .target = target,
        .linkage = std.build.CompileStep.Linkage.static,
    });
    kernel.code_model = .kernel;
    kernel.setLinkerScriptPath(.{ .path = "src/x64.ld" });
    kernel.addAssemblyFile(Build.LazyPath{ .path = "src/boot.S" });
    kernel.addAssemblyFile(Build.LazyPath{ .path = "src/interrupt.S" });
    kernel.addObjectFile(Build.LazyPath{ .path = "build/newlib/libc.a" });
    kernel.addObjectFile(Build.LazyPath{ .path = "build/lwip/libtcpip.a" });
    kernel.addObjectFile(Build.LazyPath{ .path = "build/lwip/liblwipcore.a" });
    kernel.addObjectFile(Build.LazyPath{ .path = "build/lwip/liblwipallapps.a" });
    kernel.addCSourceFile(Build.Step.Compile.CSourceFile{ .file = Build.LazyPath{ .path = "src/c/newlib_support.c" }, .flags = &[_][]const u8{ "-I", "submodules/newlib/newlib/libc/include" } });
    kernel.addCSourceFile(Build.Step.Compile.CSourceFile{ .file = Build.LazyPath{ .path = "src/c/lwip_support.c" }, .flags = &[_][]const u8{ "-I", "submodules/newlib/newlib/libc/include" } });
    if (obj_path_option) |p| {
        kernel.addObjectFile(Build.LazyPath{ .path = p });
    }
    if (fs_path_option) |_| {
        kernel.addObjectFile(Build.LazyPath{ .path = "disk.o" });
    }
    kernel.addOptions("options", kernel_options);
    b.installArtifact(kernel);

    const kernel_step = b.step("kernel", "Build the kernel");
    kernel.step.dependOn(&newlib_build_cmd.step);
    kernel.step.dependOn(&lwip_build_cmd.step);
    if (fs_path_option) |p| {
        const fs_build_cmd = b.addSystemCommand(&[_][]const u8{ "./scripts/build-fs.sh", p });
        kernel.step.dependOn(&fs_build_cmd.step);
    }
    kernel_step.dependOn(&kernel.step);

    const rewrite_kernel_cmd = b.addSystemCommand(&[_][]const u8{"./scripts/rewrite-kernel.sh"});
    rewrite_kernel_cmd.step.dependOn(b.getInstallStep());

    const run_cmd_str = [_][]const u8{"./scripts/run-qemu.sh"};

    const run_cmd = b.addSystemCommand(&run_cmd_str);
    run_cmd.step.dependOn(&rewrite_kernel_cmd.step);

    const run_step = b.step("run", "Run the kernel");
    run_step.dependOn(&run_cmd.step);

    const debug_cmd_str = run_cmd_str ++ [_][]const u8{
        "--debug",
    };

    const debug_cmd = b.addSystemCommand(&debug_cmd_str);
    debug_cmd.step.dependOn(&rewrite_kernel_cmd.step);

    const debug_step = b.step("debug", "Debug the kernel");
    debug_step.dependOn(&debug_cmd.step);
}
