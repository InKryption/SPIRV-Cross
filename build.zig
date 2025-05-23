const std = @import("std");
const Build = std.Build;

const build_manifest = @import("build.zig.zon");
pub const abi_version = std.SemanticVersion.parse("0.65.0") catch unreachable;

pub const Options = struct {
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,

    skip_install: bool,

    source_date_epoch: ?u64,

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
        const is_root = b.pkg_hash.len == 0;

        const target = b.standardTargetOptions(.{});
        const optimize = b.standardOptimizeOption(.{});

        const skip_install = if (is_root) b.option(
            bool,
            "skip_install",
            "Skips installation targets.",
        ) orelse false else false;

        const source_date_epoch: ?u64 = blk: {
            // SEE: https://cmake.org/cmake/help/latest/command/string.html#timestamp
            // SEE: https://reproducible-builds.org/specs/source-date-epoch

            const SOURCE_DATE_EPOCH = "SOURCE_DATE_EPOCH";
            const source_date_epoch_desc =
                \\Should be an integer representing a timestamp, relative to Jan 1, 1970 at 12:00 AM.
                \\Used for the git version string's timestamp component.
                \\Overrides the SOURCE_DATE_EPOCH environment value.
                \\Defaults to an "unknown" timestamp.
            ;
            if (b.option(u64, SOURCE_DATE_EPOCH, source_date_epoch_desc)) |source_date_epoch|
                break :blk source_date_epoch;
            if (b.graph.env_map.get(SOURCE_DATE_EPOCH)) |source_date_epoch| {
                break :blk std.fmt.parseInt(u64, source_date_epoch, 10) catch std.debug.panic(
                    "Failed to parse environment variable SOURCE_DATE_EPOCH='{s}' as a base 10 integer",
                    .{source_date_epoch},
                );
            }
            break :blk null;
        };

        const want_all_features = if (is_root) b.option(
            bool,
            "want_all",
            "Enable GLSL, HLSL, MSL, C++, and reflection support for the library (shared and/or static).",
        ) orelse false else false;

        return .{
            .target = target,
            .optimize = optimize,

            .skip_install = skip_install,

            .source_date_epoch = source_date_epoch,

            .want_glsl = b.option(bool, "want_glsl", "Enable GLSL support for the shared library.") orelse want_all_features,
            .want_hlsl = b.option(bool, "want_hlsl", "Enable HLSL target support for the shared library.") orelse want_all_features,
            .want_msl = b.option(bool, "want_msl", "Enable MSL target support for the shared library.") orelse want_all_features,
            .want_cpp = b.option(bool, "want_cpp", "Enable C++ target support for the shared library.") orelse want_all_features,
            .want_reflect = b.option(bool, "want_reflect", "Enable JSON reflection target support for the shared library.") orelse want_all_features,

            .exceptions_to_assertions = b.option(bool, "exceptions_to_assertions", "Instead of throwing exceptions assert") orelse false,
            .enable_tests = if (is_root) b.option(bool, "enable_tests", "Enable SPIRV-Cross tests.") orelse false else false,

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
        static_step.dependOn(reflect_step);
        static_step.dependOn(util_step);
    }

    const lib_wanted_feature_apis: LibraryName.Feature.Set = .init(.{
        .glsl = opts.want_glsl,
        .cpp = opts.want_cpp,
        .msl = opts.want_msl,
        .hlsl = opts.want_hlsl,
        .reflect = opts.want_reflect,
    });

    // if any of the other APIs are enabled, the glsl API is implied
    const lib_needed_feature_apis =
        lib_wanted_feature_apis.unionWith(.init(.{
            .glsl = !lib_wanted_feature_apis.eql(.initEmpty()),
        }));

    const gitversion_h_helper = struct {
        fn addIncludeTo(artifact: *Build.Step.Compile, gitversion_h: *Build.Step.ConfigHeader) void {
            const HAVE_SPIRV_CROSS_GIT_VERSION = "HAVE_SPIRV_CROSS_GIT_VERSION";
            artifact.addConfigHeader(gitversion_h);
            artifact.root_module.addCMacro(HAVE_SPIRV_CROSS_GIT_VERSION, "");
            artifact.step.dependOn(&gitversion_h.step);
        }
    };
    const gitversion_h: *Build.Step.ConfigHeader = gen: {
        const gitversion_h = b.addConfigHeader(.{
            .style = .{ .cmake = b.path("cmake/gitversion.in.h") },
            .include_path = "gitversion.h",
        }, .{});
        gitversion_h.addValue(
            "spirv-cross-timestamp",
            []const u8,
            if (opts.source_date_epoch) |ts| b.fmt("{}", .{dateFmt(ts)}) else "unknown",
        );
        // TODO: add support for getting the commit somehow?
        // probably will involve enhancing `Build.Step.ConfigHeader` to be able to have values
        // generated by run steps, ie a hypothetical `gitversion_h.addValueEmbedFile(@as(Build.LazyPath, ...))`.
        gitversion_h.addValue(
            "spirv-cross-build-version",
            []const u8,
            "unknown",
        );
        break :gen gitversion_h;
    };

    const cxx_is_clang = true;
    const cxx_is_gnu = false;
    const cxx_is_msvc = false;

    // TODO: linker flag pass through???
    // CMakeLists.txt:76:1
    const spirv_cross_link_flags = {};

    const cxx_flags: []const []const u8, //
    const cxx_defines: []const struct { []const u8, []const u8 } //
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

    const core_lib = spvcAddLibraryStatic(b, .core, opts, cxx_flags, cxx_defines);
    installArtifactWithStep(b, opts.skip_install, core_lib, core_step);

    const glsl_lib = spvcAddLibraryStatic(b, .glsl, opts, cxx_flags, cxx_defines);
    installArtifactWithStep(b, opts.skip_install, glsl_lib, glsl_step);
    glsl_lib.linkLibrary(core_lib);
    glsl_lib.installLibraryHeaders(core_lib);

    const cpp_lib = spvcAddLibraryStatic(b, .cpp, opts, cxx_flags, cxx_defines);
    installArtifactWithStep(b, opts.skip_install, cpp_lib, cpp_step);
    cpp_lib.linkLibrary(glsl_lib);
    cpp_lib.installLibraryHeaders(glsl_lib);

    const msl_lib = spvcAddLibraryStatic(b, .msl, opts, cxx_flags, cxx_defines);
    installArtifactWithStep(b, opts.skip_install, msl_lib, msl_step);
    msl_lib.linkLibrary(glsl_lib);
    msl_lib.installLibraryHeaders(glsl_lib);

    const hlsl_lib = spvcAddLibraryStatic(b, .hlsl, opts, cxx_flags, cxx_defines);
    installArtifactWithStep(b, opts.skip_install, hlsl_lib, hlsl_step);
    hlsl_lib.linkLibrary(glsl_lib);
    hlsl_lib.installLibraryHeaders(glsl_lib);

    const reflect_lib = spvcAddLibraryStatic(b, .reflect, opts, cxx_flags, cxx_defines);
    installArtifactWithStep(b, opts.skip_install, reflect_lib, reflect_step);
    // NOTE: in the original CMakeLists.txt file, the reflection library doesn't link the glsl library,
    // despite both requiring it through CMake logic, and the `spirv_reflect.cpp` source code making use
    // of the library.
    reflect_lib.linkLibrary(glsl_lib);
    reflect_lib.installLibraryHeaders(glsl_lib);

    const util_lib = spvcAddLibraryStatic(b, .util, opts, cxx_flags, cxx_defines);
    installArtifactWithStep(b, opts.skip_install, util_lib, util_step);
    util_lib.linkLibrary(core_lib);

    const c_static_lib = spvcAddLibraryStatic(b, .c, opts, cxx_flags, cxx_defines);
    installArtifactWithStep(b, opts.skip_install, c_static_lib, c_static_step);
    gitversion_h_helper.addIncludeTo(c_static_lib, gitversion_h);
    LibraryName.Feature.defineMacroSetFor(lib_needed_feature_apis, c_static_lib.root_module);
    { // link wanted/needed libraries
        var feature_iter = lib_needed_feature_apis.iterator();
        while (feature_iter.next()) |feature| {
            const artifact = switch (feature) {
                .glsl => glsl_lib,
                .hlsl => hlsl_lib,
                .msl => msl_lib,
                .cpp => cpp_lib,
                .reflect => reflect_lib,
            };
            c_static_lib.linkLibrary(artifact);
            c_static_lib.installLibraryHeaders(artifact);
        }
    }

    const c_shared_lib = spvcAddLibrary(b, .c, opts, .{ .dynamic = abi_version });
    const c_shared_lib_source_groups = LibraryName.Feature
        .setToLibrarySet(lib_needed_feature_apis)
        .unionWith(.initMany(&.{ .c, .core }));
    installArtifactWithStep(b, opts.skip_install, c_shared_lib, c_shared_step);
    installSpvcHeaders(b, c_shared_lib, .c);
    compileSpvcSources(b, c_shared_lib, c_shared_lib_source_groups, cxx_flags);
    addCMacros(c_shared_lib.root_module, cxx_defines);
    spvcDefineNamespaceOverride(c_shared_lib.root_module, opts.namespace_override);
    gitversion_h_helper.addIncludeTo(c_shared_lib, gitversion_h);
    c_shared_lib.root_module.addCMacro("SPVC_EXPORT_SYMBOLS", "");
    LibraryName.Feature.defineMacroSetFor(lib_needed_feature_apis, c_shared_lib.root_module);
    // logic details from the original CMakeLists.txt file
    if (cxx_is_gnu or cxx_is_clang) {
        // Only export the C API.

        // TODO: -fvisibility=hidden; apply to c_shared_lib
        if (!opts.target.result.os.tag.isDarwin()) {
            _ = spirv_cross_link_flags; // TODO: goto def; apply to c_shared_lib.
        }
    }

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
    cli_exe.addCSourceFile(.{
        .file = b.path("src/main.cpp"),
        .flags = cxx_flags,
    });
    installArtifactWithStep(b, opts.skip_install, cli_exe, cli_step);
    addCMacros(cli_exe.root_module, cxx_defines);
    gitversion_h_helper.addIncludeTo(cli_exe, gitversion_h);
    _ = spirv_cross_link_flags; // TODO: goto def; apply to main_exe.
    cli_exe.linkLibrary(core_lib);
    cli_exe.linkLibrary(glsl_lib);
    cli_exe.linkLibrary(hlsl_lib);
    cli_exe.linkLibrary(msl_lib);
    cli_exe.linkLibrary(cpp_lib);
    cli_exe.linkLibrary(reflect_lib);
    cli_exe.linkLibrary(util_lib);

    if (opts.enable_tests) {
        const maybe_glslang_dep = b.lazyDependency("glslang", .{});
        const maybe_spirv_tools_dep = b.lazyDependency("spirv_tools", .{});
        const maybe_spirv_headers_dep = b.lazyDependency("spirv_headers", .{});

        const glslang_dep = maybe_glslang_dep orelse return;
        _ = glslang_dep;
        const spirv_tools_dep = maybe_spirv_tools_dep orelse return;
        _ = spirv_tools_dep;
        const spirv_headers_dep = maybe_spirv_headers_dep orelse return;
        _ = spirv_headers_dep;

        // # Set up tests, using only the simplest modes of the test_shaders
        // # script.  You have to invoke the script manually to:
        // #  - Update the reference files
        // #  - Get cycle counts from malisc
        // #  - Keep failing outputs
        // if (${CMAKE_VERSION} VERSION_GREATER "3.12")
        //     find_package(Python3)
        //     if (${PYTHON3_FOUND})
        //         set(PYTHONINTERP_FOUND ON)
        //         set(PYTHON_VERSION_MAJOR 3)
        //         set(PYTHON_EXECUTABLE ${Python3_EXECUTABLE})
        //     else()
        //         set(PYTHONINTERP_FOUND OFF)
        //     endif()
        // else()
        //     find_package(PythonInterp)
        // endif()

        // find_program(spirv-cross-glslang NAMES glslangValidator
        //         PATHS ${CMAKE_CURRENT_SOURCE_DIR}/external/glslang-build/output/bin
        //         NO_DEFAULT_PATH)
        // find_program(spirv-cross-spirv-as NAMES spirv-as
        //         PATHS ${CMAKE_CURRENT_SOURCE_DIR}/external/spirv-tools-build/output/bin
        //         NO_DEFAULT_PATH)
        // find_program(spirv-cross-spirv-val NAMES spirv-val
        //         PATHS ${CMAKE_CURRENT_SOURCE_DIR}/external/spirv-tools-build/output/bin
        //         NO_DEFAULT_PATH)
        // find_program(spirv-cross-spirv-opt NAMES spirv-opt
        //         PATHS ${CMAKE_CURRENT_SOURCE_DIR}/external/spirv-tools-build/output/bin
        //         NO_DEFAULT_PATH)

        // if ((${spirv-cross-glslang} MATCHES "NOTFOUND") OR (${spirv-cross-spirv-as} MATCHES "NOTFOUND") OR (${spirv-cross-spirv-val} MATCHES "NOTFOUND") OR (${spirv-cross-spirv-opt} MATCHES "NOTFOUND"))
        //     set(SPIRV_CROSS_ENABLE_TESTS OFF)
        //     message("SPIRV-Cross:  Testing will be disabled for SPIRV-Cross. Could not find glslang or SPIRV-Tools build under external/. To enable testing, run ./checkout_glslang_spirv_tools.sh and ./build_glslang_spirv_tools.sh first.")
        // else()
        //     set(SPIRV_CROSS_ENABLE_TESTS ON)
        //     message("SPIRV-Cross: Found glslang and SPIRV-Tools. Enabling test suite.")
        //     message("SPIRV-Cross: Found glslangValidator in: ${spirv-cross-glslang}.")
        //     message("SPIRV-Cross: Found spirv-as in: ${spirv-cross-spirv-as}.")
        //     message("SPIRV-Cross: Found spirv-val in: ${spirv-cross-spirv-val}.")
        //     message("SPIRV-Cross: Found spirv-opt in: ${spirv-cross-spirv-opt}.")
        // endif()

        // set(spirv-cross-externals
        //         --glslang "${spirv-cross-glslang}"
        //         --spirv-as "${spirv-cross-spirv-as}"
        //         --spirv-opt "${spirv-cross-spirv-opt}"
        //         --spirv-val "${spirv-cross-spirv-val}")

        // if (${PYTHONINTERP_FOUND} AND SPIRV_CROSS_ENABLE_TESTS)
        //     if (${PYTHON_VERSION_MAJOR} GREATER 2)
        //         add_executable(spirv-cross-c-api-test tests-other/c_api_test.c)
        //         target_link_libraries(spirv-cross-c-api-test spirv-cross-c)
        //         set_target_properties(spirv-cross-c-api-test PROPERTIES LINK_FLAGS "${spirv-cross-link-flags}")

        //         add_executable(spirv-cross-small-vector-test tests-other/small_vector.cpp)
        //         target_link_libraries(spirv-cross-small-vector-test spirv-cross-core)
        //         set_target_properties(spirv-cross-small-vector-test PROPERTIES LINK_FLAGS "${spirv-cross-link-flags}")

        //         add_executable(spirv-cross-msl-constexpr-test tests-other/msl_constexpr_test.cpp)
        //         target_link_libraries(spirv-cross-msl-constexpr-test spirv-cross-c)
        //         set_target_properties(spirv-cross-msl-constexpr-test PROPERTIES LINK_FLAGS "${spirv-cross-link-flags}")

        //         add_executable(spirv-cross-msl-resource-binding-test tests-other/msl_resource_bindings.cpp)
        //         target_link_libraries(spirv-cross-msl-resource-binding-test spirv-cross-c)
        //         set_target_properties(spirv-cross-msl-resource-binding-test PROPERTIES LINK_FLAGS "${spirv-cross-link-flags}")

        //         add_executable(spirv-cross-hlsl-resource-binding-test tests-other/hlsl_resource_bindings.cpp)
        //         target_link_libraries(spirv-cross-hlsl-resource-binding-test spirv-cross-c)
        //         set_target_properties(spirv-cross-hlsl-resource-binding-test PROPERTIES LINK_FLAGS "${spirv-cross-link-flags}")

        //         add_executable(spirv-cross-msl-ycbcr-conversion-test tests-other/msl_ycbcr_conversion_test.cpp)
        //         target_link_libraries(spirv-cross-msl-ycbcr-conversion-test spirv-cross-c)
        //         set_target_properties(spirv-cross-msl-ycbcr-conversion-test PROPERTIES LINK_FLAGS "${spirv-cross-link-flags}")

        //         add_executable(spirv-cross-typed-id-test tests-other/typed_id_test.cpp)
        //         target_link_libraries(spirv-cross-typed-id-test spirv-cross-core)
        //         set_target_properties(spirv-cross-typed-id-test PROPERTIES LINK_FLAGS "${spirv-cross-link-flags}")

        //         if (CMAKE_COMPILER_IS_GNUCXX OR (${CMAKE_CXX_COMPILER_ID} MATCHES "Clang"))
        //             target_compile_options(spirv-cross-c-api-test PRIVATE -std=c89 -Wall -Wextra)
        //         endif()
        //         add_test(NAME spirv-cross-c-api-test
        //                 COMMAND $<TARGET_FILE:spirv-cross-c-api-test> ${CMAKE_CURRENT_SOURCE_DIR}/tests-other/c_api_test.spv
        //                 ${spirv-cross-abi-major}
        //                 ${spirv-cross-abi-minor}
        //                 ${spirv-cross-abi-patch})
        //         add_test(NAME spirv-cross-small-vector-test
        //                 COMMAND $<TARGET_FILE:spirv-cross-small-vector-test>)
        //         add_test(NAME spirv-cross-msl-constexpr-test
        //                 COMMAND $<TARGET_FILE:spirv-cross-msl-constexpr-test> ${CMAKE_CURRENT_SOURCE_DIR}/tests-other/msl_constexpr_test.spv)
        //         add_test(NAME spirv-cross-msl-resource-binding-test
        //                 COMMAND $<TARGET_FILE:spirv-cross-msl-resource-binding-test> ${CMAKE_CURRENT_SOURCE_DIR}/tests-other/msl_resource_binding.spv)
        //         add_test(NAME spirv-cross-hlsl-resource-binding-test
        //                 COMMAND $<TARGET_FILE:spirv-cross-hlsl-resource-binding-test> ${CMAKE_CURRENT_SOURCE_DIR}/tests-other/hlsl_resource_binding.spv)
        //         add_test(NAME spirv-cross-msl-ycbcr-conversion-test
        //                 COMMAND $<TARGET_FILE:spirv-cross-msl-ycbcr-conversion-test> ${CMAKE_CURRENT_SOURCE_DIR}/tests-other/msl_ycbcr_conversion_test.spv)
        //         add_test(NAME spirv-cross-msl-ycbcr-conversion-test-2
        //                 COMMAND $<TARGET_FILE:spirv-cross-msl-ycbcr-conversion-test> ${CMAKE_CURRENT_SOURCE_DIR}/tests-other/msl_ycbcr_conversion_test_2.spv)
        //         add_test(NAME spirv-cross-typed-id-test
        //                 COMMAND $<TARGET_FILE:spirv-cross-typed-id-test>)
        //         add_test(NAME spirv-cross-test
        //                 COMMAND ${PYTHON_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/test_shaders.py --parallel
        //                 ${spirv-cross-externals}
        //                 ${CMAKE_CURRENT_SOURCE_DIR}/shaders
        //                 WORKING_DIRECTORY $<TARGET_FILE_DIR:spirv-cross>)
        //         add_test(NAME spirv-cross-test-no-opt
        //                 COMMAND ${PYTHON_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/test_shaders.py --parallel
        //                 ${spirv-cross-externals}
        //                 ${CMAKE_CURRENT_SOURCE_DIR}/shaders-no-opt
        //                 WORKING_DIRECTORY $<TARGET_FILE_DIR:spirv-cross>)
        //         add_test(NAME spirv-cross-test-metal
        //                 COMMAND ${PYTHON_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/test_shaders.py --metal --parallel
        //                 ${spirv-cross-externals}
        //                 ${CMAKE_CURRENT_SOURCE_DIR}/shaders-msl
        //                 WORKING_DIRECTORY $<TARGET_FILE_DIR:spirv-cross>)
        //         add_test(NAME spirv-cross-test-metal-no-opt
        //                 COMMAND ${PYTHON_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/test_shaders.py --metal --parallel
        //                 ${spirv-cross-externals}
        //                 ${CMAKE_CURRENT_SOURCE_DIR}/shaders-msl-no-opt
        //                 WORKING_DIRECTORY $<TARGET_FILE_DIR:spirv-cross>)
        //         add_test(NAME spirv-cross-test-hlsl
        //                 COMMAND ${PYTHON_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/test_shaders.py --hlsl --parallel
        //                 ${spirv-cross-externals}
        //                 ${CMAKE_CURRENT_SOURCE_DIR}/shaders-hlsl
        //                 WORKING_DIRECTORY $<TARGET_FILE_DIR:spirv-cross>)
        //         add_test(NAME spirv-cross-test-hlsl-no-opt
        //                 COMMAND ${PYTHON_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/test_shaders.py --hlsl --parallel
        //                 ${spirv-cross-externals}
        //                 ${CMAKE_CURRENT_SOURCE_DIR}/shaders-hlsl-no-opt
        //                 WORKING_DIRECTORY $<TARGET_FILE_DIR:spirv-cross>)
        //         add_test(NAME spirv-cross-test-opt
        //                 COMMAND ${PYTHON_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/test_shaders.py --opt --parallel
        //                 ${spirv-cross-externals}
        //                 ${CMAKE_CURRENT_SOURCE_DIR}/shaders
        //                 WORKING_DIRECTORY $<TARGET_FILE_DIR:spirv-cross>)
        //         add_test(NAME spirv-cross-test-metal-opt
        //                 COMMAND ${PYTHON_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/test_shaders.py --metal --opt --parallel
        //                 ${spirv-cross-externals}
        //                 ${CMAKE_CURRENT_SOURCE_DIR}/shaders-msl
        //                 WORKING_DIRECTORY $<TARGET_FILE_DIR:spirv-cross>)
        //         add_test(NAME spirv-cross-test-hlsl-opt
        //                 COMMAND ${PYTHON_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/test_shaders.py --hlsl --opt --parallel
        //                 ${spirv-cross-externals}
        //                 ${CMAKE_CURRENT_SOURCE_DIR}/shaders-hlsl
        //                 WORKING_DIRECTORY $<TARGET_FILE_DIR:spirv-cross>)
        //         add_test(NAME spirv-cross-test-reflection
        //                 COMMAND ${PYTHON_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/test_shaders.py --reflect --parallel
        //                 ${spirv-cross-externals}
        //                 ${CMAKE_CURRENT_SOURCE_DIR}/shaders-reflection
        //                 WORKING_DIRECTORY $<TARGET_FILE_DIR:spirv-cross>)
        //         add_test(NAME spirv-cross-test-ue4
        //                 COMMAND ${PYTHON_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/test_shaders.py --msl --parallel
        //                 ${spirv-cross-externals}
        //                 ${CMAKE_CURRENT_SOURCE_DIR}/shaders-ue4
        //                 WORKING_DIRECTORY $<TARGET_FILE_DIR:spirv-cross>)
        //         add_test(NAME spirv-cross-test-ue4-opt
        //                 COMMAND ${PYTHON_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/test_shaders.py --msl --opt --parallel
        //                 ${spirv-cross-externals}
        //                 ${CMAKE_CURRENT_SOURCE_DIR}/shaders-ue4
        //                 WORKING_DIRECTORY $<TARGET_FILE_DIR:spirv-cross>)
        //         add_test(NAME spirv-cross-test-ue4-no-opt
        //                 COMMAND ${PYTHON_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/test_shaders.py --msl --parallel
        //                 ${spirv-cross-externals}
        //                 ${CMAKE_CURRENT_SOURCE_DIR}/shaders-ue4-no-opt
        //                 WORKING_DIRECTORY $<TARGET_FILE_DIR:spirv-cross>)
        //     endif()
        // elseif(NOT ${PYTHONINTERP_FOUND})
        //     message(WARNING "SPIRV-Cross: Testing disabled. Could not find python3. If you have python3 installed try running "
        //             "cmake with -DPYTHON_EXECUTABLE:FILEPATH=/path/to/python3 to help it find the executable")
        // endif()
    }
}

