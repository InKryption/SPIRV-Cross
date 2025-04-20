const std = @import("std");
const Build = std.Build;

const build_manifest = @import("build.zig.zon");
pub const build_version = std.SemanticVersion.parse(build_manifest.version) catch unreachable;
pub const abi_version = std.SemanticVersion.parse("0.65.0") catch unreachable;

pub const Options = struct {
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,

    skip_install: bool,

    want_glsl: bool,
    want_hlsl: bool,
    want_msl: bool,
    want_cpp: bool,
    want_reflect: bool,

    exceptions_to_assertions: bool,
    enable_tests: bool,

    sanitize_address: bool,
    sanitize_memory: bool,
    sanitize_threads: bool,
    sanitize_undefined: bool,

    namespace_override: ?[]const u8,
    force_stl_types: bool,

    werror: bool,
    misc_warnings: bool,

    force_pic: bool,

    pub fn fromBuild(b: *Build) Options {
        const target = b.standardTargetOptions(.{});
        const optimize = b.standardOptimizeOption(.{});
        const skip_install = b.option(bool, "skip_install", "Skips installation targets.") orelse false;

        const want_all_features = if (b.pkg_hash.len == 0)
            b.option(bool, "want_all", "Enable GLSL, HLSL, MSL, C++, and reflection support for the shared library.") orelse false
        else
            false;
        return .{
            .target = target,
            .optimize = optimize,
            .skip_install = skip_install,

            .want_glsl = b.option(bool, "want_glsl", "Enable GLSL support for the shared library.") orelse want_all_features,
            .want_hlsl = b.option(bool, "want_hlsl", "Enable HLSL target support for the shared library.") orelse want_all_features,
            .want_msl = b.option(bool, "want_msl", "Enable MSL target support for the shared library.") orelse want_all_features,
            .want_cpp = b.option(bool, "want_cpp", "Enable C++ target support for the shared library.") orelse want_all_features,
            .want_reflect = b.option(bool, "want_reflect", "Enable JSON reflection target support for the shared library.") orelse want_all_features,

            .exceptions_to_assertions = b.option(bool, "exceptions_to_assertions", "Instead of throwing exceptions assert") orelse false,
            .enable_tests = b.option(bool, "enable_tests", "Enable SPIRV-Cross tests.") orelse true,

            .sanitize_address = b.option(bool, "sanitize_address", "Sanitize address") orelse false,
            .sanitize_memory = b.option(bool, "sanitize_memory", "Sanitize memory") orelse false,
            .sanitize_threads = b.option(bool, "sanitize_threads", "Sanitize threads") orelse false,
            .sanitize_undefined = b.option(bool, "sanitize_undefined", "Sanitize undefined") orelse false,

            .namespace_override = b.option([]const u8, "namespace_override", "Override the namespace used in the C++ API."),
            .force_stl_types = b.option(bool, "force_stl_types", "Force use of STL types instead of STL replacements in certain places. Might reduce performance.") orelse false,

            .werror = b.option(bool, "werror", "Fail build on warnings.") orelse false,
            .misc_warnings = b.option(bool, "misc_warnings", "Misc warnings useful for Travis runs.") orelse false,

            .force_pic = b.option(bool, "force_pic", "Force position-independent code for all targets.") orelse false,
        };
    }
};

