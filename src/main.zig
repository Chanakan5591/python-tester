const std = @import("std");
const comparison = @import("comparison");

const showDiff = comparison.showDiff;
const compareFileNames = comparison.compareFileNames;
const compareFiles = comparison.compareFiles;
const fs = std.fs;
const os = std.os;
const process = std.process;
const mem = std.mem;
const testing = std.testing;

pub const std_options = .{
    // Set the log level to info
    .log_level = .info,
};

pub fn main() !void {
    var success_count: u8 = 0;
    var fail_count: u8 = 0;

    var general_purpose_gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = general_purpose_gpa.allocator();

    const stdout = std.io.getStdOut().writer();

    defer {
        const deinit_status = general_purpose_gpa.deinit();
        if (deinit_status == .leak) {
            std.debug.print("Memory leak detected\n", .{});
        }
    }

    var args = try std.process.argsWithAllocator(gpa);
    defer args.deinit();

    _ = args.skip();

    var python_cmd: []const u8 = "python";
    var input_pathdir: []const u8 = "testcases";
    var output_pathdir: []const u8 = "outs";
    var python_filename: []const u8 = "main.py";

    while (args.next()) |arg| {
        if (mem.eql(u8, arg, "--python") or mem.eql(u8, arg, "-p")) {
            python_cmd = args.next().?;
        } else if (mem.eql(u8, arg, "--input") or mem.eql(u8, arg, "-i")) {
            input_pathdir = args.next().?;
        } else if (mem.eql(u8, arg, "--output") or mem.eql(u8, arg, "-o")) {
            output_pathdir = args.next().?;
        } else if (mem.eql(u8, arg, "--file") or mem.eql(u8, arg, "-f")) {
            python_filename = args.next().?;
        } else {
            try stdout.print("Unknown argument: \x1b[1;31m{s}\x1b[0m\n", .{arg});
            return;
        }
    }

    // Create 'outs' directory
    try fs.cwd().makePath(output_pathdir);

    // Open the testcases directory
    var dir = try fs.cwd().openDir(input_pathdir, .{ .iterate = true });
    defer dir.close();

    var entries = std.ArrayList(fs.Dir.Entry).init(gpa);
    defer entries.deinit();

    var it = dir.iterate();

    while (try it.next()) |entry| {
        if (entry.kind != .file or !mem.endsWith(u8, entry.name, ".in")) continue;
        // try entries.append(entry); // cannot be append right away due to windows bug (maybe due to how windows handle files)
        const entryCopy = try gpa.dupe(u8, entry.name);
        try entries.append(.{ .name = entryCopy, .kind = entry.kind });
    }

    mem.sort(fs.Dir.Entry, entries.items, {}, compareFileNames); // culprit for "5.ou" in every element in entries

    for (entries.items) |entry| {
        // free entry.name after use of each loop
        defer gpa.free(entry.name);

        const caseName = entry.name[0 .. entry.name.len - 3];
        try stdout.print("Running Case \x1b[1;36m{s}\x1b[0m...\n", .{caseName});

        // Run main.py with input file
        const input_path = try std.fs.path.join(gpa, &[_][]const u8{ input_pathdir, entry.name });
        defer gpa.free(input_path);
        const output_path = try std.fs.path.join(gpa, &[_][]const u8{ output_pathdir, caseName });
        defer gpa.free(output_path);

        var child = process.Child.init(&.{ python_cmd, python_filename }, gpa);

        const input_file = try fs.cwd().openFile(input_path, .{});
        defer input_file.close();

        const output_file = try fs.cwd().createFile(output_path, .{});
        defer output_file.close();

        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;

        try child.spawn();

        var reader = input_file.reader();
        var writer = child.stdin.?.writer();

        const buffer_size = 4096;
        var buffer: [buffer_size]u8 = undefined;

        while (true) {
            const bytes_read = try reader.read(&buffer);
            if (bytes_read == 0) break; // End of file

            try writer.writeAll(buffer[0..bytes_read]);
        }

        try writer.writeAll("\n");

        while (true) {
            const bytes_read = try child.stdout.?.read(&buffer);
            if (bytes_read == 0) break; // End of file

            try output_file.writeAll(buffer[0..bytes_read]);
        }

        _ = try child.wait();

        // Compare output files
        const out_filename = try std.fmt.allocPrint(gpa, "{s}.out", .{caseName});
        const expected_path = try std.fs.path.join(gpa, &[_][]const u8{ input_pathdir, out_filename });

        defer gpa.free(out_filename);
        defer gpa.free(expected_path);

        const result = try compareFiles(gpa, expected_path, output_path);

        if (result) {
            try stdout.print("Results: \x1b[1;32mMatched\x1b[0m, Good job!\n", .{});
            success_count += 1;
        } else {
            std.log.err("Results: \x1b[1;31mNOT\x1b[0m Matched, Please check your code!\n", .{});
            fail_count += 1;
            try showDiff(gpa, stdout, expected_path, output_path);
        }

        std.debug.print("\n", .{});
    }

    const green = "\x1b[32m";
    const red = "\x1b[31m";
    const reset = "\x1b[0m";

    std.debug.print("Total Successes: {s}{d}{s}\nTotal Failures:  {s}{d}{s}\n", .{ green, success_count, reset, red, fail_count, reset });
}
