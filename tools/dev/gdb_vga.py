import gdb, time, subprocess

gdb.execute("set pagination off")
gdb.execute("set target-async on")
gdb.execute("target remote :1234")

# Let the guest boot and settle (firmware + 1s stall + kernel boot + shell)
for _ in range(45):
    gdb.execute("continue", to_string=True)
    time.sleep(1)

# Stop the guest so we can inspect memory
gdb.execute("interrupt", to_string=True)
time.sleep(1)

# Read the VGA text buffer: should show 'welcome to zigos' / prompt if working
print(gdb.execute("x/64bx 0xB8000", to_string=True))
print(gdb.execute("x/40c 0xB8000", to_string=True))

# Take a screendump while stopped (also resume right after)
subprocess.run(["bash", "-c",
                "echo screendump /tmp/vgashot.ppm | socat - UNIX-CONNECT:/tmp/qmon.sock"],
               timeout=10)
print("screendump taken")
