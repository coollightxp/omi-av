#include "screen_recorder_core.h"

#include <audioclient.h>
#include <audioclientactivationparams.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mmdeviceapi.h>
#include <windows.graphics.capture.h>
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>
#include <winrt/base.h>

#include <atomic>
#include <cstring>
#include <mutex>
#include <thread>
#include <vector>

#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfuuid.lib")
#pragma comment(lib, "mfreadwrite.lib")
#pragma comment(lib, "wmcodecdspuuid.lib")
#pragma comment(lib, "mmdevapi.lib")
#pragma comment(lib, "windowsapp.lib")
#pragma comment(lib, "ole32.lib")

namespace omi_recorder {

namespace {

namespace wgc = winrt::Windows::Graphics::Capture;
namespace wgdx = winrt::Windows::Graphics::DirectX;
namespace wgdx11 = winrt::Windows::Graphics::DirectX::Direct3D11;

// VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK（SDK 19041 起才有定义，自带一份防旧）
constexpr GUID kVirtualAudioDeviceProcessLoopback = {
    0x2e3e7c9a, 0xb9ee, 0x4edd, {0x9b, 0x3f, 0x87, 0x79, 0xe5, 0x6c, 0x37, 0x4f}};

// KSDATAFORMAT_SUBTYPE_IEEE_FLOAT
constexpr GUID kIeeeFloatSubtype = {
    0x00000003, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}};

// ActivateAudioInterface 在部分 SDK 的导入库/头文件守卫不一致（静态链接
// LNK2019），改为运行时从 mmdevapi.dll 动态解析，签名固定、行为一致
typedef HRESULT(__stdcall* ActivateAudioInterfaceProc)(const GUID*,
                                                       const PROPVARIANT*,
                                                       REFIID, void**);

ActivateAudioInterfaceProc ResolveActivateAudioInterface() {
  static ActivateAudioInterfaceProc proc = nullptr;
  if (proc == nullptr) {
    HMODULE h = LoadLibraryW(L"mmdevapi.dll");
    if (h != nullptr) {
      proc = reinterpret_cast<ActivateAudioInterfaceProc>(
          GetProcAddress(h, "ActivateAudioInterface"));
    }
  }
  return proc;
}

std::wstring Utf8ToWide(const std::string& s) {
  if (s.empty()) return std::wstring();
  int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()),
                              nullptr, 0);
  if (n <= 0) return std::wstring();
  std::wstring w(static_cast<size_t>(n), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()),
                      &w[0], n);
  return w;
}

LARGE_INTEGER QpcNow() {
  LARGE_INTEGER v;
  QueryPerformanceCounter(&v);
  return v;
}

// 相对 start 的 100ns 时间戳（MF 采样时间单位）
int64_t Qpc100ns(LARGE_INTEGER start, LARGE_INTEGER now, LARGE_INTEGER freq) {
  return static_cast<int64_t>((now.QuadPart - start.QuadPart) * 10000000LL /
                              freq.QuadPart);
}

bool IsFloatFormat(const WAVEFORMATEX* f) {
  if (f == nullptr) return false;
  if (f->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) return true;
  if (f->wFormatTag == WAVE_FORMAT_EXTENSIBLE && f->cbSize >= 22) {
    const WAVEFORMATEXTENSIBLE* ext =
        reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(f);
    return ext->SubFormat == kIeeeFloatSubtype;
  }
  return false;
}

// ---------------- 全局状态（单实例录制，进程内只有一路） ----------------
struct RecorderState {
  std::atomic<bool> running{false};
  LARGE_INTEGER startQpc{};
  LARGE_INTEGER freq{};

  // WGC
  wgc::GraphicsCaptureItem item{nullptr};
  wgc::Direct3D11CaptureFramePool pool{nullptr};
  wgc::GraphicsCaptureSession session{nullptr};
  wgc::Direct3D11CaptureFramePool::FrameArrived_revoker frameRevoker;
  winrt::com_ptr<ID3D11Device> d3d;
  winrt::com_ptr<ID3D11DeviceContext> ctx;
  winrt::com_ptr<ID3D11Texture2D> staging;
  int width = 0;
  int height = 0;
  int fps = 30;
  int bitrateMbps = 8;

