#!/usr/bin/env python3
"""
Standalone builder for ZigOS EFI System Partition (ESP), GPT disk image, and UEFI bootable ISO.
Pure Python - creates valid FAT32 (for USB/Disk) and FAT16 (for El Torito ISO).
"""

import os
import sys
import struct
import shutil
import hashlib
import binascii

def align_up(val, align):
    return (val + align - 1) & ~(align - 1)

def create_fat16_image(size_mb, files_dict):
    total_bytes = size_mb * 1024 * 1024
    sector_size = 512
    total_sectors = total_bytes // sector_size
    sectors_per_cluster = 4 # 2KB clusters
    cluster_size = sectors_per_cluster * sector_size
    reserved_sectors = 1
    num_fats = 2
    root_entries = 512
    root_dir_sectors = (root_entries * 32 + sector_size - 1) // sector_size

    data_sectors = total_sectors - (reserved_sectors + root_dir_sectors)
    total_clusters = data_sectors // sectors_per_cluster
    fat_size_bytes = (total_clusters + 2) * 2
    sectors_per_fat = (fat_size_bytes + sector_size - 1) // sector_size

    data_start_sector = reserved_sectors + (num_fats * sectors_per_fat) + root_dir_sectors
    disk = bytearray(total_bytes)

    bpb = bytearray(sector_size)
    bpb[0:3] = b"\xeb<\x90"
    bpb[3:11] = b"MSWIN4.1"
    struct.pack_into("<H", bpb, 11, sector_size)
    bpb[13] = sectors_per_cluster
    struct.pack_into("<H", bpb, 14, reserved_sectors)
    bpb[16] = num_fats
    struct.pack_into("<H", bpb, 17, root_entries)
    struct.pack_into("<H", bpb, 19, total_sectors)
    bpb[21] = 0xF8
    struct.pack_into("<H", bpb, 22, sectors_per_fat)
    struct.pack_into("<H", bpb, 24, 63)
    struct.pack_into("<H", bpb, 26, 255)
    struct.pack_into("<I", bpb, 28, 0)
    bpb[36] = 0x80
    bpb[38] = 0x29
    struct.pack_into("<I", bpb, 39, 0x12345678)
    bpb[43:54] = b"ZIGOS_ESP  "
    bpb[54:62] = b"FAT16   "
    bpb[510] = 0x55
    bpb[511] = 0xAA
    disk[0:sector_size] = bpb

    fat = bytearray(sectors_per_fat * sector_size)
    fat[0] = 0xF8
    fat[1] = 0xFF
    fat[2] = 0xFF
    fat[3] = 0xFF

    allocated_clusters = 2
    def alloc_cluster_chain(data_bytes):
        nonlocal allocated_clusters
        if len(data_bytes) == 0:
            return 0
        num_c = (len(data_bytes) + cluster_size - 1) // cluster_size
        start_cluster = allocated_clusters
        for i in range(num_c):
            c = start_cluster + i
            c_offset = (data_start_sector + (c - 2) * sectors_per_cluster) * sector_size
            chunk = data_bytes[i * cluster_size : (i + 1) * cluster_size]
            disk[c_offset : c_offset + len(chunk)] = chunk
            if i == num_c - 1:
                next_c = 0xFFFF
            else:
                next_c = c + 1
            struct.pack_into("<H", fat, c * 2, next_c)
        allocated_clusters += num_c
        return start_cluster

    dirs = {"": bytearray(root_entries * 32)}
    dir_files = {"": []}

    for path, content in files_dict.items():
        parts = [p for p in path.replace("\\", "/").strip("/").split("/") if p]
        dir_path = ""
        for p in parts[:-1]:
            parent = dir_path
            dir_path = (dir_path + "/" + p).strip("/")
            if dir_path not in dirs:
                dirs[dir_path] = bytearray(cluster_size)
                dir_files[dir_path] = []
                dir_files[parent].append((p, True, dir_path))
        filename = parts[-1]
        dir_files[dir_path].append((filename, False, content))

    def make_83_name(name):
        if "." in name:
            base, ext = name.rsplit(".", 1)
        else:
            base, ext = name, ""
        base = base.upper().replace(" ", "_")[:8]
        ext = ext.upper().replace(" ", "_")[:3]
        return f"{base:<8}{ext:<3}".encode("ascii")

    dir_clusters = {"": 0}
    def preassign_dir_clusters(dir_p):
        nonlocal allocated_clusters
        for item_name, is_dir, target in dir_files[dir_p]:
            if is_dir:
                c = allocated_clusters
                allocated_clusters += 1
                dir_clusters[target] = c
                struct.pack_into("<H", fat, c * 2, 0xFFFF)
                preassign_dir_clusters(target)

    preassign_dir_clusters("")

    def process_dir(dir_p, is_root=False):
        entries_buf = dirs[dir_p]
        my_c = dir_clusters[dir_p]
        entry_idx = 0
        if not is_root:
            parent_p = dir_p.rsplit("/", 1)[0] if "/" in dir_p else ""
            parent_c = dir_clusters[parent_p]
            e = bytearray(32)
            e[0:11] = b".          "
            e[11] = 0x10
            struct.pack_into("<H", e, 26, my_c & 0xFFFF)
            entries_buf[0:32] = e

            e2 = bytearray(32)
            e2[0:11] = b"..         "
            e2[11] = 0x10
            struct.pack_into("<H", e2, 26, parent_c & 0xFFFF)
            entries_buf[32:64] = e2
            entry_idx = 2

        for item_name, is_dir, target in dir_files[dir_p]:
            if is_dir:
                sub_c = dir_clusters[target]
                process_dir(target, False)
                e = bytearray(32)
                e[0:11] = make_83_name(item_name)
                e[11] = 0x10
                struct.pack_into("<H", e, 26, sub_c & 0xFFFF)
                entries_buf[entry_idx * 32 : (entry_idx + 1) * 32] = e
            else:
                cluster = alloc_cluster_chain(target)
                e = bytearray(32)
                e[0:11] = make_83_name(item_name)
                e[11] = 0x20
                struct.pack_into("<H", e, 26, cluster & 0xFFFF)
                struct.pack_into("<I", e, 28, len(target))
                entries_buf[entry_idx * 32 : (entry_idx + 1) * 32] = e
            entry_idx += 1

        if not is_root:
            c_offset = (data_start_sector + (my_c - 2) * sectors_per_cluster) * sector_size
            disk[c_offset : c_offset + cluster_size] = entries_buf

    process_dir("", True)

    fat1_offset = reserved_sectors * sector_size
    fat2_offset = (reserved_sectors + sectors_per_fat) * sector_size
    disk[fat1_offset : fat1_offset + len(fat)] = fat
    disk[fat2_offset : fat2_offset + len(fat)] = fat

    root_offset = (reserved_sectors + (num_fats * sectors_per_fat)) * sector_size
    root_bytes = dirs[""]
    disk[root_offset : root_offset + len(root_bytes)] = root_bytes

    return bytes(disk)

