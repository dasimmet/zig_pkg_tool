// Pagination Http Client Iterator
//
//
//
// https://github.com/dasimmet/zig_pkg_tool.git

const std = @import("std");

// ---- Fetches until pagination header ends
const PaginationApiIterator = @This();
pub const Response = struct {
    status: std.http.Status,
    body: []const u8,

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.body);
    }
};

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
    const res = self.client.fetch(fetchOptions) catch @panic("Internet issue.");
    var headers = std.http.HeaderIterator.init(&serverHeaderBuffer);
    if (self.url_owned) {
        self.client.allocator.free(self.next_url.?);
    }
    self.next_url = null;
    while (headers.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "link")) {
            if (LinkHeader.getLink(h.value, "next")) |next_url| {
                self.url_owned = true;
                self.next_url = try self.client.allocator.dupe(u8, next_url);
                break;
            }
        }
    }
    return .{
        .status = res.status,
        .body = try charBuffer.toOwnedSlice(),
    };
}

const example_header = "<https://example.com/last>; rel=\"last\", <https://example.com/prev>; rel=\"prev\", <https://example.com/next>; rel=\"next\"";
pub const LinkHeader = struct {
    pub fn getLink(header: []const u8, rel: []const u8) ?[]const u8 {
        if (std.mem.indexOf(u8, header, "rel=\"next\"") == null) {
            return null;
        }
        var urlStart: usize = 0;
        var urlEnd: usize = 0;
        while (true) {
            // find the url
            urlStart = urlEnd + (std.mem.indexOfScalar(u8, header[urlEnd..], '<') orelse return null);
            urlEnd = urlStart + (std.mem.indexOfScalar(u8, header[urlStart..], '>') orelse return null);
            const next_url = header[urlStart + 1 .. urlEnd];
            // check where rel is relative to it
            const relPos = std.ascii.indexOfIgnoreCase(header[urlEnd..], "rel=\"") orelse return null;
            const relVal = std.ascii.startsWithIgnoreCase(header[urlEnd + relPos + "rel=\"".len ..], rel);
            if (relVal and relPos <= 3) {
                return next_url;
            }
            if (header.len - urlEnd <= 5) return null;
        }
    }
};

test "linkheader" {
    try std.testing.expectEqualSlices(
        u8,
        "https://example.com/next",
        LinkHeader.getLink(example_header, "next").?,
    );
    try std.testing.expectEqualSlices(
        u8,
        "https://example.com/last",
        LinkHeader.getLink(example_header, "last").?,
    );
    try std.testing.expectEqualSlices(
        u8,
        "https://example.com/prev",
        LinkHeader.getLink(example_header, "prev").?,
    );
}
