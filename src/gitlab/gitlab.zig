const std = @import("std");
const PaginationApiIterator = @import("PaginationApiIterator.zig");
const GitlabApi = @import("GitlabApi.zig");

const gitlab_url_base = "https://gitlab.com/api/v4/projects?order_by=last_activity_at&per_page=10&license=yes&topic=";
const gitlab_url_zig = gitlab_url_base ++ "zig";
const gitlab_url_zig_package = gitlab_url_base ++ "zig-package";

pub fn main() !void {
    var gpa_alloc = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa_alloc.allocator();

    var repo_num: usize = 0;
    try iterate(&repo_num, allocator, gitlab_url_zig);
    try iterate(&repo_num, allocator, gitlab_url_zig_package);
}

pub fn iterate(repo_num: *usize, allocator: std.mem.Allocator, gitlab_url: []const u8) !void {
    const stdout = std.io.getStdOut().writer();
    var iter = PaginationApiIterator.init(allocator, gitlab_url);
    while (try iter.next()) |res| {
        defer allocator.free(res);
        if (std.mem.eql(u8, "", res)) {
            @panic("Can't connect to gitlab.");
        }

        const parsed = std.json.parseFromSlice([]GitlabApi.Projects, allocator, res, .{
            .ignore_unknown_fields = true,
        }) catch {
            @panic("Wrong json");
        };
        defer parsed.deinit();
        for (parsed.value) |repo| {
            try stdout.print("repo: {d}\n", .{repo_num.*});
            try std.zon.stringify.serialize(repo, .{
                .whitespace = true,
            }, stdout);
            try stdout.writeAll("\n");
            repo_num.* += 1;
        }
    }
}
// git checkout master;git reset --hard other-branch;git push -f