def create_fat32_image(size_mb, files_dict, hidden_sectors=2048):
    total_bytes = size_mb * 1024 * 1024
    sector_size = 512
    total_sectors = total_bytes // sector_size
    sectors_per_cluster = 1
    cluster_size = sectors_per_cluster * sector_size
    reserved_sectors = 32
    num_fats = 2

    data_sectors_approx = total_sectors - reserved_sectors
    total_clusters_approx = data_sectors_approx // sectors_per_cluster
    fat_size_bytes = (total_clusters_approx + 2) * 4
    sectors_per_fat = (fat_size_bytes + sector_size - 1) // sector_size

    data_start_sector = reserved_sectors + (num_fats * sectors_per_fat)
    data_sectors = total_sectors - data_start_sector
    total_clusters = data_sectors // sectors_per_cluster

    disk = bytearray(total_bytes)

    bpb = bytearray(sector_size)
    bpb[0:3] = b"\xebX\x90"
    bpb[3:11] = b"MSWIN4.1"
    struct.pack_into("<H", bpb, 11, sector_size)
    bpb[13] = sectors_per_cluster
    struct.pack_into("<H", bpb, 14, reserved_sectors)
    bpb[16] = num_fats
    struct.pack_into("<H", bpb, 17, 0)
    struct.pack_into("<H", bpb, 19, 0)
    bpb[21] = 0xF8
    struct.pack_into("<H", bpb, 22, 0)
    struct.pack_into("<H", bpb, 24, 63)
    struct.pack_into("<H", bpb, 26, 255)
    struct.pack_into("<I", bpb, 28, hidden_sectors)
    struct.pack_into("<I", bpb, 32, total_sectors)

    struct.pack_into("<I", bpb, 36, sectors_per_fat)
    struct.pack_into("<H", bpb, 40, 0)
    struct.pack_into("<H", bpb, 42, 0)
    struct.pack_into("<I", bpb, 44, 2)
    struct.pack_into("<H", bpb, 48, 1)
    struct.pack_into("<H", bpb, 50, 6)

    bpb[64] = 0x80
    bpb[66] = 0x29
    struct.pack_into("<I", bpb, 67, 0x12345678)
    bpb[71:82] = b"ZIGOS_ESP  "
    bpb[82:90] = b"FAT32   "
    bpb[510] = 0x55
    bpb[511] = 0xAA

    disk[0:sector_size] = bpb
    disk[6 * sector_size : 7 * sector_size] = bpb

    fsinfo = bytearray(sector_size)
    fsinfo[0:4] = b"RRaA"
    fsinfo[0x1E4:0x1E8] = b"rrAa"
    struct.pack_into("<I", fsinfo, 0x1E8, total_clusters - 100)
    struct.pack_into("<I", fsinfo, 0x1EC, 3)
    fsinfo[508] = 0x00
    fsinfo[509] = 0x00
    fsinfo[510] = 0x55
    fsinfo[511] = 0xAA

    disk[1 * sector_size : 2 * sector_size] = fsinfo
    disk[7 * sector_size : 8 * sector_size] = fsinfo

    fat = bytearray(sectors_per_fat * sector_size)
    struct.pack_into("<I", fat, 0, 0x0FFFFFF8)
    struct.pack_into("<I", fat, 4, 0x0FFFFFFF)
    struct.pack_into("<I", fat, 8, 0x0FFFFFFF)

    allocated_clusters = 3
    def alloc_cluster_chain(data_bytes):
        nonlocal allocated_clusters
        if len(data_bytes) == 0:
            return 0
        num_c = (len(data_bytes) + cluster_size - 1) // cluster_size
        start_cluster = allocated_clusters
        for i in range(num_c):
            c = start_cluster + i
            c_offset = (data_start_sector + (c - 2) * sectors_per_cluster) * sector_size
            chunk = data_bytes[i * cluster_size : (i + 1) * cluster_size]
            disk[c_offset : c_offset + len(chunk)] = chunk
            if i == num_c - 1:
                next_c = 0x0FFFFFFF
            else:
                next_c = c + 1
            struct.pack_into("<I", fat, c * 4, next_c)
        allocated_clusters += num_c
        return start_cluster

    dirs = {"": bytearray(cluster_size)}
    dir_files = {"": []}

    for path, content in files_dict.items():
        parts = [p for p in path.replace("\\", "/").strip("/").split("/") if p]
        dir_path = ""
        for p in parts[:-1]:
            parent = dir_path
            dir_path = (dir_path + "/" + p).strip("/")
            if dir_path not in dirs:
                dirs[dir_path] = bytearray(cluster_size)
                dir_files[dir_path] = []
                dir_files[parent].append((p, True, dir_path))
        filename = parts[-1]
        dir_files[dir_path].append((filename, False, content))

    def make_83_name(name):
        if "." in name:
            base, ext = name.rsplit(".", 1)
        else:
            base, ext = name, ""
        base = base.upper().replace(" ", "_")[:8]
        ext = ext.upper().replace(" ", "_")[:3]
        return f"{base:<8}{ext:<3}".encode("ascii")

    dir_clusters = {"": 2}
    def preassign_dir_clusters(dir_p):
        nonlocal allocated_clusters
        for item_name, is_dir, target in dir_files[dir_p]:
            if is_dir:
                c = allocated_clusters
                allocated_clusters += 1
                dir_clusters[target] = c
                struct.pack_into("<I", fat, c * 4, 0x0FFFFFFF)
                preassign_dir_clusters(target)

    preassign_dir_clusters("")

    def process_dir(dir_p, is_root=False):
        entries_buf = dirs[dir_p]
        my_c = dir_clusters[dir_p]
        entry_idx = 0

        if not is_root:
            parent_p = dir_p.rsplit("/", 1)[0] if "/" in dir_p else ""
            parent_c = dir_clusters[parent_p]
            parent_val = 0 if parent_c == 2 else parent_c
            e = bytearray(32)
            e[0:11] = b".          "
            e[11] = 0x10
            struct.pack_into("<H", e, 20, (my_c >> 16) & 0xFFFF)
            struct.pack_into("<H", e, 26, my_c & 0xFFFF)
            entries_buf[0:32] = e

            e2 = bytearray(32)
            e2[0:11] = b"..         "
            e2[11] = 0x10
            struct.pack_into("<H", e2, 20, (parent_val >> 16) & 0xFFFF)
            struct.pack_into("<H", e2, 26, parent_val & 0xFFFF)
            entries_buf[32:64] = e2
            entry_idx = 2

        for item_name, is_dir, target in dir_files[dir_p]:
            if is_dir:
                sub_c = dir_clusters[target]
                process_dir(target, False)
                e = bytearray(32)
                e[0:11] = make_83_name(item_name)
                e[11] = 0x10
                struct.pack_into("<H", e, 20, (sub_c >> 16) & 0xFFFF)
                struct.pack_into("<H", e, 26, sub_c & 0xFFFF)
                entries_buf[entry_idx * 32 : (entry_idx + 1) * 32] = e
            else:
                cluster = alloc_cluster_chain(target)
                e = bytearray(32)
                e[0:11] = make_83_name(item_name)
                e[11] = 0x20
                struct.pack_into("<H", e, 20, (cluster >> 16) & 0xFFFF)
                struct.pack_into("<H", e, 26, cluster & 0xFFFF)
                struct.pack_into("<I", e, 28, len(target))
                entries_buf[entry_idx * 32 : (entry_idx + 1) * 32] = e
            entry_idx += 1

        c_offset = (data_start_sector + (my_c - 2) * sectors_per_cluster) * sector_size
        disk[c_offset : c_offset + cluster_size] = entries_buf

    process_dir("", True)

    fat1_offset = reserved_sectors * sector_size
    fat2_offset = (reserved_sectors + sectors_per_fat) * sector_size
    disk[fat1_offset : fat1_offset + len(fat)] = fat
    disk[fat2_offset : fat2_offset + len(fat)] = fat

    return bytes(disk)

