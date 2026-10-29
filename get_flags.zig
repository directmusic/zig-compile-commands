/// This file just contains ports of functions from std.Build.Step.Compile and
/// std.Build.Module which determine what compilation flags should be used. But
/// in these versions, linker flags and zig-specific flags are removed, so only
/// the clangd-relevant flags appear in the compile_commands.json
/// (also, most of the relevant functions are private in std, so they have to
/// be replicated here anyways)
const std = @import("std");
const LazyPath = std.Build.LazyPath;
const CompileCommandEntry = @import("compile_commands.zig").CompileCommandEntry;
const CompileCommandOptions = @import("compile_commands.zig").CompileCommandOptions;
const PathRegistry = @import("compile_commands.zig").PathRegistry;

const InProgressCompileCommandsEntry = struct {
    directory: []const u8,
    file_specific_flags: std.ArrayList([]const u8) = .empty,
};
const CompileCommandsBuilder = struct {
    files: std.StringHashMapUnmanaged(InProgressCompileCommandsEntry) = .{},

    pub fn init() @This() {
        return .{};
    }

    pub fn resolvePathAndAdd(self: *@This(), b: *std.Build, registry: *PathRegistry, source: *std.Build.Module.CSourceFile) !void {
        // the file for this is a LazyPath; both the file and its directory get
        // a token which is substituted with the resolved path at make time
        const file_token = registry.add(b, source.file, false);
        const directory_token = registry.add(b, source.file.dirname(), true);
        const gop_result = try self.files.getOrPut(b.allocator, file_token);
        if (!gop_result.found_existing) {
            gop_result.value_ptr.* = .{ .directory = directory_token };
        } else {
            std.log.warn("Found duplicate source file in a single compile step: \"{s}\", ignoring repeated instance", .{file_token});
            return;
        }
        try gop_result.value_ptr.file_specific_flags.appendSlice(b.allocator, source.flags);
    }
    pub fn resolvePathAndAddMany(self: *@This(), b: *std.Build, registry: *PathRegistry, sources: *std.Build.Module.CSourceFiles) !void {
        // the files in CSourceFiles are subpaths from root
        for (sources.files) |subpath| {
            const file_token = registry.add(b, sources.root.path(b, subpath), false);
            const directory_token = registry.add(b, sources.root, true);
            const gop_result = try self.files.getOrPut(b.allocator, file_token);
            if (!gop_result.found_existing) {
                gop_result.value_ptr.* = .{ .directory = directory_token };
            } else {
                std.log.warn("Found duplicate source file in a single compile step: \"{s}\", ignoring repeated instance", .{subpath});
                continue;
            }
            try gop_result.value_ptr.file_specific_flags.appendSlice(b.allocator, sources.flags);
        }
    }

    /// Fills up some CompileCommandEntrys with pointers to shared_flags. relies
    /// on builder allocator being leaky, and not using this builder after this
    /// function is called, as the entries have pointers to keys of this
    /// object's hash map
    pub fn finish(
        self: *@This(),
        b: *std.Build,
        registry: *PathRegistry,
        shared_flags: []const []const u8,
        driver: ?[]const u8,
        output: *std.ArrayList(CompileCommandEntry),
    ) !void {
        try output.ensureUnusedCapacity(b.allocator, self.files.size);
        var iterator = self.files.iterator();
        var idx: usize = 0;
        while (iterator.next()) |hm_entry| {
            const output_str = registry.add(b, .{
                .relative = .{ .base = .global_cache, .sub_path = b.fmt("zcc-{d}.o", .{idx}) },
            }, false);

            // for each source file, create a new set of flags which is the shared flags + file specific flags
            var allflags: std.ArrayList([]const u8) = .empty; // leak this
            const initial_flags = &.{ driver orelse "clang", hm_entry.key_ptr.*, "-o", output_str };
            try allflags.ensureTotalCapacity(b.allocator, initial_flags.len + shared_flags.len + hm_entry.value_ptr.file_specific_flags.items.len);

            allflags.appendSliceAssumeCapacity(initial_flags);
            allflags.appendSliceAssumeCapacity(shared_flags);
            allflags.appendSliceAssumeCapacity(hm_entry.value_ptr.file_specific_flags.items);

            output.appendAssumeCapacity(CompileCommandEntry{
                .file = hm_entry.key_ptr.*,
                .directory = hm_entry.value_ptr.directory,
                .output = output_str,
                .arguments = allflags.items,
            });
            idx += 1;
        }
    }
};

