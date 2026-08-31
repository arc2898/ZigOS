// xHCI (USB 3.0 / USB 2.0 / USB 1.1) Host Controller Driver for ZigOS.
// Compliant with xHCI Specification Revision 1.2.
// Supports root hub port enumeration, device slot management, USB control transfers,
// USB HID Keyboard & Mouse (Boot Protocol), and USB Mass Storage detection.

const std = @import("std");
const types = @import("../shared/types.zig");
const pmem = @import("../mm/physical.zig");
const pci = @import("pci.zig");
const serial = @import("serial.zig");
const vmm = @import("../mm/virtual.zig");
const hid = @import("hid.zig");

// --- xHCI Capability & Operational Register Layout ---

pub const XhciCapRegs = extern struct {
    cap_length: u8,
    reserved0: u8,
    hci_version: u16,
    hcs_params1: u32,
    hcs_params2: u32,
    hcs_params3: u32,
    hcc_params1: u32,
    doorbell_offset: u32,
    rts_offset: u32,
    hcc_params2: u32,
};

// Operational Register Offsets (relative to controller_base + cap_length)
const OP_USBCMD: usize = 0x00;
const OP_USBSTS: usize = 0x04;
const OP_PAGESIZE: usize = 0x08;
const OP_DNCTRL: usize = 0x14;
const OP_CRCR_LO: usize = 0x18;
const OP_CRCR_HI: usize = 0x1C;
const OP_DCBAAP_LO: usize = 0x30;
const OP_DCBAAP_HI: usize = 0x34;
const OP_CONFIG: usize = 0x38;

// USBCMD Flags
const CMD_RUN: u32 = 1 << 0;
const CMD_RESET: u32 = 1 << 1;
const CMD_INTE: u32 = 1 << 2;

// USBSTS Flags
const STS_HCH: u32 = 1 << 0;
const STS_CNR: u32 = 1 << 11;

// --- TRB (Transfer Request Block) Structures ---

pub const Trb = extern struct {
    data: u64,
    status: u32,
    control: u32,
};

// TRB Types
pub const TRB_NORMAL: u32 = 1;
pub const TRB_SETUP: u32 = 2;
pub const TRB_DATA: u32 = 3;
pub const TRB_STATUS: u32 = 4;
pub const TRB_LINK: u32 = 6;
pub const TRB_ENABLE_SLOT: u32 = 9;
pub const TRB_DISABLE_SLOT: u32 = 10;
pub const TRB_ADDRESS_DEVICE: u32 = 11;
pub const TRB_CONFIG_EP: u32 = 12;
pub const TRB_EVALUATE_CTX: u32 = 13;
pub const TRB_RESET_EP: u32 = 14;
pub const TRB_STOP_EP: u32 = 15;
pub const TRB_SET_TR_DEQUEUE: u32 = 16;
pub const TRB_RESET_DEV: u32 = 17;
pub const TRB_TRANSFER_EVENT: u32 = 32;
pub const TRB_CMD_COMPLETION: u32 = 33;
pub const TRB_PORT_STATUS_CHANGE: u32 = 34;

// --- Ring Buffers (Command, Event, and Transfer Rings) ---

pub const Ring = struct {
    phys: u64,
    virt: [*]volatile Trb,
    enqueue_idx: u32,
    cycle: u32,
    size: u32,

    pub fn init(size: u32) Ring {
        const frames_needed = (size * @sizeOf(Trb) + 4095) / 4096;
        const phys = pmem.alloc_frames(@max(1, frames_needed));
        if (phys == 0) return Ring{ .phys = 0, .virt = undefined, .enqueue_idx = 0, .cycle = 0, .size = 0 };
        const virt = @as([*]volatile Trb, @ptrFromInt(pmem.phys_to_virt(phys)));
        @memset(@as([*]u8, @ptrCast(@volatileCast(virt)))[0 .. size * @sizeOf(Trb)], 0);

        var r = Ring{
            .phys = phys,
            .virt = virt,
            .enqueue_idx = 0,
            .cycle = 1,
            .size = size,
        };

        // Link TRB at the end of the ring (pointing back to start)
        const last_idx = size - 1;
        r.virt[last_idx].data = phys;
        r.virt[last_idx].status = 0;
        r.virt[last_idx].control = (TRB_LINK << 10) | (1 << 1); // Link TRB, TC=1 (Toggle Cycle)
        return r;
    }

    pub fn enqueue(self: *Ring, trb: Trb) void {
        const last_idx = self.size - 1;
        var t = trb;
        t.control = (t.control & ~@as(u32, 1)) | self.cycle;
        self.virt[self.enqueue_idx] = t;
        self.enqueue_idx += 1;

        if (self.enqueue_idx == last_idx) {
            // Update cycle bit on Link TRB and loop around
            self.virt[last_idx].control = (TRB_LINK << 10) | (1 << 1) | self.cycle;
            self.enqueue_idx = 0;
            self.cycle ^= 1;
        }
    }
};