def create_gpt_disk_image(size_mb, esp_fat_bytes):
    total_bytes = size_mb * 1024 * 1024
    sector_size = 512
    total_lba = total_bytes // sector_size

    disk = bytearray(total_bytes)

    mbr = bytearray(512)
    mbr[0x1BE] = 0x00
    mbr[0x1BF] = 0x00
    mbr[0x1C0] = 0x02
    mbr[0x1C1] = 0x00
    mbr[0x1C2] = 0xEE
    mbr[0x1C3] = 0xFF
    mbr[0x1C4] = 0xFF
    mbr[0x1C5] = 0xFF
    struct.pack_into("<I", mbr, 0x1C6, 1)
    struct.pack_into("<I", mbr, 0x1CA, min(total_lba - 1, 0xFFFFFFFF))
    mbr[510] = 0x55
    mbr[511] = 0xAA
    disk[0:512] = mbr

    p_start_lba = 2048
    p_sectors = len(esp_fat_bytes) // sector_size
    p_end_lba = p_start_lba + p_sectors - 1

    entries = bytearray(128 * 128)
    esp_guid = bytes([
        0x28, 0x73, 0x2A, 0xC1, 0x1F, 0xF8, 0xD2, 0x11,
        0xBA, 0x4B, 0x00, 0xA0, 0xC9, 0x3E, 0xC9, 0x3B
    ])
    unique_guid = bytes([
        0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6, 0x07, 0x18,
        0x29, 0x3A, 0x4B, 0x5C, 0x6D, 0x7E, 0x8F, 0x90
    ])
    entries[0:16] = esp_guid
    entries[16:32] = unique_guid
    struct.pack_into("<Q", entries, 32, p_start_lba)
    struct.pack_into("<Q", entries, 40, p_end_lba)
    struct.pack_into("<Q", entries, 48, 0)
    name = "EFI System Partition".encode("utf-16le")
    entries[56 : 56 + len(name)] = name
    entries_crc = binascii.crc32(entries) & 0xFFFFFFFF

    gpt_head = bytearray(512)
    gpt_head[0:8] = b"EFI PART"
    struct.pack_into("<I", gpt_head, 8, 0x00010000)
    struct.pack_into("<I", gpt_head, 12, 92)
    struct.pack_into("<I", gpt_head, 16, 0)
    struct.pack_into("<I", gpt_head, 20, 0)
    struct.pack_into("<Q", gpt_head, 24, 1)
    struct.pack_into("<Q", gpt_head, 32, total_lba - 1)
    struct.pack_into("<Q", gpt_head, 40, 34)
    struct.pack_into("<Q", gpt_head, 48, total_lba - 34)
    gpt_head[56:72] = b"\x12\x34\x56\x78\x9a\xbc\xde\xf0\x11\x22\x33\x44\x55\x66\x77\x88"
    struct.pack_into("<Q", gpt_head, 72, 2)
    struct.pack_into("<I", gpt_head, 80, 128)
    struct.pack_into("<I", gpt_head, 84, 128)
    struct.pack_into("<I", gpt_head, 88, entries_crc)
    head_crc = binascii.crc32(gpt_head[:92]) & 0xFFFFFFFF
    struct.pack_into("<I", gpt_head, 16, head_crc)

    disk[512:1024] = gpt_head
    disk[1024 : 1024 + len(entries)] = entries

    esp_start_byte = p_start_lba * sector_size
    disk[esp_start_byte : esp_start_byte + len(esp_fat_bytes)] = esp_fat_bytes

    backup_entries_lba = total_lba - 33
    backup_entries_byte = backup_entries_lba * sector_size
    disk[backup_entries_byte : backup_entries_byte + len(entries)] = entries

    backup_head = bytearray(512)
    backup_head[0:8] = b"EFI PART"
    struct.pack_into("<I", backup_head, 8, 0x00010000)
    struct.pack_into("<I", backup_head, 12, 92)
    struct.pack_into("<I", backup_head, 16, 0)
    struct.pack_into("<I", backup_head, 20, 0)
    struct.pack_into("<Q", backup_head, 24, total_lba - 1)
    struct.pack_into("<Q", backup_head, 32, 1)
    struct.pack_into("<Q", backup_head, 40, 34)
    struct.pack_into("<Q", backup_head, 48, total_lba - 34)
    backup_head[56:72] = b"\x12\x34\x56\x78\x9a\xbc\xde\xf0\x11\x22\x33\x44\x55\x66\x77\x88"
    struct.pack_into("<Q", backup_head, 72, backup_entries_lba)
    struct.pack_into("<I", backup_head, 80, 128)
    struct.pack_into("<I", backup_head, 84, 128)
    struct.pack_into("<I", backup_head, 88, entries_crc)
    backup_head_crc = binascii.crc32(backup_head[:92]) & 0xFFFFFFFF
    struct.pack_into("<I", backup_head, 16, backup_head_crc)

    backup_head_byte = (total_lba - 1) * sector_size
    disk[backup_head_byte : backup_head_byte + 512] = backup_head

    return bytes(disk)