const GenerateCompileCommandsParameters = struct {
    output: *std.ArrayList(CompileCommandEntry),
    options: CompileCommandOptions,
};
/// configuration parameters and intermediate data
const GenerateCompileCommandsIntermediate = struct {
    params: GenerateCompileCommandsParameters,
    allocator: std.mem.Allocator,
    flags: *std.ArrayList([]const u8), // per-module not per-file
    registry: *PathRegistry,
};
const GenerateLazyPathParameters = struct {
    output: *std.ArrayList(LazyPath),
};
const GenerateParameters = union(enum) {
    cc_params: GenerateCompileCommandsIntermediate,
    lazy_path_params: GenerateLazyPathParameters,
};

const GenerateOutput = struct {
    params: GenerateParameters,

    pub fn wantsFlags(self: *const @This()) bool {
        return self.params == .cc_params;
    }

    pub fn options(self: *const @This()) ?CompileCommandOptions {
        switch (self.params) {
            .cc_params => |intermediate| return intermediate.params.options,
            else => return null,
        }
    }

    /// add CSourceFile to compile_commands.json, OR add LazyPath so we can depend on the generation of this file
    /// does not use our allocator or modify us, just reads self.params to check if we are resolving the paths or not
    pub fn addResolvedPath(self: *const @This(), b: *std.Build, builder: *CompileCommandsBuilder, source_file: *std.Build.Module.CSourceFile) !void {
        switch (self.params) {
            .cc_params => |params| try builder.resolvePathAndAdd(b, params.registry, source_file),
            .lazy_path_params => |params| try params.output.append(b.allocator, source_file.file),
        }
    }
    /// add CSourceFiles to compile_commands.json, OR add LazyPath so we can depend on the generation of these files
    /// does not use our allocator or modify us, just reads self.params to check if we are resolving the paths or not
    pub fn addResolvedPaths(self: *const @This(), b: *std.Build, builder: *CompileCommandsBuilder, source_files: *std.Build.Module.CSourceFiles) !void {
        switch (self.params) {
            .cc_params => |params| try builder.resolvePathAndAddMany(b, params.registry, source_files),
            .lazy_path_params => |params| try params.output.append(b.allocator, source_files.root),
        }
    }
    /// add include directive to compile_commands.json, OR add LazyPath so we can depend on the generation of the file/folder
    pub fn appendFlagForIncludeDir(self: *const @This(), include_dir: FlagForIncludeDir, asking_step: *std.Build.Step) !void {
        const b = asking_step.owner;
        switch (self.params) {
            .cc_params => |params| {
                const token = params.registry.add(b, include_dir.path, true);
                switch (include_dir.flag) {
                    .prefix => |prefix| {
                        return self.appendFlagSlice(&.{ prefix, token });
                    },
                    .embed_path => {
                        return self.appendFlag(b.fmt("--embed-dir={s}", .{token}));
                    },
                }
            },
            .lazy_path_params => |params| try params.output.append(b.allocator, include_dir.path),
        }
    }

    pub fn appendFlag(self: *const @This(), flag: []const u8) !void {
        switch (self.params) {
            .cc_params => |params| try params.flags.append(params.allocator, flag),
            .lazy_path_params => {},
        }
    }

    pub fn appendFlagSlice(self: *const @This(), to_append: []const []const u8) !void {
        switch (self.params) {
            .cc_params => |params| try params.flags.appendSlice(params.allocator, to_append),
            .lazy_path_params => {},
        }
    }

    pub fn appendYesNoFlag(
        self: *const @This(),
        opt: ?bool,
        then_name: []const u8,
        else_name: []const u8,
    ) !void {
        switch (self.params) {
            .cc_params => |params| {
                const cond = opt orelse return;
                return params.flags.append(params.allocator, if (cond) then_name else else_name);
            },
            .lazy_path_params => {},
        }
    }

    fn appendFNoFlag(self: @This(), comptime name: []const u8, opt: ?bool) !void {
        switch (self.params) {
            .cc_params => |params| {
                const cond = opt orelse return;
                try params.flags.ensureUnusedCapacity(params.allocator, 1);
                if (cond) {
                    params.flags.appendAssumeCapacity("-f" ++ name);
                } else {
                    params.flags.appendAssumeCapacity("-fno-" ++ name);
                }
            },
            .lazy_path_params => {},
        }
    }
};

