const std = @import("std");
pub const TempFile = @import("TempFile.zig");
pub const EmbedRunnerSources = struct {
    pub const @"BuildSerialize.zig" = @embedFile("BuildSerialize.zig");
    pub const @"Manifest.zig" = @embedFile("Manifest.zig");
    pub const @"runner-dot.zig" = @embedFile("runner-dot.zig");
    pub const @"runner-zig-0.14.0.zig" = @embedFile("runner-zig-0.14.0.zig");
    pub const @"runner-zig-master.zig" = @embedFile("runner-zig-master.zig");
    pub const @"runner-zig.zig" = @embedFile("runner-zig.zig");
    pub const @"runner-zon.zig" = @embedFile("runner-zon.zig");
    pub const @"zonparse-0.14.0.zig" = @embedFile("zonparse-0.14.0.zig");
    pub const @"zonparse-master.zig" = @embedFile("zonparse-master.zig");
    pub const @"zonparse.zig" = @embedFile("zonparse.zig");
};
pub const Embedded = BuildRunnerTmp(EmbedRunnerSources);

pub fn BuildRunnerTmp(T: type) type {
    return struct {
        const Self = @This();
        temp: TempFile.TmpDir,
        runner: []const u8,

        pub fn init(gpa: std.mem.Allocator, runner_file: []const u8) !Self {
            var tempD = try TempFile.tmpDir(.{
                .prefix = "zigpkg",
            });

            const runner = try std.fs.path.join(gpa, &.{
                tempD.abs_path,
                runner_file,
            });

            inline for (comptime std.meta.declarations(T)) |decl| {
                try tempD.dir.writeFile(.{
                    .data = @field(T, decl.name),
                    .sub_path = decl.name,
                });
            }

            return .{
                .temp = tempD,
                .runner = runner,
            };
        }
        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.temp.deinit();
            gpa.free(self.runner);
        }
    };
}