  // 帧缓冲：WGC 回调生产，encode 线程消费
  std::mutex frameMutex;
  std::vector<uint8_t> pendingFrame;
  LARGE_INTEGER pendingQpc{};
  bool hasPending = false;

  // Media Foundation
  IMFSinkWriter* writer = nullptr;
  DWORD videoIdx = 0;
  DWORD audioIdx = 0;
  bool hasAudio = false;
  std::mutex writerMutex;

  // 音频（对象在启动线程创建，泵循环线程只做 GetBuffer/ReleaseBuffer）
  IAudioClient* aClient = nullptr;
  IAudioCaptureClient* aCapture = nullptr;
  WAVEFORMATEX* aFormat = nullptr;
  HANDLE aEvent = nullptr;
  bool aEventDriven = false;

  // 线程
  std::thread encodeThread;
  std::thread audioThread;
  std::atomic<bool> encodeStop{false};
  std::atomic<bool> audioStop{false};
};

RecorderState g;

// ---------------- WGC 帧回调 ----------------
void OnFrame(wgc::Direct3D11CaptureFramePool const& sender) {
  if (!g.running.load()) return;
  wgc::Direct3D11CaptureFrame frame = sender.TryGetNextFrame();
  if (!frame) return;
  try {
    wgdx11::IDirect3DSurface surface = frame.Surface();
    if (!surface) return;
    auto access = surface.as<
        ::Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess>();
    winrt::com_ptr<::ID3D11Texture2D> tex;
    if (FAILED(access->GetInterface(winrt::guid_of<::ID3D11Texture2D>(),
                                    tex.put_void())) ||
        tex == nullptr) {
      return;
    }
    D3D11_TEXTURE2D_DESC desc{};
    tex->GetDesc(&desc);
    // 窗口尺寸变化时按较小者拷贝：变大裁掉、变小留旧帧残留（可接受）
    const UINT cw = desc.Width < static_cast<UINT>(g.width)
                        ? desc.Width
                        : static_cast<UINT>(g.width);
    const UINT ch = desc.Height < static_cast<UINT>(g.height)
                        ? desc.Height
                        : static_cast<UINT>(g.height);
    D3D11_BOX box{0, 0, 0, cw, ch, 1};
    g.ctx->CopySubresourceRegion(g.staging.get(), 0, 0, 0, 0, tex.get(), 0,
                                 &box);
    D3D11_MAPPED_SUBRESOURCE mapped{};
    if (FAILED(g.ctx->Map(g.staging.get(), 0, D3D11_MAP_READ, 0, &mapped))) {
      return;
    }
    {
      std::lock_guard<std::mutex> lk(g.frameMutex);
      g.pendingFrame.assign(static_cast<size_t>(g.width) * g.height * 4, 0);
      const uint8_t* src = static_cast<const uint8_t*>(mapped.pData);
      for (UINT y = 0; y < ch; ++y) {
        std::memcpy(g.pendingFrame.data() + static_cast<size_t>(y) * g.width * 4,
                    src + static_cast<size_t>(y) * mapped.RowPitch,
                    static_cast<size_t>(cw) * 4);
      }
      g.pendingQpc = QpcNow();
      g.hasPending = true;
    }
    g.ctx->Unmap(g.staging.get(), 0);
  } catch (...) {
    // 单帧失败不影响整体录制
  }
}