const FlagForIncludeDir = struct {
    const Flag = union(enum) {
        prefix: []const u8,
        embed_path: void,
    };

    flag: Flag,
    path: LazyPath,

    /// Modified version of std.Build.Module.IncludeDir.appendZigProcessFlags,
    /// should stay up to date with that
    fn initFromIncludeDir(include_dir: std.Build.Module.IncludeDir) FlagForIncludeDir {
        return switch (include_dir) {
            // zig fmt: off
            .path =>                    |lp|        .{ .flag = .{ .prefix = "-I" },             .path = lp },
            .path_system =>             |lp|        .{ .flag = .{ .prefix = "-isystem" },       .path = lp },
            .path_after =>              |lp|        .{ .flag = .{ .prefix = "-idirafter" },     .path = lp },
            .framework_path =>          |lp|        .{ .flag = .{ .prefix = "-F" },             .path = lp },
            .framework_path_system =>   |lp|        .{ .flag = .{ .prefix = "-iframework" },    .path = lp },
            .config_header_step =>      |ch|        .{ .flag = .{ .prefix = "-I" },             .path = ch.getOutputDir() },
            // implementation in zig std does .installed_headers_include_tree.?.getDirectory() instead of getEmittedIncludeTree()
            // if that changes this has to change, too
            .other_step =>              |comp|      .{ .flag = .{ .prefix = "-I" },             .path = comp.getEmittedIncludeTree() },
            .embed_path =>              |lazy_path| .{ .flag = .embed_path,                     .path = lazy_path },
            // zig fmt: on
        };
    }
};

/// Modified version of std.Build.Module.appendZigProcessFlags which removes
/// or modifies zig-specific flags to work with clang
fn appendFlagsForModule(
    output: GenerateOutput,
    mod: *std.Build.Module,
    asking_step: *std.Build.Step,
) !void {
    const b = mod.owner;

    try output.appendYesNoFlag(mod.stack_protector, "-fstack-protector", "-fno-stack-protector");
    try output.appendYesNoFlag(mod.omit_frame_pointer, "-fomit-frame-pointer", "-fno-omit-frame-pointer");
    try output.appendYesNoFlag(mod.sanitize_thread, "-fsanitize=thread", "-fno-sanitize=thread");
    try output.appendYesNoFlag(mod.pic, "-fPIC", "-fno-PIC");
    try output.appendYesNoFlag(mod.no_builtin, "-fno-builtin", "-fbuiltin");

    if (mod.sanitize_c) |sc| switch (sc) {
        .off => try output.appendFlag("-fno-sanitize=undefined"),
        .trap => try output.appendFlag("-fsanitize-trap=undefined"),
        .full => try output.appendFlag("-fsanitize=undefined"),
    };

    if (mod.dwarf_format) |dwarf_format| {
        try output.appendFlag(switch (dwarf_format) {
            .@"32" => "-gdwarf32",
            .@"64" => "-gdwarf64",
        });
    }

    if (mod.optimize) |optimize| switch (optimize) {
        .debug => try output.appendFlag("-O0"),
        .small => try output.appendFlag("-Os"),
        .fast, .safe => try output.appendFlag("-O3"),
    };

    if (mod.code_model != .default) {
        if (output.params == .cc_params) {
            try output.appendFlag(b.fmt("-mcmodel={s}", .{@tagName(mod.code_model)}));
        }
    }

    if (mod.resolved_target) |*target| {
        if (!target.query.isNative()) {
            const triple: ?[]const u8 = @import("triple.zig").llvmTriple(&target.result, b.allocator) catch |err| block: switch (err) {
                error.LlvmUnsupportedArch => {
                    std.log.warn("No know LLVM triple for architecture {}, refusing to append -target flag", .{target.result});
                    break :block null;
                },
                else => return err,
            };

            if (triple) |llvm_triple| {
                try output.appendFlagSlice(&.{ "-target", llvm_triple });
            }

            if (output.options()) |options| {
                if (options.include_cpu_features) {
                    try appendTargetCpuFlags(output, &target.result);
                }
            }

            try appendBundledLibcIncludeFlags(output, b, mod, &target.result);
        }
    }

    // include dirs
    for (mod.include_dirs.items) |include_dir| {
        try output.appendFlagForIncludeDir(FlagForIncludeDir.initFromIncludeDir(include_dir), asking_step);
    }

    // c macro flags
    try output.appendFlagSlice(mod.c_macros.items);
}

