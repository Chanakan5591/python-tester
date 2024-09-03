const std = @import("std");
const testing = std.testing;

const mem = std.mem;
const fs = std.fs;

pub fn showDiff(allocator: mem.Allocator, writer: anytype, file1: []const u8, file2: []const u8) !void {
    const content1 = try readFileNormalized(allocator, file1);
    defer allocator.free(content1);

    const content2 = try readFileNormalized(allocator, file2);
    defer allocator.free(content2);

    var lines1 = mem.tokenizeSequence(u8, content1, "\n");
    var lines2 = mem.tokenizeSequence(u8, content2, "\n");
    var line_number: usize = 1;
    try writer.print("Line | {s:<40} | {s}\n", .{ "Expected", "Got" });
    try writer.print("---- | {s:-<40} | {s:-<40}\n", .{ "", "" });
    while (true) {
        const line1 = lines1.next();
        const line2 = lines2.next();
        if (line1 == null and line2 == null) break;
        if (line1) |l1| {
            if (line2) |l2| {
                if (mem.eql(u8, l1, l2)) {
                    try writer.print("{d:4} | {s:<40} | {s}\n", .{ line_number, l1, l2 });
                } else {
                    try writer.print("{d:4} | {s:<40} | \x1b[1;31m{s}\x1b[0m\n", .{ line_number, l1, l2 });
                }
            } else {
                try writer.print("{d:4} | {s:<40} | \n", .{ line_number, l1 });
            }
        } else if (line2) |l2| {
            try writer.print("{d:4} | {s:<40} | \x1b[1;33m{s}\x1b[0m\n", .{ line_number, "", l2 });
        }
        line_number += 1;
    }
}

pub fn compareFileNames(context: void, a: fs.Dir.Entry, b: fs.Dir.Entry) bool {
    _ = context;
    const a_num = std.fmt.parseInt(usize, mem.sliceTo(a.name, '.'), 10) catch return false;
    const b_num = std.fmt.parseInt(usize, mem.sliceTo(b.name, '.'), 10) catch return false;
    return a_num < b_num;
}

// required for converting CRLF to LF for Windows/DOS file
fn readFileNormalized(gpa: mem.Allocator, path: []const u8) ![]u8 {
    var file = try fs.cwd().openFile(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(gpa, std.math.maxInt(usize));

    // Normalize line endings
    var normalized = try gpa.alloc(u8, content.len);
    errdefer gpa.free(normalized);

    var i: usize = 0;
    var j: usize = 0;
    while (i < content.len) : (i += 1) {
        if (content[i] == '\r' and i + 1 < content.len and content[i + 1] == '\n') {
            normalized[j] = '\n';
            i += 1;
        } else {
            normalized[j] = content[i];
        }
        j += 1;
    }

    gpa.free(content);
    return gpa.realloc(normalized, j);
}

pub fn compareFiles(gpa: mem.Allocator, file1: []const u8, file2: []const u8) !bool {
    const content1 = try readFileNormalized(gpa, file1);
    defer gpa.free(content1);

    const content2 = try readFileNormalized(gpa, file2);
    defer gpa.free(content2);

    return mem.eql(u8, content1, content2);
}

test "showDiff correctly shows differences between files" {
    const allocator = std.testing.allocator;
    var buffer: [10000]u8 = undefined;
    var output_stream = std.io.fixedBufferStream(&buffer);

    // Create test files
    const file1_path = try std.fs.path.join(allocator, &[_][]const u8{ "src", "test_resources", "matchingA.txt" });
    const file2_path = try std.fs.path.join(allocator, &[_][]const u8{ "src", "test_resources", "misMatchedB.txt" });

    defer allocator.free(file1_path);
    defer allocator.free(file2_path);

    // Run showDiff
    try showDiff(allocator, output_stream.writer(), file1_path, file2_path);

    // current does not know how to get multiline string to work with color formatting
    const expected_output = "Line | Expected                                 | Got\n---- | ---------------------------------------- | ----------------------------------------\n   1 | This file will match with the other one. | \x1b[1;31mThis file will not match with the other one.\x1b[0m\n   2 | Just fine.                               | Just fine.\n   3 | Thanks                                   | Thanks\n";

    const output_str = output_stream.getWritten();

    // Compare the filtered strings
    try std.testing.expect(mem.eql(u8, expected_output, output_str));
}

test "compareFiles Identical Files Matched" {
    const allocator = testing.allocator;

    const file1_path = try std.fs.path.join(allocator, &[_][]const u8{ "src", "test_resources", "matchingA.txt" });
    const file2_path = try std.fs.path.join(allocator, &[_][]const u8{ "src", "test_resources", "matchingB.txt" });

    defer allocator.free(file1_path);
    defer allocator.free(file2_path);

    const result = try compareFiles(allocator, file1_path, file2_path);

    try testing.expect(result);
}

test "compareFiles Different Files Not Matched" {
    const allocator = testing.allocator;

    const file1_path = try std.fs.path.join(allocator, &[_][]const u8{ "src", "test_resources", "matchingA.txt" });
    const file2_path = try std.fs.path.join(allocator, &[_][]const u8{ "src", "test_resources", "misMatchedB.txt" });

    defer allocator.free(file1_path);
    defer allocator.free(file2_path);

    const result = try compareFiles(allocator, file1_path, file2_path);

    try testing.expect(!result);
}
