const std = @import("std");

pub const std_options = struct {
    pub const page_size_max = 4096;
};

const e1000 = @import("driver/e1000.zig");
const serial = @import("driver/serial.zig");

pub const IpAddr = [4]u8;
pub const MacAddr = [6]u8;

pub var my_ip: IpAddr = .{ 10, 0, 2, 15 }; // QEMU user net default
pub var gateway_ip: IpAddr = .{ 10, 0, 2, 2 };
pub var dns_ip: IpAddr = .{ 10, 0, 2, 3 };

pub const ArpEntry = struct {
    ip: IpAddr,
    mac: MacAddr,
    valid: bool,
};
var arp_cache: [16]ArpEntry = [_]ArpEntry{.{ .ip = .{ 0, 0, 0, 0 }, .mac = .{ 0, 0, 0, 0, 0, 0 }, .valid = false }} ** 16;

pub const EthernetHeader = extern struct {
    dst: MacAddr,
    src: MacAddr,
    ethertype: u16,
};

pub const ArpPacket = extern struct {
    htype: u16,
    ptype: u16,
    hlen: u8,
    plen: u8,
    op: u16,
    src_mac: MacAddr,
    src_ip: IpAddr,
    dst_mac: MacAddr,
    dst_ip: IpAddr,
};

pub const IpHeader = extern struct {
    ver_ihl: u8,
    tos: u8,
    len: u16,
    id: u16,
    flags_frag: u16,
    ttl: u8,
    proto: u8,
    checksum: u16,
    src: IpAddr,
    dst: IpAddr,
};

pub const UdpHeader = extern struct {
    src_port: u16,
    dst_port: u16,
    len: u16,
    checksum: u16,
};

pub const TcpHeader = extern struct {
    src_port: u16,
    dst_port: u16,
    seq: u32,
    ack: u32,
    data_offset_flags: u16,
    window_size: u16,
    checksum: u16,
    urgent_ptr: u16,
};

pub const DhcpPacket = extern struct {
    op: u8,
    htype: u8,
    hlen: u8,
    hops: u8,
    xid: u32,
    secs: u16,
    flags: u16,
    ciaddr: IpAddr,
    yiaddr: IpAddr,
    siaddr: IpAddr,
    giaddr: IpAddr,
    chaddr: [16]u8,
    sname: [64]u8,
    file: [128]u8,
    magic: u32,
};

// TCP flags
const TCP_FIN: u16 = 0x01;
const TCP_SYN: u16 = 0x02;
const TCP_RST: u16 = 0x04;
const TCP_PSH: u16 = 0x08;
const TCP_ACK: u16 = 0x10;

// =========================================================================
// Socket infrastructure
// =========================================================================
pub const SocketState = enum { closed, syn_sent, established, fin_wait };
pub const SocketType = enum { tcp, udp };

const RECV_BUF_SIZE = 16384;
const MAX_SOCKETS = 32;

pub const Socket = struct {
    in_use: bool,
    type_: SocketType,
    state: SocketState,
    local_port: u16,
    remote_port: u16,
    remote_ip: IpAddr,
    // TCP state
    seq_num: u32,
    ack_num: u32,
    // Receive buffer (ring)
    recv_buf: [RECV_BUF_SIZE]u8,
    recv_head: usize,
    recv_tail: usize,
    recv_closed: bool,
};

var sockets: [MAX_SOCKETS]Socket = init_sockets();
var next_local_port: u16 = 49152;

fn init_sockets() [MAX_SOCKETS]Socket {
    var s: [MAX_SOCKETS]Socket = undefined;
    for (0..MAX_SOCKETS) |i| {
        s[i].in_use = false;
        s[i].state = .closed;
        s[i].recv_head = 0;
        s[i].recv_tail = 0;
        s[i].recv_closed = false;
    }
    return s;
}

fn alloc_socket() ?usize {
    for (0..MAX_SOCKETS) |i| {
        if (!sockets[i].in_use) {
            sockets[i] = Socket{
                .in_use = true,
                .type_ = .tcp,
                .state = .closed,
                .local_port = next_local_port,
                .remote_port = 0,
                .remote_ip = .{ 0, 0, 0, 0 },
                .seq_num = 0x1000,
                .ack_num = 0,
                .recv_buf = undefined,
                .recv_head = 0,
                .recv_tail = 0,
                .recv_closed = false,
            };
            next_local_port +%= 1;
            if (next_local_port < 49152) next_local_port = 49152;
            return i;
        }
    }
    return null;
}

fn recv_buf_avail(s: *const Socket) usize {
    if (s.recv_head >= s.recv_tail) return s.recv_head - s.recv_tail;
    return RECV_BUF_SIZE - s.recv_tail + s.recv_head;
}

fn recv_buf_push(s: *Socket, data: []const u8) void {
    for (data) |b| {
        const next_head = (s.recv_head + 1) % RECV_BUF_SIZE;
        if (next_head == s.recv_tail) return; // full
        s.recv_buf[s.recv_head] = b;
        s.recv_head = next_head;
    }
}

