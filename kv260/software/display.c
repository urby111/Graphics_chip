// PS DisplayPort -> KV260 splitter -> HDMI, using the AMD standalone drivers.
#include "display.h"
#include "xparameters.h"
#include "xdppsu.h"
#include "xdpdma.h"
#include "xavbuf.h"
#include "xavbuf_clk.h"
#include "xscugic.h"
#include "xil_exception.h"
#include "xil_printf.h"
#include "sleep.h"

static XDpPsu dp;
static XDpDma dma;
static XAVBuf av;
static XScuGic gic;
static XDpDma_FrameBuffer frame;

static int setup_interrupts(void)
{
    XScuGic_Config *cfg = XScuGic_LookupConfig(XPAR_SCUGIC_0_DEVICE_ID);
    if (!cfg || XScuGic_CfgInitialize(&gic, cfg, cfg->CpuBaseAddress) != XST_SUCCESS)
        return XST_FAILURE;

    // VSYNC commits the queued framebuffer descriptor.
    if (XScuGic_Connect(&gic, 154, (Xil_InterruptHandler)XDpDma_InterruptHandler, &dma) != XST_SUCCESS)
        return XST_FAILURE;

    Xil_ExceptionInit();
    Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_INT,
                                (Xil_ExceptionHandler)XScuGic_InterruptHandler, &gic);
    XScuGic_Enable(&gic, 154);
    XDpDma_InterruptEnable(&dma, XDPDMA_IEN_VSYNC_INT_MASK);
    Xil_ExceptionEnable();

    return XST_SUCCESS;
}

int kv260_display_start(UINTPTR framebuffer)
{
    XDpPsu_Config *pc = XDpPsu_LookupConfig(XPAR_PSU_DP_DEVICE_ID);
    XDpDma_Config *dc = XDpDma_LookupConfig(XPAR_XDPDMA_0_DEVICE_ID);
    if (!pc || !dc) return XST_FAILURE;

    XDpPsu_CfgInitialize(&dp, pc, pc->BaseAddr);
    XDpDma_CfgInitialize(&dma, dc);
    XAVBuf_CfgInitialize(&av, pc->BaseAddr, XPAR_PSU_DP_DEVICE_ID);
    if (XDpPsu_InitializeTx(&dp) != XST_SUCCESS) return XST_FAILURE;

    // Use the RGBA8888 framebuffer written by the GPU.
    if (XDpDma_SetGraphicsFormat(&dma, RGBA8888) != XST_SUCCESS ||
        XAVBuf_SetInputNonLiveGraphicsFormat(&av, RGBA8888) != XST_SUCCESS)
        return XST_FAILURE;

    XDpDma_SetQOS(&dma, 11);
    XAVBuf_EnableGraphicsBuffers(&av, 1);
    XAVBuf_SetOutputVideoFormat(&av, RGB_8BPC);
    XAVBuf_InputVideoSelect(&av, XAVBUF_VIDSTREAM1_NONE, XAVBUF_VIDSTREAM2_NONLIVE_GFX);
    XAVBuf_ConfigureGraphicsPipeline(&av);
    XAVBuf_ConfigureOutputVideo(&av);
    XAVBuf_SetBlenderAlpha(&av, 1, 255);
    XDpPsu_CfgMsaEnSynchClkMode(&dp, 0);
    XAVBuf_SetAudioVideoClkSrc(&av, XAVBUF_PS_CLK, XAVBUF_PS_CLK);
    XAVBuf_SoftReset(&av);
    XDpPsu_EnableMainLink(&dp, 0);

    // Wait for the monitor, then negotiate the link.
    for (unsigned i = 0; i < 50 && !XDpPsu_IsConnected(&dp); ++i)
        usleep(100000);
    if (!XDpPsu_IsConnected(&dp)) return XST_FAILURE;

    u8 power = 1;
    if (XDpPsu_AuxWrite(&dp, XDPPSU_DPCD_SET_POWER_DP_PWR_VOLTAGE, 1, &power) != XST_SUCCESS)
        return XST_FAILURE;
    usleep(100000);

    if (XDpPsu_GetRxCapabilities(&dp) != XST_SUCCESS) return XST_FAILURE;
    if (XDpPsu_SetEnhancedFrameMode(&dp, dp.LinkConfig.SupportEnhancedFramingMode ? 1 : 0) != XST_SUCCESS ||
        XDpPsu_SetLaneCount(&dp, dp.LinkConfig.MaxLaneCount) != XST_SUCCESS ||
        XDpPsu_SetLinkRate(&dp, dp.LinkConfig.MaxLinkRate) != XST_SUCCESS ||
        XDpPsu_SetDownspread(&dp, dp.LinkConfig.SupportDownspreadControl) != XST_SUCCESS)
        return XST_FAILURE;

    int trained = XST_FAILURE;
    for (unsigned i = 0; i < 3 && trained != XST_SUCCESS; ++i) {
        trained = XDpPsu_EstablishLink(&dp);
        usleep(100000);
    }
    if (trained != XST_SUCCESS) return XST_FAILURE;

    // Configure 640x480 scanout after link training.
    XDpPsu_SetColorEncode(&dp, XDPPSU_CENC_RGB);
    XDpPsu_CfgMsaSetBpc(&dp, XVIDC_BPC_8);
    XDpPsu_CfgMsaUseStandardVideoMode(&dp, XVIDC_VM_640x480_60_P);
    if (XAVBuf_SetPixelClock(dp.MsaConfig.PixelClockHz) != XST_SUCCESS) return XST_FAILURE;

    XDpPsu_WriteReg(dp.Config.BaseAddr, XDPPSU_SOFT_RESET, 1);
    usleep(10);
    XDpPsu_WriteReg(dp.Config.BaseAddr, XDPPSU_SOFT_RESET, 0);
    XDpPsu_SetMsaValues(&dp);
    XAVBuf_SoftReset(&av);

    frame.Address = framebuffer;
    frame.Stride = 2560;
    frame.LineSize = 2560;
    frame.Size = 640 * 480 * 4;

    if (setup_interrupts() != XST_SUCCESS) return XST_FAILURE;
    XDpDma_DisplayGfxFrameBuffer(&dma, &frame);
    XDpPsu_EnableMainLink(&dp,1);

    return XDpPsu_CheckLinkStatus(&dp, dp.LinkConfig.LaneCount);
}