pub fn build(b: *Build) void {
    const opts: Options = .fromBuild(b);
    const wanted_feature_apis: LibraryName.Set = .init(.{
        .glsl = opts.want_glsl,
        .cpp = opts.want_cpp,
        .msl = opts.want_msl,
        .hlsl = opts.want_hlsl,
        .reflect = opts.want_reflect,
    });

    const cli_step = b.step("cli", "Build the CLI binary. Implies the static library.");

    const c_static_step = b.step("c-static", "Build the C and C++ API as static libraries.");
    const c_shared_step = b.step("c-shared", "Build the C API as a single shared library.");

    const core_step = b.step("core", "Build and install the core module.");
    const glsl_step = b.step("glsl", "Build and install the glsl module.");
    const cpp_step = b.step("cpp", "Build and install the cpp module.");
    const msl_step = b.step("msl", "Build and install the msl module.");
    const hlsl_step = b.step("hlsl", "Build and install the hlsl module.");
    const reflect_step = b.step("reflect", "Build and install the reflect module.");
    const util_step = b.step("util", "Build and install the util module.");

    {
        const static_step = b.step("static", "Build and install the C and C++ API along with all specified feature libraries.");
        static_step.dependOn(c_static_step);

        static_step.dependOn(core_step);
        static_step.dependOn(glsl_step);
        static_step.dependOn(cpp_step);
        static_step.dependOn(msl_step);
        static_step.dependOn(hlsl_step);
        static_step.dependOn(util_step);
    }

    const gitversion_h_helper = struct {
        fn addIncludeTo(mod: *Build.Module, gitversion_h: Build.LazyPath) void {
            const HAVE_SPIRV_CROSS_GIT_VERSION = "HAVE_SPIRV_CROSS_GIT_VERSION";
            mod.addIncludePath(gitversion_h.dirname());
            mod.addCMacro(HAVE_SPIRV_CROSS_GIT_VERSION, "");
        }
    };
    const gitversion_h: Build.LazyPath = gen: {
        const gen_gitversion_h_exe = b.addExecutable(.{
            .name = "gen-gitversion-h",
            .root_module = b.createModule(.{
                .root_source_file = b.path("scripts/gen_gitversion_h.zig"), // NOTE: see the script for explanation
                .target = b.resolveTargetQuery(.{}),
                .optimize = .ReleaseSafe,
            }),
        });

        const gen_gitversion_h_run = b.addRunArtifact(gen_gitversion_h_exe);
        const gitversion_h = gen_gitversion_h_run.addOutputFileArg("gitversion.h");
        gen_gitversion_h_run.addFileArg(b.path("cmake/gitversion.in.h"));
        gen_gitversion_h_run.addArg(b.fmt("{}", .{build_version}));

        const SOURCE_DATE_EPOCH = "SOURCE_DATE_EPOCH";
        if (b.graph.env_map.get(SOURCE_DATE_EPOCH)) |source_date_epoch| {
            gen_gitversion_h_run.setEnvironmentVariable(
                SOURCE_DATE_EPOCH,
                source_date_epoch,
            );
        }

        // dependencies to re-run gen-gitversion-h for
        const srcdir = b.path("src");
        for (all_sources.values) |source_list| {
            for (source_list) |file| {
                const file_lp = srcdir.path(b, file);
                gen_gitversion_h_run.addFileInput(file_lp);
            }
        }
        gen_gitversion_h_run.addFileInput(b.path("build.zig"));

        break :gen gitversion_h;
    };

    const cxx_is_clang = true;
    const cxx_is_gnu = false;
    const cxx_is_msvc = false;

    // TODO: linker flag pass through???
    // CMakeLists.txt:76:1
    const spirv_cross_link_flags = {};

    const spirv_compiler_options: []const []const u8, //
    const spirv_compiler_defines: []const struct { []const u8, []const u8 } //
    = blk: {
        var spirv_compiler_options: std.ArrayListUnmanaged([]const u8) = .empty;
        spirv_compiler_options.ensureTotalCapacity(b.graph.arena, 256) catch unreachable; // just increment this if you need more items

        var spirv_compiler_defines: std.ArrayListUnmanaged(struct { []const u8, []const u8 }) = .empty;
        spirv_compiler_defines.ensureTotalCapacity(b.graph.arena, 256) catch unreachable; // just increment this if you need more itesm

        if (opts.exceptions_to_assertions) {
            spirv_compiler_defines.appendAssumeCapacity(
                .{ "SPIRV_CROSS_EXCEPTIONS_TO_ASSERTIONS", "" },
            );
        }

        if (opts.force_stl_types) {
            spirv_compiler_defines.appendAssumeCapacity(
                .{ "SPIRV_CROSS_FORCE_STL_TYPES", "" },
            );
        }

        // logic details from the original CMakeLists.txt file
        if ((cxx_is_gnu or cxx_is_clang) and !cxx_is_msvc) {
            spirv_compiler_options.appendSliceAssumeCapacity(&.{
                "-Wall", "-Wextra", "-Wshadow", "-Wno-deprecated-declarations",
            });
            if (opts.misc_warnings) {
                if (cxx_is_clang) {
                    spirv_compiler_options.appendAssumeCapacity("-Wshorten-64-to-32");
                }
            }
            if (opts.werror) {
                spirv_compiler_options.appendAssumeCapacity("-Werror");
            }
            if (opts.exceptions_to_assertions) {
                spirv_compiler_options.appendAssumeCapacity("-fno-exceptions");
            }
            if (opts.sanitize_address) {
                spirv_compiler_options.appendAssumeCapacity("-fsanitize=address");
                _ = spirv_cross_link_flags; // TODO: goto def
            }
            if (opts.sanitize_undefined) {
                spirv_compiler_options.appendAssumeCapacity("-fsanitize=undefined");
                _ = spirv_cross_link_flags; // TODO: goto def
            }
            if (opts.sanitize_memory) {
                spirv_compiler_options.appendAssumeCapacity("-fsanitize=memory");
                _ = spirv_cross_link_flags; // TODO: goto def
            }
            if (opts.sanitize_threads) {
                spirv_compiler_options.appendAssumeCapacity("-fsanitize=thread");
                _ = spirv_cross_link_flags; // TODO: goto def
            }
        } else if (cxx_is_msvc) {
            if (true) {
                @compileError("Didn't expect to actually get here? Check that the flags and everything else is right");
            }
            spirv_compiler_options.appendSliceAssumeCapacity(&.{
                "/wd4267", "/wd4996",
            });
            if (opts.optimize == .Debug) {
                // AppVeyor spuriously fails in debug build on older MSVC without /bigobj.
                spirv_compiler_options.appendAssumeCapacity("/bigobj");
            }
        }

        break :blk .{
            spirv_compiler_options.items,
            spirv_compiler_defines.items,
        };
    };

    // TODO: pkgconfig stuff?

    // // CMakeLists.txt:255:3
    // configure_file(
    //     ${CMAKE_CURRENT_SOURCE_DIR}/pkg-config/spirv-cross-c.pc.in
    //     ${CMAKE_CURRENT_BINARY_DIR}/spirv-cross-c.pc @ONLY)
    // install(FILES ${CMAKE_CURRENT_BINARY_DIR}/spirv-cross-c.pc DESTINATION ${CMAKE_INSTALL_LIBDIR}/pkgconfig)
    // // CMakeLists.txt:351:3
    // configure_file(
    //     ${CMAKE_CURRENT_SOURCE_DIR}/pkg-config/spirv-cross-c-shared.pc.in
    //     ${CMAKE_CURRENT_BINARY_DIR}/spirv-cross-c-shared.pc @ONLY)
    // install(FILES ${CMAKE_CURRENT_BINARY_DIR}/spirv-cross-c-shared.pc DESTINATION ${CMAKE_INSTALL_LIBDIR}/pkgconfig)

    const core_lib = spirvCrossAddLibrary(b, "spirv-cross-core", opts, .{
        .step = core_step,
        .linkage = .static,
        .defines = spirv_compiler_defines,
        .files = all_sources.get(.core),
        .options = spirv_compiler_options,
    });

    const glsl_lib = spirvCrossAddLibrary(b, "spirv-cross-glsl", opts, .{
        .step = glsl_step,
        .linkage = .static,
        .defines = spirv_compiler_defines,
        .files = all_sources.get(.glsl),
        .options = spirv_compiler_options,
    });
    glsl_lib.linkLibrary(core_lib);
    glsl_lib.installLibraryHeaders(core_lib);

    const cpp_lib = spirvCrossAddLibrary(b, "spirv-cross-cpp", opts, .{
        .step = cpp_step,
        .linkage = .static,
        .defines = spirv_compiler_defines,
        .files = all_sources.get(.cpp),
        .options = spirv_compiler_options,
    });
    cpp_lib.linkLibrary(glsl_lib);
    cpp_lib.installLibraryHeaders(glsl_lib);

    const msl_lib = spirvCrossAddLibrary(b, "spirv-cross-msl", opts, .{
        .step = msl_step,
        .linkage = .static,
        .defines = spirv_compiler_defines,
        .files = all_sources.get(.msl),
        .options = spirv_compiler_options,
    });
    msl_lib.linkLibrary(glsl_lib);
    msl_lib.installLibraryHeaders(glsl_lib);

    const hlsl_lib = spirvCrossAddLibrary(b, "spirv-cross-hlsl", opts, .{
        .step = hlsl_step,
        .linkage = .static,
        .defines = spirv_compiler_defines,
        .files = all_sources.get(.hlsl),
        .options = spirv_compiler_options,
    });
    hlsl_lib.linkLibrary(glsl_lib);
    hlsl_lib.installLibraryHeaders(glsl_lib);

    const reflect_lib = spirvCrossAddLibrary(b, "spirv-cross-reflect", opts, .{
        .step = reflect_step,
        .linkage = .static,
        .defines = spirv_compiler_defines,
        .files = all_sources.get(.reflect),
        .options = spirv_compiler_options,
    });
    // NOTE: in the original CMakeLists.txt file, the reflection library doesn't link the glsl library,
    // despite both requiring it through CMake logic, and the `spirv_reflect.cpp` source code making use
    // of the library.
    reflect_lib.linkLibrary(glsl_lib);
    reflect_lib.installLibraryHeaders(glsl_lib);

    const util_lib = spirvCrossAddLibrary(b, "spirv-cross-util", opts, .{
        .step = util_step,
        .linkage = .static,
        .defines = spirv_compiler_defines,
        .files = all_sources.get(.util),
        .options = spirv_compiler_options,
    });
    util_lib.linkLibrary(core_lib);

    // -- START: spirv-cross-c --
    const c_static_lib = spirvCrossAddLibrary(b, "spirv-cross-c", opts, .{
        .step = c_static_step,
        .linkage = .static,
        .defines = spirv_compiler_defines,
        .files = all_sources.get(.c),
        .options = spirv_compiler_options,
    });
    gitversion_h_helper.addIncludeTo(c_static_lib.root_module, gitversion_h);
    {
        // GLSL can itself be disabled, but if any other support library
        // that needs it is enabled, it needs to become enabled.
        var need_glsl = false;
        for ([_]struct { LibraryName, *Build.Step.Compile }{
            .{ .hlsl, hlsl_lib },
            .{ .msl, msl_lib },
            .{ .cpp, cpp_lib },
            .{ .reflect, reflect_lib },
        }) |maybe_lib_info| {
            const feature, const artifact = maybe_lib_info;
            if (!wanted_feature_apis.contains(feature)) continue;
            c_static_lib.root_module.addCMacro(feature.featureMacroName().?, "1");
            c_static_lib.linkLibrary(artifact);
            c_static_lib.installLibraryHeaders(artifact);
            need_glsl = true;
        }

        if (opts.want_glsl or need_glsl) {
            c_static_lib.root_module.addCMacro(LibraryName.featureMacroName(.glsl).?, "1");
            c_static_lib.linkLibrary(glsl_lib);
            c_static_lib.installLibraryHeaders(glsl_lib);
        }
    }
    // -- END: spirv-cross-c --

    // -- START: spirv-cross-c-shared --
    const c_shared_lib = spirvCrossAddLibrary(b, "spirv-cross-c-shared", opts, .{
        .step = c_shared_step,
        .linkage = .{ .dynamic = abi_version },
        .defines = spirv_compiler_defines,
        .files = comptime all_sources.get(.core) ++ all_sources.get(.c),
        .options = null, // combine the overall options down below
    });
    gitversion_h_helper.addIncludeTo(c_shared_lib.root_module, gitversion_h);
    c_shared_lib.root_module.addCMacro("SPVC_EXPORT_SYMBOLS", "");

    // logic details from the original CMakeLists.txt file
    if (cxx_is_gnu or cxx_is_clang) {
        // Only export the C API.

        // TODO: -fvisibility=hidden; apply to c_shared_lib
        if (!opts.target.result.os.tag.isDarwin()) {
            _ = spirv_cross_link_flags; // TODO: goto def; apply to c_shared_lib.
        }
    }

    {
        var c_shared_lib_sources: std.ArrayListUnmanaged([]const u8) = .empty;
        c_shared_lib_sources.ensureTotalCapacity(b.graph.arena, 256) catch unreachable; // just increment this if you need more items
        getSourceFilesIntoList(b, &c_shared_lib_sources, all_sources.get(.core));
        getSourceFilesIntoList(b, &c_shared_lib_sources, all_sources.get(.c));

        // GLSL can itself be disabled, but if any other support library
        // that needs it is enabled, it needs to become enabled.
        var need_glsl = false;
        for ([_]LibraryName{
            .hlsl,
            .msl,
            .cpp,
            .reflect,
        }) |feature| {
            if (!wanted_feature_apis.contains(feature)) continue;
            c_shared_lib.root_module.addCMacro(feature.featureMacroName().?, "1");
            getSourceFilesIntoList(b, &c_shared_lib_sources, all_sources.get(feature));
            need_glsl = true;
        }

        if (opts.want_glsl or need_glsl) {
            c_shared_lib.root_module.addCMacro(LibraryName.featureMacroName(.glsl).?, "1");
            getSourceFilesIntoList(b, &c_shared_lib_sources, all_sources.get(.glsl));
        }
        c_shared_lib.addCSourceFiles(.{
            .root = b.path("src"),
            .files = c_shared_lib_sources.items,
            .flags = spirv_compiler_options,
        });
    }
    // -- END: spirv-cross-c-shared --

    {
        const cli_exe = b.addExecutable(.{
            .name = "spirv-cross",
            .root_module = b.createModule(.{
                .root_source_file = null,
                .target = opts.target,
                .optimize = opts.optimize,
                // .link_libc = true,
                // .link_libcpp = true,
            }),
        });
        cli_step.dependOn(&cli_exe.step);

        if (!opts.skip_install) {
            const cli_install = b.addInstallArtifact(cli_exe, .{});
            cli_step.dependOn(&cli_install.step);

            const install_step = b.getInstallStep();
            install_step.dependOn(&cli_install.step);
        }

        cli_exe.linkLibrary(glsl_lib);
        cli_exe.linkLibrary(hlsl_lib);
        cli_exe.linkLibrary(cpp_lib);
        cli_exe.linkLibrary(reflect_lib);
        cli_exe.linkLibrary(msl_lib);
        cli_exe.linkLibrary(util_lib);
        cli_exe.linkLibrary(core_lib);

        _ = spirv_cross_link_flags; // TODO: goto def; apply to main_exe.

        cli_exe.addCSourceFile(.{
            .file = b.path("src/main.cpp"),
            .flags = spirv_compiler_options,
        });

        for (spirv_compiler_defines) |def| {
            const def_name, const def_val = def;
            cli_exe.root_module.addCMacro(def_name, def_val);
        }
        gitversion_h_helper.addIncludeTo(cli_exe.root_module, gitversion_h);

        // if (SPIRV_CROSS_ENABLE_TESTS)
        //     # Set up tests, using only the simplest modes of the test_shaders
        //     # script.  You have to invoke the script manually to:
        //     #  - Update the reference files
        //     #  - Get cycle counts from malisc
        //     #  - Keep failing outputs
        //     if (${CMAKE_VERSION} VERSION_GREATER "3.12")
        //         find_package(Python3)
        //         if (${PYTHON3_FOUND})
        //             set(PYTHONINTERP_FOUND ON)
        //             set(PYTHON_VERSION_MAJOR 3)
        //             set(PYTHON_EXECUTABLE ${Python3_EXECUTABLE})
        //         else()
        //             set(PYTHONINTERP_FOUND OFF)
        //         endif()
        //     else()
        //         find_package(PythonInterp)
        //     endif()

        //     find_program(spirv-cross-glslang NAMES glslangValidator
        //             PATHS ${CMAKE_CURRENT_SOURCE_DIR}/external/glslang-build/output/bin
        //             NO_DEFAULT_PATH)
        //     find_program(spirv-cross-spirv-as NAMES spirv-as
        //             PATHS ${CMAKE_CURRENT_SOURCE_DIR}/external/spirv-tools-build/output/bin
        //             NO_DEFAULT_PATH)
        //     find_program(spirv-cross-spirv-val NAMES spirv-val
        //             PATHS ${CMAKE_CURRENT_SOURCE_DIR}/external/spirv-tools-build/output/bin
        //             NO_DEFAULT_PATH)
        //     find_program(spirv-cross-spirv-opt NAMES spirv-opt
        //             PATHS ${CMAKE_CURRENT_SOURCE_DIR}/external/spirv-tools-build/output/bin
        //             NO_DEFAULT_PATH)

        //     if ((${spirv-cross-glslang} MATCHES "NOTFOUND") OR (${spirv-cross-spirv-as} MATCHES "NOTFOUND") OR (${spirv-cross-spirv-val} MATCHES "NOTFOUND") OR (${spirv-cross-spirv-opt} MATCHES "NOTFOUND"))
        //         set(SPIRV_CROSS_ENABLE_TESTS OFF)
        //         message("SPIRV-Cross:  Testing will be disabled for SPIRV-Cross. Could not find glslang or SPIRV-Tools build under external/. To enable testing, run ./checkout_glslang_spirv_tools.sh and ./build_glslang_spirv_tools.sh first.")
        //     else()
        //         set(SPIRV_CROSS_ENABLE_TESTS ON)
        //         message("SPIRV-Cross: Found glslang and SPIRV-Tools. Enabling test suite.")
        //         message("SPIRV-Cross: Found glslangValidator in: ${spirv-cross-glslang}.")
        //         message("SPIRV-Cross: Found spirv-as in: ${spirv-cross-spirv-as}.")
        //         message("SPIRV-Cross: Found spirv-val in: ${spirv-cross-spirv-val}.")
        //         message("SPIRV-Cross: Found spirv-opt in: ${spirv-cross-spirv-opt}.")
        //     endif()

        //     set(spirv-cross-externals
        //             --glslang "${spirv-cross-glslang}"
        //             --spirv-as "${spirv-cross-spirv-as}"
        //             --spirv-opt "${spirv-cross-spirv-opt}"
        //             --spirv-val "${spirv-cross-spirv-val}")

        //     if (${PYTHONINTERP_FOUND} AND SPIRV_CROSS_ENABLE_TESTS)
        //         if (${PYTHON_VERSION_MAJOR} GREATER 2)
        //             add_executable(spirv-cross-c-api-test tests-other/c_api_test.c)
        //             target_link_libraries(spirv-cross-c-api-test spirv-cross-c)
        //             set_target_properties(spirv-cross-c-api-test PROPERTIES LINK_FLAGS "${spirv-cross-link-flags}")

        //             add_executable(spirv-cross-small-vector-test tests-other/small_vector.cpp)
        //             target_link_libraries(spirv-cross-small-vector-test spirv-cross-core)
        //             set_target_properties(spirv-cross-small-vector-test PROPERTIES LINK_FLAGS "${spirv-cross-link-flags}")

        //             add_executable(spirv-cross-msl-constexpr-test tests-other/msl_constexpr_test.cpp)
        //             target_link_libraries(spirv-cross-msl-constexpr-test spirv-cross-c)
        //             set_target_properties(spirv-cross-msl-constexpr-test PROPERTIES LINK_FLAGS "${spirv-cross-link-flags}")

        //             add_executable(spirv-cross-msl-resource-binding-test tests-other/msl_resource_bindings.cpp)
        //             target_link_libraries(spirv-cross-msl-resource-binding-test spirv-cross-c)
        //             set_target_properties(spirv-cross-msl-resource-binding-test PROPERTIES LINK_FLAGS "${spirv-cross-link-flags}")

        //             add_executable(spirv-cross-hlsl-resource-binding-test tests-other/hlsl_resource_bindings.cpp)
        //             target_link_libraries(spirv-cross-hlsl-resource-binding-test spirv-cross-c)
        //             set_target_properties(spirv-cross-hlsl-resource-binding-test PROPERTIES LINK_FLAGS "${spirv-cross-link-flags}")

        //             add_executable(spirv-cross-msl-ycbcr-conversion-test tests-other/msl_ycbcr_conversion_test.cpp)
        //             target_link_libraries(spirv-cross-msl-ycbcr-conversion-test spirv-cross-c)
        //             set_target_properties(spirv-cross-msl-ycbcr-conversion-test PROPERTIES LINK_FLAGS "${spirv-cross-link-flags}")

        //             add_executable(spirv-cross-typed-id-test tests-other/typed_id_test.cpp)
        //             target_link_libraries(spirv-cross-typed-id-test spirv-cross-core)
        //             set_target_properties(spirv-cross-typed-id-test PROPERTIES LINK_FLAGS "${spirv-cross-link-flags}")

        //             if (CMAKE_COMPILER_IS_GNUCXX OR (${CMAKE_CXX_COMPILER_ID} MATCHES "Clang"))
        //                 target_compile_options(spirv-cross-c-api-test PRIVATE -std=c89 -Wall -Wextra)
        //             endif()
        //             add_test(NAME spirv-cross-c-api-test
        //                     COMMAND $<TARGET_FILE:spirv-cross-c-api-test> ${CMAKE_CURRENT_SOURCE_DIR}/tests-other/c_api_test.spv
        //                     ${spirv-cross-abi-major}
        //                     ${spirv-cross-abi-minor}
        //                     ${spirv-cross-abi-patch})
        //             add_test(NAME spirv-cross-small-vector-test
        //                     COMMAND $<TARGET_FILE:spirv-cross-small-vector-test>)
        //             add_test(NAME spirv-cross-msl-constexpr-test
        //                     COMMAND $<TARGET_FILE:spirv-cross-msl-constexpr-test> ${CMAKE_CURRENT_SOURCE_DIR}/tests-other/msl_constexpr_test.spv)
        //             add_test(NAME spirv-cross-msl-resource-binding-test
        //                     COMMAND $<TARGET_FILE:spirv-cross-msl-resource-binding-test> ${CMAKE_CURRENT_SOURCE_DIR}/tests-other/msl_resource_binding.spv)
        //             add_test(NAME spirv-cross-hlsl-resource-binding-test
        //                     COMMAND $<TARGET_FILE:spirv-cross-hlsl-resource-binding-test> ${CMAKE_CURRENT_SOURCE_DIR}/tests-other/hlsl_resource_binding.spv)
        //             add_test(NAME spirv-cross-msl-ycbcr-conversion-test
        //                     COMMAND $<TARGET_FILE:spirv-cross-msl-ycbcr-conversion-test> ${CMAKE_CURRENT_SOURCE_DIR}/tests-other/msl_ycbcr_conversion_test.spv)
        //             add_test(NAME spirv-cross-msl-ycbcr-conversion-test-2
        //                     COMMAND $<TARGET_FILE:spirv-cross-msl-ycbcr-conversion-test> ${CMAKE_CURRENT_SOURCE_DIR}/tests-other/msl_ycbcr_conversion_test_2.spv)
        //             add_test(NAME spirv-cross-typed-id-test
        //                     COMMAND $<TARGET_FILE:spirv-cross-typed-id-test>)
        //             add_test(NAME spirv-cross-test
        //                     COMMAND ${PYTHON_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/test_shaders.py --parallel
        //                     ${spirv-cross-externals}
        //                     ${CMAKE_CURRENT_SOURCE_DIR}/shaders
        //                     WORKING_DIRECTORY $<TARGET_FILE_DIR:spirv-cross>)
        //             add_test(NAME spirv-cross-test-no-opt
        //                     COMMAND ${PYTHON_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/test_shaders.py --parallel
        //                     ${spirv-cross-externals}
        //                     ${CMAKE_CURRENT_SOURCE_DIR}/shaders-no-opt
        //                     WORKING_DIRECTORY $<TARGET_FILE_DIR:spirv-cross>)
        //             add_test(NAME spirv-cross-test-metal
        //                     COMMAND ${PYTHON_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/test_shaders.py --metal --parallel
        //                     ${spirv-cross-externals}
        //                     ${CMAKE_CURRENT_SOURCE_DIR}/shaders-msl
        //                     WORKING_DIRECTORY $<TARGET_FILE_DIR:spirv-cross>)
        //             add_test(NAME spirv-cross-test-metal-no-opt
        //                     COMMAND ${PYTHON_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/test_shaders.py --metal --parallel
        //                     ${spirv-cross-externals}
        //                     ${CMAKE_CURRENT_SOURCE_DIR}/shaders-msl-no-opt
        //                     WORKING_DIRECTORY $<TARGET_FILE_DIR:spirv-cross>)
        //             add_test(NAME spirv-cross-test-hlsl
        //                     COMMAND ${PYTHON_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/test_shaders.py --hlsl --parallel
        //                     ${spirv-cross-externals}
        //                     ${CMAKE_CURRENT_SOURCE_DIR}/shaders-hlsl
        //                     WORKING_DIRECTORY $<TARGET_FILE_DIR:spirv-cross>)
        //             add_test(NAME spirv-cross-test-hlsl-no-opt
        //                     COMMAND ${PYTHON_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/test_shaders.py --hlsl --parallel
        //                     ${spirv-cross-externals}
        //                     ${CMAKE_CURRENT_SOURCE_DIR}/shaders-hlsl-no-opt
        //                     WORKING_DIRECTORY $<TARGET_FILE_DIR:spirv-cross>)
        //             add_test(NAME spirv-cross-test-opt
        //                     COMMAND ${PYTHON_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/test_shaders.py --opt --parallel
        //                     ${spirv-cross-externals}
        //                     ${CMAKE_CURRENT_SOURCE_DIR}/shaders
        //                     WORKING_DIRECTORY $<TARGET_FILE_DIR:spirv-cross>)
        //             add_test(NAME spirv-cross-test-metal-opt
        //                     COMMAND ${PYTHON_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/test_shaders.py --metal --opt --parallel
        //                     ${spirv-cross-externals}
        //                     ${CMAKE_CURRENT_SOURCE_DIR}/shaders-msl
        //                     WORKING_DIRECTORY $<TARGET_FILE_DIR:spirv-cross>)
        //             add_test(NAME spirv-cross-test-hlsl-opt
        //                     COMMAND ${PYTHON_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/test_shaders.py --hlsl --opt --parallel
        //                     ${spirv-cross-externals}
        //                     ${CMAKE_CURRENT_SOURCE_DIR}/shaders-hlsl
        //                     WORKING_DIRECTORY $<TARGET_FILE_DIR:spirv-cross>)
        //             add_test(NAME spirv-cross-test-reflection
        //                     COMMAND ${PYTHON_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/test_shaders.py --reflect --parallel
        //                     ${spirv-cross-externals}
        //                     ${CMAKE_CURRENT_SOURCE_DIR}/shaders-reflection
        //                     WORKING_DIRECTORY $<TARGET_FILE_DIR:spirv-cross>)
        //             add_test(NAME spirv-cross-test-ue4
        //                     COMMAND ${PYTHON_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/test_shaders.py --msl --parallel
        //                     ${spirv-cross-externals}
        //                     ${CMAKE_CURRENT_SOURCE_DIR}/shaders-ue4
        //                     WORKING_DIRECTORY $<TARGET_FILE_DIR:spirv-cross>)
        //             add_test(NAME spirv-cross-test-ue4-opt
        //                     COMMAND ${PYTHON_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/test_shaders.py --msl --opt --parallel
        //                     ${spirv-cross-externals}
        //                     ${CMAKE_CURRENT_SOURCE_DIR}/shaders-ue4
        //                     WORKING_DIRECTORY $<TARGET_FILE_DIR:spirv-cross>)
        //             add_test(NAME spirv-cross-test-ue4-no-opt
        //                     COMMAND ${PYTHON_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/test_shaders.py --msl --parallel
        //                     ${spirv-cross-externals}
        //                     ${CMAKE_CURRENT_SOURCE_DIR}/shaders-ue4-no-opt
        //                     WORKING_DIRECTORY $<TARGET_FILE_DIR:spirv-cross>)
        //         endif()
        //     elseif(NOT ${PYTHONINTERP_FOUND})
        //         message(WARNING "SPIRV-Cross: Testing disabled. Could not find python3. If you have python3 installed try running "
        //                 "cmake with -DPYTHON_EXECUTABLE:FILEPATH=/path/to/python3 to help it find the executable")
        //     endif()
        // endif()
    }
}

