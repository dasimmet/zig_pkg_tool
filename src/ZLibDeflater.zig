const std = @import("std");
const Io = std.Io;
const Self = @This();

const zlib = @cImport({
    @cInclude("zlib.h");
});

const CHUNKSIZE = 16 * 1024;
zstream_initialized: bool = false,
level: u4,
zstream: zlib.z_stream,
outbuf: []u8,
underlying_writer: *std.io.Writer,
writer: std.io.Writer,
gpa: std.mem.Allocator,

pub const Options = struct {
    gpa: std.mem.Allocator,
    level: u4 = 9,
    writer: *std.io.Writer,
};

pub fn init(opt: Self.Options) !Self {
    return .{
        .zstream = .{
            // .zalloc = null,
            // .zfree = null,
            // .@"opaque" = null,
            .next_in = zlib.Z_NULL,
            .avail_in = 0,
            .next_out = zlib.Z_NULL,
            .avail_out = 0,
        },
        .level = opt.level,
        .outbuf = try opt.gpa.alloc(u8, CHUNKSIZE),
        .writer = .{
            .buffer = try opt.gpa.alloc(u8, CHUNKSIZE),
            .vtable = &.{
                .drain = drain,
                .flush = flush,
                .sendFile = sendFile,
            },
        },
        .underlying_writer = opt.writer,
        .gpa = opt.gpa,
    };
}

pub fn deinit(self: *Self) void {
    _ = zlib.deflateEnd(&self.zstream);
    self.gpa.free(self.writer.buffer);
    self.gpa.free(self.outbuf);
}

inline fn zStreamInit(self: *@This()) !void {
    if (!self.zstream_initialized) {
        try zLibError(zlib.deflateInit2(
            &self.zstream,
            self.level,
            zlib.Z_DEFLATED,
            16 + 15,
            zlib.MAX_MEM_LEVEL,
            zlib.Z_DEFAULT_STRATEGY,
        ));
        self.zstream_initialized = true;
    }
}

fn drain(wr: *Io.Writer, blobs: []const []const u8, splat: usize) error{WriteFailed}!usize {
    const self: *Self = @fieldParentPtr("writer", wr);
    self.zStreamInit() catch |err| {
        std.log.err("zstream:\n{any}", .{self.zstream});
        std.log.err("zlib error: {}\n", .{err});
        return error.WriteFailed;
    };

    try self.zdrain(wr.buffer[0..wr.end]);
    wr.end = 0;

    var count: usize = 0;
    for (blobs, 1..) |blob, i| {
        var splat_i: usize = 0;
        while ((i != blobs.len and splat_i < 1) or (i == blobs.len and splat_i < splat)) : (splat_i += 1) {
            try self.zdrain(blob);
            count += blob.len;
        }
    }
    return count;
}

fn zdrain(self: *Self, blob: []const u8) !void {
    if (blob.len == 0) return;
    self.zstream.next_in = @constCast(blob.ptr);
    self.zstream.avail_in = @intCast(blob.len);
    while (self.zstream.avail_in > 0) {
        self.zstream.next_out = self.outbuf.ptr;
        self.zstream.avail_out = @intCast(self.outbuf.len);

        zLibError(zlib.deflate(&self.zstream, zlib.Z_NO_FLUSH)) catch |err| {
            std.log.err("zstream:\n{any}", .{self.zstream});
            std.log.err("zlib error: {}\n", .{err});
            return error.WriteFailed;
        };
        const have = self.outbuf.len - self.zstream.avail_out;
        try self.underlying_writer.writeAll(self.outbuf[0..have]);
    }
}

fn sendFile(
    wr: *Io.Writer,
    file_reader: *std.fs.File.Reader,
    /// Maximum amount of bytes to read from the file. Implementations may
    /// assume that the file size does not exceed this amount. Data from
    /// `buffer` does not count towards this limit.
    limit: Io.Limit,
) Io.Writer.FileError!usize {
    const self: *Self = @fieldParentPtr("writer", wr);
    self.zStreamInit() catch |err| {
        std.log.err("zstream:\n{any}", .{self.zstream});
        std.log.err("zlib error: {}\n", .{err});
        return error.WriteFailed;
    };

    try self.zdrain(wr.buffer[0..wr.end]);
    wr.end = 0;
    var transferred: usize = 0;
    while (limit == .unlimited or transferred < @intFromEnum(limit)) {
        const to_read = @min(wr.buffer.len, @intFromEnum(limit) - transferred);
        const just_read = try file_reader.readStreaming(wr.buffer[0..to_read]);
        transferred += just_read;
        try self.zdrain(wr.buffer[0..just_read]);
        if (file_reader.atEnd()) break;
    }
    return transferred;
}

fn flush(wr: *Io.Writer) Io.Writer.Error!void {
    const self: *Self = @fieldParentPtr("writer", wr);
    self.zStreamInit() catch |err| {
        std.log.err("zstream:\n{any}", .{self.zstream});
        std.log.err("zlib error: {}\n", .{err});
        return error.WriteFailed;
    };

    self.zstream.next_in = wr.buffer.ptr;
    self.zstream.avail_in = @intCast(wr.buffer.len);

    var end: bool = false;
    while (!end) {
        self.zstream.next_out = self.outbuf.ptr;
        self.zstream.avail_out = @intCast(self.outbuf.len);
        zLibError(zlib.deflate(&self.zstream, zlib.Z_FINISH)) catch |err| switch (err) {
            error.ZLibStreamEnd => {
                end = true;
            },
            else => {
                std.log.err("zstream:\n{any}", .{self.zstream});
                std.log.err("zlib error: {}\n", .{err});
                return error.WriteFailed;
            },
        };
        const have = self.outbuf.len - self.zstream.avail_out;
        try self.underlying_writer.writeAll(self.outbuf[0..have]);
    }
    wr.end = 0;
    try self.underlying_writer.flush();
}

fn zLibError(ret: c_int) !void {
    return switch (ret) {
        zlib.Z_OK => {},
        zlib.Z_STREAM_END => error.ZLibStreamEnd,
        zlib.Z_STREAM_ERROR => error.ZLibStream,
        zlib.Z_DATA_ERROR => error.ZLibData,
        zlib.Z_MEM_ERROR => error.ZLibMem,
        zlib.Z_BUF_ERROR => error.ZLibBuf,
        zlib.Z_VERSION_ERROR => error.ZLibVersion,
        else => error.ZLibUnknown,
    };
}
