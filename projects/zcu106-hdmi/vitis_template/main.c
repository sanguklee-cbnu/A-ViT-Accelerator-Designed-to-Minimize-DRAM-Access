#include <string.h>

#include "sleep.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include "xparameters.h"
#include "xstatus.h"
#include "xiic.h"
#include "xv_frmbufrd_l2.h"
#include "xv_hdmitxss.h"
#include "xvidc.h"
#include "xvphy.h"

#if defined(XPAR_XV_HDMITX_0_DEVICE_ID)
#define HDMI_TX_DEVICE_ID XPAR_XV_HDMITX_0_DEVICE_ID
#elif defined(XPAR_V_HDMI_TX_SS_0_DEVICE_ID)
#define HDMI_TX_DEVICE_ID XPAR_V_HDMI_TX_SS_0_DEVICE_ID
#else
#error "HDMI TX SS device id macro not found in xparameters.h"
#endif

#if defined(XPAR_VPHY_0_DEVICE_ID)
#define VPHY_DEVICE_ID XPAR_VPHY_0_DEVICE_ID
#elif defined(XPAR_VID_PHY_CONTROLLER_0_DEVICE_ID)
#define VPHY_DEVICE_ID XPAR_VID_PHY_CONTROLLER_0_DEVICE_ID
#else
#error "Video PHY device id macro not found in xparameters.h"
#endif

#if defined(XPAR_V_FRMBUF_RD_0_DEVICE_ID)
#define FRMBUF_RD_DEVICE_ID XPAR_V_FRMBUF_RD_0_DEVICE_ID
#else
#error "Frame buffer read device id macro not found in xparameters.h"
#endif

#if defined(XPAR_IIC_0_DEVICE_ID)
#define FMC_IIC_DEVICE_ID XPAR_IIC_0_DEVICE_ID
#elif defined(XPAR_AXI_IIC_0_DEVICE_ID)
#define FMC_IIC_DEVICE_ID XPAR_AXI_IIC_0_DEVICE_ID
#endif

#if defined(XPAR_PSU_DDR_0_S_AXI_BASEADDR)
#define DDR_BASE_ADDR XPAR_PSU_DDR_0_S_AXI_BASEADDR
#elif defined(XPAR_DDR_MEM_BASEADDR)
#define DDR_BASE_ADDR XPAR_DDR_MEM_BASEADDR
#else
#error "DDR base address macro not found in xparameters.h"
#endif

#define FRAME_BASE_ADDR ((UINTPTR)(DDR_BASE_ADDR + 0x10000000U))
#define VIDEO_MODE XVIDC_VM_1920x1080_60_P
#define VIDEO_COLOR_FORMAT XVIDC_CSF_RGB
#define VIDEO_MEM_FORMAT XVIDC_CSF_MEM_RGB8
#define VIDEO_BPC XVIDC_BPC_8

static XV_FrmbufRd_l2 FrmbufRd;
static XV_HdmiTxSs HdmiTxSs;
static XVphy Vphy;
#if defined(FMC_IIC_DEVICE_ID)
static XIic FmcIic;
#endif

static u32 CalcStride(XVidC_ColorFormat Cfmt, u16 AxiMmDataWidth,
                      const XVidC_VideoStream *StreamPtr)
{
    u32 stride;
    u32 width = StreamPtr->Timing.HActive;
    u16 mm_width_bytes = AxiMmDataWidth / 8U;
    u8 bpp_numerator;
    u8 bpp_denominator = 1U;

    switch (Cfmt) {
    case XVIDC_CSF_MEM_Y_UV10:
    case XVIDC_CSF_MEM_Y_UV10_420:
    case XVIDC_CSF_MEM_Y10:
    case XVIDC_CSF_MEM_Y_U_V10:
        bpp_numerator = 4U;
        bpp_denominator = 3U;
        break;
    case XVIDC_CSF_MEM_Y_UV8:
    case XVIDC_CSF_MEM_Y_UV8_420:
    case XVIDC_CSF_MEM_Y8:
    case XVIDC_CSF_MEM_Y_U_V8:
        bpp_numerator = 1U;
        break;
    case XVIDC_CSF_MEM_RGB8:
    case XVIDC_CSF_MEM_YUV8:
    case XVIDC_CSF_MEM_BGR8:
        bpp_numerator = 3U;
        break;
    case XVIDC_CSF_MEM_RGBX12:
    case XVIDC_CSF_MEM_YUVX12:
        bpp_numerator = 5U;
        break;
    case XVIDC_CSF_MEM_Y_UV12:
    case XVIDC_CSF_MEM_Y_UV12_420:
    case XVIDC_CSF_MEM_Y12:
        bpp_numerator = 3U;
        bpp_denominator = 2U;
        break;
    case XVIDC_CSF_MEM_RGB16:
    case XVIDC_CSF_MEM_YUV16:
        bpp_numerator = 6U;
        break;
    case XVIDC_CSF_MEM_YUYV8:
    case XVIDC_CSF_MEM_UYVY8:
    case XVIDC_CSF_MEM_Y_UV16:
    case XVIDC_CSF_MEM_Y_UV16_420:
    case XVIDC_CSF_MEM_Y16:
        bpp_numerator = 2U;
        break;
    default:
        bpp_numerator = 4U;
        break;
    }

    stride = ((((width * bpp_numerator) / bpp_denominator) +
               mm_width_bytes - 1U) /
              mm_width_bytes) *
             mm_width_bytes;
    return stride;
}