// Event Ring State
pub const EventRing = struct {
    phys: u64,
    virt: [*]volatile Trb,
    dequeue_idx: u32,
    cycle: u32,
    size: u32,
    erst_phys: u64,
};

// --- Device Slot & Endpoint Management ---

pub const SlotState = enum {
    disabled,
    enabled,
    addressed,
    configured,
};

pub const DeviceType = enum {
    unknown,
    keyboard,
    mouse,
    storage,
    hub,
};

pub const DeviceSlot = struct {
    slot_id: u8,
    port_num: u8,
    speed: u8,
    state: SlotState,
    dev_type: DeviceType,
    
    // DMA Buffers
    input_ctx_phys: u64,
    input_ctx_virt: usize,
    output_ctx_phys: u64,
    output_ctx_virt: usize,
    
    // Transfer Rings
    ep0_ring: Ring,
    ep_in_ring: ?Ring,
    ep_in_dci: u8,
    ep_in_buf_phys: u64,
    ep_in_buf_virt: usize,
    
    ep_out_ring: ?Ring,
    ep_out_dci: u8,
};

const MAX_SLOTS = 16;
var slots: [MAX_SLOTS]DeviceSlot = undefined;

// --- Controller Globals ---

var controller_base: usize = 0;
var op_base: usize = 0;
var doorbell_base: usize = 0;
var runtime_base: usize = 0;
var enabled: bool = false;
var port_count: u32 = 0;
var max_slots: u32 = 0;
var context_size_64: bool = false;

var dcbaa_phys: u64 = 0;
var dcbaa_virt: [*]volatile u64 = undefined;

var cmd_ring: Ring = undefined;
var event_ring: EventRing = undefined;

// --- Register Access Helpers ---

fn op_read32(offset: usize) u32 {
    return @as(*volatile u32, @ptrFromInt(op_base + offset)).*;
}

fn op_write32(offset: usize, value: u32) void {
    @as(*volatile u32, @ptrFromInt(op_base + offset)).* = value;
}

fn rt_read32(offset: usize) u32 {
    return @as(*volatile u32, @ptrFromInt(runtime_base + offset)).*;
}

fn rt_write32(offset: usize, value: u32) void {
    @as(*volatile u32, @ptrFromInt(runtime_base + offset)).* = value;
}

fn rt_write64(offset: usize, value: u64) void {
    @as(*volatile u64, @ptrFromInt(runtime_base + offset)).* = value;
}

fn ring_doorbell(target_slot: u8, target_endpoint: u8) void {
    const db = @as(*volatile u32, @ptrFromInt(doorbell_base + @as(usize, target_slot) * 4));
    db.* = target_endpoint;
}

// --- BIOS Handover (xHCI Extended Capabilities) ---

fn xhci_bios_handover(hcc_params1: u32) void {
    var xecp = (hcc_params1 >> 16) << 2;
    if (xecp == 0) return;

    while (xecp != 0) {
        const addr = controller_base + xecp;
        const val = @as(*volatile u32, @ptrFromInt(addr)).*;
        const id = val & 0xFF;
        
        if (id == 1) { // USB Legacy Support Capability
            if ((val & (1 << 16)) != 0) { // BIOS Owned Semaphore
                serial.log("XHCI: BIOS owns controller, claiming OS ownership...\n");
                @as(*volatile u32, @ptrFromInt(addr)).* |= (1 << 24); // OS Owned Semaphore
                
                var timeout: usize = 0;
                while ((@as(*volatile u32, @ptrFromInt(addr)).* & (1 << 16)) != 0 and timeout < 2000) : (timeout += 1) {
                    var spin: usize = 0;
                    while (spin < 1000) : (spin += 1) { asm volatile ("pause"); }
                }
                
                if ((@as(*volatile u32, @ptrFromInt(addr)).* & (1 << 16)) != 0) {
                    serial.log("XHCI: BIOS handover timeout, forcing OS ownership\n");
                    @as(*volatile u32, @ptrFromInt(addr)).* &= ~@as(u32, 1 << 16);
                }
                // Clear SMIs
                @as(*volatile u32, @ptrFromInt(addr + 4)).* = 0;
            }
            break;
        }
        
        const next = (val >> 8) & 0xFF;
        if (next == 0) break;
        xecp += next << 2;
    }
}