fn installArtifactWithStep(
    b: *Build,
    skip_install: bool,
    artifact: *Build.Step.Compile,
    artifact_step: *Build.Step,
) void {
    const install_step = b.getInstallStep();

    artifact_step.dependOn(&artifact.step);
    install_step.dependOn(&artifact.step);

    if (!skip_install) {
        const install = b.addInstallArtifact(artifact, .{});
        artifact_step.dependOn(&install.step);
        install_step.dependOn(&install.step);
    }
}

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

    pub fn artifactBaseName(name: LibraryName, linkage: std.builtin.LinkMode) []const u8 {
        return switch (name) {
            .core => "spirv-cross-core",
            .util => "spirv-cross-util",
            .glsl => "spirv-cross-glsl",
            .cpp => "spirv-cross-cpp",
            .reflect => "spirv-cross-reflect",
            .msl => "spirv-cross-msl",
            .hlsl => "spirv-cross-hlsl",

            .c => switch (linkage) {
                .static => "spirv-cross-c",
                .dynamic => "spirv-cross-c-shared",
            },
        };
    }

    pub fn toFeature(name: LibraryName) ?Feature {
        return switch (name) {
            inline //
            .core,
            .c,
            .util,
            => |tag| blk: {
                if (!@hasField(Feature, @tagName(tag))) break :blk null;
                @compileError(@tagName(tag) ++ " tag collides with feature name tag");
            },

            inline //
            .glsl,
            .cpp,
            .msl,
            .hlsl,
            .reflect,
            => |tag| @field(Feature, @tagName(tag)),
        };
    }
    comptime {
        _ = &toFeature;
    }

    pub const Feature = enum {
        glsl,
        cpp,
        msl,
        hlsl,
        reflect,

        pub const Set = std.EnumSet(Feature);

        pub fn toLibraryName(feat: Feature) LibraryName {
            return switch (feat) {
                inline else => |tag| @field(LibraryName, @tagName(tag)),
            };
        }

        pub fn macroName(feat: Feature) []const u8 {
            return switch (feat) {
                .glsl => "SPIRV_CROSS_C_API_GLSL",
                .cpp => "SPIRV_CROSS_C_API_CPP",
                .msl => "SPIRV_CROSS_C_API_MSL",
                .hlsl => "SPIRV_CROSS_C_API_HLSL",
                .reflect => "SPIRV_CROSS_C_API_REFLECT",
            };
        }

        pub fn setToLibrarySet(feature_set: Feature.Set) LibraryName.Set {
            var lib_names: LibraryName.Set = .initEmpty();

            var feature_iter = feature_set.iterator();
            while (feature_iter.next()) |feature| {
                lib_names.insert(feature.toLibraryName());
            }

            return lib_names;
        }

        pub fn defineMacroSetFor(feature_set: Feature.Set, mod: *Build.Module) void {
            var feature_iter = feature_set.iterator();
            while (feature_iter.next()) |feature| {
                mod.addCMacro(feature.macroName(), "1");
            }
        }
    };
};

