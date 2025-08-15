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
    level: u4 = 6,
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

pub fn deinit(self: Self) void {
    self.gpa.free(self.writer.buffer);
    self.gpa.free(self.outbuf);
}

inline fn zLibInit(self: *@This()) !void {
    if (!self.zstream_initialized) {
        try zLibError(zlib.deflateInit2(
            &self.zstream,
            self.level,
            zlib.Z_DEFLATED,
            16 + 9,
            zlib.MAX_MEM_LEVEL,
            zlib.Z_DEFAULT_STRATEGY,
        ));
        self.zstream_initialized = true;
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
    self.zLibInit() catch |err| {
        std.log.err("zstream:\n{any}", .{self.zstream});
        std.log.err("zlib error: {}\n", .{err});
        return error.WriteFailed;
    };

    try self.zdrain(wr.buffer[0..wr.end], zlib.Z_NO_FLUSH);
    wr.end = 0;
    const buf = self.gpa.alloc(u8, @intFromEnum(limit)) catch return error.ReadFailed;
    defer self.gpa.free(buf);
    const count = try file_reader.readStreaming(buf);
    std.debug.assert(buf.len == count);
    try self.zdrain(buf, zlib.Z_NO_FLUSH);
    return count;
}

fn flush(wr: *Io.Writer) Io.Writer.Error!void {
    const self: *Self = @fieldParentPtr("writer", wr);
    self.zLibInit() catch |err| {
        std.log.err("zstream:\n{any}", .{self.zstream});
        std.log.err("zlib error: {}\n", .{err});
        return error.WriteFailed;
    };

    try self.zdrain(wr.buffer[0..wr.end], zlib.Z_FULL_FLUSH);
    wr.end = 0;
    try self.underlying_writer.flush();
}

fn drain(wr: *Io.Writer, blobs: []const []const u8, splat: usize) error{WriteFailed}!usize {
    const self: *Self = @fieldParentPtr("writer", wr);
    self.zLibInit() catch |err| {
        std.log.err("zstream:\n{any}", .{self.zstream});
        std.log.err("zlib error: {}\n", .{err});
        return error.WriteFailed;
    };
    var count: usize = 0;

    try self.zdrain(wr.buffer[0..wr.end], zlib.Z_NO_FLUSH);
    count += wr.end;
    wr.end = 0;
    for (blobs, 1..) |blob, i| {
        var splat_i: usize = 0;
        while ((i != blobs.len and splat_i < 1) or (i == blobs.len and splat_i < splat)) : (splat_i += 1) {
            try self.zdrain(blob, zlib.Z_NO_FLUSH);
            count += blob.len;
        }
    }
    return count;
}

fn zdrain(self: *Self, blob: []const u8, flush_flag: c_int) !void {
    if (blob.len == 0) return;
    self.zstream.next_in = @constCast(blob.ptr);
    self.zstream.avail_in = @intCast(blob.len);
    while (self.zstream.avail_in > 0) {
        self.zstream.next_out = self.outbuf.ptr;
        self.zstream.avail_out = @intCast(self.outbuf.len);

        std.log.err("zstream pre deflate: {d}\n{any}", .{
            self.writer.end,
            self.zstream,
        });

        zLibError(zlib.deflate(&self.zstream, flush_flag)) catch |err| switch (err) {
            error.ZLibBuf => {
                std.log.err("ZLibBuf!!!\nzstream:\n{any}", .{self.zstream});
                std.log.err("zlib error: {}", .{err});
                return error.WriteFailed;
            },
            else => {
                std.log.err("zstream:\n{any}", .{self.zstream});
                std.log.err("zlib error: {}\n", .{err});
                return error.WriteFailed;
            },
        };
        const have = self.outbuf.len - self.zstream.avail_out;
        std.log.err("have: {d}", .{have});
        try self.underlying_writer.writeAll(self.zstream.next_out[0..have]);
    }
}

fn zLibError(ret: c_int) !void {
    return switch (ret) {
        zlib.Z_OK => {},
        zlib.Z_STREAM_ERROR => error.ZLibStream,
        zlib.Z_DATA_ERROR => error.ZLibData,
        zlib.Z_NEED_DICT => error.ZLibNeedDict,
        zlib.Z_MEM_ERROR => error.ZLibMem,
        zlib.Z_BUF_ERROR => error.ZLibBuf,
        zlib.Z_VERSION_ERROR => error.ZLibVersion,
        else => error.ZLibUnknown,
    };
}