/// Pass some CPU features to clang frontend via -Xclang unstable flags
fn appendTargetCpuFlags(output: GenerateOutput, target: *const std.Target) !void {
    if (!output.wantsFlags()) return;

    const allocator = output.params.cc_params.allocator;

    // Some LLVM targets do not properly process CPU models in their clang
    // driver code, and zig omits the flags for those
    //
    // also see: clangSupportsTargetCpuArg in src/target.zig
    const clang_supports_target_cpu_arg = switch (target.cpu.arch) {
        .arc, .msp430, .ve, .xcore, .xtensa => false,
        else => true,
    };
    if (clang_supports_target_cpu_arg) {
        if (target.cpu.model.llvm_name) |llvm_name| {
            try output.appendFlagSlice(&.{ "-Xclang", "-target-cpu", "-Xclang", llvm_name });
        }
    }

    for (target.cpu.arch.allFeaturesList(), 0..) |feature, index_usize| {
        const index: std.Target.Cpu.Feature.Set.Index = @intCast(index_usize);
        const is_enabled = target.cpu.features.isEnabled(index);
        const llvm_name = feature.llvm_name orelse continue;

        // zig skips these and gives them somewhere else, idk
        if (std.mem.startsWith(u8, llvm_name, "soft-float") or
            std.mem.startsWith(u8, llvm_name, "hard-float"))
            continue;
        if (target.cpu.arch == .s390x and std.mem.eql(u8, llvm_name, "backchain"))
            continue;

        // skipping some stuff here that zig also skips
        //
        // also see: the line with isDynamicAMDGCNFeature() in Compilation.zig
        if (target.cpu.arch == .amdgcn and
            (std.mem.eql(u8, llvm_name, "sramecc") or std.mem.eql(u8, llvm_name, "xnack")))
            continue;

        const plus_or_minus: u8 = if (is_enabled) '+' else '-';
        try output.appendFlagSlice(&.{
            "-Xclang",
            "-target-feature",
            "-Xclang",
            try std.fmt.allocPrint(allocator, "{c}{s}", .{ plus_or_minus, llvm_name }),
        });
    }
}

/// Replicate the include flags passed to clang in order to tell it to use
/// Zig's bundled C stdlib. From addCCArgs in src/Compilation.zig of the
/// compiler. This enables finding standard library C and C++ headers.
///
/// The exact libc include paths detected by the compiler (`LibCDirs`) cannot be
/// known at configure time in Zig 0.17, so only the paths that are statically
/// known relative to the Zig lib directory are emitted here.
fn appendBundledLibcIncludeFlags(
    output: GenerateOutput,
    b: *std.Build,
    mod: *std.Build.Module,
    target: *const std.Target,
) !void {
    if (!output.wantsFlags()) return;

    const registry = output.params.cc_params.registry;

    const link_libc = mod.link_libc orelse false;
    const link_libcpp = mod.link_libcpp orelse false;
    if (!link_libc and !link_libcpp) return;

    // zig does not have a libc for every platform, for those just let the
    // driver or --sysroot or default systemwide installation happen
    if (!std.zig.target.canBuildLibC(target)) return;

    try output.appendFlag("-nostdinc");

    if (link_libcpp) {
        try appendLibCxxDefines(output, mod, target);

        const libcxx_include = registry.add(b, .{
            .relative = .{ .base = .zig_lib, .sub_path = "libcxx/include" },
        }, true);
        const libcxxabi_include = registry.add(b, .{
            .relative = .{ .base = .zig_lib, .sub_path = "libcxxabi/include" },
        }, true);
        try output.appendFlagSlice(&.{
            "-isystem",
            libcxx_include,
            "-isystem",
            libcxxabi_include,
        });
    }

    // clang builtin headers that must be included first
    const zig_include = registry.add(b, .{
        .relative = .{ .base = .zig_lib, .sub_path = "include" },
    }, true);
    try output.appendFlagSlice(&.{ "-isystem", zig_include });
}