fn spvcAddLibraryStatic(
    b: *Build,
    name: LibraryName,
    opts: Options,
    cxx_flags: []const []const u8,
    cxx_defines: []const struct { []const u8, []const u8 },
) *Build.Step.Compile {
    const artifact = spvcAddLibrary(b, name, opts, .static);
    installSpvcHeaders(b, artifact, name);
    compileSpvcSources(b, artifact, .initOne(name), cxx_flags);
    addCMacros(artifact.root_module, cxx_defines);
    spvcDefineNamespaceOverride(artifact.root_module, opts.namespace_override);
    return artifact;
}

fn spvcAddLibrary(
    b: *Build,
    name: LibraryName,
    opts: Options,
    linkage: union(std.builtin.LinkMode) {
        static,
        dynamic: ?std.SemanticVersion,
    },
) *Build.Step.Compile {
    const artifact = b.addLibrary(.{
        .linkage = linkage,
        .name = name.artifactBaseName(linkage),
        .root_module = b.createModule(.{
            .optimize = opts.optimize,
            .target = opts.target,
            .link_libcpp = true,
            .pic = if (opts.force_pic) true else null,
        }),
        .version = switch (linkage) {
            .static => null,
            .dynamic => |version| version,
        },
    });
    artifact.addIncludePath(b.path("src"));
    return artifact;
}