const LibraryName = enum {
    core,
    c,
    glsl,
    cpp,
    msl,
    hlsl,
    reflect,
    util,

    pub const Set = std.EnumSet(LibraryName);

    pub fn featureMacroName(name: LibraryName) ?[]const u8 {
        return switch (name) {
            .core => null,
            .c => null,
            .util => null,
            .glsl => "SPIRV_CROSS_C_API_GLSL",
            .cpp => "SPIRV_CROSS_C_API_CPP",
            .reflect => "SPIRV_CROSS_C_API_REFLECT",
            .msl => "SPIRV_CROSS_C_API_MSL",
            .hlsl => "SPIRV_CROSS_C_API_HLSL",
        };
    }
};

/// All headers, C source files, and C++ source files, categorized by library.
/// Relative to the `src` directory.
const all_sources: std.EnumArray(LibraryName, []const []const u8) = .init(.{
    .core = &[_][]const u8{
        "GLSL.std.450.h",
        "spirv_common.hpp",
        "spirv_cross_containers.hpp",
        "spirv_cross_error_handling.hpp",
        "spirv.hpp",
        "spirv_cross.hpp",
        "spirv_cross.cpp",
        "spirv_parser.hpp",
        "spirv_parser.cpp",
        "spirv_cross_parsed_ir.hpp",
        "spirv_cross_parsed_ir.cpp",
        "spirv_cfg.hpp",
        "spirv_cfg.cpp",
    },
    .c = &[_][]const u8{
        "spirv.h",
        "spirv_cross_c.cpp",
        "spirv_cross_c.h",
    },
    .glsl = &[_][]const u8{
        "spirv_glsl.cpp",
        "spirv_glsl.hpp",
    },
    .cpp = &[_][]const u8{
        "spirv_cpp.cpp",
        "spirv_cpp.hpp",
    },
    .msl = &[_][]const u8{
        "spirv_msl.cpp",
        "spirv_msl.hpp",
    },
    .hlsl = &[_][]const u8{
        "spirv_hlsl.cpp",
        "spirv_hlsl.hpp",
    },
    .reflect = &[_][]const u8{
        "spirv_reflect.cpp",
        "spirv_reflect.hpp",
    },
    .util = &[_][]const u8{
        "spirv_cross_util.cpp",
        "spirv_cross_util.hpp",
    },
});