// --- Controller Initialization ---

pub fn init() void {
    var xhci_pci: ?*pci.Device = null;
    var i: usize = 0;
    while (i < pci.device_count) : (i += 1) {
        const dev = &pci.devices[i];
        if (dev.class == 0x0C and dev.subclass == 0x03 and dev.prog_if == 0x30) {
            xhci_pci = dev;
            break;
        }
    }

    if (xhci_pci == null) {
        serial.log("XHCI: No xHCI controller found on PCI bus\n");
        return;
    }
    const dev = xhci_pci.?;
    
    pci.enable_bus_mastering(dev);
    const bar0 = pci.read_bar(dev, 0);
    controller_base = vmm.HH_OFFSET + bar0;
    if (!vmm.map_mmio(vmm.kernel_pml4_phys, controller_base, bar0, 0x10000)) {
        serial.log("XHCI: Failed to map MMIO space\n");
        return;
    }

    const cap = @as(*const XhciCapRegs, @ptrFromInt(controller_base));
    op_base = controller_base + @as(usize, cap.cap_length);
    doorbell_base = controller_base + cap.doorbell_offset;
    runtime_base = controller_base + cap.rts_offset;

    serial.log("XHCI: Version ");
    serial.log_hex(cap.hci_version);
    serial.log(" Controller Found at BAR0\n");

    // 1. BIOS Handover
    xhci_bios_handover(cap.hcc_params1);

    // Context size (32 bytes vs 64 bytes)
    context_size_64 = (cap.hcc_params1 & (1 << 2)) != 0;

    // 2. Wait for Controller Ready (CNR=0)
    var timeout: usize = 0;
    while ((op_read32(OP_USBSTS) & STS_CNR) != 0 and timeout < 20000) : (timeout += 1) {
        asm volatile ("pause");
    }

    // 3. Stop Controller if running
    if ((op_read32(OP_USBSTS) & STS_HCH) == 0) {
        op_write32(OP_USBCMD, op_read32(OP_USBCMD) & ~CMD_RUN);
        timeout = 0;
        while ((op_read32(OP_USBSTS) & STS_HCH) == 0 and timeout < 20000) : (timeout += 1) {
            asm volatile ("pause");
        }
    }

    // 4. Reset Controller
    op_write32(OP_USBCMD, CMD_RESET);
    timeout = 0;
    while ((op_read32(OP_USBCMD) & CMD_RESET) != 0 and timeout < 20000) : (timeout += 1) {
        asm volatile ("pause");
    }

    // 5. Setup Page Size (4KB)
    op_write32(OP_PAGESIZE, 1);

    // 6. Setup Max Slots Enabled
    max_slots = cap.hcs_params1 & 0xFF;
    if (max_slots > MAX_SLOTS) max_slots = MAX_SLOTS;
    op_write32(OP_CONFIG, max_slots);

    // 7. Setup DCBAA (Device Context Base Address Array)
    dcbaa_phys = pmem.alloc_frames(1);
    if (dcbaa_phys == 0) return;
    dcbaa_virt = @as([*]volatile u64, @ptrFromInt(pmem.phys_to_virt(dcbaa_phys)));
    @memset(@as([*]u8, @ptrCast(@volatileCast(dcbaa_virt)))[0..4096], 0);

    op_write32(OP_DCBAAP_LO, @truncate(dcbaa_phys));
    op_write32(OP_DCBAAP_HI, @truncate(dcbaa_phys >> 32));

    // 8. Setup Command Ring (256 TRBs)
    cmd_ring = Ring.init(256);
    op_write32(OP_CRCR_LO, @truncate(cmd_ring.phys | 1)); // RCS=1
    op_write32(OP_CRCR_HI, @truncate(cmd_ring.phys >> 32));

    // 9. Setup Event Ring Segment Table (ERST) & Interrupter 0
    const erst_phys = pmem.alloc_frames(1);
    const erst_virt = pmem.phys_to_virt(erst_phys);
    const er_buf_phys = pmem.alloc_frames(1);
    const er_buf_virt = pmem.phys_to_virt(er_buf_phys);

    @memset(@as([*]u8, @ptrFromInt(erst_virt))[0..4096], 0);
    @memset(@as([*]u8, @ptrFromInt(er_buf_virt))[0..4096], 0);

    const erst_entry = @as([*]volatile u64, @ptrFromInt(erst_virt));
    erst_entry[0] = er_buf_phys; // Ring Segment Base Address
    erst_entry[1] = 256;         // Ring Segment Size

    event_ring = EventRing{
        .phys = er_buf_phys,
        .virt = @as([*]volatile Trb, @ptrFromInt(er_buf_virt)),
        .dequeue_idx = 0,
        .cycle = 1,
        .size = 256,
        .erst_phys = erst_phys,
    };

    const ir0_offset = 0x20; // Interrupter 0 Register Set
    rt_write32(ir0_offset + 0x00, 0); // Disable interrupter moderation
    rt_write32(ir0_offset + 0x08, 1); // ERSTSZ = 1
    rt_write64(ir0_offset + 0x10, erst_phys); // ERSTBA
    rt_write64(ir0_offset + 0x18, er_buf_phys | (1 << 3)); // ERDP (EHB=1)

    // 10. Start Controller
    op_write32(OP_USBCMD, CMD_RUN | CMD_INTE);
    timeout = 0;
    while ((op_read32(OP_USBSTS) & STS_HCH) != 0 and timeout < 20000) : (timeout += 1) {
        asm volatile ("pause");
    }

    port_count = (cap.hcs_params1 >> 24) & 0xFF;
    enabled = true;

    for (0..MAX_SLOTS) |s| {
        slots[s].state = .disabled;
        slots[s].slot_id = 0;
    }

    serial.log("XHCI: Controller successfully started with ");
    serial.log_dec(port_count);
    serial.log(" root ports\n");

    // 11. Enumerate Ports and Connected Devices
    scan_ports();
}

