const std = @import("std");

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
        try entries.append(entry);
    }

    mem.sort(fs.Dir.Entry, entries.items, {}, compareFileNames);

    for (entries.items) |entry| {
        const caseName = entry.name[0 .. entry.name.len - 3];
        try stdout.print("Running Case \x1b[1;36m{s}\x1b[0m...\n", .{caseName});

        // Run main.py with input file
        const input_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ input_pathdir, entry.name });
        defer gpa.free(input_path);
        const output_path = try std.fmt.allocPrint(gpa, "{s}/{s}.out", .{ output_pathdir, caseName });
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
            try writer.writeAll("\n");
        }

        // clear buffer
        buffer = undefined;

        while (true) {
            const bytes_read = try child.stdout.?.read(&buffer);
            if (bytes_read == 0) break; // End of file

            try output_file.writeAll(buffer[0..bytes_read]);
        }

        _ = try child.wait();

        // Compare output files
        const expected_path = try std.fmt.allocPrint(gpa, "{s}/{s}.out", .{ input_pathdir, caseName });
        defer gpa.free(expected_path);

        const actual_path = output_path;

        const result = try compareFiles(gpa, expected_path, actual_path);

        if (result) {
            try stdout.print("Results: \x1b[1;32mMatched\x1b[0m, Good job!\n", .{});
        } else {
            std.log.err("Results: \x1b[1;31mNOT\x1b[0m Matched, Please check your code!\n", .{});
            try showDiff(gpa, expected_path, actual_path);
        }

        std.debug.print("\n", .{});
    }
}

fn compareFileNames(context: void, a: fs.Dir.Entry, b: fs.Dir.Entry) bool {
    _ = context;
    const a_num = std.fmt.parseInt(usize, mem.sliceTo(a.name, '.'), 10) catch return false;
    const b_num = std.fmt.parseInt(usize, mem.sliceTo(b.name, '.'), 10) catch return false;
    return a_num < b_num;
}

fn compareFiles(gpa: mem.Allocator, file1: []const u8, file2: []const u8) !bool {
    const content1 = try fs.cwd().readFileAlloc(gpa, file1, std.math.maxInt(usize));
    defer gpa.free(content1);

    const content2 = try fs.cwd().readFileAlloc(gpa, file2, std.math.maxInt(usize));
    defer gpa.free(content2);

    return mem.eql(u8, content1, content2);
}

pub fn showDiff(allocator: mem.Allocator, file1: []const u8, file2: []const u8) !void {
    const content1 = try std.fs.cwd().readFileAlloc(allocator, file1, std.math.maxInt(usize));
    defer allocator.free(content1);
    const content2 = try std.fs.cwd().readFileAlloc(allocator, file2, std.math.maxInt(usize));
    defer allocator.free(content2);

    var lines1 = mem.tokenizeSequence(u8, content1, "\n");
    var lines2 = mem.tokenizeSequence(u8, content2, "\n");

    const stdout = std.io.getStdOut().writer();

    var line_number: usize = 1;

    try stdout.print("Line | {s:<40} | {s}\n", .{ "Expected", "Got" });
    try stdout.print("---- | {s:-<40} | {s:-<40}\n", .{ "", "" });

    while (true) {
        const line1 = lines1.next();
        const line2 = lines2.next();

        if (line1 == null and line2 == null) break;

        if (line1) |l1| {
            if (line2) |l2| {
                if (mem.eql(u8, l1, l2)) {
                    try stdout.print("{d:4} | {s:<40} | {s}\n", .{ line_number, l1, l2 });
                } else {
                    try stdout.print("{d:4} | {s:<40} | \x1b[1;31m{s}\x1b[0m\n", .{ line_number, l1, l2 });
                }
            } else {
                try stdout.print("{d:4} | {s:<40} | \n", .{ line_number, l1 });
            }
        } else if (line2) |l2| {
            try stdout.print("{d:4} | {s:<40} | \x1b[1;33m{s}\x1b[0m\n", .{ line_number, "", l2 });
        }

        line_number += 1;
    }
}
