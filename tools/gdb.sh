gdb -ex "set disassembly-flavor intel" \
    -ex "target remote :1234" \
    -ex "file ./vmlinux" \
    -ex "file ./exp" \
    -ex "c"