pub fn init_module(sender: u32) bool {
    _ = sender;
    init();
    return enabled;
}

// --- Synchronous Command Execution ---

pub fn send_command(trb: Trb) ?Trb {
    if (!enabled) return null;

    cmd_ring.enqueue(trb);
    ring_doorbell(0, 0); // Ring Host Controller Doorbell for Command Ring

    // Poll Event Ring for Command Completion Event
    var timeout: usize = 0;
    while (timeout < 50000) : (timeout += 1) {
        const ev = poll_event_ring();
        if (ev) |event| {
            const trb_type = (event.control >> 10) & 0x3F;
            if (trb_type == TRB_CMD_COMPLETION) {
                return event;
            }
        }
        var spin: usize = 0;
        while (spin < 500) : (spin += 1) { asm volatile ("pause"); }
    }
    return null;
}

pub fn poll_event_ring() ?Trb {
    const cur_trb = event_ring.virt[event_ring.dequeue_idx];
    const trb_cycle = cur_trb.control & 1;

    if (trb_cycle != event_ring.cycle) {
        return null; // No new event
    }

    const event = cur_trb;
    event_ring.dequeue_idx += 1;
    if (event_ring.dequeue_idx >= event_ring.size) {
        event_ring.dequeue_idx = 0;
        event_ring.cycle ^= 1;
    }

    // Update ERDP in Interrupter 0
    const erdp = event_ring.phys + event_ring.dequeue_idx * @sizeOf(Trb);
    rt_write64(0x20 + 0x18, erdp | (1 << 3)); // EHB = 1

    return event;
}

// --- Root Port Enumeration & Reset ---

pub fn scan_ports() void {
    if (!enabled) return;
    const cap = @as(*const XhciCapRegs, @ptrFromInt(controller_base));
    const port_base = @as(usize, cap.cap_length) + 0x400;

    var p: u32 = 0;
    while (p < port_count) : (p += 1) {
        const port_reg = @as(*volatile u32, @ptrFromInt(controller_base + port_base + @as(usize, p) * 16));

        // 1. Ensure Port Power (PP) is enabled
        if ((port_reg.* & (1 << 9)) == 0) {
            port_reg.* |= (1 << 9);
            var timeout: usize = 0;
            while ((port_reg.* & (1 << 9)) == 0 and timeout < 1000) : (timeout += 1) {
                asm volatile ("pause");
            }
        }

        const status = port_reg.*;
        // CCS: Current Connect Status (bit 0)
        if ((status & 1) != 0) {
            // 2. Issue Port Reset (PR)
            port_reg.* = (status & 0xFFFF0000) | (1 << 4);
            var reset_timeout: usize = 0;
            while ((port_reg.* & (1 << 4)) != 0 and reset_timeout < 20000) : (reset_timeout += 1) {
                asm volatile ("pause");
            }

            // Clear Port Reset Change (PRC)
            port_reg.* = (port_reg.* & 0xFFFF0000) | (1 << 17);

            const post_status = port_reg.*;
            const speed = (post_status >> 10) & 0x0F;

            serial.log("XHCI: Port ");
            serial.log_dec(p + 1);
            serial.log(" connected - Speed: ");
            switch (speed) {
                1 => serial.log("Full-Speed (USB 1.1)\n"),
                2 => serial.log("Low-Speed (USB 1.0)\n"),
                3 => serial.log("High-Speed (USB 2.0)\n"),
                4 => serial.log("SuperSpeed (USB 3.0)\n"),
                else => serial.log("Unknown Speed\n"),
            }

            // 3. Initialize Connected USB Device
            init_device_on_port(@intCast(p + 1), @truncate(speed));
        }
    }
}