fn spirvCrossAddLibrary(
    b: *Build,
    name: []const u8,
    opts: Options,
    params: struct {
        step: *Build.Step,
        linkage: union(std.builtin.LinkMode) {
            static,
            dynamic: ?std.SemanticVersion,
        },
        defines: []const struct { []const u8, []const u8 },
        /// Relative to the `src` dir.
        /// Filters for the appropriate header files; other files are ignored.
        files: []const []const u8,
        /// Set to null if the C/C++ source files should not be added,
        /// because you're going to add them after the fact using more
        /// complicated logic.
        /// Otherwise, pass the full set of options to compile the files
        /// with.
        options: ?[]const []const u8,
    },
) *Build.Step.Compile {
    const artifact = b.addLibrary(.{
        .linkage = params.linkage,
        .name = name,
        .root_module = b.createModule(.{
            .optimize = opts.optimize,
            .target = opts.target,
            .link_libcpp = true,
            .pic = if (opts.force_pic) true else null,
        }),
        .version = switch (params.linkage) {
            .static => null,
            .dynamic => |version| version,
        },
    });

    params.step.dependOn(&artifact.step);
    if (!opts.skip_install) {
        const install = b.addInstallArtifact(artifact, .{});
        params.step.dependOn(&install.step);

        const install_step = b.getInstallStep();
        install_step.dependOn(&install.step);
    }

    artifact.addIncludePath(b.path("src"));

    for (params.defines) |def| {
        const def_name, const def_val = def;
        artifact.root_module.addCMacro(def_name, def_val);
    }

    const header_kind: HeaderKind = if (params.linkage == .static) .all_headers else .c_headers;
    installSrcHeaders(b, artifact, header_kind, params.files, "spirv_cross");

    if (opts.namespace_override) |namespace_override| {
        artifact.root_module.addCMacro(
            "SPIRV_CROSS_NAMESPACE_OVERRIDE",
            namespace_override,
        );
    }

    if (params.options) |options| {
        var sources: std.ArrayListUnmanaged([]const u8) = .empty;
        getSourceFilesIntoList(b, &sources, params.files);
        artifact.addCSourceFiles(.{
            .root = b.path("src"),
            .flags = options,
            .files = sources.items,
        });
    }

    return artifact;
}

