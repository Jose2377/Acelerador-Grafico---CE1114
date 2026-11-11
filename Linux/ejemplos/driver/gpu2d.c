// SPDX-License-Identifier: GPL-2.0
/*
 * gpu2d.c - Driver del puente ligero HPS-FPGA para la unidad de aceleración
 * gráfica 2D (DE1-SoC). Mapa de registros tomado de avalon_reg_file.sv.
 *
 * /dev/gpu2d (interfaz completa en gpu2d_ioctl.h)
 *   write(): N paquetes de 24 bytes (N <= 256). Antes de cada paquete espera
 *            a que la cola del hardware tenga espacio (STATUS.fifo_full = 0),
 *            asi no se pierde ninguno (RF-08, RF-12). Luego escribe las seis
 *            palabras W0..W5 en CMD_FIFO_W (0x0C). Ya NO abre la ventana de
 *            medicion: eso lo pide el servicio con GPU2D_IOC_VENTANA solo
 *            cuando el LOTE trae INICIO_VENTANA (PROTOCOLO.md).
 *   read():  los 16 registros (0x00..0x3C) como u32 little-endian.
 *   ioctl(): GPU2D_IOC_VENTANA, GPU2D_IOC_ACK, GPU2D_IOC_ESPERAR.
 */
#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/miscdevice.h>
#include <linux/fs.h>
#include <linux/io.h>
#include <linux/uaccess.h>
#include <linux/of.h>
#include <linux/mutex.h>
#include <linux/delay.h>
#include <linux/jiffies.h>
#include <linux/sched/signal.h>

#include "gpu2d_ioctl.h"

#define GPU2D_PKT_WORDS		(GPU2D_PKT_BYTES / 4)
#define GPU2D_TIMEOUT_COLA_MS	2000	/* sin espacio en la cola tras esto: se devuelve lo escrito */

/* --- Mapa de registros (avalon_reg_file.sv) --- */
#define REG_ID			0x00		/* R  0xACE1_1140 */
#define REG_CONTROL		0x04		/* RW */
#define REG_STATUS		0x08		/* R  */
#define REG_CMD_FIFO_W		0x0C		/* W  seis escrituras = un comando */
#define REG_ERR_INFO		0x10		/* R  */
#define REG_PERF_CYCLES		0x14
#define REG_PERF_CMDS		0x18
#define REG_PERF_PIXELS		0x1C
#define REG_PERF_DROP		0x20

#define GPU2D_ID_MAGIC		0xACE11140

#define CTRL_ENABLE		BIT(0)		/* nivel */
#define CTRL_SOFT_RESET		BIT(1)		/* pulso */
#define CTRL_PERF_WINDOW	BIT(2)		/* pulso */
#define CTRL_IRQ_EN		BIT(3)		/* nivel */
#define CTRL_IRQ_INF		BIT(4)		/* W1C */
#define CTRL_IRQ_ERR		BIT(5)		/* W1C */

#define STATUS_BUSY		BIT(0)
#define STATUS_FIFO_FULL	BIT(4)
#define STATUS_FIFO_EMPTY	BIT(5)
#define STATUS_OVERFLOW		BIT(6)

struct gpu2d {
	void __iomem *base;
	struct miscdevice misc;
	struct mutex lock;
	u32 ctrl_level;			/* bits de nivel de CONTROL: enable, irq_en */
};

static inline void gpu2d_ctrl(struct gpu2d *g, u32 pulses)
{
	/* Los bits W1C van en 0 para no limpiar pendientes por accidente. */
	iowrite32(g->ctrl_level | pulses, g->base + REG_CONTROL);
}

/*
 * Espera hasta que (STATUS & mask) == want o venza timeout_ms.
 * Devuelve 0, -ETIMEDOUT o -ERESTARTSYS (senal).
 */
static int gpu2d_esperar_status(struct gpu2d *g, u32 mask, u32 want,
				unsigned int timeout_ms)
{
	unsigned long limite = jiffies + msecs_to_jiffies(timeout_ms);

	while ((ioread32(g->base + REG_STATUS) & mask) != want) {
		if (time_after(jiffies, limite))
			return -ETIMEDOUT;
		if (signal_pending(current))
			return -ERESTARTSYS;
		usleep_range(20, 50);
	}
	return 0;
}

static ssize_t gpu2d_write(struct file *f, const char __user *buf,
			   size_t len, loff_t *off)
{
	struct gpu2d *g = container_of(f->private_data, struct gpu2d, misc);
	u32 pkt[GPU2D_PKT_WORDS];
	size_t done = 0;
	int i, ret = 0;

	if (len == 0 || len % GPU2D_PKT_BYTES ||
	    len > GPU2D_MAX_BATCH * GPU2D_PKT_BYTES)
		return -EINVAL;

	if (mutex_lock_interruptible(&g->lock))
		return -ERESTARTSYS;

	while (done < len) {
		if (copy_from_user(pkt, buf + done, GPU2D_PKT_BYTES)) {
			ret = -EFAULT;
			break;
		}
		/* Contrapresion: el ensamblador encola al recibir W5, de modo que
		 * basta con que haya un lugar libre antes de empezar el paquete. */
		ret = gpu2d_esperar_status(g, STATUS_FIFO_FULL, 0,
					   GPU2D_TIMEOUT_COLA_MS);
		if (ret)
			break;
		for (i = 0; i < GPU2D_PKT_WORDS; i++)
			iowrite32(pkt[i], g->base + REG_CMD_FIFO_W);
		done += GPU2D_PKT_BYTES;
	}
	mutex_unlock(&g->lock);
	return done ? done : ret;
}