def create_uefi_iso(output_iso_path, efiboot_img_bytes, boot_efi_bytes, kernel_bytes, ramdisk_bytes):
    sector_size = 2048
    efiboot_padded = bytearray(efiboot_img_bytes)
    while len(efiboot_padded) % sector_size != 0:
        efiboot_padded.append(0)
    efiboot_sectors_2k = len(efiboot_padded) // sector_size
    efiboot_sectors_512 = len(efiboot_padded) // 512

    pvd_sector = 16
    boot_rec_sector = 17
    term_sector = 18
    path_l_sector = 19
    path_m_sector = 20
    root_dir_sector = 21
    efi_dir_sector = 22
    boot_dir_sector = 23
    boot_cat_sector = 24

    def pad_2k(data):
        b = bytearray(data)
        while len(b) % sector_size != 0:
            b.append(0)
        return b

    boot_efi_padded = pad_2k(boot_efi_bytes)
    kernel_padded = pad_2k(kernel_bytes)
    ramdisk_padded = pad_2k(ramdisk_bytes)

    boot_efi_sector = 25
    boot_efi_sec_count = len(boot_efi_padded) // sector_size

    kernel_sector = boot_efi_sector + boot_efi_sec_count
    kernel_sec_count = len(kernel_padded) // sector_size

    ramdisk_sector = kernel_sector + kernel_sec_count
    ramdisk_sec_count = len(ramdisk_padded) // sector_size

    efiboot_sector = ramdisk_sector + ramdisk_sec_count
    efiboot_sec_count = len(efiboot_padded) // sector_size

    total_sectors = efiboot_sector + efiboot_sec_count + 16
    iso = bytearray(total_sectors * sector_size)

    # 1. PVD (Sector 16)
    pvd = bytearray(sector_size)
    pvd[0] = 1
    pvd[1:6] = b"CD001"
    pvd[6] = 1
    pvd[8:40] = f"{'ZIGOS':<32}".encode("ascii")
    pvd[40:72] = f"{'ZIGOS':<32}".encode("ascii")
    struct.pack_into("<I", pvd, 80, total_sectors)
    struct.pack_into(">I", pvd, 84, total_sectors)
    struct.pack_into("<H", pvd, 120, 1)
    struct.pack_into(">H", pvd, 122, 1)
    struct.pack_into("<H", pvd, 124, 1)
    struct.pack_into(">H", pvd, 126, 1)
    struct.pack_into("<H", pvd, 128, sector_size)
    struct.pack_into(">H", pvd, 130, sector_size)
    struct.pack_into("<I", pvd, 132, 64)
    struct.pack_into(">I", pvd, 136, 64)
    struct.pack_into("<I", pvd, 140, path_l_sector)
    struct.pack_into(">I", pvd, 148, path_m_sector)

    root_rec = bytearray(34)
    root_rec[0] = 34
    struct.pack_into("<I", root_rec, 2, root_dir_sector)
    struct.pack_into(">I", root_rec, 6, root_dir_sector)
    struct.pack_into("<I", root_rec, 10, sector_size)
    struct.pack_into(">I", root_rec, 14, sector_size)
    root_rec[25] = 0x02
    root_rec[32] = 1
    pvd[156 : 156 + 34] = root_rec
    pvd[813:830] = b"2026083000000000\x00"
    pvd[881] = 1
    iso[pvd_sector * sector_size : (pvd_sector + 1) * sector_size] = pvd

    # 2. Boot Record (Sector 17)
    br = bytearray(sector_size)
    br[0] = 0
    br[1:6] = b"CD001"
    br[6] = 1
    br[7:39] = f"{'EL TORITO SPECIFICATION':<32}".encode("ascii")
    struct.pack_into("<I", br, 0x47, boot_cat_sector)
    iso[boot_rec_sector * sector_size : (boot_rec_sector + 1) * sector_size] = br

    # 3. Terminator (Sector 18)
    term = bytearray(sector_size)
    term[0] = 255
    term[1:6] = b"CD001"
    term[6] = 1
    iso[term_sector * sector_size : (term_sector + 1) * sector_size] = term

    # 4. Path Tables (Sector 19 / 20)
    pt_l = bytearray(sector_size)
    pt_l[0] = 1; struct.pack_into("<I", pt_l, 2, root_dir_sector); struct.pack_into("<H", pt_l, 6, 1)
    off = 8
    pt_l[off] = 3; pt_l[off+1] = 0; struct.pack_into("<I", pt_l, off+2, efi_dir_sector); struct.pack_into("<H", pt_l, off+6, 1); pt_l[off+8:off+11] = b"EFI"; pt_l[off+11] = 0
    off += 12
    pt_l[off] = 4; pt_l[off+1] = 0; struct.pack_into("<I", pt_l, off+2, boot_dir_sector); struct.pack_into("<H", pt_l, off+6, 2); pt_l[off+8:off+12] = b"BOOT"
    iso[path_l_sector * sector_size : (path_l_sector + 1) * sector_size] = pt_l

    pt_m = bytearray(sector_size)
    pt_m[0] = 1; struct.pack_into(">I", pt_m, 2, root_dir_sector); struct.pack_into(">H", pt_m, 6, 1)
    off = 8
    pt_m[off] = 3; pt_m[off+1] = 0; struct.pack_into(">I", pt_m, off+2, efi_dir_sector); struct.pack_into(">H", pt_m, off+6, 1); pt_m[off+8:off+11] = b"EFI"; pt_m[off+11] = 0
    off += 12
    pt_m[off] = 4; pt_m[off+1] = 0; struct.pack_into(">I", pt_m, off+2, boot_dir_sector); struct.pack_into(">H", pt_m, off+6, 2); pt_m[off+8:off+12] = b"BOOT"
    iso[path_m_sector * sector_size : (path_m_sector + 1) * sector_size] = pt_m

    # 5. Root Directory (Sector 21)
    rdir = bytearray(sector_size)
    def add_dir_entry(buf, offset, name, sec, size, is_dir):
        reclen = align_up(33 + len(name), 2)
        buf[offset] = reclen
        struct.pack_into("<I", buf, offset + 2, sec)
        struct.pack_into(">I", buf, offset + 6, sec)
        struct.pack_into("<I", buf, offset + 10, size)
        struct.pack_into(">I", buf, offset + 14, size)
        buf[offset + 25] = 0x02 if is_dir else 0x00
        buf[offset + 32] = len(name)
        buf[offset + 33 : offset + 33 + len(name)] = name
        return offset + reclen

    r_off = add_dir_entry(rdir, 0, b"\x00", root_dir_sector, sector_size, True)
    r_off = add_dir_entry(rdir, r_off, b"\x01", root_dir_sector, sector_size, True)
    r_off = add_dir_entry(rdir, r_off, b"EFI", efi_dir_sector, sector_size, True)
    r_off = add_dir_entry(rdir, r_off, b"ZIGOS.ELF;1", kernel_sector, len(kernel_bytes), False)
    r_off = add_dir_entry(rdir, r_off, b"RAMDISK.BIN;1", ramdisk_sector, len(ramdisk_bytes), False)
    r_off = add_dir_entry(rdir, r_off, b"EFIBOOT.IMG;1", efiboot_sector, len(efiboot_img_bytes), False)
    iso[root_dir_sector * sector_size : (root_dir_sector + 1) * sector_size] = rdir

    # 6. EFI Directory (Sector 22)
    efidir = bytearray(sector_size)
    e_off = add_dir_entry(efidir, 0, b"\x00", efi_dir_sector, sector_size, True)
    e_off = add_dir_entry(efidir, e_off, b"\x01", root_dir_sector, sector_size, True)
    e_off = add_dir_entry(efidir, e_off, b"BOOT", boot_dir_sector, sector_size, True)
    iso[efi_dir_sector * sector_size : (efi_dir_sector + 1) * sector_size] = efidir

    # 7. BOOT Directory (Sector 23)
    bootdir = bytearray(sector_size)
    b_off = add_dir_entry(bootdir, 0, b"\x00", boot_dir_sector, sector_size, True)
    b_off = add_dir_entry(bootdir, b_off, b"\x01", efi_dir_sector, sector_size, True)
    b_off = add_dir_entry(bootdir, b_off, b"BOOTX64.EFI;1", boot_efi_sector, len(boot_efi_bytes), False)
    iso[boot_dir_sector * sector_size : (boot_dir_sector + 1) * sector_size] = bootdir

    # 8. El Torito Boot Catalog (Sector 24)
    # The validation entry must have its checksum at offset 0x1C and the
    # 0x55AA key at offset 0x1E.  A misplaced key/checksum makes firmware
    # reject the catalog even though the ISO filesystem remains readable.
    cat = bytearray(sector_size)
    cat[0x00] = 0x01  # Validation header ID
    cat[0x01] = 0x00  # x86 platform ID
    cat[0x04:0x04 + 20] = b"ZigOS UEFI Boot Catalog"
    cat[0x1E:0x20] = b"\x55\xAA"
    csum = sum(struct.unpack_from("<H", cat, i * 2)[0] for i in range(16))
    struct.pack_into("<H", cat, 0x1C, (-csum) & 0xFFFF)

    # Initial / Default Entry (points to efiboot.img)
    cat[0x20] = 0x88 # Bootable
    cat[0x21] = 0x00 # No emulation
    cat[0x24] = 0xEF # System Type: EFI
    struct.pack_into("<H", cat, 0x26, min(efiboot_sectors_512, 65535))
    struct.pack_into("<I", cat, 0x28, efiboot_sector)

    # Section Header for EFI
    cat[0x40] = 0x91
    cat[0x41] = 0xEF
    struct.pack_into("<H", cat, 0x42, 1)

    # Section Entry for EFI
    cat[0x60] = 0x88
    cat[0x61] = 0x00
    cat[0x64] = 0xEF
    struct.pack_into("<H", cat, 0x66, min(efiboot_sectors_512, 65535))
    struct.pack_into("<I", cat, 0x68, efiboot_sector)

    iso[boot_cat_sector * sector_size : (boot_cat_sector + 1) * sector_size] = cat

    # 9. Write File Payloads
    iso[boot_efi_sector * sector_size : (boot_efi_sector + boot_efi_sec_count) * sector_size] = boot_efi_padded
    iso[kernel_sector * sector_size : (kernel_sector + kernel_sec_count) * sector_size] = kernel_padded
    iso[ramdisk_sector * sector_size : (ramdisk_sector + ramdisk_sec_count) * sector_size] = ramdisk_padded
    iso[efiboot_sector * sector_size : (efiboot_sector + efiboot_sec_count) * sector_size] = efiboot_padded

    with open(output_iso_path, "wb") as f:
        f.write(iso)

    print(f"Generated Clean UEFI Bootable ISO: {output_iso_path} ({len(iso)} bytes)")

