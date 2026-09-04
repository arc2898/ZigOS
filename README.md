# ZigOS

A small, experimental OS kernel and tooling written in Zig.

This repository contains the source code and build scripts for ZigOS — a minimal operating system project intended for learning and experimentation with low-level systems programming using the Zig language.

Getting started

Prerequisites:
- Zig (latest stable)
- A POSIX-like shell
- qemu-system-x86_64 (optional, for running in a VM)

Build and run (example):

```bash
# Clone Repo
git clone https://github.com/arc2898/ZigOS
cd ZigOS

# You can build this in any Operating System

# Build (project may provide a build script or Zig build settings)
zig build

# Run in QEMU (if a bootable image is produced)
qemu-system-x86_64 -drive format=raw,file=build/zigos.img
```

Contributing

Contributions, issues, and suggestions are welcome. Please open an issue to discuss larger changes before submitting a pull request.

License

Add a license file or include license details here (e.g., MIT).

# This development was stopped due to less resources available this works up to one level not even stable
