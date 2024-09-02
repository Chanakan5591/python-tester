const std = @import("std");
const testing = std.testing;

const mem = std.mem;
const fs = std.fs;

pub fn showDiff(allocator: mem.Allocator, writer: anytype, file1: []const u8, file2: []const u8) !void {
    const content1 = try std.fs.cwd().readFileAlloc(allocator, file1, std.math.maxInt(usize));
    defer allocator.free(content1);
    const content2 = try std.fs.cwd().readFileAlloc(allocator, file2, std.math.maxInt(usize));
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

pub fn compareFiles(gpa: mem.Allocator, file1: []const u8, file2: []const u8) !bool {
    const content1 = try fs.cwd().readFileAlloc(gpa, file1, std.math.maxInt(usize));
    defer gpa.free(content1);

    const content2 = try fs.cwd().readFileAlloc(gpa, file2, std.math.maxInt(usize));
    defer gpa.free(content2);

    return mem.eql(u8, content1, content2);
}

test "showDiff correctly shows differences between files" {
    const allocator = std.testing.allocator;
    var buffer: [10000]u8 = undefined;
    var output_stream = std.io.fixedBufferStream(&buffer);

    // Create test files
    const file1_path = "file1.txt";
    const file2_path = "file2.txt";

    const file1_content = "line1\nline2\nline3\n";
    const file2_content = "line1\nlineX\nline3\n";

    const file1 = try std.fs.cwd().createFile(file1_path, .{ .read = true });
    try file1.writeAll(file1_content);
    const file2 = try std.fs.cwd().createFile(file2_path, .{ .read = true });
    try file2.writeAll(file2_content);

    defer std.fs.cwd().deleteFile(file1_path) catch {};
    defer std.fs.cwd().deleteFile(file2_path) catch {};

    // Run showDiff
    try showDiff(allocator, output_stream.writer(), file1_path, file2_path);

    const expected_output = \\Line | Expected                                 | Got
                            \\---- | ---------------------------------------- | ----------------------------------------
                            \\   1 | line1                                    | line1
                            \\   2 | line2                                    | \x1b[1;31mlineX\x1b[0m
                            \\   3 | line3                                    | line3
                            ;

    const output_str = output_stream.getWritten();


    const filtered_expected_output = try std.mem.filter(allocator, expected_output, |c| !std.unicode.isWhitespace(c));
    defer allocator.free(filtered_expected_output);

    const filtered_output_str = try std.mem.filter(allocator, output_str, |c| !std.unicode.isWhitespace(c));
    defer allocator.free(filtered_output_str);

    // Compare the filtered strings
    try std.testing.expect(mem.eql(u8, filtered_output_str, filtered_expected_output));
    }
}

test "Comparing Identical Files Matched" {
    const allocator = testing.allocator;
    const first_file_path = "src/test_resources/matchingA.txt";
    const second_file_path = "src/test_resources/matchingB.txt";

    const result = try compareFiles(allocator, first_file_path, second_file_path);

    try testing.expect(result);
}

test "Comparing Different Files Not Matched" {
    const allocator = testing.allocator;
    const first_file_path = "src/test_resources/matchingA.txt";
    const second_file_path = "src/test_resources/misMatchedB.txt";

    const result = try compareFiles(allocator, first_file_path, second_file_path);

    try testing.expect(!result);
}

test "Ordering Files based on filenames" {
    const allocator = testing.allocator;
    var dir = try fs.cwd().openDir("src/test_resources/", .{ .iterate = true });
    defer dir.close();

    var entries = std.ArrayList(fs.Dir.Entry).init(allocator);
    defer entries.deinit();

    var it = dir.iterate();

    while (try it.next()) |entry| {
        if (entry.kind != .file or !mem.endsWith(u8, entry.name, ".in")) continue;
        try entries.append(entry);
    }

    mem.sort(fs.Dir.Entry, entries.items, {}, compareFileNames);


    // get .name property from dir.entry and then check with the list below

    const correctOrdering = [_][]const u8{"1.in", "2.in", "3.in"};

    try testing.expectEqual(correctOrdering.len, entries.items.len);

    for (correctOrdering, entries.items) |expected, actual| {
        try testing.expectEqualStrings(expected, actual.name);
    }
}
