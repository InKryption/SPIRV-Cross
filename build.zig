const std = @import("std");
const Build = std.Build;

const build_manifest = @import("build.zig.zon");
pub const build_version = std.SemanticVersion.parse(build_manifest.version) catch unreachable;
pub const abi_version = std.SemanticVersion.parse("0.65.0") catch unreachable;

pub const Options = struct {
    skip_install: bool,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    spirv_cross: SpirvCrossOptions,

    pub fn fromBuild(b: *Build) Options {
        return .{
            .skip_install = b.option(
                bool,
                "skip_install",
                "Don't install the binaries and headers implied by the specified steps, " ++
                    "only compile them.",
            ) orelse false,
            .target = b.standardTargetOptions(.{}),
            .optimize = b.standardOptimizeOption(.{}),
            .spirv_cross = .fromBuild(b),
        };
    }
};

const HAVE_SPIRV_CROSS_GIT_VERSION = "HAVE_SPIRV_CROSS_GIT_VERSION";
pub fn build(b: *Build) void {
    const opts: Options = .fromBuild(b);
    const source_date_epoch: []const u8 = spirvSourceDateEpoch(b);

    const c_static_step = b.step("c-static", "Build the C and C++ API as static libraries.");
    const c_shared_step = b.step("c-shared", "Build the C API as a single shared library.");

    const gitversion_config_h = b.addConfigHeader(.{
        .style = .{ .cmake = b.path("cmake/gitversion.in.h") },
        .include_path = "gitversion.h",
    }, .{});
    gitversion_config_h.addValue("spirv-cross-build-version", []const u8, b.fmt("{}", .{build_version}));
    gitversion_config_h.addValue("spirv-cross-timestamp", []const u8, source_date_epoch);

    var spirv_compiler_options: std.ArrayListUnmanaged([]const u8) = .empty;
    spirv_compiler_options.ensureTotalCapacity(b.graph.arena, 256) catch unreachable; // just increment this if you need more items

    var spirv_compiler_defines: std.ArrayListUnmanaged([]const u8) = .empty;
    spirv_compiler_defines.ensureTotalCapacity(b.graph.arena, 256) catch unreachable; // just increment this if you need more itesm

    // TODO: linker flag pass through???
    // CMakeLists.txt:76:1
    const spirv_cross_link_flags = {};

    if (opts.spirv_cross.exceptions_to_assertions) {
        spirv_compiler_defines.appendAssumeCapacity(
            "SPIRV_CROSS_EXCEPTIONS_TO_ASSERTIONS",
        );
    }

    if (opts.spirv_cross.force_stl_types) {
        spirv_compiler_defines.appendAssumeCapacity(
            "SPIRV_CROSS_FORCE_STL_TYPES",
        );
    }

    const cxx_is_clang = true;
    const cxx_is_gnu = false;
    const cxx_is_msvc = false;

    // logic details from the original CMakeLists.txt file
    if ((cxx_is_gnu or cxx_is_clang) and !cxx_is_msvc) {
        spirv_compiler_options.appendSliceAssumeCapacity(&.{
            "-Wall", "-Wextra", "-Wshadow", "-Wno-deprecated-declarations",
        });
        if (opts.spirv_cross.misc_warnings) {
            if (cxx_is_clang) {
                spirv_compiler_options.appendAssumeCapacity("-Wshorten-64-to-32");
            }
        }
        if (opts.spirv_cross.werror) {
            spirv_compiler_options.appendAssumeCapacity("-Werror");
        }
        if (opts.spirv_cross.exceptions_to_assertions) {
            spirv_compiler_options.appendAssumeCapacity("-fno-exceptions");
        }
        if (opts.spirv_cross.sanitize_address) {
            spirv_compiler_options.appendAssumeCapacity("-fsanitize=address");
            _ = spirv_cross_link_flags; // TODO: goto def
        }
        if (opts.spirv_cross.sanitize_undefined) {
            spirv_compiler_options.appendAssumeCapacity("-fsanitize=undefined");
            _ = spirv_cross_link_flags; // TODO: goto def
        }
        if (opts.spirv_cross.sanitize_memory) {
            spirv_compiler_options.appendAssumeCapacity("-fsanitize=memory");
            _ = spirv_cross_link_flags; // TODO: goto def
        }
        if (opts.spirv_cross.sanitize_threads) {
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
        .step = null,
        .linkage = .static,
        .defines = spirv_compiler_defines.items,
        .options = spirv_compiler_options.items,
        .sources = all_sources.core,
    });

    const glsl_lib = spirvCrossAddLibrary(b, "spirv-cross-glsl", opts, .{
        .step = null,
        .linkage = .static,
        .defines = spirv_compiler_defines.items,
        .options = spirv_compiler_options.items,
        .sources = all_sources.glsl,
    });
    glsl_lib.linkLibrary(core_lib);

    const cpp_lib = spirvCrossAddLibrary(b, "spirv-cross-cpp", opts, .{
        .step = null,
        .linkage = .static,
        .defines = spirv_compiler_defines.items,
        .options = spirv_compiler_options.items,
        .sources = all_sources.cpp,
    });
    cpp_lib.linkLibrary(glsl_lib);

    const reflect_lib = spirvCrossAddLibrary(b, "spirv-cross-reflect", opts, .{
        .step = null,
        .linkage = .static,
        .defines = spirv_compiler_defines.items,
        .options = spirv_compiler_options.items,
        .sources = all_sources.reflect,
    });

    const msl_lib = spirvCrossAddLibrary(b, "spirv-cross-msl", opts, .{
        .step = null,
        .linkage = .static,
        .defines = spirv_compiler_defines.items,
        .options = spirv_compiler_options.items,
        .sources = all_sources.msl,
    });
    msl_lib.linkLibrary(glsl_lib);

    const hlsl_lib = spirvCrossAddLibrary(b, "spirv-cross-hlsl", opts, .{
        .step = null,
        .linkage = .static,
        .defines = spirv_compiler_defines.items,
        .options = spirv_compiler_options.items,
        .sources = all_sources.hlsl,
    });
    hlsl_lib.linkLibrary(glsl_lib);

    const util_lib = spirvCrossAddLibrary(b, "spirv-cross-util", opts, .{
        .step = null,
        .linkage = .static,
        .defines = spirv_compiler_defines.items,
        .options = spirv_compiler_options.items,
        .sources = all_sources.util,
    });
    util_lib.linkLibrary(core_lib);

    // -- START: spirv-cross-c --
    const c_lib = spirvCrossAddLibrary(b, "spirv-cross-c", opts, .{
        .step = c_static_step,
        .linkage = .static,
        .defines = spirv_compiler_defines.items,
        .options = spirv_compiler_options.items,
        .sources = all_sources.c,
        .gitversion = gitversion_config_h,
    });

    {
        // GLSL can itself be disabled, but if any other support library
        // that needs it is enabled, it needs to become enabled.
        var need_glsl = false;

        const spvc = opts.spirv_cross;
        const LibSourcesInfo = struct { macro: []const u8, bin: *Build.Step.Compile };
        for ([_]?LibSourcesInfo{
            if (!spvc.enable_hlsl) null else .{
                .macro = "SPIRV_CROSS_C_API_HLSL",
                .bin = hlsl_lib,
            },
            if (!spvc.enable_msl) null else .{
                .macro = "SPIRV_CROSS_C_API_MSL",
                .bin = msl_lib,
            },
            if (!spvc.enable_cpp) null else .{
                .macro = "SPIRV_CROSS_C_API_CPP",
                .bin = cpp_lib,
            },
            if (!spvc.enable_cpp) null else .{
                .macro = "SPIRV_CROSS_C_API_REFLECT",
                .bin = reflect_lib,
            },
        }) |maybe_lib_info| if (maybe_lib_info) |lib_info| {
            c_lib.root_module.addCMacro(lib_info.macro, "1");
            c_lib.linkLibrary(lib_info.bin);
            need_glsl = true;
        };

        if (spvc.enable_glsl or need_glsl) {
            c_lib.root_module.addCMacro("SPIRV_CROSS_C_API_GLSL", "1");
            c_lib.linkLibrary(glsl_lib);
        }
    }
    // -- END: spirv-cross-c --

    // -- START: spirv-cross-c-shared --
    const c_shared_lib = spirvCrossAddLibrary(b, "spirv-cross-c-shared", opts, .{
        .step = c_shared_step,
        .linkage = .{ .dynamic = abi_version },
        .defines = spirv_compiler_defines.items,
        .options = spirv_compiler_options.items,
        .sources = all_sources.core ++ all_sources.c,
        .gitversion = gitversion_config_h,
    });
    c_shared_step.dependOn(&c_shared_lib.step);
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

        // GLSL can itself be disabled, but if any other support library
        // that needs it is enabled, it needs to become enabled.
        var need_glsl = false;

        const spvc = opts.spirv_cross;
        const LibSourcesInfo = struct { macro: []const u8, sources: []const []const u8 };
        for ([_]?LibSourcesInfo{
            if (!spvc.enable_hlsl) null else .{
                .macro = "SPIRV_CROSS_C_API_HLSL",
                .sources = all_sources.hlsl,
            },
            if (!spvc.enable_msl) null else .{
                .macro = "SPIRV_CROSS_C_API_MSL",
                .sources = all_sources.msl,
            },
            if (!spvc.enable_cpp) null else .{
                .macro = "SPIRV_CROSS_C_API_CPP",
                .sources = all_sources.cpp,
            },
            if (!spvc.enable_cpp) null else .{
                .macro = "SPIRV_CROSS_C_API_REFLECT",
                .sources = all_sources.reflect,
            },
        }) |maybe_lib_info| if (maybe_lib_info) |lib_info| {
            c_shared_lib.root_module.addCMacro(lib_info.macro, "1");
            c_shared_lib_sources.appendSliceAssumeCapacity(extractHeadersOrSources(b, .sources, lib_info.sources));
            need_glsl = true;
        };

        if (spvc.enable_glsl or need_glsl) {
            c_shared_lib.root_module.addCMacro("SPIRV_CROSS_C_API_GLSL", "1");
            c_shared_lib_sources.appendSliceAssumeCapacity(extractHeadersOrSources(b, .sources, all_sources.glsl));
        }

        c_shared_lib.addCSourceFiles(.{
            .root = b.path("src"),
            .files = c_shared_lib_sources.items,
            .flags = spirv_compiler_options.items,
        });
    }
    // -- END: spirv-cross-c-shared --

    if (opts.spirv_cross.cli) {
        const main_exe = b.addExecutable(.{
            .name = "spirv-cross",
            .root_module = b.createModule(.{
                .root_source_file = null,
                .target = opts.target,
                .optimize = opts.optimize,
                // .link_libc = true,
                // .link_libcpp = true,
            }),
        });
        b.installArtifact(main_exe);
        main_exe.linkLibrary(glsl_lib);
        main_exe.linkLibrary(hlsl_lib);
        main_exe.linkLibrary(cpp_lib);
        main_exe.linkLibrary(reflect_lib);
        main_exe.linkLibrary(msl_lib);
        main_exe.linkLibrary(util_lib);
        main_exe.linkLibrary(core_lib);

        _ = spirv_cross_link_flags; // TODO: goto def; apply to main_exe.

        main_exe.addCSourceFile(.{
            .file = b.path("src/main.cpp"),
            .flags = spirv_compiler_options.items,
        });

        for (spirv_compiler_defines.items) |def| {
            main_exe.root_module.addCMacro(def, "");
        }
        main_exe.root_module.addCMacro(HAVE_SPIRV_CROSS_GIT_VERSION, "");
        main_exe.addConfigHeader(gitversion_config_h);

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

fn spirvCrossAddLibrary(
    b: *Build,
    name: []const u8,
    opts: Options,
    params: struct {
        step: ?*Build.Step,
        linkage: union(std.builtin.LinkMode) {
            static,
            dynamic: ?std.SemanticVersion,
        },
        defines: []const []const u8,
        options: []const []const u8,
        sources: []const []const u8,
        gitversion: ?*Build.Step.ConfigHeader = null,
    },
) *Build.Step.Compile {
    const lib = b.addLibrary(.{
        .linkage = params.linkage,
        .name = name,
        .root_module = b.createModule(.{
            .optimize = opts.optimize,
            .target = opts.target,
            .link_libcpp = true,
            .pic = if (opts.spirv_cross.force_pic) true else null,
        }),
        .version = switch (params.linkage) {
            .static => null,
            .dynamic => |version| version,
        },
    });
    if (params.step) |step| step.dependOn(&lib.step);

    if (!opts.skip_install) {
        const c_shared_install = b.addInstallArtifact(lib, .{});
        if (params.step) |step| step.dependOn(&c_shared_install.step);

        const install_step = b.getInstallStep();
        install_step.dependOn(&c_shared_install.step);
    }

    lib.addIncludePath(b.path("src"));
    lib.addCSourceFiles(.{
        .root = b.path("src"),
        .flags = params.options,
        .files = extractHeadersOrSources(b, .sources, params.sources),
    });
    for (params.defines) |def| {
        lib.root_module.addCMacro(def, "");
    }

    for (extractHeadersOrSources(
        b,
        if (params.linkage == .static) .headers_any else .headers_dyn,
        params.sources,
    )) |path| {
        lib.installHeader(b.path("src").path(b, path), b.pathJoin(&.{ "spirv-cross", path }));
    }

    if (opts.spirv_cross.namespace_override) |namespace_override| {
        lib.root_module.addCMacro(
            "SPIRV_CROSS_NAMESPACE_OVERRIDE",
            namespace_override,
        );
    }

    if (params.gitversion) |gitversion_config_h| {
        lib.addConfigHeader(gitversion_config_h);
        lib.root_module.addCMacro(HAVE_SPIRV_CROSS_GIT_VERSION, "gitversion.h");
    }

    return lib;
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
                if (std.mem.eql(u8, ext, "h")) {
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

/// SEE: https://cmake.org/cmake/help/latest/command/string.html#timestamp
/// SEE: https://reproducible-builds.org/specs/source-date-epoch
fn spirvSourceDateEpoch(b: *Build) []const u8 {
    const SOURCE_DATE_EPOCH = "SOURCE_DATE_EPOCH";
    const desc =
        "Environment variable or option to override the source build timestamp. " ++
        "Must be a raw UTC unix timestamp. ";

    const option_value = b.option([]const u8, SOURCE_DATE_EPOCH, desc);
    const env_value = b.graph.env_map.get(SOURCE_DATE_EPOCH);
    if (option_value orelse env_value) |value_str| {
        if (value_str.len == 0) return "";
        const value = std.fmt.parseInt(u64, value_str, 10) catch unreachable; // SOURCE_DATE_EPOCH must be a base 10 integer
        return epochSecondsStr(b, .{ .secs = value });
    }

    var latest_mtime: u64 = 0;
    for (@as([]const []const u8, &build_manifest.paths)) |path| {
        const stat = b.build_root.handle.statFile(path) catch |err| switch (err) {
            error.IsDir => blk: {
                var dir = b.build_root.handle.openDir(path, .{}) catch unreachable;
                defer dir.close();
                break :blk dir.stat() catch unreachable;
            },
            else => unreachable,
        };
        const mtime: u64 = @intCast(@divTrunc(stat.mtime, std.time.ns_per_s));
        latest_mtime = @max(latest_mtime, mtime);
    }

    return epochSecondsStr(b, .{ .secs = latest_mtime });
}

fn epochSecondsStr(b: *Build, es: std.time.epoch.EpochSeconds) []const u8 {
    const year_day = es.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = es.getDaySeconds();
    return b.fmt("{[y]}-{[m]:0>2}-{[d]:0>2}T{[h]:0>2}:{[min]:0>2}:{[s]:0>2}Z", .{
        .y = year_day.year,
        .m = month_day.month.numeric(),
        .d = month_day.day_index,

        .h = day_seconds.getHoursIntoDay(),
        .min = day_seconds.getMinutesIntoHour(),
        .s = day_seconds.getSecondsIntoMinute(),
    });
}

pub const SpirvCrossOptions = struct {
    exceptions_to_assertions: bool,
    cli: bool,
    enable_tests: bool,

    enable_glsl: bool,
    enable_hlsl: bool,
    enable_msl: bool,
    enable_cpp: bool,
    enable_reflect: bool,

    sanitize_address: bool,
    sanitize_memory: bool,
    sanitize_threads: bool,
    sanitize_undefined: bool,

    namespace_override: ?[]const u8,
    force_stl_types: bool,

    werror: bool,
    misc_warnings: bool,

    force_pic: bool,

    pub fn fromBuild(b: *Build) SpirvCrossOptions {
        return .{
            .exceptions_to_assertions = b.option(bool, "exceptions_to_assertions", "Instead of throwing exceptions assert") orelse false,
            .cli = b.option(bool, "cli", "Build the CLI binary. Requires SPIRV_CROSS_STATIC.") orelse true,
            .enable_tests = b.option(bool, "enable_tests", "Enable SPIRV-Cross tests.") orelse true,

            .enable_glsl = b.option(bool, "enable_glsl", "Enable GLSL support.") orelse true,
            .enable_hlsl = b.option(bool, "enable_hlsl", "Enable HLSL target support.") orelse true,
            .enable_msl = b.option(bool, "enable_msl", "Enable MSL target support.") orelse true,
            .enable_cpp = b.option(bool, "enable_cpp", "Enable C++ target support.") orelse true,
            .enable_reflect = b.option(bool, "enable_reflect", "Enable JSON reflection target support.") orelse true,

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

/// Relative to the `src` directory.
const all_sources = .{
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
};
