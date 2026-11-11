#!/bin/sh
# Arma sdcard.img:
#   256 KiB  u-boot.img en crudo, fuera de la tabla de particiones (lo lee el SPL)
#   p1 FAT (boot, desde 4 MiB) | p2 ext4 (rootfs) | p3 tipo A2 (SPL para la BootROM)
set -e
BINARIES_DIR="$1"
BOARD_DIR="$(dirname "$0")"
CFG="${BINARIES_DIR}/genimage.cfg"

[ -f "${BINARIES_DIR}/u-boot.img" ] || {
    echo ">>> DE1-SoC: ERROR, falta u-boot.img en ${BINARIES_DIR}."
    echo "    Vuelve a aplicar la configuracion: bash scripts/01-preparar-buildroot.sh"
    echo "    y luego: make -C <output> uboot-dirclean all"
    exit 1
}

# Bitstream de la FPGA (opcional): board/de1soc/fpga/soc_system.rbf
RBF_LINE=""
if [ -f "${BOARD_DIR}/fpga/soc_system.rbf" ]; then
    cp "${BOARD_DIR}/fpga/soc_system.rbf" "${BINARIES_DIR}/"
    RBF_LINE=', "soc_system.rbf"'
    echo ">>> DE1-SoC: se incluye soc_system.rbf en la partición de arranque"
else
    rm -f "${BINARIES_DIR}/soc_system.rbf"
    echo ">>> DE1-SoC: AVISO, no hay fpga/soc_system.rbf; la FPGA no se programará al arrancar"
fi

cat > "${CFG}" <<EOF
image boot.vfat {
	vfat {
		files = { "zImage", "socfpga_cyclone5_de1_soc.dtb", "boot.scr"${RBF_LINE} }
	}
	size = 32M
}

image sdcard.img {
	hdimage {
	}

	# El SPL de U-Boot 2026.01 (socfpga_de1_soc_defconfig) arranca en modo raw
	# por sector: lee u-boot.img del sector 0x200 del DISCO (256 KiB), no de la
	# particion A2. Por eso va aqui, en crudo y fuera de la tabla. El entorno de
	# U-Boot ocupa 0x4400-0x6400, antes de esta zona.
	partition uboot-img {
		in-partition-table = "no"
		image = "u-boot.img"
		offset = 256K
	}

	# La FAT empieza en 4 MiB para dejar espacio a u-boot.img (hasta ~3,7 MiB).
	partition boot {
		partition-type = 0xC
		bootable = "true"
		image = "boot.vfat"
		offset = 4M
	}

	partition rootfs {
		partition-type = 0x83
		image = "rootfs.ext4"
	}

	# La BootROM del Cyclone V busca el preloader (SPL) en la particion tipo A2.
	partition uboot {
		partition-type = 0xA2
		image = "u-boot-with-spl.sfp"
		size = 2M
	}
}
EOF

support/scripts/genimage.sh -c "${CFG}"
echo ">>> Imagen lista: ${BINARIES_DIR}/sdcard.img"
