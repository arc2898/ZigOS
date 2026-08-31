ENTRY(_start)

SECTIONS
{
    /* Kernel linked at 2MB for easy transition */
    . = 0x200000;
    
    __kernel_phys_start = .;

    .text :
    {
        __text_start = .;
        *(.text .text.*)
        __text_end = .;
    }

    . = ALIGN(4K);
    .rodata :
    {
        __rodata_start = .;
        *(.rodata .rodata.*)
        __rodata_end = .;
    }

    . = ALIGN(4K);
    .data :
    {
        __data_start = .;
        *(.data .data.*)
        __data_end = .;
    }

    . = ALIGN(4K);
    .bss :
    {
        __bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        __bss_end = .;
    }

    __kernel_phys_end = .;

    /DISCARD/ :
    {
        *(.comment)
        *(.eh_frame)
    }
}