// ---------------- 音频采集设置（启动线程调用，非阻塞） ----------------
bool SetupAudioCapture() {
  // 首选进程回环：只录本进程（含 WebView2 子进程树）
  {
    AUDIOCLIENT_ACTIVATION_PARAMS params{};
    params.ActivationType = AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK;
    params.ProcessLoopbackParams.TargetProcessId = GetCurrentProcessId();
    params.ProcessLoopbackParams.ProcessLoopbackMode =
        PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE;
    PROPVARIANT pv{};
    pv.vt = VT_BLOB;
    pv.blob.cbSize = sizeof(params);
    pv.blob.pBlobData = reinterpret_cast<BYTE*>(&params);
    IAudioClient* client = nullptr;
    const auto activate = ResolveActivateAudioInterface();
    const HRESULT hr = activate != nullptr
                           ? activate(&kVirtualAudioDeviceProcessLoopback, &pv,
                                      IID_PPV_ARGS(&client))
                           : E_NOTIMPL;
    if (SUCCEEDED(hr) && client != nullptr) {
      WAVEFORMATEX* fmt = nullptr;
      if (SUCCEEDED(client->GetMixFormat(&fmt)) && IsFloatFormat(fmt)) {
        g.aEvent = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        HRESULT hri = client->Initialize(
            AUDCLNT_SHAREMODE_SHARED,
            AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
            200000, 0, fmt, nullptr);
        if (SUCCEEDED(hri) && g.aEvent != nullptr &&
            SUCCEEDED(client->SetEventHandle(g.aEvent))) {
          IAudioCaptureClient* cap = nullptr;
          if (SUCCEEDED(client->GetService(IID_PPV_ARGS(&cap))) &&
              cap != nullptr) {
            g.aClient = client;
            g.aFormat = fmt;
            g.aCapture = cap;
            g.aEventDriven = true;
            return true;
          }
          if (cap != nullptr) cap->Release();
        }
        if (fmt != nullptr) CoTaskMemFree(fmt);
        client->Release();
        if (g.aEvent != nullptr) {
          CloseHandle(g.aEvent);
          g.aEvent = nullptr;
        }
        // 继续走兜底
      } else {
        if (fmt != nullptr) CoTaskMemFree(fmt);
        client->Release();
      }
    }
  }
  // 兜底：默认输出设备回环（Win8+，整系统声音）
  {
    IMMDeviceEnumerator* enu = nullptr;
    if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                                CLSCTX_ALL, IID_PPV_ARGS(&enu))) ||
        enu == nullptr) {
      return false;
    }
    IMMDevice* dev = nullptr;
    enu->GetDefaultAudioEndpoint(eRender, eMultimedia, &dev);
    enu->Release();
    if (dev == nullptr) return false;
    IAudioClient* client = nullptr;
    dev->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                  reinterpret_cast<void**>(&client));
    dev->Release();
    if (client == nullptr) return false;
    WAVEFORMATEX* fmt = nullptr;
    if (FAILED(client->GetMixFormat(&fmt)) || !IsFloatFormat(fmt)) {
      if (fmt != nullptr) CoTaskMemFree(fmt);
      client->Release();
      return false;
    }
    // 默认设备回环不支持事件驱动，轮询模式
    if (FAILED(client->Initialize(AUDCLNT_SHAREMODE_SHARED,
                                  AUDCLNT_STREAMFLAGS_LOOPBACK, 200000, 0, fmt,
                                  nullptr))) {
      CoTaskMemFree(fmt);
      client->Release();
      return false;
    }
    IAudioCaptureClient* cap = nullptr;
    if (FAILED(client->GetService(IID_PPV_ARGS(&cap))) || cap == nullptr) {
      CoTaskMemFree(fmt);
      client->Release();
      return false;
    }
    g.aClient = client;
    g.aFormat = fmt;
    g.aCapture = cap;
    g.aEventDriven = false;
    return true;
  }
}

