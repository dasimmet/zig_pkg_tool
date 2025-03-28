const std = @import("std");

pub const Projects = struct {
    id: usize,
    path_with_namespace: []const u8,
    path: []const u8,
    description: ?[]const u8 = null,
    star_count: usize,

    last_activity_at: []const u8,
    created_at: []const u8,

    forks_count: ?usize = null,
    default_branch: ?[]const u8 = null,

    forked_from_project: ?struct {} = null,
    topics: ?[]const []const u8 = null,

    archived: ?bool = null,
    avatar_url: ?[]const u8 = null,
    namespace: ?struct {
        avatar_url: ?[]const u8 = null,
    } = null,
};

pub const ProjectDetails = struct {
    id: usize,
    license: ?struct {
        key: []const u8,
    } = null,
    license_url: ?[]const u8 = null,
    statistics: ?struct {
        repository_size: usize,
    } = null,

    pub const url_tpl = "{s}/api/v4/projects/{d}?license=yes&statistics=yes";
};

pub const Issues = struct {
    id: usize = 1,
    const List = []const @This();

    pub const url_tpl = "{s}/api/v4/projects/{d}/issues?state=opened";
};