fn recv_buf_pop(s: *Socket, buf: []u8) usize {
    var count: usize = 0;
    while (count < buf.len and s.recv_tail != s.recv_head) {
        buf[count] = s.recv_buf[s.recv_tail];
        s.recv_tail = (s.recv_tail + 1) % RECV_BUF_SIZE;
        count += 1;
    }
    return count;
}

// =========================================================================
// Syscall implementations
// =========================================================================

pub fn sys_socket(domain: u64, type_: u64, proto: u64) u64 {
    _ = domain;
    _ = proto;
    const idx = alloc_socket() orelse return 0xFFFFFFFFFFFFFFFF;
    if (type_ == 2) { // SOCK_DGRAM
        sockets[idx].type_ = .udp;
    } else {
        sockets[idx].type_ = .tcp;
    }
    return idx;
}

pub fn sys_connect(fd: u64, ip_u32: u32, port: u16) u64 {
    if (fd >= MAX_SOCKETS) return 0xFFFFFFFFFFFFFFFF;
    var s = &sockets[fd];
    if (!s.in_use) return 0xFFFFFFFFFFFFFFFF;

    // Convert u32 ip to [4]u8 (network byte order)
    s.remote_ip[0] = @truncate(ip_u32 >> 24);
    s.remote_ip[1] = @truncate(ip_u32 >> 16);
    s.remote_ip[2] = @truncate(ip_u32 >> 8);
    s.remote_ip[3] = @truncate(ip_u32);
    s.remote_port = port;

    if (s.type_ == .udp) {
        s.state = .established;
        return 0;
    }

    // TCP: send SYN
    s.state = .syn_sent;
    s.seq_num = 0x1000;
    send_tcp_packet(s, TCP_SYN, &.{});
    s.seq_num += 1; // SYN consumes a sequence number

    // Wait for SYN-ACK (poll network)
    // int 0x80 is an interrupt gate, so IF is cleared on entry. Keep timer
    // interrupts enabled while polling or a connect would stop scheduling.
    asm volatile ("sti");
    var timeout: u32 = 0;
    while (timeout < 500000) : (timeout += 1) {
        update();
        if (s.state == .established) {
            asm volatile ("cli");
            return 0;
        }
        asm volatile ("pause");
    }
    asm volatile ("cli");

    serial.log("net: TCP connect timeout\n");
    s.state = .closed;
    return 0xFFFFFFFFFFFFFFFF;
}

pub fn sys_send(fd: u64, buf_ptr: u64, len: u64) u64 {
    if (fd >= MAX_SOCKETS) return 0xFFFFFFFFFFFFFFFF;
    var s = &sockets[fd];
    if (!s.in_use or s.state != .established) return 0xFFFFFFFFFFFFFFFF;

    const data = @as([*]const u8, @ptrFromInt(buf_ptr))[0..len];

    if (s.type_ == .udp) {
        send_udp_packet(s, data);
        return len;
    }

    // TCP: send data in chunks of up to 1400 bytes
    var sent: usize = 0;
    while (sent < data.len) {
        const chunk = @min(data.len - sent, 1400);
        send_tcp_packet(s, TCP_PSH | TCP_ACK, data[sent..sent + chunk]);
        s.seq_num +%= @as(u32, @intCast(chunk));
        sent += chunk;

        // Brief pause to let ACKs flow
        var i: u32 = 0;
        while (i < 5000) : (i += 1) {
            update();
            asm volatile ("pause");
        }
    }
    return len;
}

pub fn sys_recv(fd: u64, buf_ptr: u64, len: u64) u64 {
    if (fd >= MAX_SOCKETS) return 0xFFFFFFFFFFFFFFFF;
    const s = &sockets[fd];
    if (!s.in_use) return 0xFFFFFFFFFFFFFFFF;

    const buf = @as([*]u8, @ptrFromInt(buf_ptr))[0..len];

    // Poll until data available or connection closed
    var timeout: u32 = 0;
    while (timeout < 1000000) : (timeout += 1) {
        update();
        const avail = recv_buf_avail(s);
        if (avail > 0) {
            return recv_buf_pop(s, buf);
        }
        if (s.recv_closed or s.state == .closed) {
            return 0; // EOF
        }
        asm volatile ("pause");
    }
    return 0; // timeout
}