// ---------------- 音频泵循环 ----------------
void AudioLoop() {
  CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  if (g.aClient != nullptr) g.aClient->Start();
  const UINT32 samplesPerSec =
      g.aFormat != nullptr ? g.aFormat->nSamplesPerSec : 48000;
  const UINT32 blockAlign =
      g.aFormat != nullptr ? g.aFormat->nBlockAlign : 8;
  while (!g.audioStop.load()) {
    if (g.aEventDriven) {
      WaitForSingleObject(g.aEvent, 200);
    } else {
      Sleep(8);
    }
    if (g.audioStop.load()) break;
    UINT32 next = 0;
    while (SUCCEEDED(g.aCapture->GetNextPacketSize(&next)) && next > 0) {
      BYTE* data = nullptr;
      UINT32 frames = 0;
      DWORD flags = 0;
      UINT64 pos = 0;
      UINT64 qpcPos = 0;
      if (FAILED(g.aCapture->GetBuffer(&data, &frames, &flags, &pos, &qpcPos))) {
        break;
      }
      const UINT32 bytes = frames * blockAlign;
      if (bytes > 0 && g.writer != nullptr && g.hasAudio) {
        IMFSample* sample = nullptr;
        IMFMediaBuffer* buf = nullptr;
        if (SUCCEEDED(MFCreateSample(&sample)) && SUCCEEDED(MFCreateMemoryBuffer(bytes, &buf))) {
          BYTE* dst = nullptr;
          if (SUCCEEDED(buf->Lock(&dst, nullptr, nullptr))) {
            if (flags & AUDCLNT_BUFFERFLAGS_SILENT) {
              std::memset(dst, 0, bytes);
            } else {
              std::memcpy(dst, data, bytes);
            }
            buf->Unlock();
          }
          buf->SetCurrentLength(bytes);
          sample->AddBuffer(buf);
          buf->Release();
          const LARGE_INTEGER now = QpcNow();
          sample->SetSampleTime(Qpc100ns(g.startQpc, now, g.freq));
          sample->SetSampleDuration(static_cast<int64_t>(frames) * 10000000LL /
                                    samplesPerSec);
          {
            std::lock_guard<std::mutex> lk(g.writerMutex);
            if (g.writer != nullptr) {
              g.writer->WriteSample(g.audioIdx, sample);
            }
          }
          sample->Release();
        }
      }
      g.aCapture->ReleaseBuffer(frames);
    }
  }
  if (g.aClient != nullptr) g.aClient->Stop();
  CoUninitialize();
}

// ---------------- 视频编码循环 ----------------
void EncodeLoop() {
  CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  const UINT32 frameBytes =
      static_cast<UINT32>(g.width) * static_cast<UINT32>(g.height) * 4;
  int64_t lastTs = 0;
  const int64_t nominalDur = 10000000LL / (g.fps > 0 ? g.fps : 30);
  while (!g.encodeStop.load()) {
    bool has = false;
    std::vector<uint8_t> buf;
    LARGE_INTEGER fq{};
    {
      std::lock_guard<std::mutex> lk(g.frameMutex);
      has = g.hasPending;
      if (has) {
        buf = std::move(g.pendingFrame);
        fq = g.pendingQpc;
        g.hasPending = false;
      }
    }
    if (has && g.writer != nullptr) {
      const int64_t ts = Qpc100ns(g.startQpc, fq, g.freq);
      int64_t dur = ts - lastTs;
      if (dur <= 0 || dur > 5000000) dur = nominalDur;
      lastTs = ts;
      IMFSample* sample = nullptr;
      IMFMediaBuffer* mbuf = nullptr;
      if (SUCCEEDED(MFCreateSample(&sample)) &&
          SUCCEEDED(MFCreateMemoryBuffer(frameBytes, &mbuf))) {
        BYTE* dst = nullptr;
        if (SUCCEEDED(mbuf->Lock(&dst, nullptr, nullptr))) {
          std::memset(dst, 0, frameBytes);
          if (!buf.empty()) {
            const size_t copy = buf.size() < frameBytes ? buf.size() : frameBytes;
            std::memcpy(dst, buf.data(), copy);
          }
          mbuf->Unlock();
        }
        mbuf->SetCurrentLength(frameBytes);
        sample->AddBuffer(mbuf);
        mbuf->Release();
        sample->SetSampleTime(ts);
        sample->SetSampleDuration(dur);
        {
          std::lock_guard<std::mutex> lk(g.writerMutex);
          if (g.writer != nullptr) {
            g.writer->WriteSample(g.videoIdx, sample);
          }
        }
        sample->Release();
      }
    } else {
      Sleep(3);
    }
  }
  CoUninitialize();
}

}  // namespace