/// Install all the .h (and .hpp if `artifact.linkage == .static`) files from the given
/// library source group into the "spirv_cross" folder alongside the artifact.
fn installSpvcHeaders(
    b: *Build,
    artifact: *Build.Step.Compile,
    lib_name: LibraryName,
) void {
    std.debug.assert(artifact.kind == .lib);
    const linkage = artifact.linkage.?;

    const basedir = b.path("src");
    const dst_rel_path_base = "spirv_cross";

    if (!std.mem.eql(u8, artifact.name, lib_name.artifactBaseName(linkage))) {
        std.debug.panic("Unrecognized library '{s}', expected '{s}'", .{ artifact.name, lib_name.artifactBaseName(linkage) });
    }

    const files = all_sources.get(lib_name);
    for (files) |file| {
        const ext = std.fs.path.extension(file);
        const matching_ext = switch (linkage) {
            .static => std.mem.eql(u8, ext, ".h") or std.mem.eql(u8, ext, ".hpp"),
            .dynamic => std.mem.eql(u8, ext, ".h"),
        };
        if (!matching_ext) continue;
        const src_lp = basedir.path(b, file);
        const dst_rel_path = b.pathJoin(&.{ dst_rel_path_base, file });
        artifact.installHeader(src_lp, dst_rel_path);
    }
}