def main():
    base_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    bootloader_path = os.path.join(base_dir, "BOOTX64.EFI")
    kernel_path = os.path.join(base_dir, "zigos.elf")
    ramdisk_path = os.path.join(base_dir, "ramdisk.bin")

    print(f"Reading bootloader: {bootloader_path}")
    with open(bootloader_path, "rb") as f:
        boot_bytes = f.read()

    print(f"Reading kernel: {kernel_path}")
    with open(kernel_path, "rb") as f:
        kernel_bytes = f.read()

    print(f"Reading ramdisk: {ramdisk_path}")
    with open(ramdisk_path, "rb") as f:
        ramdisk_bytes = f.read()

    startup_nsh = b"FS0:\\EFI\\BOOT\\BOOTX64.EFI\r\n"

    files_dict = {
        "/EFI/BOOT/BOOTX64.EFI": boot_bytes,
        "/zigos.elf": kernel_bytes,
        "/ramdisk.bin": ramdisk_bytes,
        "/startup.nsh": startup_nsh,
    }

    # 1. Create 16MB FAT16 ESP image for El Torito ISO
    print("Building FAT16 EFI System Partition image (16MB) for ISO...")
    efiboot_bytes = create_fat16_image(16, files_dict)
    esp_out = os.path.join(base_dir, "efiboot.img")
    with open(esp_out, "wb") as f:
        f.write(efiboot_bytes)
    print(f"Wrote {esp_out} ({len(efiboot_bytes)} bytes)")

    # 2. Create 64MB FAT32 ESP image for GPT disk
    print("Building FAT32 EFI System Partition image (64MB) for GPT Disk...")
    esp_disk_bytes = create_fat32_image(64, files_dict, hidden_sectors=2048)

    # 3. Create GPT USB Disk image (128MB) with Primary and Backup GPT
    print("Building GPT USB raw disk image (128MB)...")
    gpt_disk_bytes = create_gpt_disk_image(128, esp_disk_bytes)
    gpt_out = os.path.join(base_dir, "zigos.img")
    with open(gpt_out, "wb") as f:
        f.write(gpt_disk_bytes)
    print(f"Wrote {gpt_out} ({len(gpt_disk_bytes)} bytes)")

    # 4. Create Clean El Torito UEFI Bootable ISO
    print("Building Clean El Torito UEFI Bootable ISO...")
    iso_out = os.path.join(base_dir, "zigos.iso")
    create_uefi_iso(iso_out, efiboot_bytes, boot_bytes, kernel_bytes, ramdisk_bytes)

    # 5. Generate SHA256 checksums
    print("\nCalculating SHA256 hashes:")
    for out_file in ["zigos.iso", "zigos.img", "efiboot.img", "zigos.elf", "ramdisk.bin"]:
        p = os.path.join(base_dir, out_file)
        if os.path.exists(p):
            h = hashlib.sha256(open(p, "rb").read()).hexdigest()
            print(f"  {out_file:15} {h}")

if __name__ == "__main__":
    main()