/// Zig does not use clang's config header and instead manually passes flags to
/// every C++ module. This is done in addCxxArgs from src/libs/libcxx.zig, and
/// is replicated here
fn appendLibCxxDefines(
    output: GenerateOutput,
    mod: *std.Build.Module,
    target: *const std.Target,
) !void {
    if (!output.wantsFlags()) return;
    const allocator = output.params.cc_params.allocator;

    // see defaultSingleThreaded in src/target.zig of compiler
    var any_non_single_threaded = false;
    for (mod.getGraph().modules) |m| {
        const m_target = if (m.resolved_target) |*rt| &rt.result else target;
        const default_single_threaded = switch (m_target.cpu.arch) {
            .wasm32, .wasm64 => true,
            else => m_target.os.tag == .haiku,
        };
        if (!(m.single_threaded orelse default_single_threaded)) {
            any_non_single_threaded = true;
            break;
        }
    }

    // defaultCompilerRtOptimizeMode in src/target.zig
    const optimize_mode: std.builtin.Optimize = switch (mod.optimize orelse .debug) {
        .debug, .safe => if (target.cpu.arch.isWasm() and target.os.tag == .freestanding)
            std.builtin.Optimize.small
        else
            .fast,
        .fast => .fast,
        .small => .small,
    };

    const abi_version: u2 = if (target.os.tag == .emscripten) 2 else 1;
    try output.appendFlag(try std.fmt.allocPrint(allocator, "-D_LIBCPP_ABI_VERSION={d}", .{abi_version}));
    try output.appendFlag(try std.fmt.allocPrint(allocator, "-D_LIBCPP_ABI_NAMESPACE=__{d}", .{abi_version}));
    try output.appendFlag(try std.fmt.allocPrint(allocator, "-D_LIBCPP_HAS_THREADS={d}", .{@intFromBool(any_non_single_threaded)}));
    try output.appendFlag("-D_LIBCPP_HAS_MONOTONIC_CLOCK");
    try output.appendFlag("-D_LIBCPP_HAS_TERMINAL");
    try output.appendFlag(try std.fmt.allocPrint(allocator, "-D_LIBCPP_HAS_MUSL_LIBC={d}", .{@intFromBool(target.abi.isMusl())}));
    try output.appendFlag("-D_LIBCXXABI_DISABLE_VISIBILITY_ANNOTATIONS");
    try output.appendFlag("-D_LIBCPP_DISABLE_VISIBILITY_ANNOTATIONS");
    try output.appendFlag("-D_LIBCPP_HAS_VENDOR_AVAILABILITY_ANNOTATIONS=0");
    try output.appendFlag(try std.fmt.allocPrint(allocator, "-D_LIBCPP_HAS_FILESYSTEM={d}", .{@intFromBool(target.os.tag != .wasi)}));
    try output.appendFlag("-D_LIBCPP_HAS_RANDOM_DEVICE");
    try output.appendFlag("-D_LIBCPP_HAS_LOCALIZATION");
    try output.appendFlag("-D_LIBCPP_HAS_UNICODE");
    try output.appendFlag("-D_LIBCPP_HAS_WIDE_CHARACTERS");
    try output.appendFlag("-D_LIBCPP_HAS_NO_STD_MODULES");
    if (target.os.tag == .linux) {
        try output.appendFlag("-D_LIBCPP_HAS_TIME_ZONE_DATABASE");
    }
    // zig always uses this backend (not sure what other options there are?)
    try output.appendFlag("-D_LIBCPP_PSTL_BACKEND_SERIAL");
    try output.appendFlag(switch (optimize_mode) {
        .debug => "-D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_DEBUG",
        .fast, .small => "-D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_NONE",
        .safe => "-D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_FAST",
    });
    if (target.isGnuLibC()) {
        if (target.os.versionRange().gnuLibCVersion().?.order(.{ .major = 2, .minor = 16, .patch = 0 }) == .lt) {
            try output.appendFlag("-D_LIBCPP_HAS_LIBRARY_ALIGNED_ALLOCATION=0");
        }
    }
}

