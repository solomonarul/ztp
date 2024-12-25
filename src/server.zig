const std = @import("std");
const ztp = @import("lib.zig");
const net = std.net;
const log = std.log;

pub fn main() !void
{
    // Resolve address.
    const address = net.Address.resolveIp("0.0.0.0", 25565) catch |err| {
        log.err("[SRVR]: Error on resolving the specified address: {}.", .{err});
        return;
    };

    // Create FTP server on said address.
    var server = ztp.FTPServer.create(.{
        .address = address,
        .root_dir = "./",
    });
    try server.run();
}
