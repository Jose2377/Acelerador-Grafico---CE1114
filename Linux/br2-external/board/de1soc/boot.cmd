# Script de arranque de U-Boot (se compila a boot.scr con mkimage).
# Partición 1 = FAT (boot), partición 2 = ext4 (rootfs), partición 3 = tipo A2 (SPL + U-Boot).

setenv bootargs "console=ttyS0,115200 root=/dev/mmcblk0p2 rw rootwait"

# 1) Programar la FPGA si existe soc_system.rbf y habilitar los puentes HPS<->FPGA.
#    El .rbf debe ser comprimido y SW10 (MSEL[4:0]) debe estar en 01010 (FPPx32).
if load mmc 0:1 ${loadaddr} soc_system.rbf; then
    echo "Programando FPGA con soc_system.rbf (${filesize} bytes)..."
    fpga load 0 ${loadaddr} ${filesize}
    bridge enable
else
    echo "AVISO: no hay soc_system.rbf; se arranca sin programar la FPGA."
fi

# 2) Kernel y device tree
load mmc 0:1 ${kernel_addr_r} zImage
load mmc 0:1 ${fdt_addr_r} socfpga_cyclone5_de1_soc.dtb
bootz ${kernel_addr_r} - ${fdt_addr_r}