// ---------------- 对外接口 ----------------

ScreenRecorder& ScreenRecorder::Instance() {
  static ScreenRecorder inst;
  return inst;
}

bool ScreenRecorder::IsSupported() {
  if (running_) return true;
  typedef LONG(WINAPI* RtlGetVersionPtr)(PRTL_OSVERSIONINFOW);
  const HMODULE nt = GetModuleHandleW(L"ntdll.dll");
  if (nt == nullptr) return false;
  const auto fn =
      reinterpret_cast<RtlGetVersionPtr>(GetProcAddress(nt, "RtlGetVersion"));
  if (fn == nullptr) return false;
  RTL_OSVERSIONINFOW info{};
  info.dwOSVersionInfoSize = sizeof(info);
  if (fn(&info) != 0) return false;
  if (info.dwMajorVersion > 10) return true;
  if (info.dwMajorVersion < 10) return false;
  // 进程回环音频需要 Win10 2004（build 19041）
  return info.dwBuildNumber >= 19041;
}

RecorderResult ScreenRecorder::Start(HWND hwnd, const std::string& pathUtf8,
                                     int fps, int bitrateMbps) {
  RecorderResult r;
  if (running_) {
    r.error = "already recording";
    return r;
  }
  if (hwnd == nullptr) {
    r.error = "no player window";
    return r;
  }
  try {
    if (FAILED(MFStartup(MF_VERSION))) {
      r.error = "MFStartup failed";
      return r;
    }

    // ---- D3D 设备（BGRA 支持，WGC 互通需要） ----
    D3D_FEATURE_LEVEL fl{};
    if (FAILED(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
                                 D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0,
                                 D3D11_SDK_VERSION, g.d3d.put(), &fl,
                                 g.ctx.put())) ||
        g.d3d == nullptr) {
      MFShutdown();
      r.error = "D3D11CreateDevice failed";
      return r;
    }

    // ---- 包装成 WinRT IDirect3DDevice ----
    winrt::com_ptr<IDXGIDevice> dxgiDev;
    g.d3d->QueryInterface(winrt::guid_of<IDXGIDevice>(), dxgiDev.put_void());
    winrt::com_ptr<::IInspectable> inspectable;
    if (FAILED(CreateDirect3D11DeviceFromDXGIDevice(dxgiDev.get(),
                                                    inspectable.put())) ||
        inspectable == nullptr) {
      MFShutdown();
      r.error = "CreateDirect3D11DeviceFromDXGIDevice failed";
      return r;
    }
    wgdx11::IDirect3DDevice d3dDevice =
        inspectable.as<wgdx11::IDirect3DDevice>();

    // ---- 捕获目标：播放器窗口 ----
    auto interop = winrt::get_activation_factory<wgc::GraphicsCaptureItem,
                                                 ::IGraphicsCaptureItemInterop>();
    wgc::GraphicsCaptureItem item{nullptr};
    if (FAILED(interop->CreateForWindow(
            hwnd, winrt::guid_of<wgc::GraphicsCaptureItem>(),
            winrt::put_abi(item))) ||
        item == nullptr) {
      MFShutdown();
      r.error = "CreateForWindow failed (窗口捕获不可用)";
      return r;
    }
    const winrt::Windows::Graphics::SizeInt32 size = item.Size();
    g.width = size.Width & ~1;  // H.264 要求偶数尺寸
    g.height = size.Height & ~1;
    g.fps = fps > 0 && fps <= 60 ? fps : 30;
    g.bitrateMbps = bitrateMbps > 0 && bitrateMbps <= 60 ? bitrateMbps : 8;
    if (g.width < 2 || g.height < 2) {
      MFShutdown();
      r.error = "window size invalid";
      return r;
    }

    // ---- CPU 可读的中转纹理 ----
    D3D11_TEXTURE2D_DESC sd{};
    sd.Width = static_cast<UINT>(g.width);
    sd.Height = static_cast<UINT>(g.height);
    sd.MipLevels = 1;
    sd.ArraySize = 1;
    sd.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    sd.SampleDesc.Count = 1;
    sd.Usage = D3D11_USAGE_STAGING;
    sd.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    if (FAILED(g.d3d->CreateTexture2D(&sd, nullptr, g.staging.put())) ||
        g.staging == nullptr) {
      MFShutdown();
      r.error = "CreateTexture2D(staging) failed";
      return r;
    }

    // ---- 帧池（FreeThreaded：无需 DispatcherQueue） ----
    g.item = item;
    g.pool = wgc::Direct3D11CaptureFramePool::CreateFreeThreaded(
        d3dDevice, wgdx::DirectXPixelFormat::B8G8R8A8UIntNormalized, 2,
        winrt::Windows::Graphics::SizeInt32{g.width, g.height});
    if (!g.pool) {
      MFShutdown();
      r.error = "CaptureFramePool create failed";
      return r;
    }
    g.frameRevoker = g.pool.FrameArrived(
        winrt::auto_revoke,
        [](wgc::Direct3D11CaptureFramePool const& sender,
           winrt::Windows::Foundation::IInspectable const&) {
          OnFrame(sender);
        });

    // ---- SinkWriter：H.264 + AAC -> mp4 ----
    const std::wstring path = Utf8ToWide(pathUtf8);
    IMFSinkWriter* writer = nullptr;
    if (path.empty() ||
        FAILED(MFCreateSinkWriterFromURL(path.c_str(), nullptr, nullptr,
                                         &writer)) ||
        writer == nullptr) {
      r.error = "MFCreateSinkWriterFromURL failed";
      // 清理帧池
      g.frameRevoker.revoke();
      g.pool = nullptr;
      g.item = nullptr;
      g.staging = nullptr;
      g.ctx = nullptr;
      g.d3d = nullptr;
      MFShutdown();
      return r;
    }
    g.writer = writer;

    // 视频输出（H.264）
    IMFMediaType* vOut = nullptr;
    MFCreateMediaType(&vOut);
    vOut->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    vOut->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
    MFSetAttributeSize(vOut, MF_MT_FRAME_SIZE, g.width, g.height);
    MFSetAttributeRatio(vOut, MF_MT_FRAME_RATE, g.fps, 1);
    MFSetAttributeRatio(vOut, MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
    vOut->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
    vOut->SetUINT32(MF_MT_AVG_BITRATE, g.bitrateMbps * 1000000);
    HRESULT hr = writer->AddStream(vOut, &g.videoIdx);
    vOut->Release();
    if (FAILED(hr)) {
      r.error = "AddStream(video) failed";
      Stop();
      return r;
    }

    // 视频输入（BGRA32，颜色转换由 SinkWriter 自动插入 DSP）
    IMFMediaType* vIn = nullptr;
    MFCreateMediaType(&vIn);
    vIn->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    vIn->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
    MFSetAttributeSize(vIn, MF_MT_FRAME_SIZE, g.width, g.height);
    MFSetAttributeRatio(vIn, MF_MT_FRAME_RATE, g.fps, 1);
    MFSetAttributeRatio(vIn, MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
    vIn->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
    hr = writer->SetInputMediaType(g.videoIdx, vIn, nullptr);
    vIn->Release();
    if (FAILED(hr)) {
      r.error = "SetInputMediaType(video) failed";
      Stop();
      return r;
    }

    // 音频：能采到就加一路 AAC
    g.hasAudio = false;
    if (SetupAudioCapture() && g.aFormat != nullptr) {
      const UINT32 rate = g.aFormat->nSamplesPerSec;
      IMFMediaType* aOut = nullptr;
      MFCreateMediaType(&aOut);
      aOut->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
      aOut->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_AAC);
      aOut->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, rate);
      aOut->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, 2);
      aOut->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
      aOut->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, 128000);
      hr = writer->AddStream(aOut, &g.audioIdx);
      aOut->Release();
      if (SUCCEEDED(hr)) {
        IMFMediaType* aIn = nullptr;
        MFCreateMediaType(&aIn);
        aIn->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
        aIn->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_Float);
        aIn->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, rate);
        aIn->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, 2);
        aIn->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 32);
        aIn->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, 8);
        aIn->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, rate * 8);
        hr = writer->SetInputMediaType(g.audioIdx, aIn, nullptr);
        aIn->Release();
        if (SUCCEEDED(hr)) {
          g.hasAudio = true;
        } else {
          // AAC 一路建立失败不致命：退化为纯视频
          g.audioIdx = 0;
        }
      }
    }

    if (FAILED(writer->BeginWriting())) {
      r.error = "BeginWrite failed";
      Stop();
      return r;
    }

    // ---- 启动采集与线程 ----
    QueryPerformanceFrequency(&g.freq);
    g.startQpc = QpcNow();
    g.hasPending = false;
    g.pendingFrame.clear();
    g.encodeStop = false;
    g.audioStop = false;
    g.running = true;
    running_ = true;
    // 显式会话：新投影里帧池没有 StartCapture(item) 便捷方法
    g.session = g.pool.CreateCaptureSession(g.item);
    g.session.StartCapture();
    g.encodeThread = std::thread(EncodeLoop);
    g.audioThread = std::thread(AudioLoop);
    r.ok = true;
    return r;
  } catch (const winrt::hresult_error& e) {
    try {
      Stop();
    } catch (...) {
    }
    r.error = winrt::to_string(e.message());
    return r;
  } catch (...) {
    try {
      Stop();
    } catch (...) {
    }
    r.error = "unknown error";
    return r;
  }
}

