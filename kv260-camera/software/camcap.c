#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/of.h>
#include <linux/dmaengine.h>
#include <linux/dma-mapping.h>
#include <linux/miscdevice.h>
#include <linux/fs.h>
#include <linux/uaccess.h>
#include <linux/completion.h>
#include <linux/slab.h>
#include <linux/videodev2.h>
#include <linux/dma/xilinx_frmbuf.h>

/* Y10: 3 pixels per 32-bit word. 1920 px -> 640 words -> 2560 bytes/line */
#define WIDTH_BYTES  (1920 / 3 * 4)   /* = 2560 */
#define HEIGHT       1080
#define FRAME_SIZE   (WIDTH_BYTES * HEIGHT)

struct camcap_dev {
    struct dma_chan *chan;
    dma_addr_t buf_phys;
    void *buf_virt;
    struct completion done;
    struct miscdevice miscdev;
};

static void camcap_callback(void *param)
{
    struct camcap_dev *cd = param;
    complete(&cd->done);
}

static ssize_t camcap_read(struct file *f, char __user *ubuf, size_t len, loff_t *off)
{
    struct camcap_dev *cd = container_of(f->private_data, struct camcap_dev, miscdev);
    struct dma_async_tx_descriptor *desc;
    struct dma_interleaved_template *xt;
    struct dma_tx_state state;
    enum dma_status st;
    dma_cookie_t cookie;
    unsigned long ret;
    size_t frame;

    reinit_completion(&cd->done);

    /* Tell frmbuf the pixel format before preparing the transfer */
    xilinx_xdma_v4l2_config(cd->chan, V4L2_PIX_FMT_XY10);

    xt = kzalloc(sizeof(*xt) + sizeof(struct data_chunk), GFP_KERNEL);
    if (!xt)
        return -ENOMEM;

    xt->dir = DMA_DEV_TO_MEM;
    xt->src_sgl = false;
    xt->dst_sgl = true;
    xt->dst_start = cd->buf_phys;
    xt->frame_size = 1;
    xt->numf = HEIGHT;
    xt->sgl[0].size = WIDTH_BYTES;
    xt->sgl[0].icg = 0;

    desc = dmaengine_prep_interleaved_dma(cd->chan, xt, DMA_PREP_INTERRUPT);
    kfree(xt);
    if (!desc) {
        pr_err("camcap: prep_interleaved failed\n");
        return -EIO;
    }

    desc->callback = camcap_callback;
    desc->callback_param = cd;

    cookie = dmaengine_submit(desc);
    if (dma_submit_error(cookie)) {
        pr_err("camcap: submit failed\n");
        return -EIO;
    }

    dma_async_issue_pending(cd->chan);

    ret = wait_for_completion_timeout(&cd->done, msecs_to_jiffies(5000));
    st = dmaengine_tx_status(cd->chan, cookie, &state);
    pr_info("camcap: wait_ret=%lu status=%d\n", ret, (int)st);

    if (ret == 0 && st != DMA_COMPLETE) {
        pr_err("camcap: transfer timed out\n");
        dmaengine_terminate_sync(cd->chan);
        return -ETIMEDOUT;
    }

    frame = min_t(size_t, len, (size_t)FRAME_SIZE);
    if (copy_to_user(ubuf, cd->buf_virt, frame))
        return -EFAULT;
    return frame;
}

static const struct file_operations camcap_fops = {
    .owner = THIS_MODULE,
    .read  = camcap_read,
};

static bool camcap_filter(struct dma_chan *chan, void *param)
{
    struct device_node *node = param;
    return chan->device->dev->of_node == node;
}

static int camcap_probe(struct platform_device *pdev)
{
    struct camcap_dev *cd;
    struct device_node *dma_node;
    dma_cap_mask_t mask;
    int ret;

    cd = devm_kzalloc(&pdev->dev, sizeof(*cd), GFP_KERNEL);
    if (!cd)
        return -ENOMEM;

    dma_node = of_parse_phandle(pdev->dev.of_node, "dmas", 0);
    if (!dma_node) {
        dev_err(&pdev->dev, "no dmas phandle found\n");
        return -ENODEV;
    }

    dma_cap_zero(mask);
    dma_cap_set(DMA_SLAVE, mask);

    cd->chan = dma_request_channel(mask, camcap_filter, dma_node);
    of_node_put(dma_node);
    if (!cd->chan) {
        dev_err(&pdev->dev, "failed to get DMA channel\n");
        return -ENODEV;
    }

    dev_info(&pdev->dev, "camcap: got channel %s\n", dma_chan_name(cd->chan));

    cd->buf_virt = dma_alloc_coherent(&pdev->dev, FRAME_SIZE, &cd->buf_phys, GFP_KERNEL);
    if (!cd->buf_virt) {
        dma_release_channel(cd->chan);
        return -ENOMEM;
    }

    init_completion(&cd->done);

    cd->miscdev.minor = MISC_DYNAMIC_MINOR;
    cd->miscdev.name  = "camcap";
    cd->miscdev.fops  = &camcap_fops;

    ret = misc_register(&cd->miscdev);
    if (ret) {
        dma_free_coherent(&pdev->dev, FRAME_SIZE, cd->buf_virt, cd->buf_phys);
        dma_release_channel(cd->chan);
        return ret;
    }

    platform_set_drvdata(pdev, cd);
    dev_info(&pdev->dev, "camcap: ready, %d bytes (%dx%d Y10), phys=0x%llx\n",
             FRAME_SIZE, WIDTH_BYTES, HEIGHT, (u64)cd->buf_phys);
    return 0;
}

static int camcap_remove(struct platform_device *pdev)
{
    struct camcap_dev *cd = platform_get_drvdata(pdev);
    misc_deregister(&cd->miscdev);
    dma_free_coherent(&pdev->dev, FRAME_SIZE, cd->buf_virt, cd->buf_phys);
    dma_release_channel(cd->chan);
    return 0;
}

static const struct of_device_id camcap_of_match[] = {
    { .compatible = "kv260,camcap" },
    { }
};
MODULE_DEVICE_TABLE(of, camcap_of_match);

static struct platform_driver camcap_driver = {
    .probe  = camcap_probe,
    .remove = camcap_remove,
    .driver = { .name = "camcap", .of_match_table = camcap_of_match },
};
module_platform_driver(camcap_driver);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Frame-buffer capture driver for KV260 camera");