const HeaderKind = enum { all_headers, c_headers };
fn installSrcHeaders(
    b: *Build,
    artifact: *Build.Step.Compile,
    kind: HeaderKind,
    files: []const []const u8,
    dst_rel_path_base: []const u8,
) void {
    const basedir = b.path("src");
    for (files) |file| {
        const ext = std.fs.path.extension(file);
        const matching_ext = switch (kind) {
            .all_headers => std.mem.eql(u8, ext, ".h") or std.mem.eql(u8, ext, ".hpp"),
            .c_headers => std.mem.eql(u8, ext, ".h"),
        };
        if (!matching_ext) continue;
        const src_lp = basedir.path(b, file);
        const dst_rel_path = b.pathJoin(&.{ dst_rel_path_base, file });
        artifact.installHeader(src_lp, dst_rel_path);
    }
}

/// Get all `.c` and `.cpp` into the list.
fn getSourceFilesIntoList(
    b: *Build,
    list: *std.ArrayListUnmanaged([]const u8),
    files: []const []const u8,
) void {
    list.clearRetainingCapacity();
    list.ensureTotalCapacity(b.graph.arena, files.len) catch unreachable;
    for (files) |file| {
        const ext = std.fs.path.extension(file);
        const matching_ext = std.mem.eql(u8, ext, ".c") or std.mem.eql(u8, ext, ".cpp");
        if (!matching_ext) continue;
        list.appendAssumeCapacity(file);
    }
}

fn extractHeadersOrSources(
    b: *Build,
    file_get: enum { sources, headers_any, headers_dyn },
    file_list: []const []const u8,
) []const []const u8 {
    var out_abs: std.ArrayListUnmanaged([]const u8) = .empty;
    out_abs.ensureTotalCapacityPrecise(b.graph.arena, file_list.len) catch unreachable;

    for (file_list) |path| {
        const ext = std.fs.path.extension(path);

        switch (file_get) {
            .headers_any => {
                if (std.mem.eql(u8, ext, ".h") or std.mem.eql(u8, ext, ".hpp")) {
                    out_abs.appendAssumeCapacity(b.dupe(path));
                }
            },
            .headers_dyn => {
                if (std.mem.eql(u8, ext, ".h")) {
                    out_abs.appendAssumeCapacity(b.dupe(path));
                }
            },
            .sources => if (std.mem.eql(u8, ext, ".c") or std.mem.eql(u8, ext, ".cpp")) {
                out_abs.appendAssumeCapacity(b.dupe(path));
            },
        }
    }

    return out_abs.toOwnedSlice(b.graph.arena) catch unreachable;
}