/// Appends the transitive/public flags of a system library which is linked to some artifact `step`
/// A subset of std.Build.Step.Compile.getZigArgs
fn appendFlagsForSystemLib(
    step: *std.Build.Step.Compile,
    output: GenerateOutput,
    system_lib: std.Build.Module.SystemLib,
    system_lib_flags_cache: *std.StringHashMapUnmanaged([]const []const u8),
    already_linked: bool,
) !void {
    const b = step.step.owner;
    const system_lib_gop = try system_lib_flags_cache.getOrPut(b.allocator, system_lib.name);
    if (system_lib_gop.found_existing) {
        try output.appendFlagSlice(system_lib_gop.value_ptr.*);
        return;
    } else {
        system_lib_gop.value_ptr.* = &.{};
    }

    if (already_linked) {
        return;
    }

    const prefix: []const u8 = prefix: {
        if (system_lib.needed) break :prefix "-needed-l";
        if (system_lib.weak) break :prefix "-weak-l";
        break :prefix "-l";
    };
    // pkg-config based flags cannot be computed at configure time in Zig 0.17,
    // so only the -l flag is emitted, matching what happens when pkg-config is
    // not installed.
    if (output.wantsFlags()) try output.appendFlag(b.fmt("{s}{s}", .{ prefix, system_lib.name }));
}

/// Get all the LazyPaths that must be resolved before
/// compileStepToCompileCommandEntries can be safely called.
pub fn compileStepPathDependencies(
    step: *std.Build.Step.Compile,
    output: *std.ArrayList(LazyPath),
    do_later: *std.ArrayList(*std.Build.Step.Compile),
) !void {
    const intermediate_output = GenerateOutput{ .params = .{ .lazy_path_params = .{ .output = output } } };
    return generateCompileCommandEntriesOrGatherDependencies(step, do_later, intermediate_output);
}

pub fn compileStepToCompileCommandEntries(
    step: *std.Build.Step.Compile,
    options: CompileCommandOptions,
    registry: *PathRegistry,
    output: *std.ArrayList(CompileCommandEntry),
    do_later: *std.ArrayList(*std.Build.Step.Compile),
) !void {
    var flags: std.ArrayList([]const u8) = .empty;
    const intermediate_output = GenerateOutput{ .params = .{ .cc_params = .{
        .params = .{
            .output = output,
            .options = options,
        },
        .allocator = step.step.owner.allocator,
        .flags = &flags,
        .registry = registry,
    } } };
    return generateCompileCommandEntriesOrGatherDependencies(step, do_later, intermediate_output);
}

