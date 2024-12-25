const std = @import("std");
const posix = std.posix;
const log = std.log;

pub fn write_buffer(socket: posix.socket_t, data: []const u8) void
{
    var position: usize = 0;
    while(position < data.len)
        position += posix.write(socket,data[position..]) catch {
            log.warn("[SOKT]: Failed write to socket, aborting...", .{});
            return;
        };
}

pub fn read_buffer(socket: posix.socket_t, data: *const []u8) usize {
    const result = posix.read(socket, data.*) catch {
        log.warn("[SOKT]: Failed read from socket, aborting...", .{});
        return 0;
    };
    return result;
}