#!/bin/bash
# Disassemble idt.init in the final ELF
objdump -d -M intel --start-address=0x2055a0 --stop-address=0x205700 /home/ubuntu/zigos/zigos.elf
