# Script de arranque de U-Boot (se compila a boot.scr con mkimage).
# Particion 1 = FAT (boot), particion 2 = ext4 (rootfs), particion 3 = tipo A2 (SPL).

# 1) Programar la FPGA si existe soc_system.rbf y, SOLO si funciono, habilitar
#    los puentes HPS<->FPGA. El .rbf debe ser comprimido y SW10 (MSEL[4:0]) = 01010.
#    gpu2d.fpga=1 le dice al driver que puede tocar el puente ligero; con 0 el
#    driver no lo toca (leer 0xFF200000 sin FPGA programada cuelga el sistema).
setenv fpga_ok 0
if load mmc 0:1 ${loadaddr} soc_system.rbf; then
    echo "Programando FPGA con soc_system.rbf (${filesize} bytes)..."
    if fpga load 0 ${loadaddr} ${filesize}; then
        bridge enable
        setenv fpga_ok 1
        echo "FPGA programada y puentes habilitados."
    else
        echo "ERROR: fpga load fallo. Linux arranca SIN el acelerador."
        echo "       Revisa SW10 (MSEL) y el Configuration scheme del proyecto (Linux/LEEME.md)."
    fi
else
    echo "AVISO: no hay soc_system.rbf; se arranca sin programar la FPGA."
fi

setenv bootargs "console=ttyS0,115200 root=/dev/mmcblk0p2 rw rootwait gpu2d.fpga=${fpga_ok}"

# 2) Kernel y device tree
load mmc 0:1 ${kernel_addr_r} zImage
load mmc 0:1 ${fdt_addr_r} socfpga_cyclone5_de1_soc.dtb
bootz ${kernel_addr_r} - ${fdt_addr_r}
