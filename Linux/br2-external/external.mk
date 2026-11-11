include $(sort $(wildcard $(BR2_EXTERNAL_DE1SOC_PATH)/package/*/*.mk))

# Si generaste los encabezados del preloader desde TU proyecto de Quartus
# (scripts/qts-handoff.sh), colócalos en board/de1soc/qts/ y se copiarán sobre los de
# fábrica de U-Boot. Después de cambiarlos: make uboot-dirclean all
define DE1SOC_UBOOT_COPY_QTS
	if ls $(BR2_EXTERNAL_DE1SOC_PATH)/board/de1soc/qts/*.h >/dev/null 2>&1; then \
		echo ">>> DE1-SoC: usando handoff del proyecto (board/de1soc/qts)"; \
		cp -v $(BR2_EXTERNAL_DE1SOC_PATH)/board/de1soc/qts/*.h \
			$(@D)/board/terasic/de1-soc/qts/; \
	fi
endef
UBOOT_POST_PATCH_HOOKS += DE1SOC_UBOOT_COPY_QTS

# El kernel mainline no trae DTS de la DE1-SoC: se agrega al árbol del kernel
# (arch/arm/boot/dts/intel/socfpga/) para compilarlo como un DTS más.
DE1SOC_DTS_DIR = $(@D)/arch/arm/boot/dts/intel/socfpga
define DE1SOC_LINUX_ADD_DTS
	cp -f $(BR2_EXTERNAL_DE1SOC_PATH)/board/de1soc/socfpga_cyclone5_de1_soc.dts $(DE1SOC_DTS_DIR)/
	grep -q socfpga_cyclone5_de1_soc.dtb $(DE1SOC_DTS_DIR)/Makefile || \
		echo 'dtb-$$(CONFIG_ARCH_INTEL_SOCFPGA) += socfpga_cyclone5_de1_soc.dtb' >> $(DE1SOC_DTS_DIR)/Makefile
endef
LINUX_PRE_BUILD_HOOKS += DE1SOC_LINUX_ADD_DTS
# Si editas el DTS: make linux-rebuild all  (vuelve a copiarlo y recompila)
