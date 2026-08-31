import os
import struct
import sys

BLOCK = 4096
MAGIC = struct.unpack("<Q", b"FTFS\0\0\0\0")[0]
VERSION = 2
MAX_NAME = 63
MAX_BLOCKS = 2048
INODE_SIZE = 16544
EMPTY, REGULAR, DIRECTORY = 0, 1, 2

def pack_ftfs(output_path, asset_paths):
    files = {}
    files["/hostname"] = b"zigos\n"
    files["/version"] = b"0.1.0\n"
    files["/motd"] = b"Welcome to ZigOS!\n"
    
    if not asset_paths and os.path.exists("assets"):
        import glob
        asset_paths = glob.glob("assets/*.raw")

    for f in asset_paths:
        name = "/" + os.path.basename(f)
        with open(f, "rb") as fh:
            files[name] = fh.read()
            print(f"FTFS: including asset {name} ({len(files[name])} bytes)")

    test_bin = os.path.join("userspace", "test_ring3.elf")
    if os.path.exists(test_bin):
        with open(test_bin, "rb") as f:
            files["/test_ring3.elf"] = f.read()
            print(f"FTFS: including /test_ring3.elf ({len(files['/test_ring3.elf'])} bytes)")

    # Add apps
    app_bins = ["gui.bin", "desktop.bin", "dm.bin", "fm.bin", "test_gui.bin", "notepad.bin", "zterm.bin", "sysmon.bin", "ide.bin", "props.bin", "zbrowser.bin", "pkgmgr.bin", "imgview.bin", "play.bin", "zide.bin"]
    for ab in app_bins:
        app_path = os.path.join("sample", ab)
        if os.path.exists(app_path):
            with open(app_path, "rb") as f:
                files["/apps/" + ab.replace(".bin", "")] = f.read()
                print(f"FTFS: including app /apps/{ab.replace('.bin', '')} ({len(files['/apps/' + ab.replace('.bin', '')])} bytes)")

    inodes = [("/", DIRECTORY), ("/apps", DIRECTORY)]
    children = [[], []]
    
    for path, content in sorted(files.items()):
        idx = len(inodes)
        inodes.append((path, REGULAR))
        children.append([])
        if path.startswith("/apps/"):
            children[1].append((os.path.basename(path), idx))
        else:
            children[0].append((os.path.basename(path), idx))
            
    # Add apps dir to root
    children[0].append(("apps", 1))

    # Data block allocator
    data_blocks = []
    def allocate(content):
        blk_idx = len(data_blocks) + 1 # 1-based
        if len(content) < BLOCK:
            content = content.ljust(BLOCK, b"\x00")
        data_blocks.append(content[:BLOCK])
        return blk_idx

    inode_payloads = []
    for idx, (path, kind) in enumerate(inodes):
        if kind == DIRECTORY:
            dir_content = bytearray()
            for name, child_idx in children[idx]:
                child_kind = 1 if inodes[child_idx][1] == REGULAR else 2
                child_size = 0
                if child_kind == 1:
                    child_size = len(files[inodes[child_idx][0]])
                
                entry = struct.pack("<II64sBB6sQ", 
                    child_idx, 0, name.encode()[:MAX_NAME], 
                    child_kind, 0, b"\x00"*6, child_size)
                dir_content += entry
            
            blks = []
            if len(dir_content) == 0:
                blks.append(allocate(b"\x00" * BLOCK))
            else:
                for i in range(0, len(dir_content), BLOCK):
                    blks.append(allocate(dir_content[i:i+BLOCK]))
            inode_payloads.append((blks, len(dir_content)))
        else:
            content = files[path]
            blks = []
            if len(content) == 0:
                blks.append(allocate(b"\x00" * BLOCK))
            else:
                for i in range(0, len(content), BLOCK):
                    blks.append(allocate(content[i:i+BLOCK]))
            inode_payloads.append((blks, len(content)))

    # Calculate layout
    inode_table_blocks = (len(inodes) * INODE_SIZE + BLOCK - 1) // BLOCK
    data_start_blk = 1 + inode_table_blocks
    img_size = (data_start_blk + len(data_blocks)) * BLOCK
    img = bytearray(img_size)

    # Superblock
    data_offset = data_start_blk * BLOCK
    sb = struct.pack("<QIIIIIIQQ32sIIQQIIQIIII", 
        MAGIC, VERSION, BLOCK, len(inodes), 0, len(data_blocks), 0,
        4096, data_offset, b"ZigOS", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    
    csum = 0
    for i in range(0, 80, 1):
        csum = (csum + sb[i]) & 0xFFFFFFFF
    
    sb = struct.pack("<QIIIIIIQQ32sIIQQIIQIIII", 
        MAGIC, VERSION, BLOCK, len(inodes), 0, len(data_blocks), 0,
        4096, data_offset, b"ZigOS", csum, 0, 0, 0, 0, 0, 0, 0, 0, csum ^ 0xA5A5A5A5, 0)
    img[0:len(sb)] = sb

    # Inode Table
    for i, (path, kind) in enumerate(inodes):
        blks, size = inode_payloads[i]
        buf = bytearray(INODE_SIZE)
        struct.pack_into("<B", buf, 0, kind)
        struct.pack_into("<Q", buf, 8, size)
        name = os.path.basename(path) if path != "/" else "/"
        struct.pack_into("64s", buf, 16, name.encode()[:MAX_NAME])
        
        for j, blk in enumerate(blks[:MAX_BLOCKS]):
            struct.pack_into("<Q", buf, 80 + j*8, blk)
            
        csum = 0
        for j in range(0, 16528, 1):
            csum = (csum + buf[j]) & 0xFFFFFFFF
        struct.pack_into("<I", buf, 16528, csum)
        
        off = 4096 + i * INODE_SIZE
        img[off:off+INODE_SIZE] = buf

    # Data Blocks
    for i, content in enumerate(data_blocks):
        off = data_offset + i * BLOCK
        img[off:off+BLOCK] = content

    with open(output_path, "wb") as f:
        f.write(img)
    print(f"Successfully wrote {output_path} ({len(img)} bytes)")

if __name__ == "__main__":
    pack_ftfs(sys.argv[1], sys.argv[2:])