// --- USB Device Initialization & Slot Configuration ---

fn init_device_on_port(port_num: u8, speed: u8) void {
    // 1. Send Enable Slot Command
    const enable_trb = Trb{
        .data = 0,
        .status = 0,
        .control = (TRB_ENABLE_SLOT << 10),
    };

    const completion = send_command(enable_trb) orelse {
        serial.log("XHCI: Enable Slot command failed on port ");
        serial.log_dec(port_num);
        serial.log("\n");
        return;
    };

    const slot_id = @as(u8, @truncate(completion.control >> 24));
    if (slot_id == 0 or slot_id > MAX_SLOTS) {
        serial.log("XHCI: Invalid Slot ID returned\n");
        return;
    }

    serial.log("XHCI: Allocated Slot ID ");
    serial.log_dec(slot_id);
    serial.log(" for Port ");
    serial.log_dec(port_num);
    serial.log("\n");

    var slot = &slots[slot_id - 1];
    slot.slot_id = slot_id;
    slot.port_num = port_num;
    slot.speed = speed;
    slot.state = .enabled;
    slot.dev_type = .unknown;
    slot.ep_in_ring = null;
    slot.ep_out_ring = null;

    // 2. Allocate Output Device Context & register with DCBAA
    const out_ctx_phys = pmem.alloc_frames(1);
    if (out_ctx_phys == 0) return;
    const out_ctx_virt = pmem.phys_to_virt(out_ctx_phys);
    @memset(@as([*]u8, @ptrFromInt(out_ctx_virt))[0..4096], 0);

    slot.output_ctx_phys = out_ctx_phys;
    slot.output_ctx_virt = out_ctx_virt;
    dcbaa_virt[slot_id] = out_ctx_phys;

    // 3. Allocate Input Context
    const in_ctx_phys = pmem.alloc_frames(1);
    if (in_ctx_phys == 0) return;
    const in_ctx_virt = pmem.phys_to_virt(in_ctx_phys);
    @memset(@as([*]u8, @ptrFromInt(in_ctx_virt))[0..4096], 0);

    slot.input_ctx_phys = in_ctx_phys;
    slot.input_ctx_virt = in_ctx_virt;

    // 4. Allocate Endpoint 0 Transfer Ring
    slot.ep0_ring = Ring.init(64);

    // Setup Input Control Context (Input Context offset 0)
    const in_ctrl = @as([*]volatile u32, @ptrFromInt(in_ctx_virt));
    in_ctrl[0] = 0;        // Drop flags
    in_ctrl[1] = (1 << 0) | (1 << 1); // Add flags: Add Slot Context (bit 0) & EP0 Context (bit 1)

    // Setup Slot Context (Input Context offset 32 / 64)
    const ctx_step: usize = if (context_size_64) 64 else 32;
    const in_slot = @as([*]volatile u32, @ptrFromInt(in_ctx_virt + ctx_step));
    const context_entries: u32 = 1; // Only EP0 initially
    in_slot[0] = (context_entries << 27) | (@as(u32, speed) << 20); // Route String=0, Speed, Context Entries=1
    in_slot[1] = @as(u32, port_num) << 16; // Root Hub Port Number

    // Setup Endpoint 0 Context (Input Context offset 64 / 128)
    const in_ep0 = @as([*]volatile u32, @ptrFromInt(in_ctx_virt + ctx_step * 2));
    const max_packet_size: u32 = switch (speed) {
        4 => 512, // SuperSpeed
        3 => 64,  // HighSpeed
        1 => 64,  // FullSpeed
        else => 8, // LowSpeed
    };

    in_ep0[1] = (3 << 1) | (4 << 3) | (max_packet_size << 16); // CErr=3, EP Type=Control (4), MaxPacketSize
    in_ep0[2] = @truncate(slot.ep0_ring.phys | 1); // TR Dequeue Pointer Lo | DCS=1
    in_ep0[3] = @truncate(slot.ep0_ring.phys >> 32);
    in_ep0[4] = 8; // Average TRB Length = 8

    // 5. Send Address Device Command TRB
    const addr_trb = Trb{
        .data = in_ctx_phys,
        .status = 0,
        .control = (TRB_ADDRESS_DEVICE << 10) | (@as(u32, slot_id) << 24),
    };

    const addr_completion = send_command(addr_trb) orelse {
        serial.log("XHCI: Address Device command failed on Slot ");
        serial.log_dec(slot_id);
        serial.log("\n");
        return;
    };

    const completion_code = (addr_completion.status >> 24) & 0xFF;
    if (completion_code != 1) { // 1 = Success
        serial.log("XHCI: Address Device returned error code: ");
        serial.log_dec(completion_code);
        serial.log("\n");
        return;
    }

    slot.state = .addressed;
    serial.log("XHCI: Slot ");
    serial.log_dec(slot_id);
    serial.log(" successfully ADDRESSED! Probing USB descriptors...\n");

    // 6. Query USB Device Descriptors & Configure Device
    probe_and_configure_device(slot);
}