pub fn sys_resolve_host(hostname_ptr: u64, ip_out_ptr: u64) u64 {
    const hostname = @as([*]const u8, @ptrFromInt(hostname_ptr));
    var hostname_len: usize = 0;
    while (hostname_len < 253 and hostname[hostname_len] != 0) : (hostname_len += 1) {}
    if (hostname_len == 0) return 0xFFFFFFFFFFFFFFFF;

    // Allocate a UDP socket for DNS
    const dns_fd = alloc_socket() orelse return 0xFFFFFFFFFFFFFFFF;
    var s = &sockets[dns_fd];
    s.type_ = .udp;
    s.state = .established;
    s.remote_ip = dns_ip;
    s.remote_port = 53;

    // Build DNS query
    var query: [512]u8 = [_]u8{0} ** 512;
    // Header: ID=0xBEEF, flags=0x0100 (standard query, RD=1), QDCOUNT=1
    query[0] = 0xBE; query[1] = 0xEF; // ID
    query[2] = 0x01; query[3] = 0x00; // Flags: RD=1
    query[4] = 0x00; query[5] = 0x01; // QDCOUNT=1
    // ANCOUNT, NSCOUNT, ARCOUNT = 0

    // Question section: encode hostname as DNS labels
    var qoff: usize = 12;
    var label_start: usize = 0;
    var hi: usize = 0;
    while (hi <= hostname_len) : (hi += 1) {
        if (hi == hostname_len or hostname[hi] == '.') {
            const label_len = hi - label_start;
            if (label_len == 0 or label_len > 63) break;
            query[qoff] = @truncate(label_len);
            qoff += 1;
            var j: usize = 0;
            while (j < label_len) : (j += 1) {
                query[qoff] = hostname[label_start + j];
                qoff += 1;
            }
            label_start = hi + 1;
        }
    }
    query[qoff] = 0; qoff += 1; // null terminator
    // QTYPE = A (1)
    query[qoff] = 0; query[qoff + 1] = 1; qoff += 2;
    // QCLASS = IN (1)
    query[qoff] = 0; query[qoff + 1] = 1; qoff += 2;

    send_udp_packet(s, query[0..qoff]);
    serial.log("DNS query sent\n");

    // Wait for response
    var timeout: u32 = 0;
    while (timeout < 500000) : (timeout += 1) {
        update();
        if (recv_buf_avail(s) > 0) break;
        asm volatile ("pause");
    }

    var resp: [512]u8 = undefined;
    const resp_len = recv_buf_pop(s, &resp);
    s.in_use = false; // free socket

    if (resp_len < 12) return 0xFFFFFFFFFFFFFFFF;

    // Check ANCOUNT > 0
    const ancount = (@as(u16, resp[6]) << 8) | resp[7];
    if (ancount == 0) return 0xFFFFFFFFFFFFFFFF;

    // Skip question section (it mirrors what we sent)
    var roff: usize = 12;
    // Skip QNAME
    while (roff < resp_len and resp[roff] != 0) {
        if ((resp[roff] & 0xC0) == 0xC0) { roff += 2; break; } // pointer
        roff += @as(usize, resp[roff]) + 1;
    } else { roff += 1; } // skip null
    roff += 4; // skip QTYPE + QCLASS

    // Parse first answer
    // Skip NAME (could be pointer)
    if (roff + 2 > resp_len) return 0xFFFFFFFFFFFFFFFF;
    if ((resp[roff] & 0xC0) == 0xC0) {
        roff += 2; // pointer
    } else {
        while (roff < resp_len and resp[roff] != 0) : (roff += @as(usize, resp[roff]) + 1) {}
        roff += 1;
    }
    // TYPE(2) + CLASS(2) + TTL(4) + RDLENGTH(2) = 10 bytes
    if (roff + 10 > resp_len) return 0xFFFFFFFFFFFFFFFF;
    const rdlen = (@as(u16, resp[roff + 8]) << 8) | resp[roff + 9];
    roff += 10;
    if (rdlen != 4 or roff + 4 > resp_len) return 0xFFFFFFFFFFFFFFFF;

    // Write IP to user pointer
    const ip_out = @as(*u32, @ptrFromInt(ip_out_ptr));
    ip_out.* = (@as(u32, resp[roff]) << 24) |
               (@as(u32, resp[roff + 1]) << 16) |
               (@as(u32, resp[roff + 2]) << 8) |
               @as(u32, resp[roff + 3]);

    serial.log("DNS resolved: ");
    serial.log_dec(resp[roff]); serial.log(".");
    serial.log_dec(resp[roff+1]); serial.log(".");
    serial.log_dec(resp[roff+2]); serial.log(".");
    serial.log_dec(resp[roff+3]); serial.log("\n");
    return 0;
}

// =========================================================================
// Packet sending helpers
// =========================================================================

fn arp_resolve(target_ip: IpAddr) MacAddr {
    // Check cache
    for (0..16) |i| {
        if (arp_cache[i].valid and std.mem.eql(u8, &arp_cache[i].ip, &target_ip)) {
            return arp_cache[i].mac;
        }
    }
    // Send ARP request
    send_arp_request(target_ip);
    var timeout: u32 = 0;
    while (timeout < 200000) : (timeout += 1) {
        update();
        for (0..16) |i| {
            if (arp_cache[i].valid and std.mem.eql(u8, &arp_cache[i].ip, &target_ip)) {
                return arp_cache[i].mac;
            }
        }
        asm volatile ("pause");
    }
    // Fallback: QEMU default gateway MAC
    return .{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 };
}