/// A subset of std.Build.Step.Compile.getZigArgs
/// Two possible code paths: one to generate CompileCommandEntrys, one to
/// just output the dependent LazyPaths
fn generateCompileCommandEntriesOrGatherDependencies(
    step: *std.Build.Step.Compile,
    do_later: *std.ArrayList(*std.Build.Step.Compile),
    output: GenerateOutput,
) !void {
    const b = step.step.owner;

    // these are additional per-file flags, stored by absolute path to source file
    var file_flags = CompileCommandsBuilder.init();
    // not adding -lc -lc++ here
    {
        var system_lib_flags_cache: std.StringHashMapUnmanaged([]const []const u8) = .empty;
        // store -framework FrameworkName flags, which I think clangd might care about?
        var frameworks: std.StringArrayHashMapUnmanaged(std.Build.Module.LinkFrameworkOptions) = .empty;

        for (step.getCompileDependencies(false)) |dep_compile| {
            const my_responsibility = dep_compile == step;
            if (!my_responsibility and find(dep_compile, do_later.items) == null) {
                try do_later.append(b.allocator, dep_compile);
            }

            // when compiling a C/C++ project, usually there is just one module
            // per compile step, but for completeness's sake this loop is here
            for (dep_compile.root_module.getGraph().modules) |mod| {
                const already_linked = !my_responsibility and dep_compile.isDynamicLibrary();

                if (output.wantsFlags() and !already_linked) {
                    for (mod.frameworks.keys(), mod.frameworks.values()) |name, info| {
                        try frameworks.put(b.allocator, name, info);
                    }
                }

                // Inherit dependencies on system libraries and static libraries.
                for (mod.link_objects.items) |link_object| {
                    switch (link_object) {
                        // linking a static library by path offers nothing to compile_commands.json
                        .static_path => {},
                        .other_step => |other_step| {
                            if (other_step != step and find(other_step, do_later.items) == null) {
                                try do_later.append(b.allocator, other_step);
                            }
                            // clangd doesnt care about linking against a test or object file or library or adding to rpath
                            // NOTE: if compile steps get a concept of public flags, then this will change and other_step
                            // maye forward something, and we will need to do getCompileDependencies(true) or something to
                            // gather the public flags of linked objects
                        },
                        .win32_resource_file => {},
                        // assembly files have no associated flags
                        .assembly_file => {},

                        .c_source_file => |c_source_file| if (my_responsibility) try output.addResolvedPath(b, &file_flags, c_source_file),
                        .c_source_files => |c_source_files| if (my_responsibility) try output.addResolvedPaths(b, &file_flags, c_source_files),
                        .system_lib => |system_lib| try appendFlagsForSystemLib(step, output, system_lib, &system_lib_flags_cache, already_linked),
                    }
                }

                if (!my_responsibility)
                    continue;

                // original getZigArgs code does some stuff here to provide a unique name to every module, but this always
                // covers all modules so it is fine to do the stuff after it unconditionally here
                try appendFlagsForModule(output, mod, &step.step);
            }
        }

        for (frameworks.keys(), frameworks.values()) |name, info| {
            if (info.needed) {
                try output.appendFlag("-needed_framework");
            } else if (info.weak) {
                try output.appendFlag("-weak_framework");
            } else {
                try output.appendFlag("-framework");
            }
            try output.appendFlag(name);
        }
    }

    // if (step.link_function_sections) {
    //     try output.appendFlag("-ffunction-sections");
    // }
    // if (step.link_data_sections) {
    //     try output.appendFlag("-fdata-sections");
    // }
    if (step.force_load_objc) {
        try output.appendFlag("-ObjC");
    }
    if (step.wasi_exec_model) |model| {
        try output.appendFlag(b.fmt("-mexec-model={s}", .{@tagName(model)}));
    }

    // NOTE: the actual zig std code checks if the directories exist before doing this
    if (output.wantsFlags()) {
        const registry = output.params.cc_params.registry;
        for (b.graph.search_prefixes.items) |search_prefix| {
            const lp = b.graph.cwdRelativePath(b.pathJoin(&.{ search_prefix, "include" }));
            try output.appendFlagSlice(&.{ "-I", registry.add(b, lp, true) });
        }
    }

    try output.appendFNoFlag("PIE", step.pie);

    if (step.lto) |lto| {
        try output.appendFlag(switch (lto) {
            .full => "-flto=full",
            .thin => "-flto=thin",
            .none => "-fno-lto",
        });
    }

    switch (output.params) {
        .cc_params => |params| return file_flags.finish(b, params.registry, params.flags.items, params.params.options.driver, params.params.output),
        .lazy_path_params => {},
    }
}

fn find(step: *std.Build.Step.Compile, haystack: []const *std.Build.Step.Compile) ?usize {
    return std.mem.find(*std.Build.Step.Compile, haystack, &.{step});
}