// --- USB Control Transfers & Descriptors ---

pub fn control_transfer(
    slot: *DeviceSlot,
    bmRequestType: u8,
    bRequest: u8,
    wValue: u16,
    wIndex: u16,
    wLength: u16,
    data_phys: u64,
) bool {
    // 1. Setup Stage TRB
    const setup_packet: u64 = @as(u64, bmRequestType) |
        (@as(u64, bRequest) << 8) |
        (@as(u64, wValue) << 16) |
        (@as(u64, wIndex) << 32) |
        (@as(u64, wLength) << 48);

    const trt: u32 = if (wLength == 0) 0 else if ((bmRequestType & 0x80) != 0) 3 else 2; // TRT: 0=No Data, 2=Out, 3=In

    const setup_trb = Trb{
        .data = setup_packet,
        .status = 8, // Length of setup packet is always 8 bytes
        .control = (TRB_SETUP << 10) | (trt << 6) | (1 << 6), // IDT (Immediate Data) = 1
    };
    slot.ep0_ring.enqueue(setup_trb);

    // 2. Data Stage TRB (if data payload exists)
    if (wLength > 0) {
        const dir: u32 = if ((bmRequestType & 0x80) != 0) 1 else 0; // 1 = IN, 0 = OUT
        const data_trb = Trb{
            .data = data_phys,
            .status = wLength,
            .control = (TRB_DATA << 10) | (dir << 16),
        };
        slot.ep0_ring.enqueue(data_trb);
    }

    // 3. Status Stage TRB (IOC=1, Direction opposite of Data stage)
    const status_dir: u32 = if (wLength == 0 or (bmRequestType & 0x80) == 0) 1 else 0;
    const status_trb = Trb{
        .data = 0,
        .status = 0,
        .control = (TRB_STATUS << 10) | (1 << 5) | (status_dir << 16), // IOC = 1
    };
    slot.ep0_ring.enqueue(status_trb);

    // 4. Ring Doorbell for EP0 (Target = 1)
    ring_doorbell(slot.slot_id, 1);

    // 5. Wait for Transfer Event
    var timeout: usize = 0;
    while (timeout < 50000) : (timeout += 1) {
        const ev = poll_event_ring();
        if (ev) |event| {
            const trb_type = (event.control >> 10) & 0x3F;
            if (trb_type == TRB_TRANSFER_EVENT) {
                const comp = (event.status >> 24) & 0xFF;
                return comp == 1 or comp == 13; // 1 = Success, 13 = Short Packet (valid in USB)
            }
        }
        var spin: usize = 0;
        while (spin < 500) : (spin += 1) { asm volatile ("pause"); }
    }
    return false;
}

// --- USB Device Probing & Configuration ---

