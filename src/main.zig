const std = @import("std");

const fs = std.fs;
const os = std.os;
const process = std.process;
const mem = std.mem;
const testing = std.testing;


pub fn main() !void {
    var general_purpose_gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = general_purpose_gpa.allocator();

    defer {
            const deinit_status = general_purpose_gpa.deinit();
            //fail test; can't try in defer as defer is executed after we return
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

    while (args.next()) |arg| {
        if (mem.eql(u8, arg, "--python")) {
            python_cmd = args.next().?;
        } else if (mem.eql(u8, arg, "--input")) {
            input_pathdir = args.next().?;
        } else if (mem.eql(u8, arg, "--output")) {
            output_pathdir = args.next().?;
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
        try entries.append(entry);
    }

    std.mem.sort(fs.Dir.Entry, entries.items, {}, compareFileNames);

    for (entries.items) |entry| {
        if (entry.kind != .file or !mem.endsWith(u8, entry.name, ".in")) continue;

        const caseName = entry.name[0 .. entry.name.len - 3];
        std.log.info("Running Case {s} ...", .{caseName});

        // Run main.py with input file
        const input_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ input_pathdir, entry.name });
        const output_path = try std.fmt.allocPrint(gpa, "{s}/{s}.out", .{ output_pathdir, caseName });

        defer {
            gpa.free(input_path);
            gpa.free(output_path);
        }

        var child = process.Child.init(&.{ python_cmd, "main.py" }, gpa);

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
            std.log.info("Results: Matched, Good job!", .{});
        } else {
            std.log.err("Results: NOT Matched, Please check your code!", .{});
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

fn compareFiles(gpa: std.mem.Allocator, file1: []const u8, file2: []const u8) !bool {
    const content1 = try fs.cwd().readFileAlloc(gpa, file1, std.math.maxInt(usize));
    defer gpa.free(content1);

    const content2 = try fs.cwd().readFileAlloc(gpa, file2, std.math.maxInt(usize));
    defer gpa.free(content2);

    return mem.eql(u8, content1, content2);
}

pub fn showDiff(allocator: std.mem.Allocator, file1: []const u8, file2: []const u8) !void {
    const content1 = try std.fs.cwd().readFileAlloc(allocator, file1, std.math.maxInt(usize));
    defer allocator.free(content1);
    const content2 = try std.fs.cwd().readFileAlloc(allocator, file2, std.math.maxInt(usize));
    defer allocator.free(content2);

    var lines1 = std.mem.tokenize(u8, content1, "\n");
    var lines2 = std.mem.tokenize(u8, content2, "\n");

    const stdout = std.io.getStdOut().writer();

    var line_number: usize = 1;

    try stdout.print("Line | {s:<40} | {s}\n", .{"Expected", "Got"});
    try stdout.print("---- | {s:-<40} | {s:-<40}\n", .{"", ""});

    while (true) {
        const line1 = lines1.next();
        const line2 = lines2.next();

        if (line1 == null and line2 == null) break;

        if (line1) |l1| {
            if (line2) |l2| {
                if (std.mem.eql(u8, l1, l2)) {
                    try stdout.print("{d:4} | {s}\n", .{ line_number, l1 });
                } else {
                    try stdout.print("{d:4} | {s:<40} | {s}\n", .{ line_number, l1, l2 });
                }
            } else {
                try stdout.print("{d:4} | {s:<40} | \n", .{ line_number, l1 });
            }
        } else if (line2) |l2| {
            try stdout.print("{d:4} | {s:<40} | {s}\n", .{ line_number, "", l2 });
        }

        line_number += 1;
    }
}