/// Compile all the .c and .cpp files from the given library source group as part of the artifact.
fn compileSpvcSources(
    b: *Build,
    artifact: *Build.Step.Compile,
    lib_names: LibraryName.Set,
    flags: []const []const u8,
) void {
    std.debug.assert(artifact.kind == .lib);
    const linkage = artifact.linkage.?;

    var sources: std.ArrayListUnmanaged([]const u8) = .empty;
    defer sources.deinit(b.graph.arena);

    var matching_name = false;

    var iter = lib_names.iterator();
    while (iter.next()) |lib_name| {
        const files = all_sources.get(lib_name);
        sources.ensureUnusedCapacity(b.graph.arena, files.len) catch unreachable;
        for (files) |file| {
            const ext = std.fs.path.extension(file);
            const matching_ext =
                std.mem.eql(u8, ext, ".c") or
                std.mem.eql(u8, ext, ".cpp");
            if (!matching_ext) continue;
            sources.appendAssumeCapacity(file);
        }

        matching_name = matching_name or std.mem.eql(u8, artifact.name, lib_name.artifactBaseName(linkage));
    }

    artifact.addCSourceFiles(.{
        .root = b.path("src"),
        .files = sources.items,
        .flags = flags,
    });
}

fn addCMacros(
    mod: *Build.Module,
    macros: []const struct { []const u8, []const u8 },
) void {
    for (macros) |def| {
        const def_name, const def_val = def;
        mod.addCMacro(def_name, def_val);
    }
}

