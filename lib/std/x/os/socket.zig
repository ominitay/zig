// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2021 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.

const std = @import("../../std.zig");
const net = @import("net.zig");

const io = std.io;
const os = std.os;
const fmt = std.fmt;
const mem = std.mem;
const time = std.time;
const builtin = std.builtin;

/// Import in a `Socket` abstraction depending on the platform we are compiling against.
pub usingnamespace switch (builtin.os.tag) {
    .windows => @import("socket_windows.zig"),
    else => @import("socket_posix.zig"),
};

/// A common subset of shared structs across cross-platform abstractions over socket syscalls.
pub fn Mixin(comptime Self: type) type {
    return struct {
        /// A socket-address pair.
        pub const Connection = struct {
            socket: Self,
            address: Self.Address,

            /// Enclose a socket and address into a socket-address pair.
            pub fn from(socket: Self, address: Self.Address) Self.Connection {
                return .{ .socket = socket, .address = address };
            }
        };

        /// A generic socket address abstraction. It is safe to directly access and modify
        /// the fields of a `Self.Address`.
        pub const Address = union(enum) {
            ipv4: net.IPv4.Address,
            ipv6: net.IPv6.Address,

            /// Instantiate a new address with a IPv4 host and port.
            pub fn initIPv4(host: net.IPv4, port: u16) Self.Address {
                return .{ .ipv4 = .{ .host = host, .port = port } };
            }

            /// Instantiate a new address with a IPv6 host and port.
            pub fn initIPv6(host: net.IPv6, port: u16) Self.Address {
                return .{ .ipv6 = .{ .host = host, .port = port } };
            }

            /// Parses a `sockaddr` into a generic socket address.
            pub fn fromNative(address: *align(4) const os.sockaddr) Self.Address {
                switch (address.family) {
                    os.AF_INET => {
                        const info = @ptrCast(*const os.sockaddr_in, address);
                        const host = net.IPv4{ .octets = @bitCast([4]u8, info.addr) };
                        const port = mem.bigToNative(u16, info.port);
                        return Self.Address.initIPv4(host, port);
                    },
                    os.AF_INET6 => {
                        const info = @ptrCast(*const os.sockaddr_in6, address);
                        const host = net.IPv6{ .octets = info.addr, .scope_id = info.scope_id };
                        const port = mem.bigToNative(u16, info.port);
                        return Self.Address.initIPv6(host, port);
                    },
                    else => unreachable,
                }
            }

            /// Encodes a generic socket address into an extern union that may be reliably
            /// casted into a `sockaddr` which may be passed into socket syscalls.
            pub fn toNative(self: Self.Address) extern union {
                ipv4: os.sockaddr_in,
                ipv6: os.sockaddr_in6,
            } {
                return switch (self) {
                    .ipv4 => |address| .{
                        .ipv4 = .{
                            .addr = @bitCast(u32, address.host.octets),
                            .port = mem.nativeToBig(u16, address.port),
                        },
                    },
                    .ipv6 => |address| .{
                        .ipv6 = .{
                            .addr = address.host.octets,
                            .port = mem.nativeToBig(u16, address.port),
                            .scope_id = address.host.scope_id,
                            .flowinfo = 0,
                        },
                    },
                };
            }

            /// Returns the number of bytes that make up the `sockaddr` equivalent to the address. 
            pub fn getNativeSize(self: Self.Address) u32 {
                return switch (self) {
                    .ipv4 => @sizeOf(os.sockaddr_in),
                    .ipv6 => @sizeOf(os.sockaddr_in6),
                };
            }

            /// Implements the `std.fmt.format` API.
            pub fn format(
                self: Self.Address,
                comptime layout: []const u8,
                opts: fmt.FormatOptions,
                writer: anytype,
            ) !void {
                switch (self) {
                    .ipv4 => |address| try fmt.format(writer, "{}:{}", .{ address.host, address.port }),
                    .ipv6 => |address| try fmt.format(writer, "{}:{}", .{ address.host, address.port }),
                }
            }
        };

        /// Implements `std.io.Reader`.
        pub const Reader = struct {
            socket: Self,
            flags: u32,

            /// Implements `readFn` for `std.io.Reader`.
            pub fn read(self: Self.Reader, buffer: []u8) !usize {
                return self.socket.read(buffer, self.flags);
            }
        };

        /// Implements `std.io.Writer`.
        pub const Writer = struct {
            socket: Self,
            flags: u32,

            /// Implements `writeFn` for `std.io.Writer`.
            pub fn write(self: Self.Writer, buffer: []const u8) !usize {
                return self.socket.write(buffer, self.flags);
            }
        };

        /// Extracts the error set of a function.
        /// TODO: remove after Socket.{read, write} error unions are well-defined across different platforms
        fn ErrorSetOf(comptime Function: anytype) type {
            return @typeInfo(@typeInfo(@TypeOf(Function)).Fn.return_type.?).ErrorUnion.error_set;
        }

        /// Wrap `Socket` into `std.io.Reader`.
        pub fn reader(self: Self, flags: u32) io.Reader(Self.Reader, ErrorSetOf(Self.Reader.read), Self.Reader.read) {
            return .{ .context = .{ .socket = self, .flags = flags } };
        }

        /// Wrap `Socket` into `std.io.Writer`.
        pub fn writer(self: Self, flags: u32) io.Writer(Self.Writer, ErrorSetOf(Self.Writer.write), Self.Writer.write) {
            return .{ .context = .{ .socket = self, .flags = flags } };
        }
    };
}
