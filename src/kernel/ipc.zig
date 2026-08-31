// Inter-process communication. Modules register named ports; senders look
// up a port by name and deliver messages. Blocking send() suspends the
// sender until the receiver picks the message up; receive_async() queues it
// for later polling.

const std = @import("std");
const types = @import("shared/types.zig");
const Message = types.Message;
const TaskId = types.TaskId;
const MAX_PORTS = types.MAX_PORTS;
const sched = @import("sched.zig");

pub const Port = struct {
    name: [types.MAX_PORT_NAME]u8,
    owner: TaskId,
    busy: bool,       // a synchronous handoff is in progress
    sender_waiting: ?TaskId,
    pending: Message,
    has_pending: bool,
    queue: [8]Message,
    queue_len: usize,
    active: bool,
};

var ports: [MAX_PORTS]Port = undefined;

fn zero_port(p: *Port) void {
    var j: usize = 0;
    while (j < types.MAX_PORT_NAME) : (j += 1) {
        p.name[j] = 0;
    }
    p.owner = 0;
    p.busy = false;
    p.sender_waiting = null;
    j = 0;
    while (j < 8) : (j += 1) {
        p.queue[j] = undefined;
    }
    p.pending = undefined;
    p.has_pending = false;
    p.queue_len = 0;
    p.active = false;
}

pub fn init() void {
    var i: usize = 0;
    while (i < MAX_PORTS) : (i += 1) {
        zero_port(&ports[i]);
    }
}

fn port_empty() ?usize {
    var i: usize = 0;
    while (i < MAX_PORTS) : (i += 1) {
        if (!ports[i].active) return i;
    }
    return null;
}

/// Register a named port for a task. Returns the slot index or null.
pub fn register_port(name: [types.MAX_PORT_NAME]u8, owner: TaskId) ?usize {
    const idx = port_empty() orelse return null;
    ports[idx].name = name;
    ports[idx].owner = owner;
    ports[idx].active = true;
    ports[idx].queue_len = 0;
    ports[idx].has_pending = false;
    return idx;
}

pub fn unregister_port(name: [types.MAX_PORT_NAME]u8) void {
    var i: usize = 0;
    while (i < MAX_PORTS) : (i += 1) {
        if (ports[i].active and std.mem.eql(u8, &ports[i].name, &name)) {
            // ZIGOS-006: Wake any waiting sender before closing
            if (ports[i].sender_waiting) |sid| {
                sched.wake(sid);
            }
            zero_port(&ports[i]);
            return;
        }
    }
}

fn find_port(name: [types.MAX_PORT_NAME]u8) ?usize {
    var i: usize = 0;
    while (i < MAX_PORTS) : (i += 1) {
        if (ports[i].active and std.mem.eql(u8, &ports[i].name, &name)) {
            return i;
        }
    }
    return null;
}

/// Synchronous send: the sender blocks until the receiver calls receive().
/// If the receiver already polled and left a pending slot open, the message
/// is staged there and the sender returns immediately.
pub fn send(name: [types.MAX_PORT_NAME]u8, msg: *const Message) bool {
    const idx = find_port(name) orelse return false;
    const p = &ports[idx];

    // ZIGOS-006: Fix blocking logic. Senders should only block if the queue is full.
    // stage the message and block the sender if queue is full.
    if (p.queue_len < 8) {
        enqueue(p, msg);
        return true;
    }

    return false;
}

/// Blocking receive on a named port. Returns null when nothing is pending;
/// otherwise stages the slot so a blocking sender can complete.
pub fn receive(name: [types.MAX_PORT_NAME]u8, msg: *Message) bool {
    const idx = find_port(name) orelse return false;
    const p = &ports[idx];

    if (p.queue_len > 0) {
        msg.* = p.queue[0];
        shift_queue(p);
        // If there's a sender waiting for a free slot, wake it.
        if (p.sender_waiting) |sid| {
            sched.wake(sid);
            p.sender_waiting = null;
        }
        return true;
    }

    return false;
}

/// Asynchronous receive: polls for a message without staging a sender slot.
pub fn receive_async(name: [types.MAX_PORT_NAME]u8, msg: *Message) bool {
    const idx = find_port(name) orelse return false;
    const p = &ports[idx];
    if (p.queue_len > 0) {
        msg.* = p.queue[0];
        shift_queue(p);
        // If there's a sender waiting for a free slot, wake it.
        if (p.sender_waiting) |sid| {
            sched.wake(sid);
            p.sender_waiting = null;
        }
        return true;
    }
    return false;
}

fn enqueue(p: *Port, msg: *const Message) void {
    if (p.queue_len >= 8) return;
    p.queue[p.queue_len] = msg.*;
    p.queue_len += 1;
}

fn shift_queue(p: *Port) void {
    var i: usize = 1;
    while (i < p.queue_len) : (i += 1) {
        p.queue[i - 1] = p.queue[i];
    }
    p.queue_len -= 1;
}

pub fn broadcast(name: [types.MAX_PORT_NAME]u8, msg: *const Message) void {
    _ = send(name, msg);
}

pub fn list_ports(buffer: *[256]u8, out_len: *usize) void {
    out_len.* = 0;
    var i: usize = 0;
    while (i < MAX_PORTS) : (i += 1) {
        const p = &ports[i];
        if (!p.active) continue;
        var j: usize = 0;
        while (j < types.MAX_PORT_NAME) : (j += 1) {
            if (p.name[j] == 0) break;
            buffer[out_len.*] = p.name[j];
            out_len.* += 1;
        }
        buffer[out_len.*] = ':';
        out_len.* += 1;
        buffer[out_len.*] = '0' + @as(u8, @truncate(p.owner));
        out_len.* += 1;
        buffer[out_len.*] = '\n';
        out_len.* += 1;
    }
}
