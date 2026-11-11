GPU2D_DRIVER_VERSION = 1.0
GPU2D_DRIVER_SITE = $(BR2_EXTERNAL_DE1SOC_PATH)/../ejemplos/driver
GPU2D_DRIVER_SITE_METHOD = local
GPU2D_DRIVER_LICENSE = GPL-2.0

$(eval $(kernel-module))
$(eval $(generic-package))
