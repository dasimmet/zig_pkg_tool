// Pagination Http Client Iterator
//
//
//
// https://github.com/dasimmet/zig_pkg_tool.git

const std = @import("std");

// Fetches http responses until the "next" link pagination header is not available
const PaginationApiIterator = @This();

/// a Response from the Iterator's next() function
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
// this will be set to true after the first url passed in is consumed and 
// replaced by an internally allocated one.
next_url_owned: bool = false,
method: std.http.Method = .GET,

/// Initializes an http client and wraps it in the Iterator
pub fn init(allocator: std.mem.Allocator, url: []const u8) PaginationApiIterator {
    return .{
        .client = std.http.Client{ .allocator = allocator },
        .next_url = url,
    };
}

pub fn deinit(self: *PaginationApiIterator) void {
    if (self.next_url_owned) {
        if (self.next_url) |url| {
            self.client.allocator.free(url);
        }
    }
    self.client.deinit();
}

/// fetches the next http response,
/// parses the "next" link header if available
/// stores in it in next_url
/// returns the response. The caller is expected to deinitialize the response
/// before calling next() again
pub fn next(self: *PaginationApiIterator) !?Response {
    if (self.next_url == null) return null;

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
    if (self.next_url_owned) {
        self.client.allocator.free(self.next_url.?);
    }
    self.next_url = null;
    while (headers.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "link")) {
            if (LinkHeader.getLink(h.value, "next")) |next_url| {
                self.next_url_owned = true;
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

pub const LinkHeader = struct {
    pub fn getLink(header: []const u8, rel: []const u8) ?[]const u8 {
        if (std.ascii.indexOfIgnoreCase(header, "rel=\"") == null) {
            return null;
        }
        var urlStart: usize = 0;
        var urlEnd: usize = 0;
        while (true) {
            // find the url
            urlStart = urlEnd + (std.mem.indexOfScalar(
                u8,
                header[urlEnd..],
                '<',
            ) orelse return null);
            urlEnd = urlStart + (std.mem.indexOfScalar(
                u8,
                header[urlStart..],
                '>',
            ) orelse return null);
            const next_url = header[urlStart + 1 .. urlEnd];
            // check where rel is relative to it
            const relPos = std.ascii.indexOfIgnoreCase(
                header[urlEnd..],
                "rel=\"",
            ) orelse return null;
            if (relPos > 3) continue;
            // check if its the one we look for
            const relVal = std.ascii.startsWithIgnoreCase(
                header[urlEnd + relPos + "rel=\"".len ..],
                rel,
            );
            if (relVal) return next_url;
        }
    }
};

pub const example_header =
    \\<http://last>; rel="last",
    \\<http://prev>; rel="prev",
    \\<http://next>; rel="next"
;

test "linkheader" {
    inline for (&.{ "next", "last", "prev" }) |rel| {
        try std.testing.expectEqualSlices(
            u8,
            "http://" ++ rel,
            LinkHeader.getLink(example_header, rel).?,
        );
    }
}
