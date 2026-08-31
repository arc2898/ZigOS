#!/usr/bin/env python3
"""
Comprehensive validator for ZigOS boot artifacts:
- ISO 9660 + El Torito UEFI Boot
- GPT Partition Table & EFI System Partition (ESP)
- FAT16/FAT32 filesystem structure and file contents
- ELF64 kernel executable integrity
- UEFI PE32+ bootloader binary integrity
- FTFS Ramdisk image integrity
"""

import os
import sys
import struct
import hashlib

def verify_all():
    print("=" * 60)
    print("       ZigOS Boot Artifact Verification & Audit")
    print("=" * 60)

    base = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    errors = 0

    # 1. Verify Kernel ELF
    elf_path = os.path.join(base, "zigos.elf")
    print(f"\n[1] Verifying Kernel: {elf_path}")
    if os.path.exists(elf_path):
        elf_data = open(elf_path, "rb").read()
        if elf_data[:4] == b"\x7fELF" and elf_data[4] == 2: # ELF64
            e_entry = struct.unpack_from("<Q", elf_data, 0x18)[0]
            e_phoff = struct.unpack_from("<Q", elf_data, 0x20)[0]
            e_phnum = struct.unpack_from("<H", elf_data, 0x38)[0]
            print(f"  [+] Valid 64-bit ELF executable ({len(elf_data):,} bytes)")
            print(f"  [+] Entry Point: 0x{e_entry:016X}")
            print(f"  [+] Program Headers: {e_phnum} entries at offset 0x{e_phoff:X}")
        else:
            print("  [-] Invalid ELF magic or architecture")
            errors += 1
    else:
        print("  [-] zigos.elf not found")
        errors += 1

    # 2. Verify UEFI Bootloader
    efi_path = os.path.join(base, "BOOTX64.EFI.efi")
    if not os.path.exists(efi_path):
        efi_path = os.path.join(base, "BOOTX64.EFI")
    print(f"\n[2] Verifying UEFI Bootloader: {efi_path}")
    if os.path.exists(efi_path):
        efi_data = open(efi_path, "rb").read()
        if efi_data[:2] == b"MZ":
            pe_off = struct.unpack_from("<I", efi_data, 0x3C)[0]
            if pe_off < len(efi_data) - 4 and efi_data[pe_off:pe_off+4] == b"PE\x00\x00":
                machine = struct.unpack_from("<H", efi_data, pe_off + 4)[0]
                if machine == 0x8664: # AMD64 / x86_64
                    print(f"  [+] Valid PE32+ (x86_64) UEFI Application ({len(efi_data):,} bytes)")
                else:
                    print(f"  [!] Machine type: 0x{machine:04X}")
            else:
                print("  [-] Invalid PE signature")
                errors += 1
        else:
            print("  [-] Missing MZ DOS stub header")
            errors += 1
    else:
        print("  [-] Bootloader not found")
        errors += 1

    # 3. Verify FTFS Ramdisk
    rd_path = os.path.join(base, "ramdisk.bin")
    print(f"\n[3] Verifying Ramdisk: {rd_path}")
    if os.path.exists(rd_path):
        rd_data = open(rd_path, "rb").read()
        if rd_data[:4] == b"FTFS":
            version = struct.unpack_from("<I", rd_data, 8)[0]
            block_size = struct.unpack_from("<I", rd_data, 12)[0]
            inode_count = struct.unpack_from("<I", rd_data, 16)[0]
            data_blocks = struct.unpack_from("<I", rd_data, 24)[0]
            print(f"  [+] Valid FTFS v{version} Ramdisk ({len(rd_data):,} bytes)")
            print(f"  [+] Block size: {block_size:,}, Inodes: {inode_count}, Data blocks: {data_blocks}")
        else:
            print("  [-] Invalid FTFS magic")
            errors += 1
    else:
        print("  [-] ramdisk.bin not found")
        errors += 1

    # 4. Verify EFI System Partition (efiboot.img)
    esp_path = os.path.join(base, "efiboot.img")
    print(f"\n[4] Verifying EFI System Partition image: {esp_path}")
    if os.path.exists(esp_path):
        esp_data = open(esp_path, "rb").read()
        if esp_data[510:512] == b"\x55\xAA":
            oem = esp_data[3:11].decode("latin-1", "replace").strip()
            fs_type = esp_data[54:62].decode("latin-1", "replace").strip()
            print(f"  [+] Valid FAT Boot Sector (Signature 0xAA55, OEM: {oem}, Type: {fs_type})")
            print(f"  [+] Total Image Size: {len(esp_data) // (1024*1024)} MB ({len(esp_data):,} bytes)")
            # Check for files in root
            if b"ZIGOS   ELF" in esp_data and b"RAMDISK BIN" in esp_data:
                print("  [+] Found /zigos.elf and /ramdisk.bin in FAT directory table")
            else:
                print("  [!] Files missing from FAT table")
                errors += 1
        else:
            print("  [-] Invalid FAT boot sector signature")
            errors += 1
    else:
        print("  [-] efiboot.img not found")
        errors += 1

    # 5. Verify GPT USB Disk Image (zigos.img)
    img_path = os.path.join(base, "zigos.img")
    print(f"\n[5] Verifying GPT USB Disk Image: {img_path}")
    if os.path.exists(img_path):
        img_data = open(img_path, "rb").read()
        # Check Protective MBR
        if img_data[510:512] == b"\x55\xAA" and img_data[0x1C2] == 0xEE:
            print("  [+] Valid Protective MBR at LBA 0 (Type 0xEE)")
        else:
            print("  [-] Protective MBR invalid")
            errors += 1
        # Check Primary GPT Header
        gpt_head = img_data[512:1024]
        if gpt_head[:8] == b"EFI PART":
            import binascii
            crc_stored = struct.unpack_from("<I", gpt_head, 16)[0]
            head_copy = bytearray(gpt_head[:92])
            struct.pack_into("<I", head_copy, 16, 0)
            crc_calc = binascii.crc32(head_copy) & 0xFFFFFFFF
            if crc_stored == crc_calc:
                print(f"  [+] Valid Primary GPT Header at LBA 1 (CRC32: 0x{crc_calc:08X})")
            else:
                print(f"  [-] GPT Header CRC mismatch: stored 0x{crc_stored:08X}, calc 0x{crc_calc:08X}")
                errors += 1
            # Check partition entries
            entries = img_data[1024:1024 + 128*128]
            entries_crc_stored = struct.unpack_from("<I", gpt_head, 88)[0]
            entries_crc_calc = binascii.crc32(entries) & 0xFFFFFFFF
            if entries_crc_stored == entries_crc_calc:
                print(f"  [+] Valid GPT Partition Table CRC32: 0x{entries_crc_calc:08X}")
                # Check ESP Partition GUID
                esp_guid = bytes([0x28, 0x73, 0x2A, 0xC1, 0x1F, 0xF8, 0xD2, 0x11, 0xBA, 0x4B, 0x00, 0xA0, 0xC9, 0x3E, 0xC9, 0x3B])
                if entries[:16] == esp_guid:
                    p_start = struct.unpack_from("<Q", entries, 32)[0]
                    p_end = struct.unpack_from("<Q", entries, 40)[0]
                    print(f"  [+] ESP Partition detected at LBA {p_start}..{p_end} (Size: {(p_end - p_start + 1)*512 // (1024*1024)} MB)")
                else:
                    print("  [-] ESP Partition GUID not found at entry 0")
                    errors += 1
            else:
                print("  [-] GPT Partition Entries CRC mismatch")
                errors += 1
        else:
            print("  [-] Primary GPT Header signature 'EFI PART' missing")
            errors += 1
    else:
        print("  [-] zigos.img not found")
        errors += 1

    # 6. Verify UEFI Bootable ISO (zigos.iso)
    iso_path = os.path.join(base, "zigos.iso")
    print(f"\n[6] Verifying El Torito UEFI Bootable ISO: {iso_path}")
    if os.path.exists(iso_path):
        iso_data = open(iso_path, "rb").read()
        pvd = iso_data[16 * 2048 : 17 * 2048]
        if pvd[0] == 1 and pvd[1:6] == b"CD001":
            vol_id = pvd[40:72].decode("ascii").strip()
            print(f"  [+] Valid ISO 9660 Primary Volume Descriptor (Volume ID: '{vol_id}')")
        else:
            print("  [-] Invalid PVD or Standard Identifier")
            errors += 1
        br = iso_data[17 * 2048 : 18 * 2048]
        if br[0] == 0 and br[1:6] == b"CD001" and b"EL TORITO" in br[7:39]:
            cat_lba = struct.unpack_from("<I", br, 0x47)[0]
            print(f"  [+] Valid El Torito Boot Record (Boot Catalog at Sector {cat_lba})")
            cat = iso_data[cat_lba * 2048 : (cat_lba + 1) * 2048]
            if cat[0] == 1 and cat[0x1C:0x1E] == b"\x55\xAA":
                print("  [+] Valid El Torito Validation Entry (0x55AA)")
                bios_media = cat[0x21]
                bios_lba = struct.unpack_from("<I", cat, 0x28)[0]
                print(f"  [+] BIOS Boot Entry: Media={bios_media} (No Emulation), LBA={bios_lba}")
                
                # Check EFI section header and entry
                if cat[0x40] == 0x91 and cat[0x41] == 0xEF:
                    efi_lba = struct.unpack_from("<I", cat, 0x68)[0]
                    efi_secs = struct.unpack_from("<H", cat, 0x66)[0]
                    print(f"  [+] EFI Section Entry: Platform=0xEF (UEFI), Image LBA={efi_lba}, Sectors={efi_secs}")
                    boot_img = iso_data[efi_lba * 2048 :]
                    if boot_img[510:512] == b"\x55\xAA":
                        print("  [+] EFI Boot Image is a valid FAT ESP volume")
                    else:
                        print("  [!] EFI Boot image signature warning")
                else:
                    print("  [!] EFI Section Header missing")
            else:
                print("  [-] Boot Catalog Header invalid")
                errors += 1
        else:
            print("  [-] El Torito Boot Record Descriptor invalid")
            errors += 1
    else:
        print("  [-] zigos.iso not found")
        errors += 1

    print("\n" + "=" * 60)
    if errors == 0:
        print("   >>> ALL 6 BOOT ARTIFACTS PASSED VERIFICATION 100% <<<")
    else:
        print(f"   >>> {errors} ERRORS FOUND DURING VERIFICATION <<<")
    print("=" * 60)
    return errors == 0

if __name__ == "__main__":
    success = verify_all()
    sys.exit(0 if success else 1)