static void BuildVideoStream(XVidC_VideoStream *StreamPtr, u8 ppc)
{
    const XVidC_VideoTiming *timing;

    memset(StreamPtr, 0, sizeof(*StreamPtr));

    timing = XVidC_GetTimingInfo(VIDEO_MODE);
    StreamPtr->VmId = VIDEO_MODE;
    StreamPtr->Timing = *timing;
    StreamPtr->FrameRate = XVidC_GetFrameRate(VIDEO_MODE);
    StreamPtr->ColorFormatId = VIDEO_COLOR_FORMAT;
    StreamPtr->ColorDepth = VIDEO_BPC;
    StreamPtr->PixPerClk = (XVidC_PixelsPerClock)ppc;
}

static void FillColorBarsRgb888(UINTPTR base_addr, const XVidC_VideoStream *StreamPtr,
                                u32 stride)
{
    static const u8 colors[8][3] = {
        {255, 255, 255}, {255, 255, 0},   {0, 255, 255}, {0, 255, 0},
        {255, 0, 255},   {255, 0, 0},     {0, 0, 255},   {0, 0, 0},
    };
    u8 *frame = (u8 *)base_addr;
    u32 x;
    u32 y;
    u32 width = StreamPtr->Timing.HActive;
    u32 height = StreamPtr->Timing.VActive;

    for (y = 0; y < height; ++y) {
        u8 *line = frame + (y * stride);
        for (x = 0; x < width; ++x) {
            u32 band = (x * 8U) / width;
            line[(x * 3U) + 0U] = colors[band][0];
            line[(x * 3U) + 1U] = colors[band][1];
            line[(x * 3U) + 2U] = colors[band][2];
        }
    }

    Xil_DCacheFlushRange(base_addr, (INTPTR)(stride * height));
}

static int InitFmcIic(void)
{
#if defined(FMC_IIC_DEVICE_ID)
    int status;

    status = XIic_Initialize(&FmcIic, FMC_IIC_DEVICE_ID);
    if (status != XST_SUCCESS) {
        xil_printf("ERR: FMC IIC init failed: %d\r\n", status);
        return status;
    }

    status = XIic_Start(&FmcIic);
    if (status != XST_SUCCESS) {
        xil_printf("ERR: FMC IIC start failed: %d\r\n", status);
        return status;
    }

    xil_printf("INFO: FMC IIC ready\r\n");
#else
    xil_printf("INFO: FMC IIC macro not found, skipping I2C init\r\n");
#endif
    return XST_SUCCESS;
}

static int BoardClockInit(u32 tx_refclk_hz)
{
    (void)tx_refclk_hz;

    xil_printf("WARN: BoardClockInit() is currently a stub\r\n");
    xil_printf("WARN: If HDMI stays dark, add SI5324/IDT clock programming here\r\n");

    /*
     * If needed, port the following helper sources from the Xilinx HDMI TX example:
     * - si5324drv.c / si5324drv.h
     * - idt_8t49n24x.c / idt_8t49n24x.h
     * Then program the FMC HDMI clock chip for the requested TMDS reference clock.
     */

    return XST_SUCCESS;
}

static int InitFrmbuf(void)
{
    int status;

    status = XVFrmbufRd_Initialize(&FrmbufRd, FRMBUF_RD_DEVICE_ID);
    if (status != XST_SUCCESS) {
        xil_printf("ERR: XVFrmbufRd_Initialize failed: %d\r\n", status);
        return status;
    }

    xil_printf("INFO: Frame buffer reader ready\r\n");
    return XST_SUCCESS;
}

static int InitHdmiTxSs(void)
{
    int status;
    XV_HdmiTxSs_Config *cfg;

    cfg = XV_HdmiTxSs_LookupConfig(HDMI_TX_DEVICE_ID);
    if (cfg == NULL) {
        xil_printf("ERR: HDMI TX SS config not found\r\n");
        return XST_FAILURE;
    }

    status = XV_HdmiTxSs_CfgInitialize(&HdmiTxSs, cfg, cfg->BaseAddress);
    if (status != XST_SUCCESS) {
        xil_printf("ERR: XV_HdmiTxSs_CfgInitialize failed: %d\r\n", status);
        return status;
    }

    XV_HdmiTxSs_Start(&HdmiTxSs);
    xil_printf("INFO: HDMI TX SS ready\r\n");
    return XST_SUCCESS;
}

