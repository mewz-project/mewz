const std = @import("std");
const Build = @import("std").Build;
const Target = @import("std").Target;
const Query = @import("std").Target.Query;
const Feature = @import("std").Target.Cpu.Feature;

const TEST_DIR_PATH = "build/test";

const BuildParams = struct {
    obj_path: ?[]const u8 = undefined,
    dir_path: ?[]const u8 = undefined,
    is_test: bool = undefined,
    log_level: []const u8 = undefined,

    const Self = @This();

    fn new(b: *Build) Self {
        var params = BuildParams{};

        const obj_path_option = b.option([]const u8, "app-obj", "object file of application");
        if (obj_path_option) |p| {
            params.obj_path = p;
        } else {
            params.obj_path = null;
        }

        const log_level_option = b.option([]const u8, "log-level", "log level");
        if (log_level_option) |l| {
            params.log_level = l;
        } else {
            params.log_level = "fatal";
        }

        const dir_path_option = b.option([]const u8, "dir", "path to directory");
        if (dir_path_option) |p| {
            std.debug.print("building fs: {s}\n", .{p});
            params.dir_path = p;
        } else {
            params.dir_path = null;
        }

        const test_option = b.option(bool, "test", "run tests");
        if (test_option) |t| {
            params.is_test = t;
            if (t) {
                createTestDir() catch unreachable;
                params.dir_path = TEST_DIR_PATH;
            }
        } else {
            params.is_test = false;
        }

        return params;
    }

    fn setOptions(self: *const Self, b: *Build) *Build.Step.Options {
        const options = b.addOptions();

        options.addOption(bool, "is_test", self.is_test);
        options.addOption([]const u8, "log_level", self.log_level);

        if (self.obj_path) |_| {
            options.addOption(bool, "has_wasm", true);
        } else {
            options.addOption(bool, "has_wasm", false);
        }

        if (self.dir_path) |_| {
            options.addOption(bool, "has_fs", true);
        } else {
            options.addOption(bool, "has_fs", false);
        }

        return options;
    }
};

pub fn build(b: *Build) !void {
    const params = BuildParams.new(b);
    const options = params.setOptions(b);

    const optimize = b.standardOptimizeOption(.{});

    const newlib_build_cmd = b.addSystemCommand(&[_][]const u8{"./scripts/build-newlib.sh"});
    const lwip_build_cmd = b.addSystemCommand(&[_][]const u8{"./scripts/build-lwip.sh"});

    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .ofmt = .elf,
    });

    const kernel = b.addExecutable(.{
        .name = "mewz.elf",
        .root_source_file = b.path("src/main.zig"),
        .optimize = optimize,
        .target = target,
        .linkage = .static,
        .code_model = .kernel,
    });

    kernel.linker_script = b.path("src/x64.ld");
    kernel.addAssemblyFile(b.path("src/boot.S"));
    kernel.addAssemblyFile(b.path("src/interrupt.S"));
    kernel.addObjectFile(b.path("build/newlib/libc.a"));
    kernel.addObjectFile(b.path("build/lwip/libtcpip.a"));
    kernel.addObjectFile(b.path("build/lwip/liblwipcore.a"));
    kernel.addObjectFile(b.path("build/lwip/liblwipallapps.a"));
    kernel.addCSourceFile(.{ .file = b.path("src/c/newlib_support.c"), .flags = &.{ "-I", "submodules/newlib/newlib/libc/include" } });
    kernel.addCSourceFile(.{ .file = b.path("src/c/lwip_support.c"), .flags = &.{ "-I", "submodules/newlib/newlib/libc/include" } });
    if (params.obj_path) |p| {
        kernel.addObjectFile(b.path(p));
    }
    if (params.dir_path) |_| {
        kernel.addObjectFile(b.path("build/disk.o"));
    }
    kernel.root_module.addOptions("options", options);
    kernel.entry = .{ .symbol_name = "boot" };
    b.installArtifact(kernel);

    const kernel_step = b.step("kernel", "Build the kernel");
    kernel.step.dependOn(&newlib_build_cmd.step);
    kernel.step.dependOn(&lwip_build_cmd.step);
    if (params.dir_path) |p| {
        const fs_build_cmd = b.addSystemCommand(&[_][]const u8{ "./scripts/build-fs.sh", p });
        kernel.step.dependOn(&fs_build_cmd.step);
    }
    kernel_step.dependOn(&kernel.step);

    const rewrite_kernel_cmd = b.addSystemCommand(&[_][]const u8{"./scripts/rewrite-kernel.sh"});
    rewrite_kernel_cmd.step.dependOn(b.getInstallStep());

    const run_cmd_str = if (params.is_test)
        [_][]const u8{"./scripts/integration-test.sh"}
    else
        [_][]const u8{"./scripts/run-qemu.sh"};

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

fn createTestDir() !void {
    const cwd = std.fs.cwd();
    const test_dir = try cwd.makeOpenPath(TEST_DIR_PATH, std.fs.Dir.OpenDirOptions{});
    const file = try test_dir.createFile("test.txt", std.fs.File.CreateFlags{});
    defer file.close();
    _ = try file.write("fd_read test\n");
}
