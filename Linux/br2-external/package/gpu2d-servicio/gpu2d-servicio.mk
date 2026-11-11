GPU2D_SERVICIO_VERSION = 1.0
GPU2D_SERVICIO_SITE = $(BR2_EXTERNAL_DE1SOC_PATH)/../ejemplos/servicio
GPU2D_SERVICIO_SITE_METHOD = local

define GPU2D_SERVICIO_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) $(TARGET_CONFIGURE_OPTS) -C $(@D)
endef

define GPU2D_SERVICIO_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/gpu2d-servicio $(TARGET_DIR)/usr/bin/gpu2d-servicio
endef

$(eval $(generic-package))