int64_t ScreenRecorder::Stop() {
  const bool wasRunning = g.running.load();
  const LARGE_INTEGER now = QpcNow();
  int64_t ms = 0;
  if (wasRunning && g.freq.QuadPart > 0) {
    ms = (now.QuadPart - g.startQpc.QuadPart) * 1000 / g.freq.QuadPart;
  }
  g.running = false;
  running_ = false;

  // 线程收尾
  g.encodeStop = true;
  if (g.encodeThread.joinable()) g.encodeThread.join();
  g.audioStop = true;
  if (g.audioThread.joinable()) g.audioThread.join();

  // SinkWriter 落盘（Finalize 写 mp4 文件尾）
  {
    std::lock_guard<std::mutex> lk(g.writerMutex);
    if (g.writer != nullptr) {
      g.writer->Finalize();
      g.writer->Release();
      g.writer = nullptr;
    }
  }

  // WGC 资源
  g.frameRevoker.revoke();
  g.session = nullptr;
  g.pool = nullptr;
  g.item = nullptr;
  g.staging = nullptr;
  g.ctx = nullptr;
  g.d3d = nullptr;

  // 音频资源
  if (g.aClient != nullptr) {
    g.aClient->Release();
    g.aClient = nullptr;
  }
  if (g.aCapture != nullptr) {
    g.aCapture->Release();
    g.aCapture = nullptr;
  }
  if (g.aFormat != nullptr) {
    CoTaskMemFree(g.aFormat);
    g.aFormat = nullptr;
  }
  if (g.aEvent != nullptr) {
    CloseHandle(g.aEvent);
    g.aEvent = nullptr;
  }
  g.aEventDriven = false;
  g.hasAudio = false;

  MFShutdown();
  return ms;
}

}  // namespace omi_recorder