fn spvcDefineNamespaceOverride(
    mod: *Build.Module,
    maybe_namespace_override: ?[]const u8,
) void {
    if (maybe_namespace_override) |namespace_override| mod.addCMacro(
        "SPIRV_CROSS_NAMESPACE_OVERRIDE",
        namespace_override,
    );
}

fn dateFmt(secs: u64) DateFmt {
    return .{ .secs = secs };
}
const DateFmt = struct {
    /// seconds since epoch Jan 1, 1970 at 12:00 AM
    secs: u64,

    pub fn format(
        self: DateFmt,
        comptime fmt_str: []const u8,
        fmt_options: std.fmt.FormatOptions,
        writer: anytype,
    ) @TypeOf(writer).Error!void {
        _ = fmt_str;
        _ = fmt_options;

        const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = self.secs };
        const year_day = epoch_seconds.getEpochDay().calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const day_seconds = epoch_seconds.getDaySeconds();
        try writer.print("{[y]}-{[m]:0>2}-{[d]:0>2}T{[h]:0>2}:{[min]:0>2}:{[s]:0>2}Z", .{
            .y = year_day.year,
            .m = month_day.month.numeric(),
            .d = month_day.day_index,

            .h = day_seconds.getHoursIntoDay(),
            .min = day_seconds.getMinutesIntoHour(),
            .s = day_seconds.getSecondsIntoMinute(),
        });
    }
};