fn probe_and_configure_device(slot: *DeviceSlot) void {
    const buf_phys = pmem.alloc_frames(1);
    if (buf_phys == 0) return;
    const buf_virt = pmem.phys_to_virt(buf_phys);
    const buf = @as([*]u8, @ptrFromInt(buf_virt));
    @memset(buf[0..4096], 0);

    // 1. GET_DESCRIPTOR (Device Descriptor: 18 bytes)
    // bmRequestType: 0x80 (Device-to-Host, Standard, Device)
    // bRequest: 6 (GET_DESCRIPTOR), wValue: 0x0100 (Device), wIndex: 0, wLength: 18
    if (!control_transfer(slot, 0x80, 6, 0x0100, 0, 18, buf_phys)) {
        serial.log("XHCI: Failed to retrieve Device Descriptor on Slot ");
        serial.log_dec(slot.slot_id);
        serial.log("\n");
        return;
    }

    const vid = @as(u16, buf[8]) | (@as(u16, buf[9]) << 8);
    const pid = @as(u16, buf[10]) | (@as(u16, buf[11]) << 8);
    const dev_class = buf[4];

    serial.log("XHCI: Device on Slot ");
    serial.log_dec(slot.slot_id);
    serial.log(" - VID: ");
    serial.log_hex(vid);
    serial.log(" PID: ");
    serial.log_hex(pid);
    serial.log(" Class: ");
    serial.log_hex(dev_class);
    serial.log("\n");

    // 2. GET_DESCRIPTOR (Configuration Descriptor: first 9 bytes to read total length)
    @memset(buf[0..4096], 0);
    if (!control_transfer(slot, 0x80, 6, 0x0200, 0, 9, buf_phys)) {
        serial.log("XHCI: Failed to read Configuration Descriptor header\n");
        return;
    }

    const total_length = @as(u16, buf[2]) | (@as(u16, buf[3]) << 8);
    const fetch_len = @min(@as(u16, 512), total_length);

    // Read full Configuration Descriptor tree
    @memset(buf[0..4096], 0);
    if (!control_transfer(slot, 0x80, 6, 0x0200, 0, fetch_len, buf_phys)) {
        serial.log("XHCI: Failed to read full Configuration Descriptor tree\n");
        return;
    }

    // Parse Interface and Endpoint Descriptors
    var offset: usize = 0;
    var if_class: u8 = 0;
    var if_subclass: u8 = 0;
    var if_protocol: u8 = 0;
    var ep_in_addr: u8 = 0;
    var ep_in_interval: u8 = 0;
    var ep_in_max_packet: u16 = 0;

    while (offset + 2 <= fetch_len) {
        const desc_len = buf[offset];
        const desc_type = buf[offset + 1];
        if (desc_len == 0) break;

        if (desc_type == 4) { // INTERFACE Descriptor
            if_class = buf[offset + 5];
            if_subclass = buf[offset + 6];
            if_protocol = buf[offset + 7];
        } else if (desc_type == 5) { // ENDPOINT Descriptor
            const ep_addr = buf[offset + 2];
            const ep_attr = buf[offset + 3];
            const ep_max = @as(u16, buf[offset + 4]) | (@as(u16, buf[offset + 5]) << 8);
            const ep_int = buf[offset + 6];

            if ((ep_addr & 0x80) != 0 and (ep_attr & 3) == 3) { // Interrupt IN Endpoint
                ep_in_addr = ep_addr;
                ep_in_interval = ep_int;
                ep_in_max_packet = ep_max;
            }
        }
        offset += desc_len;
    }

    // 3. Classify and Configure Device
    if (if_class == 3) { // HID Class
        if (if_protocol == 1 or if_subclass == 1) {
            slot.dev_type = .keyboard;
            serial.log("XHCI: Configured USB HID KEYBOARD on Slot ");
            serial.log_dec(slot.slot_id);
            serial.log("\n");
        } else if (if_protocol == 2) {
            slot.dev_type = .mouse;
            serial.log("XHCI: Configured USB HID MOUSE on Slot ");
            serial.log_dec(slot.slot_id);
            serial.log("\n");
        } else {
            slot.dev_type = .keyboard; // Generic HID input
            serial.log("XHCI: Configured USB HID Composite Input on Slot ");
            serial.log_dec(slot.slot_id);
            serial.log("\n");
        }

        // Configure Interrupt IN Endpoint if found
        if (ep_in_addr != 0) {
            configure_hid_endpoint(slot, ep_in_addr, ep_in_interval, ep_in_max_packet);
        }
    } else if (if_class == 8) { // Mass Storage (USB Flash Drive)
        slot.dev_type = .storage;
        serial.log("XHCI: Detected USB Mass Storage Drive on Slot ");
        serial.log_dec(slot.slot_id);
        serial.log("\n");
    }

    // 4. SET_CONFIGURATION (Config 1)
    _ = control_transfer(slot, 0x00, 9, 1, 0, 0, 0);

    // 5. If HID, send SET_PROTOCOL (0 = Boot Protocol) and SET_IDLE (0)
    if (slot.dev_type == .keyboard or slot.dev_type == .mouse) {
        _ = control_transfer(slot, 0x21, 0x0A, 0, 0, 0, 0); // SET_IDLE (0)
        _ = control_transfer(slot, 0x21, 0x0B, 0, 0, 0, 0); // SET_PROTOCOL (Boot Protocol)
    }

    slot.state = .configured;
}