static long gpu2d_ioctl(struct file *f, unsigned int cmd, unsigned long arg)
{
	struct gpu2d *g = container_of(f->private_data, struct gpu2d, misc);
	u32 v;
	int ret = 0;

	switch (cmd) {
	case GPU2D_IOC_VENTANA:
		if (mutex_lock_interruptible(&g->lock))
			return -ERESTARTSYS;
		gpu2d_ctrl(g, CTRL_PERF_WINDOW | CTRL_IRQ_INF);
		mutex_unlock(&g->lock);
		break;
	case GPU2D_IOC_ACK:
		if (get_user(v, (u32 __user *)arg))
			return -EFAULT;
		gpu2d_ctrl(g, v & (CTRL_IRQ_INF | CTRL_IRQ_ERR));
		break;
	case GPU2D_IOC_ESPERAR:
		if (get_user(v, (u32 __user *)arg))
			return -EFAULT;
		ret = gpu2d_esperar_status(g, STATUS_FIFO_EMPTY | STATUS_BUSY,
					   STATUS_FIFO_EMPTY, v);
		break;
	default:
		ret = -ENOTTY;
	}
	return ret;
}

static ssize_t gpu2d_read(struct file *f, char __user *buf,
			  size_t len, loff_t *off)
{
	struct gpu2d *g = container_of(f->private_data, struct gpu2d, misc);
	u32 regs[GPU2D_NREGS];
	size_t n = min(len, sizeof(regs));
	int i;

	for (i = 0; i < GPU2D_NREGS; i++)
		regs[i] = (i == REG_CMD_FIFO_W / 4) ? 0 :	/* solo escritura */
			  ioread32(g->base + 4 * i);

	if (copy_to_user(buf, regs, n))
		return -EFAULT;
	return n;
}

static const struct file_operations gpu2d_fops = {
	.owner	= THIS_MODULE,
	.write	= gpu2d_write,
	.read	= gpu2d_read,
	.unlocked_ioctl	= gpu2d_ioctl,
	.llseek	= noop_llseek,
};

static int gpu2d_probe(struct platform_device *pdev)
{
	struct gpu2d *g;
	u32 id;

	g = devm_kzalloc(&pdev->dev, sizeof(*g), GFP_KERNEL);
	if (!g)
		return -ENOMEM;

	g->base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(g->base))
		return PTR_ERR(g->base);

	/*
	 * Si la FPGA no está programada o el puente está cerrado, esta lectura
	 * puede colgar el bus: boot.scr solo habilita los puentes tras "fpga load".
	 */
	id = ioread32(g->base + REG_ID);
	if (id != GPU2D_ID_MAGIC) {
		dev_err(&pdev->dev, "ID inesperado 0x%08x (esperado 0x%08x)\n",
			id, GPU2D_ID_MAGIC);
		return -ENODEV;
	}

	mutex_init(&g->lock);
	g->ctrl_level = CTRL_ENABLE;
	gpu2d_ctrl(g, CTRL_SOFT_RESET | CTRL_IRQ_INF | CTRL_IRQ_ERR);

	g->misc.minor = MISC_DYNAMIC_MINOR;
	g->misc.name  = "gpu2d";
	g->misc.fops  = &gpu2d_fops;
	g->misc.mode  = 0660;
	platform_set_drvdata(pdev, g);

	dev_info(&pdev->dev, "acelerador 2D listo (ID 0x%08x, STATUS 0x%08x)\n",
		 id, ioread32(g->base + REG_STATUS));
	return misc_register(&g->misc);
}

static void gpu2d_remove(struct platform_device *pdev)
{
	struct gpu2d *g = platform_get_drvdata(pdev);

	misc_deregister(&g->misc);
	g->ctrl_level = 0;
	gpu2d_ctrl(g, 0);			/* enable = 0 */
}

static const struct of_device_id gpu2d_of_match[] = {
	{ .compatible = "itcr,gpu2d-1.0" },
	{ }
};
MODULE_DEVICE_TABLE(of, gpu2d_of_match);

static struct platform_driver gpu2d_driver = {
	.probe	= gpu2d_probe,
	.remove	= gpu2d_remove,
	.driver	= {
		.name		= "gpu2d",
		.of_match_table	= gpu2d_of_match,
	},
};
module_platform_driver(gpu2d_driver);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("Jose Maria Vindas Ortiz");
MODULE_DESCRIPTION("Driver del puente ligero HPS-FPGA para la unidad gráfica 2D");
