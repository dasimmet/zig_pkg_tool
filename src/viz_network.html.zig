const std = @import("std");

pub const viz_network = JsonTemplate.generate(html_tpl, payload_marker);

const html_tpl = @embedFile("viz_network.html");
const payload_marker = "{ steps: [], UNIQUE_MARKER_FOR_PAYLOAD: true }";

const JsonTemplate = struct {
    prefix: []const u8,
    suffix: []const u8,
    fn generate(tpl: []const u8, marker: []const u8) @This() {
        const marker_pos = std.mem.indexOf(u8, tpl, marker).?;
        return .{
            .prefix = tpl[0..marker_pos],
            .suffix = tpl[marker_pos + payload_marker.len ..],
        };
    }

    pub fn render(self: @This(), content: anytype, writer: anytype) !void {
        try writer.writeAll(self.prefix);
        try std.json.stringify(content, .{
            .emit_null_optional_fields = false,
        }, writer);
        try writer.writeAll(self.suffix);
        try writer.writeAll("\n");
    }
};