fn send_arp_request(target_ip: IpAddr) void {
    var packet: [60]u8 align(8) = undefined;
    @memset(packet[0..], 0);
    const eth = @as(*EthernetHeader, @ptrCast(@alignCast(&packet[0])));
    eth.dst = .{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
    eth.src = e1000.get_mac();
    eth.ethertype = std.mem.nativeToBig(u16, 0x0806);
    const arp = @as(*ArpPacket, @ptrCast(@alignCast(&packet[@sizeOf(EthernetHeader)])));
    arp.htype = std.mem.nativeToBig(u16, 1);
    arp.ptype = std.mem.nativeToBig(u16, 0x0800);
    arp.hlen = 6;
    arp.plen = 4;
    arp.op = std.mem.nativeToBig(u16, 1); // Request
    arp.src_mac = e1000.get_mac();
    arp.src_ip = my_ip;
    arp.dst_mac = .{ 0, 0, 0, 0, 0, 0 };
    arp.dst_ip = target_ip;
    e1000.send_packet(&packet);
}

fn get_gateway_mac() MacAddr {
    return arp_resolve(gateway_ip);
}

var ip_id_counter: u16 = 1;

fn send_ip_packet(dst_ip: IpAddr, proto: u8, payload: []const u8) void {
    const total_len = @sizeOf(EthernetHeader) + @sizeOf(IpHeader) + payload.len;
    if (total_len > 1518) return;

    var packet_buf: [1518]u8 align(8) = undefined;
    @memset(packet_buf[0..], 0);

    // Ethernet
    const eth = @as(*EthernetHeader, @ptrCast(@alignCast(&packet_buf[0])));
    eth.dst = get_gateway_mac();
    eth.src = e1000.get_mac();
    eth.ethertype = std.mem.nativeToBig(u16, 0x0800);

    // IP
    const ip_len: u16 = @truncate(@sizeOf(IpHeader) + payload.len);
    var ip: IpHeader align(1) = .{
        .ver_ihl = 0x45,
        .tos = 0,
        .len = std.mem.nativeToBig(u16, ip_len),
        .id = std.mem.nativeToBig(u16, ip_id_counter),
        .flags_frag = 0,
        .ttl = 64,
        .proto = proto,
        .checksum = 0,
        .src = my_ip,
        .dst = dst_ip,
    };
    ip_id_counter +%= 1;
    @memcpy(packet_buf[@sizeOf(EthernetHeader)..(@sizeOf(EthernetHeader) + @sizeOf(IpHeader))], std.mem.asBytes(&ip));

    // Calculate IP checksum
    const ip_bytes = packet_buf[@sizeOf(EthernetHeader)..(@sizeOf(EthernetHeader) + @sizeOf(IpHeader))];
    const cs = calculate_checksum(ip_bytes);
    packet_buf[@sizeOf(EthernetHeader) + 10] = @truncate(cs >> 8);
    packet_buf[@sizeOf(EthernetHeader) + 11] = @truncate(cs);

    // Payload
    const payload_off = @sizeOf(EthernetHeader) + @sizeOf(IpHeader);
    @memcpy(packet_buf[payload_off..payload_off + payload.len], payload);

    e1000.send_packet(packet_buf[0..total_len]);
}

fn send_udp_packet(s: *Socket, data: []const u8) void {
    const udp_len: u16 = @truncate(@sizeOf(UdpHeader) + data.len);
    var segment: [1400 + @sizeOf(UdpHeader)]u8 = undefined;
    @memset(segment[0..], 0);

    // UDP header
    segment[0] = @truncate(s.local_port >> 8);
    segment[1] = @truncate(s.local_port);
    segment[2] = @truncate(s.remote_port >> 8);
    segment[3] = @truncate(s.remote_port);
    segment[4] = @truncate(udp_len >> 8);
    segment[5] = @truncate(udp_len);
    // checksum = 0 (optional for UDP over IPv4)

    @memcpy(segment[@sizeOf(UdpHeader)..@sizeOf(UdpHeader) + data.len], data);
    send_ip_packet(s.remote_ip, 17, segment[0..udp_len]);
}

fn send_tcp_packet(s: *Socket, flags: u16, data: []const u8) void {
    const tcp_hdr_len: usize = 20;
    const seg_len = tcp_hdr_len + data.len;
    var segment: [1420]u8 = undefined;
    @memset(segment[0..], 0);

    // TCP header (20 bytes, no options)
    segment[0] = @truncate(s.local_port >> 8);
    segment[1] = @truncate(s.local_port);
    segment[2] = @truncate(s.remote_port >> 8);
    segment[3] = @truncate(s.remote_port);
    // Sequence number (big-endian)
    segment[4] = @truncate(s.seq_num >> 24);
    segment[5] = @truncate(s.seq_num >> 16);
    segment[6] = @truncate(s.seq_num >> 8);
    segment[7] = @truncate(s.seq_num);
    // Ack number
    segment[8] = @truncate(s.ack_num >> 24);
    segment[9] = @truncate(s.ack_num >> 16);
    segment[10] = @truncate(s.ack_num >> 8);
    segment[11] = @truncate(s.ack_num);
    // Data offset (5 = 20 bytes) << 4 in high nibble of byte 12
    const offset_and_flags: u16 = (5 << 12) | flags;
    segment[12] = @truncate(offset_and_flags >> 8);
    segment[13] = @truncate(offset_and_flags);
    // Window size = 8192
    segment[14] = 0x20;
    segment[15] = 0x00;

    // Copy payload
    if (data.len > 0) {
        @memcpy(segment[tcp_hdr_len..tcp_hdr_len + data.len], data);
    }

    // TCP checksum (with pseudo-header)
    var pseudo: [12]u8 = undefined;
    @memcpy(pseudo[0..4], &my_ip);
    @memcpy(pseudo[4..8], &s.remote_ip);
    pseudo[8] = 0;
    pseudo[9] = 6; // TCP proto
    const tcp_len_be: u16 = @truncate(seg_len);
    pseudo[10] = @truncate(tcp_len_be >> 8);
    pseudo[11] = @truncate(tcp_len_be);

    var csum: u32 = 0;
    // Sum pseudo-header
    var pi: usize = 0;
    while (pi < 12) : (pi += 2) {
        csum += (@as(u32, pseudo[pi]) << 8) | pseudo[pi + 1];
    }
    // Sum TCP segment
    pi = 0;
    while (pi + 1 < seg_len) : (pi += 2) {
        csum += (@as(u32, segment[pi]) << 8) | segment[pi + 1];
    }
    if (seg_len % 2 != 0) {
        csum += @as(u32, segment[seg_len - 1]) << 8;
    }
    while (csum > 0xFFFF) {
        csum = (csum & 0xFFFF) + (csum >> 16);
    }
    const tcp_cs: u16 = @truncate(~csum);
    segment[16] = @truncate(tcp_cs >> 8);
    segment[17] = @truncate(tcp_cs);

    send_ip_packet(s.remote_ip, 6, segment[0..seg_len]);
}

// =========================================================================
// Initialization and packet receive loop
// =========================================================================

pub fn init() void {
    e1000.init();
    serial.log("Network stack initialized\n");
}

var net_heap: [65536]u8 align(4096) = undefined;
var net_heap_ptr: usize = 0;

fn net_alloc(len: usize) ?[]u8 {
    if (net_heap_ptr + len > net_heap.len) {
        net_heap_ptr = 0;
    }
    const res = net_heap[net_heap_ptr .. net_heap_ptr + len];
    net_heap_ptr += (len + 7) & ~@as(usize, 7);
    return res;
}

pub fn update() void {
    while (e1000.poll_receive_raw()) |packet_info| {
        const packet = @as([*]u8, @ptrFromInt(packet_info.offset))[0..packet_info.len];
        handle_packet(packet);
    }
}

fn handle_packet(packet: []u8) void {
    if (packet.len < @sizeOf(EthernetHeader)) return;
    if (!std.mem.isAligned(@intFromPtr(packet.ptr), @alignOf(EthernetHeader))) {
        serial.log("net: packet unaligned, skipping\n");
        return;
    }
    const eth = @as(*EthernetHeader, @ptrCast(@alignCast(packet.ptr)));
    const ethertype = std.mem.nativeToBig(u16, eth.ethertype);

    if (ethertype == 0x0806) {
        handle_arp(packet[@sizeOf(EthernetHeader)..]);
    } else if (ethertype == 0x0800) {
        handle_ipv4(packet[@sizeOf(EthernetHeader)..]);
    }
}

// =========================================================================
// DHCP
// =========================================================================

pub fn start_dhcp() void {
    var packet_buf: [512]u8 align(8) = undefined;
    @memset(packet_buf[0..], 0);

    const eth = @as(*EthernetHeader, @ptrCast(@alignCast(&packet_buf[0])));
    eth.dst = .{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
    eth.src = e1000.get_mac();
    eth.ethertype = std.mem.nativeToBig(u16, 0x0800);

    var ip: IpHeader align(1) = .{
        .ver_ihl = 0x45,
        .tos = 0,
        .len = std.mem.nativeToBig(u16, @as(u16, @truncate(512 - @sizeOf(EthernetHeader)))),
        .id = 0,
        .flags_frag = 0,
        .ttl = 64,
        .proto = 17,
        .src = .{ 0, 0, 0, 0 },
        .dst = .{ 255, 255, 255, 255 },
        .checksum = 0,
    };
    @memcpy(packet_buf[@sizeOf(EthernetHeader)..(@sizeOf(EthernetHeader) + @sizeOf(IpHeader))], std.mem.asBytes(&ip));
    const ip_ptr = @as(*IpHeader, @ptrCast(&packet_buf[@sizeOf(EthernetHeader)]));
    ip_ptr.checksum = calculate_checksum(packet_buf[@sizeOf(EthernetHeader)..(@sizeOf(EthernetHeader) + @sizeOf(IpHeader))]);

    var udp: UdpHeader align(1) = .{
        .src_port = std.mem.nativeToBig(u16, 68),
        .dst_port = std.mem.nativeToBig(u16, 67),
        .len = std.mem.nativeToBig(u16, @as(u16, @truncate(512 - @sizeOf(EthernetHeader) - @sizeOf(IpHeader)))),
        .checksum = 0,
    };
    @memcpy(packet_buf[(@sizeOf(EthernetHeader) + @sizeOf(IpHeader))..(@sizeOf(EthernetHeader) + @sizeOf(IpHeader) + @sizeOf(UdpHeader))], std.mem.asBytes(&udp));

    var dhcp: DhcpPacket align(1) = undefined;
    @memset(std.mem.asBytes(&dhcp), 0);
    dhcp.op = 1;
    dhcp.htype = 1;
    dhcp.hlen = 6;
    dhcp.xid = 0x12345678;
    dhcp.magic = std.mem.nativeToBig(u32, 0x63825363);
    @memcpy(dhcp.chaddr[0..6], &e1000.get_mac());
    @memcpy(packet_buf[(@sizeOf(EthernetHeader) + @sizeOf(IpHeader) + @sizeOf(UdpHeader))..(@sizeOf(EthernetHeader) + @sizeOf(IpHeader) + @sizeOf(UdpHeader) + @sizeOf(DhcpPacket))], std.mem.asBytes(&dhcp));

    const options_off = @sizeOf(EthernetHeader) + @sizeOf(IpHeader) + @sizeOf(UdpHeader) + @sizeOf(DhcpPacket);
    packet_buf[options_off + 0] = 53;
    packet_buf[options_off + 1] = 1;
    packet_buf[options_off + 2] = 1;
    packet_buf[options_off + 3] = 255;

    e1000.send_packet(packet_buf[0..]);
    serial.log("DHCP Discover sent\n");
}

pub fn send_ping(target_ip: IpAddr) void {
    var packet_buf: [98]u8 align(8) = undefined;
    @memset(packet_buf[0..], 0);

    const eth = @as(*EthernetHeader, @ptrCast(@alignCast(&packet_buf[0])));
    eth.dst = .{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 };
    eth.src = e1000.get_mac();
    eth.ethertype = std.mem.nativeToBig(u16, 0x0800);

    var ip: IpHeader align(1) = .{
        .ver_ihl = 0x45,
        .tos = 0,
        .len = std.mem.nativeToBig(u16, @as(u16, @truncate(98 - @sizeOf(EthernetHeader)))),
        .id = 0x1234,
        .flags_frag = 0,
        .ttl = 64,
        .proto = 1,
        .src = my_ip,
        .dst = target_ip,
        .checksum = 0,
    };
    @memcpy(packet_buf[@sizeOf(EthernetHeader)..(@sizeOf(EthernetHeader) + @sizeOf(IpHeader))], std.mem.asBytes(&ip));
    const ip_ptr = @as(*IpHeader, @ptrCast(&packet_buf[@sizeOf(EthernetHeader)]));
    ip_ptr.checksum = calculate_checksum(packet_buf[@sizeOf(EthernetHeader)..(@sizeOf(EthernetHeader) + @sizeOf(IpHeader))]);

    const icmp_off = @sizeOf(EthernetHeader) + @sizeOf(IpHeader);
    packet_buf[icmp_off + 0] = 8;
    packet_buf[icmp_off + 1] = 0;
    packet_buf[icmp_off + 2] = 0;
    packet_buf[icmp_off + 3] = 0;
    packet_buf[icmp_off + 4] = 0;
    packet_buf[icmp_off + 5] = 1;
    packet_buf[icmp_off + 6] = 0;
    packet_buf[icmp_off + 7] = 1;

    const icmp_checksum = calculate_checksum(packet_buf[icmp_off..]);
    packet_buf[icmp_off + 2] = @truncate(icmp_checksum >> 8);
    packet_buf[icmp_off + 3] = @truncate(icmp_checksum);

    e1000.send_packet(packet_buf[0..]);
    serial.log("ICMP Echo Request sent\n");
}

// =========================================================================
// Protocol handlers
// =========================================================================

fn handle_arp(data: []u8) void {
    if (data.len < @sizeOf(ArpPacket)) return;
    if (!std.mem.isAligned(@intFromPtr(data.ptr), @alignOf(ArpPacket))) {
        var arp_aligned: ArpPacket align(@alignOf(ArpPacket)) = undefined;
        @memcpy(std.mem.asBytes(&arp_aligned), data.ptr[0..@sizeOf(ArpPacket)]);
        handle_arp_internal(&arp_aligned);
        return;
    }
    const arp = @as(*ArpPacket, @ptrCast(@alignCast(data.ptr)));
    handle_arp_internal(arp);
}

fn handle_arp_internal(arp: *const ArpPacket) void {
    if (std.mem.nativeToBig(u16, arp.htype) != 1) return;
    if (std.mem.nativeToBig(u16, arp.ptype) != 0x0800) return;

    const op = std.mem.nativeToBig(u16, arp.op);

    // Update ARP cache
    var i: usize = 0;
    var found = false;
    while (i < 16) : (i += 1) {
        if (arp_cache[i].valid and std.mem.eql(u8, &arp_cache[i].ip, &arp.src_ip)) {
            arp_cache[i].mac = arp.src_mac;
            found = true;
            break;
        }
    }
    if (!found) {
        i = 0;
        while (i < 16) : (i += 1) {
            if (!arp_cache[i].valid) {
                arp_cache[i].ip = arp.src_ip;
                arp_cache[i].mac = arp.src_mac;
                arp_cache[i].valid = true;
                break;
            }
        }
    }

    if (op == 1) {
        if (std.mem.eql(u8, &arp.dst_ip, &my_ip)) {
            send_arp_reply(arp.src_mac, arp.src_ip);
        }
    }
}

fn send_arp_reply(target_mac: MacAddr, target_ip: IpAddr) void {
    var packet: [60]u8 align(8) = undefined;
    @memset(packet[0..], 0);
    const eth = @as(*EthernetHeader, @ptrCast(@alignCast(&packet[0])));
    eth.dst = target_mac;
    eth.src = e1000.get_mac();
    eth.ethertype = std.mem.nativeToBig(u16, 0x0806);
    const arp = @as(*ArpPacket, @ptrCast(@alignCast(&packet[@sizeOf(EthernetHeader)])));
    arp.htype = std.mem.nativeToBig(u16, 1);
    arp.ptype = std.mem.nativeToBig(u16, 0x0800);
    arp.hlen = 6;
    arp.plen = 4;
    arp.op = std.mem.nativeToBig(u16, 2);
    arp.src_mac = e1000.get_mac();
    arp.src_ip = my_ip;
    arp.dst_mac = target_mac;
    arp.dst_ip = target_ip;
    e1000.send_packet(&packet);
}

fn handle_ipv4(data: []u8) void {
    if (data.len < @sizeOf(IpHeader)) return;
    if (!std.mem.isAligned(@intFromPtr(data.ptr), @alignOf(IpHeader))) {
        var ip_aligned: IpHeader align(@alignOf(IpHeader)) = undefined;
        @memcpy(std.mem.asBytes(&ip_aligned), data.ptr[0..@sizeOf(IpHeader)]);
        handle_ipv4_internal(&ip_aligned, data);
        return;
    }
    const ip = @as(*IpHeader, @ptrCast(@alignCast(data.ptr)));
    handle_ipv4_internal(ip, data);
}

fn handle_ipv4_internal(ip: *const IpHeader, data: []u8) void {
    if ((ip.ver_ihl >> 4) != 4) return;
    const ihl = (ip.ver_ihl & 0x0F) * 4;
    if (data.len < ihl) return;

    const total_len = std.mem.nativeToBig(u16, ip.len);
    if (data.len < total_len) return;

    const payload = data[ihl..total_len];

    if (ip.proto == 1) {
        handle_icmp(payload, ip.src);
    } else if (ip.proto == 17) {
        handle_udp(payload, ip.src);
    } else if (ip.proto == 6) {
        handle_tcp(payload, ip.src);
    }
}

fn handle_udp(data: []u8, src_ip: IpAddr) void {
    if (data.len < @sizeOf(UdpHeader)) return;

    const src_port = (@as(u16, data[0]) << 8) | data[1];
    const dst_port = (@as(u16, data[2]) << 8) | data[3];
    const udp_len = (@as(u16, data[4]) << 8) | data[5];
    _ = src_port;

    if (dst_port == 68) {
        handle_dhcp(data[@sizeOf(UdpHeader)..]);
        return;
    }

    // Route to matching socket
    const payload = data[@sizeOf(UdpHeader)..@min(data.len, udp_len)];
    for (0..MAX_SOCKETS) |i| {
        if (sockets[i].in_use and sockets[i].type_ == .udp and
            sockets[i].local_port == dst_port and
            std.mem.eql(u8, &sockets[i].remote_ip, &src_ip))
        {
            recv_buf_push(&sockets[i], payload);
            return;
        }
    }
}

fn handle_tcp(data: []u8, src_ip: IpAddr) void {
    if (data.len < 20) return;

    const src_port = (@as(u16, data[0]) << 8) | data[1];
    const dst_port = (@as(u16, data[2]) << 8) | data[3];
    const seq = (@as(u32, data[4]) << 24) | (@as(u32, data[5]) << 16) | (@as(u32, data[6]) << 8) | data[7];
    const ack = (@as(u32, data[8]) << 24) | (@as(u32, data[9]) << 16) | (@as(u32, data[10]) << 8) | data[11];
    const data_offset = (data[12] >> 4) * 4;
    const flags: u16 = ((@as(u16, data[12]) & 0x01) << 8) | data[13];

    // Find matching socket
    for (0..MAX_SOCKETS) |i| {
        var s = &sockets[i];
        if (!s.in_use or s.type_ != .tcp) continue;
        if (s.local_port != dst_port) continue;
        if (s.remote_port != src_port) continue;
        if (!std.mem.eql(u8, &s.remote_ip, &src_ip)) continue;

        if (s.state == .syn_sent and (flags & TCP_SYN) != 0 and (flags & TCP_ACK) != 0) {
            // SYN-ACK received — complete handshake
            s.ack_num = seq + 1;
            s.state = .established;
            send_tcp_packet(s, TCP_ACK, &.{});
            serial.log("TCP: connection established\n");
            return;
        }

        if (s.state == .established) {
            _ = ack; // We don't track ACKs in this simplified stack

            // Handle FIN
            if ((flags & TCP_FIN) != 0) {
                s.ack_num = seq + 1;
                send_tcp_packet(s, TCP_ACK, &.{});
                s.recv_closed = true;
                s.state = .closed;
                serial.log("TCP: connection closed by remote\n");
                return;
            }

            // Handle RST
            if ((flags & TCP_RST) != 0) {
                s.recv_closed = true;
                s.state = .closed;
                return;
            }

            // Handle data
            if (data.len > data_offset) {
                const payload = data[data_offset..];
                if (payload.len > 0) {
                    recv_buf_push(s, payload);
                    s.ack_num = seq +% @as(u32, @truncate(payload.len));
                    send_tcp_packet(s, TCP_ACK, &.{});
                }
            }
            return;
        }
        return;
    }
}

fn handle_dhcp(data: []u8) void {
    if (data.len < @sizeOf(DhcpPacket)) return;
    if (!std.mem.isAligned(@intFromPtr(data.ptr), @alignOf(DhcpPacket))) {
        var dhcp_aligned: DhcpPacket align(@alignOf(DhcpPacket)) = undefined;
        @memcpy(std.mem.asBytes(&dhcp_aligned), data.ptr[0..@sizeOf(DhcpPacket)]);
        handle_dhcp_internal(&dhcp_aligned);
        return;
    }
    const dhcp = @as(*DhcpPacket, @ptrCast(@alignCast(data.ptr)));
    handle_dhcp_internal(dhcp);
}

fn handle_dhcp_internal(dhcp: *const DhcpPacket) void {
    if (dhcp.op == 2) {
        my_ip = dhcp.yiaddr;
        serial.log("DHCP IP assigned: ");
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            serial.log_dec(my_ip[i]);
            if (i < 3) serial.log(".");
        }
        serial.log("\n");
    }
}

fn handle_icmp(data: []u8, src_ip: IpAddr) void {
    if (data.len < 8) return;
    const icmp_type = data[0];
    if (icmp_type == 8) {
        send_icmp_reply(src_ip, data);
    } else if (icmp_type == 0) {
        serial.log("ICMP Echo Reply received\n");
    }
}

fn send_icmp_reply(target_ip: IpAddr, request_data: []u8) void {
    const packet_len = @sizeOf(EthernetHeader) + @sizeOf(IpHeader) + request_data.len;
    const packet = net_alloc(packet_len) orelse return;

    const eth = @as(*EthernetHeader, @ptrCast(@alignCast(packet.ptr)));
    var target_mac: MacAddr = .{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 };
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        if (arp_cache[i].valid and std.mem.eql(u8, &arp_cache[i].ip, &target_ip)) {
            target_mac = arp_cache[i].mac;
            break;
        }
    }

    eth.dst = target_mac;
    eth.src = e1000.get_mac();
    eth.ethertype = std.mem.nativeToBig(u16, 0x0800);

    const ip = @as(*IpHeader, @ptrCast(@alignCast(packet.ptr + @sizeOf(EthernetHeader))));
    ip.ver_ihl = 0x45;
    ip.tos = 0;
    ip.len = std.mem.nativeToBig(u16, @as(u16, @truncate(@sizeOf(IpHeader) + request_data.len)));
    ip.id = 0;
    ip.flags_frag = 0;
    ip.ttl = 64;
    ip.proto = 1;
    ip.checksum = 0;
    ip.src = my_ip;
    ip.dst = target_ip;
    ip.checksum = calculate_checksum(packet[@sizeOf(EthernetHeader)..(@sizeOf(EthernetHeader) + @sizeOf(IpHeader))]);

    const icmp = packet.ptr + @sizeOf(EthernetHeader) + @sizeOf(IpHeader);
    @memcpy(icmp[0..request_data.len], request_data);
    icmp[0] = 0;
    icmp[2] = 0;
    icmp[3] = 0;
    const icmp_checksum = calculate_checksum(icmp[0..request_data.len]);
    icmp[2] = @truncate(icmp_checksum >> 8);
    icmp[3] = @truncate(icmp_checksum);

    e1000.send_packet(packet);
}

fn calculate_checksum(data: []u8) u16 {
    var sum: u32 = 0;
    var ci: usize = 0;
    while (ci + 1 < data.len) : (ci += 2) {
        sum += (@as(u32, data[ci]) << 8) | data[ci + 1];
    }
    if (data.len % 2 != 0) {
        sum += @as(u32, data[data.len - 1]) << 8;
    }
    while (sum > 0xFFFF) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    return @truncate(~sum);
}
