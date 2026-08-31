import subprocess
import time
import os

def run_gdb():
    import glob
    elf_files = glob.glob("/home/ubuntu/zigos/.zig-cache/o/*/zigos.zig.elf")
    latest_elf = max(elf_files, key=os.path.getmtime)
    print(f"Using ELF: {latest_elf}")
    
    gdb_script = f"""
target remote :1234
set architecture i386:x86-64
symbol-file {latest_elf}
# Break at jump_to_user_asm
b jump_to_user_asm
c
echo \\n--- AT jump_to_user_asm ---\\n
info registers cr3
# Step through jump_to_user_asm until iretq
# jump_to_user_asm is at 0x20ab16
# iretq is at 0x20ab16 + offset
# Let's just step instruction by instruction until CS changes or we hit user address
while $cs == 0x8
  si
end
echo \\n--- AFTER iretq ---\\n
info registers rip cs ss rsp
q
"""
    with open("/tmp/gdb_commands.txt", "w") as f:
        f.write(gdb_script)
    
    cmd = ["gdb", "-batch", "-x", "/tmp/gdb_commands.txt"]
    result = subprocess.run(cmd, capture_output=True, text=True, cwd="/home/ubuntu/zigos")
    return result.stdout, result.stderr

if __name__ == "__main__":
    # Ensure no other QEMU is running
    os.system("pkill qemu-system-x86_64")
    time.sleep(1)

    # Start QEMU in background
    print("Starting QEMU with GDB...")
    # Use a separate process group so we can kill it all
    qemu_proc = subprocess.Popen(["/home/ubuntu/zigos/tools/test_baseline.sh", "/home/ubuntu/zigos/zig-out/zigos.iso", "-gdb"], 
                                 preexec_fn=os.setsid)
    
    time.sleep(10) # Wait for QEMU to start and wait for GDB
    
    print("Running GDB...")
    stdout, stderr = run_gdb()
    print("GDB Output:")
    print(stdout)
    if stderr:
        print("GDB Error:")
        print(stderr)
    
    # Cleanup
    import signal
    os.killpg(os.getpgid(qemu_proc.pid), signal.SIGTERM)
