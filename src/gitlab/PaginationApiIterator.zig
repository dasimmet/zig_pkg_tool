// Pagination Http Client Iterator
//
//
//

// https://github.com/dasimmet/zig_pkg_tool.git

const std = @import("std");

// ---- Fetches until pagination header ends
const PaginationApiIterator = @This();
pub const Response = std.http.Client.Response;

client: std.http.Client,
// the next url to fetch. finish if null
next_url: ?[]const u8,
// is the url owned and should be freed after the next fetch?
url_owned: bool = false,
method: std.http.Method = .GET,

pub fn init(allocator: std.mem.Allocator, url: []const u8) PaginationApiIterator {
    return .{
        .client = std.http.Client{ .allocator = allocator },
        .next_url = url,
    };
}

pub fn deinit(self: *PaginationApiIterator) void {
    if (self.url_owned) {
        if (self.next_url) |url| {
            self.client.allocator.free(url);
        }
    }
    self.client.deinit();
}

pub fn next(self: *PaginationApiIterator) !?Response {
    if (self.next_url == null) {
        self.deinit();
        return null;
    }
    var serverHeaderBuffer = std.mem.zeroes([4096]u8);
    var charBuffer = std.ArrayList(u8).init(self.client.allocator);
    errdefer charBuffer.deinit();
    const fetchOptions = std.http.Client.FetchOptions{
        .location = std.http.Client.FetchOptions.Location{
            .url = self.next_url.?,
        },
        .method = self.method,
        .response_storage = .{ .dynamic = &charBuffer },
        .server_header_buffer = &serverHeaderBuffer,
    };
    _ = self.client.fetch(fetchOptions) catch @panic("Internet issue.");
    var headers = std.http.HeaderIterator.init(&serverHeaderBuffer);
    if (self.url_owned) {
        self.client.allocator.free(self.next_url.?);
    }
    self.next_url = null;
    while (headers.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "link") and std.mem.indexOf(u8, h.value, "rel=\"next\"") != null) {
            std.debug.print("h: {s}\n", .{h.value});
            const urlStart = std.mem.indexOfScalar(u8, h.value, '<');
            const urlEnd = std.mem.indexOfScalar(u8, h.value, '>');
            if (urlStart != null and urlEnd != null) {
                self.url_owned = true;
                const next_url = h.value[urlStart.? + 1 .. urlEnd.?];
                self.next_url = try self.client.allocator.dupe(u8, next_url);
            }
        }
    }
    return charBuffer.toOwnedSlice() catch @panic("Can't convert buffer to string");
}

const example_header = "<https://gitlab.com/api/v4/projects?imported=false&include_hidden=false&license=yes&membership=false&order_by=last_activity_at&owned=false&page=2&per_page=1&repository_checksum_failed=false&simple=false&sort=desc&starred=false&statistics=false&topic%5B%5D=zig&wiki_checksum_failed=false&with_custom_attributes=false&with_issues_enabled=false&with_merge_requests_enabled=false>; rel=\"next\", <https://gitlab.com/api/v4/projects?imported=false&include_hidden=false&license=yes&membership=false&order_by=last_activity_at&owned=false&page=1&per_page=1&repository_checksum_failed=false&simple=false&sort=desc&starred=false&statistics=false&topic%5B%5D=zig&wiki_checksum_failed=false&with_custom_attributes=false&with_issues_enabled=false&with_merge_requests_enabled=false>; rel=\"first\", <https://gitlab.com/api/v4/projects?imported=false&include_hidden=false&license=yes&membership=false&order_by=last_activity_at&owned=false&page=43&per_page=1&repository_checksum_failed=false&simple=false&sort=desc&starred=false&statistics=false&topic%5B%5D=zig&wiki_checksum_failed=false&with_custom_attributes=false&with_issues_enabled=false&with_merge_requests_enabled=false>; rel=\"last\"";
pub const LinkHeader = struct {
    pub fn getRel(header: []const u8, rel: []const u8) ?[]const u8 {
        var head = header;
        while (true) {
            const urlStart = std.mem.indexOfScalar(u8, head, '<');
            const urlEnd = std.mem.indexOf(u8, head, ">; ");
            if (urlStart == null or urlEnd == null) {
                return null;
            }
            const url = head[urlStart.? + 1 .. urlEnd.?];

            const urlEndEnd = urlEnd.? + ">; ".len;
            const relPos = std.mem.indexOf(
                u8,
                head,
                "rel=",
            );
            if (relPos == null) return null;
            const relSlice = head[relPos.?..];

            var i: usize = 0;
            var quoted: bool = false;
            const quoted_char: bool = false;
            while (true) : (i += 1) {
                if (relSlice.len < i) return null;
                if (i == 0 and relSlice[0] == '"') {
                    quoted = true;
                    continue;
                }
                _ = rel;
                _ = quoted_char;
                return url;
            }
        }
    }
    pub fn getRel(header: []const u8, rel: []const u8) ?[]const u8 {}
};

test "linkheader" {
    try std.testing.expectEqual(LinkHeader.getRel(example_header, "next"), "asdf");
}
