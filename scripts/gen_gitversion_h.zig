//! This script mimics the transformation of the "gitversion.in.h" template into the "gitversion.h" header
//! as done by CMake; this is done primarily to obtain a sane value for the "build date", by having the run
//! step for this script depend on its input arguments (like the template file and build version), and other
//! input files (like the build script itself, and the C/C++ header and source files), such that it will
//! be run when any of those inputs change (or this script itself changes), and therefore only record a new
//! timestamp when the build or any of its inputs have truly changed.
//!
//! SEE: https://cmake.org/cmake/help/latest/command/string.html#timestamp
//! SEE: https://reproducible-builds.org/specs/source-date-epoch

const std = @import("std");

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const argv = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, argv);

    const args: []const []const u8 = argv[1..];

    if (args.len != 3) {
        std.log.err("Expected 3 argument, got {d}", .{args.len});
        return error.BadArgs;
    }

    const output_path = args[0];
    const template_path = args[1];
    const version_str = args[2];
    const timestamp_fmt: DateFmt = .{ .epoch = .{ .secs = @intCast(std.time.timestamp()) } };

    const template_src: []u8 = try std.fs.cwd().readFileAlloc(gpa, template_path, 1 << 18);
    defer gpa.free(template_src);

    const output_file = try std.fs.cwd().createFile(output_path, .{});
    defer output_file.close();

    var output_buffered = std.io.bufferedWriter(output_file.writer());
    const output_writer = output_buffered.writer();

    const Placeholder = enum {
        @"spirv-cross-build-version",
        @"spirv-cross-timestamp",
    };

    var index: usize = 0;
    while (index != template_src.len) {
        const line_start = index;
        const line_end = std.mem.indexOfScalarPos(u8, template_src, line_start, '\n') orelse template_src.len;
        const line = template_src[line_start..line_end];
        index = line_end + @intFromBool(line_end != template_src.len);

        var column: usize = 0;

        while (std.mem.indexOfScalarPos(u8, line, column, '@')) |arroba1_index| {
            const arroba2_index = std.mem.indexOfScalarPos(u8, line, arroba1_index + 1, '@') orelse break;
            try output_writer.writeAll(line[column..arroba1_index]);

            const placeholder_ident = line[arroba1_index + 1 .. arroba2_index];
            if (std.mem.indexOfAny(u8, placeholder_ident, &std.ascii.whitespace) != null) {
                try output_writer.writeAll(line[arroba1_index..arroba2_index]);
                column = arroba2_index;
                continue;
            }

            const placeholder = std.meta.stringToEnum(Placeholder, placeholder_ident) orelse {
                std.log.err("Missing value for '{s}'", .{placeholder_ident});
                return error.MissingValue;
            };
            column = arroba2_index + 1;

            switch (placeholder) {
                .@"spirv-cross-build-version",
                => try output_writer.writeAll(version_str),
                .@"spirv-cross-timestamp",
                => try output_writer.print("{}", .{timestamp_fmt}),
            }
        }

        try output_writer.writeAll(line[column..]);
        try output_writer.writeAll("\n");
    }

    try output_buffered.flush();
}

const DateFmt = struct {
    epoch: std.time.epoch.EpochSeconds,

    pub fn format(
        self: DateFmt,
        comptime fmt_str: []const u8,
        fmt_options: std.fmt.FormatOptions,
        writer: anytype,
    ) @TypeOf(writer).Error!void {
        _ = fmt_str;
        _ = fmt_options;

        const year_day = self.epoch.getEpochDay().calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const day_seconds = self.epoch.getDaySeconds();
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
