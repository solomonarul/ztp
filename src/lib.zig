const std = @import("std");
const socket = @import("socket.zig");
const builtin = @import("builtin");
const net = std.net;
const posix = std.posix;
const log = std.log;
const fmt = std.fmt;

const COMMAND_BUFFER_SIZE = 128;

const ALLOWED_USERNAME = "admin";
const ALLOWED_PASSWORD = "admin";

const FTPConnectedClient = struct
{
    address: net.Address,
    server: *FTPServer,
    command_buffer_length: usize,
    command_buffer: [COMMAND_BUFFER_SIZE:0]u8,
    connected_status: enum(u2) {
        NOT_CONNECTED = 0,
        USERNAME_PROVIDED,
        CONNECTED,
        ABORTED,
    },

    fn do_user_command(self: *FTPConnectedClient) bool
    {
        const user_start = std.mem.indexOf(u8, &self.command_buffer, "USER ") orelse return false;
        if(user_start != 0) return false;

        const username = self.command_buffer[5..self.command_buffer_length];
        if(std.mem.eql(u8, username, ALLOWED_USERNAME))
        {
            self.connected_status = .USERNAME_PROVIDED;
            socket.write_buffer(self.server.control_socket, "331 Username okay, need password.\r\n");
            return true;
        }

        socket.write_buffer(self.server.control_socket, "530 Not logged in.\r\n");
        return true;
    }

    fn do_pass_command(self: *FTPConnectedClient) bool
    {
        const pass_start = std.mem.indexOf(u8, &self.command_buffer, "PASS ") orelse return false;
        if(pass_start != 0) return false;

        const pass = self.command_buffer[5..self.command_buffer_length];
        if(std.mem.eql(u8, pass, ALLOWED_PASSWORD))
        {
            self.connected_status = .CONNECTED;
            socket.write_buffer(self.server.control_socket, "230 User logged in, proceed..\r\n");
            return true;
        }

        socket.write_buffer(self.server.control_socket, "530 Not logged in.\r\n");
        return true;
    }

    fn do_syst_command(self: *FTPConnectedClient) bool
    {
        const syst_start = std.mem.indexOf(u8, &self.command_buffer, "SYST") orelse return false;
        if(syst_start != 0) return false;

        // Windows NT.
        if(comptime builtin.os.tag == .windows)
        {
            socket.write_buffer(self.server.control_socket, "215 WINDOWS_NT\r\n");
        }
        else // Everything else should be treated as Unix Linux.
            socket.write_buffer(self.server.control_socket, "215 UNIX Type: L8\r\n");
        
        return true;
    }

    fn do_quit_command(self: *FTPConnectedClient) bool
    {
        const syst_start = std.mem.indexOf(u8, &self.command_buffer, "QUIT") orelse return false;
        if(syst_start != 0) return false;

        socket.write_buffer(self.server.control_socket, "221 Goodbye.\r\n");
        self.connected_status = .ABORTED;
        
        return true;        
    }

    pub fn handle(self: *FTPConnectedClient) void
    {
        log.info("[SRVR]: Accepted connection from {}.", .{self.address});
        socket.write_buffer(self.server.control_socket, "220 Service ready for new user.\r\n");

        @memset(&self.command_buffer, 0);
        while(self.connected_status != .ABORTED)
        {
            const read_count = socket.read_buffer(self.server.control_socket, &self.command_buffer[0..]);
            if(read_count == 0)
            {
                self.connected_status = .ABORTED;
                break;
            }
            if(read_count < 3)
            {
                socket.write_buffer(self.server.control_socket, "500 Syntax error, command unrecognized.\r\n");
                continue;
            }

            self.command_buffer_length = read_count - 2;
            self.command_buffer[self.command_buffer_length] = 0;
            
            if(self.do_user_command()) continue;
            if(self.do_pass_command()) continue;
            if(self.do_syst_command()) continue;
            if(self.do_quit_command()) continue;

            socket.write_buffer(self.server.control_socket, "502 Command not implemented.\r\n");
            log.warn("Command not implemented:\n\t{s}", .{self.command_buffer[0..self.command_buffer_length]});
        }
    }
};

pub const FTPServerConfig = struct
{
    address: net.Address,
    root_dir: []const u8,
};

pub const FTPServer = struct
{
    address: net.Address,
    control_socket: posix.socket_t,

    pub fn create(config: FTPServerConfig) FTPServer
    {
        return FTPServer
        {
            .address = config.address,
            .control_socket = undefined,
        };
    }

    pub fn run(self: *FTPServer) !void
    {
        // Create listener socket and make sure to close it on end.
        const socket_type = posix.SOCK.STREAM;
        const protocol = posix.IPPROTO.TCP;
        const listener = try posix.socket(self.address.any.family, socket_type, protocol);
        defer posix.close(listener);

        // Listen on the created socket.
        try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));  // Reusable.
        try posix.bind(listener, &self.address.any, self.address.getOsSockLen());
        try posix.listen(listener, 128);
        log.info("[SRVR]: Created FTP control socket on {}", .{self.address});

        // Main loop.
        while (true)
        {
            // Accept the first client that connects.
            var client_address_len: posix.socklen_t = @sizeOf(net.Address);
            var client: FTPConnectedClient = .{
                .address = undefined,
                .command_buffer_length = 0,
                .command_buffer = undefined,
                .server = self,
                .connected_status = .NOT_CONNECTED,
            };
            self.control_socket = posix.accept(listener, &client.address.any, &client_address_len, 0) catch |err|
            {
                log.err("[SRVR]: Error on accepting connection: {}.", .{err});
                continue;
            };

            // Handle the connection.
            client.handle();

            // Connection has been ended.
            log.info("[SRVR]: Connection with client terminated.", .{});
            posix.close(self.control_socket);
        }
    }
};