// --- HID Endpoint Configuration & Polling ---

fn configure_hid_endpoint(slot: *DeviceSlot, ep_addr: u8, interval: u8, max_packet: u16) void {
    const ep_num = ep_addr & 0x0F;
    const is_in = (ep_addr & 0x80) != 0;
    const dci = @as(u8, @intCast((ep_num * 2) + (if (is_in) @as(usize, 1) else 0)));

    slot.ep_in_dci = dci;
    slot.ep_in_ring = Ring.init(64);

    // Setup Input Context for Configure Endpoint Command
    const ctx_step: usize = if (context_size_64) 64 else 32;
    const in_ctrl = @as([*]volatile u32, @ptrFromInt(slot.input_ctx_virt));
    in_ctrl[0] = 0; // Drop flags
    in_ctrl[1] = (1 << 0) | (@as(u32, 1) << @as(u5, @truncate(dci))); // Add Slot Context + Target Endpoint Context

    // Update Slot Context: Context Entries = max(dci, old)
    const in_slot = @as([*]volatile u32, @ptrFromInt(slot.input_ctx_virt + ctx_step));
    in_slot[0] = (@as(u32, dci) << 27) | (@as(u32, slot.speed) << 20);

    // Setup Target Endpoint Context (offset: ctx_step * (dci + 1))
    const in_ep = @as([*]volatile u32, @ptrFromInt(slot.input_ctx_virt + ctx_step * (dci + 1)));
    const interval_val: u32 = if (interval > 0) interval else 1;
    const max_pkt: u32 = if (max_packet > 0) max_packet else 8;

    in_ep[0] = (interval_val << 16); // Interval
    in_ep[1] = (3 << 1) | (7 << 3) | (max_pkt << 16); // CErr=3, EP Type=Interrupt IN (7), MaxPacketSize
    in_ep[2] = @truncate(slot.ep_in_ring.?.phys | 1); // TR Dequeue Pointer Lo | DCS=1
    in_ep[3] = @truncate(slot.ep_in_ring.?.phys >> 32);
    in_ep[4] = 8; // Average TRB Length

    // Send Configure Endpoint Command TRB
    const config_trb = Trb{
        .data = slot.input_ctx_phys,
        .status = 0,
        .control = (TRB_CONFIG_EP << 10) | (@as(u32, slot.slot_id) << 24),
    };

    _ = send_command(config_trb);

    // Allocate DMA receive buffer for input reports
    const report_buf_phys = pmem.alloc_frames(1);
    if (report_buf_phys == 0) return;
    const report_buf_virt = pmem.phys_to_virt(report_buf_phys);
    @memset(@as([*]u8, @ptrFromInt(report_buf_virt))[0..4096], 0);

    slot.ep_in_buf_phys = report_buf_phys;
    slot.ep_in_buf_virt = report_buf_virt;

    // Queue first Normal TRB to start listening for hardware input
    queue_input_trb(slot);
}

fn queue_input_trb(slot: *DeviceSlot) void {
    if (slot.ep_in_ring == null) return;

    const normal_trb = Trb{
        .data = slot.ep_in_buf_phys,
        .status = 8, // 8 bytes report buffer
        .control = (TRB_NORMAL << 10) | (1 << 5) | (1 << 1), // IOC = 1, ISP = 1 (Interrupt on Short Packet)
    };
    slot.ep_in_ring.?.enqueue(normal_trb);
    ring_doorbell(slot.slot_id, slot.ep_in_dci);
}

// --- Continuous Event & Input Processing Loop ---

pub fn poll() void {
    if (!enabled) return;

    while (true) {
        const ev = poll_event_ring() orelse break;
        const trb_type = (ev.control >> 10) & 0x3F;

        if (trb_type == TRB_TRANSFER_EVENT) {
            const slot_id = @as(u8, @truncate(ev.control >> 24));
            if (slot_id > 0 and slot_id <= MAX_SLOTS) {
                const slot = &slots[slot_id - 1];
                if (slot.state == .configured and slot.ep_in_buf_virt != 0) {
                    const report_data = @as([*]const u8, @ptrFromInt(slot.ep_in_buf_virt))[0..8];

                    if (slot.dev_type == .keyboard) {
                        hid.handle_keyboard_report(report_data);
                    } else if (slot.dev_type == .mouse) {
                        hid.handle_mouse_report(report_data);
                    }

                    // Re-queue TRB to continuously receive next keystroke / mouse movement
                    queue_input_trb(slot);
                }
            }
        }
    }
}

