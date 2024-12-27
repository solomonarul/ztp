const std = @import("std");
const socket = @import("socket.zig");
const builtin = @import("builtin");
const net = std.net;
const fs = std.fs;
const posix = std.posix;
const log = std.log;
const fmt = std.fmt;

const PATH_SIZE = 256;
const COMMAND_BUFFER_SIZE = 128;

// TODO: maybe do not handle credentials like this.
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
    interaction_mode: enum(u2) {
        NONE = 0,
        PASSIVE,
        ACTIVE
    },
    transfer_type: enum(u1) {
        ASCII = 0,
        BINARY = 1
    },
    current_dir_length: usize,
    current_dir: [PATH_SIZE:0]u8,
    data_address: net.Address,
    data_socket: posix.socket_t,

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
            log.info("[CLNT]: Logged in as {s}.", .{ALLOWED_USERNAME});
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
        const quit_start = std.mem.indexOf(u8, &self.command_buffer, "QUIT") orelse return false;
        if(quit_start != 0) return false;

        socket.write_buffer(self.server.control_socket, "221 Goodbye.\r\n");
        self.connected_status = .ABORTED;
        
        return true;
    }

    fn do_type_command(self: *FTPConnectedClient) bool
    {
        const type_start = std.mem.indexOf(u8, &self.command_buffer, "TYPE ") orelse return false;
        if(type_start != 0) return false;

        self.transfer_type = if(self.command_buffer[type_start] == 'I') .BINARY else .ASCII;
        socket.write_buffer(self.server.control_socket, "200 Type set to");
        socket.write_buffer(self.server.control_socket, if(self.transfer_type == .BINARY) "I" else "A");
        socket.write_buffer(self.server.control_socket, ".\r\n");

        return true;
    }

    fn do_pwd_command(self: *FTPConnectedClient) bool
    {
        const pwd_start = std.mem.indexOf(u8, &self.command_buffer, "PWD") orelse return false;
        if(pwd_start != 0) return false;

        const pwd = self.current_dir[0..self.current_dir_length];
        log.info("[CLNT]: Requested PWD, returning {s}.", .{pwd});
        socket.write_buffer(self.server.control_socket, "257 \"");
        socket.write_buffer(self.server.control_socket, pwd);
        socket.write_buffer(self.server.control_socket, "\" is the current directory. \r\n");
        
        return true;
    }

    fn do_list_command(self: *FTPConnectedClient) bool
    {
        const list_start = std.mem.indexOf(u8, &self.command_buffer, "LIST") orelse return false;
        if(list_start != 0) return false;

        const path = self.current_dir[0..self.current_dir_length];
        var dir = fs.cwd().openDir(path, .{.iterate = true}) catch |err| {
            log.err("[SRVR]: Could not open current directory for reading.\n\tError: {}", .{err});
            return true;
        };
        log.info("[SRVR]: Opened folder {s} for listing.", .{path});
        defer dir.close();
        socket.write_buffer(self.server.control_socket, "150 File status okay. About to open data connection.\r\n");

        var info_buffer: [2 * PATH_SIZE]u8 = undefined;
        var dirIterator = dir.iterate();
        while(true)
        {
            const current = dirIterator.next() catch |err| {
                log.err("[SRVR]: Could not open in current directory for reading.\n\tError: {}", .{err});
                break;
            };

            if(current) |entry|
            {
                const result = fmt.bufPrint(
                    &info_buffer, "{s}{s}{s}{s}{s}{s}{s}{s}{s}{s} 1 owner group 1234 Jan 01 12:34 {s}\r\n",
                    .{
                        "d", // if(file_info.kind == .directory) "-" else "d",
                        "-", //if(file_info.perms & fs.FilePerm.readable()) "r" else "-",
                        "-", //if(file_info.perms & fs.FilePerm.writable()) "w" else "-",
                        "-", //if(file_info.perms & fs.FilePerm.executable()) "x" else "-",
                        "-", //if(file_info.perms & fs.FilePerm.readable()) "r" else "-",
                        "-", //if(file_info.perms & fs.FilePerm.writable()) "w" else "-",
                        "-", //if(file_info.perms & fs.FilePerm.executable()) "x" else "-",
                        "-", //if(file_info.perms & fs.FilePerm.readable()) "r" else "-",
                        "-", //if(file_info.perms & fs.FilePerm.writable()) "w" else "-",
                        "-", //if(file_info.perms & fs.FilePerm.executable()) "x" else "-",
                        entry.name
                    }
                ) catch { continue; };
                socket.write_buffer(self.data_socket, result);
            }
            else { break; }
        }
        
        if(self.interaction_mode != .NONE)
        {
            posix.close(self.data_socket);
            self.interaction_mode = .NONE;
        }

        socket.write_buffer(self.server.control_socket, "226 Closing data connection. Requested file action successful.\r\n\r\n");
        return true;
    }

    fn do_port_command(self: *FTPConnectedClient) bool
    {
        const port_start = std.mem.indexOf(u8, &self.command_buffer, "PORT ") orelse return false;
        if(port_start != 0) return false;

        var index: usize = 0;
        const arg_string = self.command_buffer[5..self.command_buffer_length];
        var args: [6][]const u8 = undefined;
        var arg_parts = std.mem.split(u8, arg_string, ",");
        while(arg_parts.next()) |value|
        {
            if(index > 5)
            {
                log.err("[CLNT]: PORT command called with an invalid argument count. {s}", .{arg_string});
                socket.write_buffer(self.server.control_socket, "501 Syntax error in parameters or arguments.\r\n");
                return true;
            }
            args[index] = value;
            index += 1;
        }
        if(index != 6)
        {
            log.err("[CLNT]: PORT command called with an invalid argument count. {s}", .{arg_string});
            socket.write_buffer(self.server.control_socket, "501 Syntax error in parameters or arguments.\r\n");
            return true;
        }

        var parsed_args: [6]u8 = undefined;
        for(0..6) |arg_index|
        {
            parsed_args[arg_index] = std.fmt.parseInt(u8, args[arg_index], 10) catch |err| {
                log.err("[CLNT]: PORT command called with a non numerical argument.\n\tError:  {} with input: {s} in args: {s}", .{err, args[arg_index], arg_string});
                socket.write_buffer(self.server.control_socket, "501 Syntax error in parameters or arguments.\r\n");
                return true;
            };
        }

        var address_buffer: [20]u8 = undefined;
        const address_writer = fmt.bufPrint(&address_buffer, "{}.{}.{}.{}", .{parsed_args[0], parsed_args[1], parsed_args[2], parsed_args[3]});
        if(address_writer) |writer| // Should never error out.
        {
            const port: u16 = @as(u16, parsed_args[4]) * 256 + @as(u16, parsed_args[5]);
            self.data_address = net.Address.parseIp4(address_buffer[0..writer.len], port) catch |err| {
                log.err("[CLNT]: PORT command called with an invalid address.\n\tError: {}", .{err});
                socket.write_buffer(self.server.control_socket, "425 Can't open data connection.\r\n");
                return true;
            };
        }
        else |err|
        {
            log.err("[SRVR]: Could not print to address buffer.\n\tError: {}", .{err});
            socket.write_buffer(self.server.control_socket, "425 Can't open data connection.\r\n");
            return true;
        }

        log.info("[CLNT]: Requested active connection on address {}.", .{self.data_address});
        self.data_socket = posix.socket(self.data_address.any.family, posix.SOCK.STREAM, posix.IPPROTO.TCP) catch |err| {
            log.err("[SRVR]: Could not create data socket.\n\tError: {}", .{err});
            socket.write_buffer(self.server.control_socket, "425 Can't open data connection.\r\n");
            return true;
        };

        posix.connect(self.data_socket, &self.data_address.any, self.data_address.getOsSockLen()) catch |err|
        {
            log.err("[SRVR]: Could not connect to active connection on address {}.\n\tError: {}", .{self.data_address, err});
            socket.write_buffer(self.server.control_socket, "425 Can't open data connection.\r\n");
            return true;
        };
        self.interaction_mode = .ACTIVE;
        log.info("[SRVR]: Connected to active connection on address {}.", .{self.data_address});
        socket.write_buffer(self.server.control_socket, "200 Command okay.\r\n");
        return true;
    }

    pub fn handle(self: *FTPConnectedClient) void
    {
        log.info("[CLNT]: Accepted connection from {}.", .{self.address});
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

            // Done on every operation.
            if(self.do_port_command()) continue;

            // Actual operations.
            if(self.do_pwd_command())  continue;
            if(self.do_type_command()) continue;
            if(self.do_list_command()) continue;

            // Only need to be done once most of the times.
            if(self.do_syst_command()) continue;
            if(self.do_user_command()) continue;
            if(self.do_pass_command()) continue;
            if(self.do_quit_command()) continue;

            socket.write_buffer(self.server.control_socket, "502 Command not implemented.\r\n");
            log.warn("[CLNT]: Command not implemented:\n\t{s}", .{self.command_buffer[0..self.command_buffer_length]});
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
    root_dir: [PATH_SIZE:0]u8,

    pub fn create(config: FTPServerConfig) !FTPServer
    {
        var result = FTPServer
        {
            .address = config.address,
            .control_socket = undefined,
            .root_dir = undefined
        };

        _ = fmt.bufPrint(&result.root_dir, "{s}", .{config.root_dir}) catch {
            return error.InvalidPath;
        };

        return result;
    }

    pub fn run(self: *FTPServer) !void
    {
        // Create listener socket and make sure to close it on end.
        const listener = try posix.socket(self.address.any.family, posix.SOCK.STREAM, posix.IPPROTO.TCP);
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
                .interaction_mode = .NONE,
                .data_address = undefined,
                .data_socket = undefined,
                .current_dir_length = 0,
                .current_dir = undefined,
                .connected_status = .NOT_CONNECTED,
                .transfer_type = .ASCII,
            };

            @memset(client.current_dir[0..], 0);
            _ = fmt.bufPrint(&client.current_dir, "{s}", .{self.root_dir}) catch {
                continue;
            };
            while(client.current_dir_length < client.current_dir.len and client.current_dir[client.current_dir_length] != 0) client.current_dir_length += 1;
    
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