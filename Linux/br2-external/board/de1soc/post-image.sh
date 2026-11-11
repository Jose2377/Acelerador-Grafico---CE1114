#!/bin/sh
# Arma sdcard.img: p1 FAT (boot), p2 ext4 (rootfs), p3 tipo A2 (SPL + U-Boot).
set -e
BINARIES_DIR="$1"
BOARD_DIR="$(dirname "$0")"
CFG="${BINARIES_DIR}/genimage.cfg"

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

	# Empieza en 1 MiB: el entorno de U-Boot vive en el offset 0x4400 de la SD.
	partition boot {
		partition-type = 0xC
		bootable = "true"
		image = "boot.vfat"
		offset = 1M
	}

	partition rootfs {
		partition-type = 0x83
		image = "rootfs.ext4"
	}

	# La BootROM del Cyclone V busca el preloader en la partición tipo A2.
	partition uboot {
		partition-type = 0xA2
		image = "u-boot-with-spl.sfp"
		size = 2M
	}
}
EOF

support/scripts/genimage.sh -c "${CFG}"
echo ">>> Imagen lista: ${BINARIES_DIR}/sdcard.img"
