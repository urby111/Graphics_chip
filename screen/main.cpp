#define NOMINMAX
#include <windows.h>

#include <cstdint>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
constexpr int kWidth = 640;
constexpr int kHeight = 480;
std::vector<std::uint32_t> pixels(kWidth * kHeight);

bool load_frame(const char* path) {
    std::ifstream input(path);
    if (!input) {
        std::cerr << "Could not open '" << path << "'.\n";
        return false;
    }

    std::string token;
    for (std::size_t i = 0; i < pixels.size(); ++i) {
        if (!(input >> token)) {
            std::cerr << "Frame ended at pixel " << i
                      << "; expected 307200 RGB values.\n";
            return false;
        }

        try {
            std::size_t consumed = 0;
            const unsigned rgb = std::stoul(token, &consumed, 16);
            if (consumed != token.size() || rgb > 0x0fffU) {
                throw std::invalid_argument("not a 12-bit RGB value");
            }

            const unsigned r = ((rgb >> 8U) & 0x0fU) * 17U;
            const unsigned g = ((rgb >> 4U) & 0x0fU) * 17U;
            const unsigned b = (rgb & 0x0fU) * 17U;
            pixels[i] = (r << 16U) | (g << 8U) | b;
        } catch (const std::exception&) {
            std::cerr << "Invalid RGB value '" << token << "' at pixel " << i
                      << ". Expected 000 through FFF.\n";
            return false;
        }
    }

    if (input >> token) {
        std::cerr << "Warning: ignoring data after the first 307200 pixels.\n";
    }
    return true;
}

LRESULT CALLBACK window_proc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    switch (message) {
    case WM_PAINT: {
        PAINTSTRUCT paint{};
        HDC device = BeginPaint(window, &paint);

        RECT client{};
        GetClientRect(window, &client);
        BITMAPINFO bitmap{};
        bitmap.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
        bitmap.bmiHeader.biWidth = kWidth;
        bitmap.bmiHeader.biHeight = -kHeight;
        bitmap.bmiHeader.biPlanes = 1;
        bitmap.bmiHeader.biBitCount = 32;
        bitmap.bmiHeader.biCompression = BI_RGB;

        SetStretchBltMode(device, COLORONCOLOR);
        StretchDIBits(device, 0, 0, client.right, client.bottom,
                      0, 0, kWidth, kHeight, pixels.data(), &bitmap,
                      DIB_RGB_COLORS, SRCCOPY);
        EndPaint(window, &paint);
        return 0;
    }
    case WM_ERASEBKGND:
        return 1;
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    default:
        return DefWindowProc(window, message, wparam, lparam);
    }
}
}  // namespace

int main(int argc, char** argv) {
    const char* frame_path = argc >= 2 ? argv[1] : "first_frame.hex";
    if (!load_frame(frame_path)) {
        return 1;
    }

    HINSTANCE instance = GetModuleHandle(nullptr);
    const char class_name[] = "VgaFrameViewer";
    WNDCLASS window_class{};
    window_class.lpfnWndProc = window_proc;
    window_class.hInstance = instance;
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = class_name;

    if (!RegisterClass(&window_class)) {
        std::cerr << "Could not register the window class.\n";
        return 1;
    }

    RECT desired{0, 0, kWidth, kHeight};
    AdjustWindowRect(&desired, WS_OVERLAPPEDWINDOW, FALSE);
    HWND window = CreateWindowEx(
        0, class_name, "VGA first frame", WS_OVERLAPPEDWINDOW,
        CW_USEDEFAULT, CW_USEDEFAULT, desired.right - desired.left,
        desired.bottom - desired.top, nullptr, nullptr, instance, nullptr);
    if (!window) {
        std::cerr << "Could not create the viewer window.\n";
        return 1;
    }

    ShowWindow(window, SW_SHOWDEFAULT);
    MSG message{};
    while (GetMessage(&message, nullptr, 0, 0) > 0) {
        TranslateMessage(&message);
        DispatchMessage(&message);
    }
    return static_cast<int>(message.wParam);
}
