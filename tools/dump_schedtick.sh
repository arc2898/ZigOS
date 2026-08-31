#!/bin/bash
# Dump scheduler_tick from the linked ELF, highlighting stores to the frame.
cd /home/ubuntu/zigos
objdump -d --start-address=0x2278c0 --stop-address=0x228000 zigos.elf
