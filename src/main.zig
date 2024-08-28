const std = @import("std");
const fs = std.fs;
const os = std.os;
const process = std.process;
const mem = std.mem;
const testing = std.testing;

pub fn main() !void {
    var general_purpose_gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = general_purpose_gpa.allocator();

    // Create 'outs' directory
    try fs.cwd().makePath("outs");

    // Open the testcases directory
    var dir = try fs.cwd().openDir("testcases", .{ .iterate = true });
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file or !mem.endsWith(u8, entry.name, ".in")) continue;

        const caseName = entry.name[0 .. entry.name.len - 3];
        std.debug.print("Running Case {s} ...\n", .{caseName});

        // Run main.py with input file
        const input_path = try std.fmt.allocPrint(gpa, "testcases/{s}", .{entry.name});
        const output_path = try std.fmt.allocPrint(gpa, "outs/{s}.out", .{caseName});

        var child = process.Child.init(&.{"python", "main.py"}, gpa);

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

        // clear buffer
        buffer = undefined;

        while (true) {
            const bytes_read = try child.stdout.?.read(&buffer);
            if (bytes_read == 0) break; // End of file

            try output_file.writeAll(buffer[0..bytes_read]);
        }

        _ = try child.wait();

        // Compare output files
        const expected_path = try std.fmt.allocPrint(gpa, "testcases/{s}.out", .{caseName});
        const actual_path = output_path;

        const result = try compareFiles(gpa, expected_path, actual_path);

        if (result) {
            std.debug.print("Results: Matched, Good job!\n", .{});
        } else {
            std.debug.print("Results: NOT Matched, Please check your code!\n", .{});
            try showDiff(gpa, expected_path, actual_path);
        }

        std.debug.print("\n", .{});
    }
}

fn compareFiles(gpa: std.mem.Allocator, file1: []const u8, file2: []const u8) !bool {
    const content1 = try fs.cwd().readFileAlloc(gpa, file1, std.math.maxInt(usize));
    defer gpa.free(content1);

    const content2 = try fs.cwd().readFileAlloc(gpa, file2, std.math.maxInt(usize));
    defer gpa.free(content2);

    return mem.eql(u8, content1, content2);
}

fn showDiff(gpa: std.mem.Allocator, file1: []const u8, file2: []const u8) !void {
    var child = process.Child.init(&.{ "diff", "-y", "--strip-trailing-cr", file1, file2 }, gpa);

    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    _ = try child.spawnAndWait();
}