static int InitVphy(void)
{
    int status;
    XVphy_Config *cfg;

    cfg = XVphy_LookupConfig(VPHY_DEVICE_ID);
    if (cfg == NULL) {
        xil_printf("ERR: VPHY config not found\r\n");
        return XST_FAILURE;
    }

    status = XVphy_Hdmi_CfgInitialize(&Vphy, 0U, cfg);
    if (status != XST_SUCCESS) {
        xil_printf("ERR: XVphy_Hdmi_CfgInitialize failed: %d\r\n", status);
        return status;
    }

    xil_printf("INFO: VPHY ready\r\n");
    return XST_SUCCESS;
}

static int ConfigureFrmbuf(const XVidC_VideoStream *StreamPtr, u32 stride)
{
    int status;

    XVFrmbufRd_Stop(&FrmbufRd);
    XVFrmbufRd_WaitForIdle(&FrmbufRd);

    status = XVFrmbufRd_SetMemFormat(&FrmbufRd, stride, VIDEO_MEM_FORMAT,
                                     (XVidC_VideoStream *)StreamPtr);
    if (status != XST_SUCCESS) {
        xil_printf("ERR: XVFrmbufRd_SetMemFormat failed: %d\r\n", status);
        return status;
    }

    status = XVFrmbufRd_SetBufferAddr(&FrmbufRd, FRAME_BASE_ADDR);
    if (status != XST_SUCCESS) {
        xil_printf("ERR: XVFrmbufRd_SetBufferAddr failed: %d\r\n", status);
        return status;
    }

    XVFrmbufRd_Start(&FrmbufRd);
    xil_printf("INFO: Frame buffer reader started\r\n");
    return XST_SUCCESS;
}

static int StartHdmi(const XVidC_VideoStream *StreamPtr)
{
    u32 tmds_clock;
    int status;

    tmds_clock = XV_HdmiTxSs_SetStream(&HdmiTxSs, StreamPtr->VmId,
                                       StreamPtr->ColorFormatId,
                                       StreamPtr->ColorDepth, NULL);
    if (tmds_clock == 0U) {
        xil_printf("ERR: Sink rejected requested HDMI mode\r\n");
        return XST_FAILURE;
    }

    Vphy.HdmiTxRefClkHz = tmds_clock;

    status = XVphy_SetHdmiTxParam(&Vphy, 0U, XVPHY_CHANNEL_ID_CHA,
                                  StreamPtr->PixPerClk, StreamPtr->ColorDepth,
                                  StreamPtr->ColorFormatId);
    if (status != XST_SUCCESS) {
        xil_printf("ERR: XVphy_SetHdmiTxParam failed: %d\r\n", status);
        return status;
    }

    status = BoardClockInit(tmds_clock);
    if (status != XST_SUCCESS) {
        xil_printf("ERR: BoardClockInit failed: %d\r\n", status);
        return status;
    }

    XV_HdmiTxSs_StreamStart(&HdmiTxSs);
    xil_printf("INFO: HDMI TX stream started\r\n");
    xil_printf("INFO: TMDS clock = %lu Hz\r\n", (unsigned long)tmds_clock);
    return XST_SUCCESS;
}

int main(void)
{
    int status;
    u32 stride;
    XVidC_VideoStream stream;
    u8 ppc;

    xil_printf("\r\n=== ZCU106 HDMI TX from DDR ===\r\n");
    xil_printf("Connect HDMI sink before running this app\r\n");

    status = InitFmcIic();
    if (status != XST_SUCCESS) {
        return status;
    }

    status = InitFrmbuf();
    if (status != XST_SUCCESS) {
        return status;
    }

    status = InitHdmiTxSs();
    if (status != XST_SUCCESS) {
        return status;
    }

    status = InitVphy();
    if (status != XST_SUCCESS) {
        return status;
    }

    ppc = HdmiTxSs.Config.Ppc;
    if (ppc != FrmbufRd.FrmbufRd.Config.PixPerClk) {
        xil_printf("ERR: PPC mismatch: HdmiTxSs=%u, FrmbufRd=%u\r\n",
                   ppc, FrmbufRd.FrmbufRd.Config.PixPerClk);
        return XST_FAILURE;
    }

    BuildVideoStream(&stream, ppc);
    stride = CalcStride(VIDEO_MEM_FORMAT, FrmbufRd.FrmbufRd.Config.AXIMMDataWidth,
                        &stream);

    xil_printf("INFO: mode=%s, stride=%lu bytes\r\n",
               XVidC_GetVideoModeStr(stream.VmId), (unsigned long)stride);
    xil_printf("INFO: framebuffer addr=0x%08lx\r\n", (unsigned long)FRAME_BASE_ADDR);

    FillColorBarsRgb888(FRAME_BASE_ADDR, &stream, stride);

    status = ConfigureFrmbuf(&stream, stride);
    if (status != XST_SUCCESS) {
        return status;
    }

    status = StartHdmi(&stream);
    if (status != XST_SUCCESS) {
        return status;
    }

    xil_printf("INFO: If the monitor stays black, implement BoardClockInit()\r\n");

    while (1) {
        usleep(1000000);
    }

    return 0;
}
