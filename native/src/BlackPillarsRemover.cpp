#include <cstdint>
#include <cstring>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <intrin.h>
#include <string>
#include <windows.h>

#define RED4EXT_HEADER_ONLY
#include <RED4ext/RED4ext.hpp>
#include <RED4ext/Scripting/Utils.hpp>
#include <RED4ext/Scripting/Natives/Generated/Vector2.hpp>

namespace
{
RED4ext::v1::PluginHandle s_pluginHandle{};
const RED4ext::v1::Sdk* s_sdk = nullptr;

using FitReferenceRect_t = RED4ext::Vector2* (*)(RED4ext::Vector2*, const RED4ext::Vector2*);
FitReferenceRect_t s_originalFitReferenceRect = nullptr;
void* s_fitReferenceRectTarget = nullptr;
uintptr_t s_controllerPointerCallerReturn = 0;
std::atomic_bool s_suppressed{false};
std::atomic_uintptr_t s_gameWindow{};
std::atomic_uint64_t s_lastWindowSearchMs{};
uint32_t s_configuredWidth = 0;
uint32_t s_configuredHeight = 0;

void LogInfo(const char* aMessage)
{
    if (s_sdk != nullptr && s_sdk->logger != nullptr)
        s_sdk->logger->Info(s_pluginHandle, aMessage);
}

bool LoadConfiguredResolution()
{
    const DWORD environmentLength =
        GetEnvironmentVariableW(L"LOCALAPPDATA", nullptr, 0);
    if (environmentLength <= 1)
        return false;

    std::wstring localAppData(environmentLength, L'\0');
    if (GetEnvironmentVariableW(L"LOCALAPPDATA", localAppData.data(),
                                environmentLength) == 0)
        return false;
    localAppData.resize(environmentLength - 1);

    const std::wstring settingsPath = localAppData +
        L"\\CD Projekt Red\\Cyberpunk 2077\\UserSettings.json";
    const HANDLE file = CreateFileW(
        settingsPath.c_str(), GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE)
        return false;

    LARGE_INTEGER fileSize{};
    constexpr LONGLONG kMaximumSettingsSize = 16LL * 1024LL * 1024LL;
    if (!GetFileSizeEx(file, &fileSize) || fileSize.QuadPart <= 0 ||
        fileSize.QuadPart > kMaximumSettingsSize)
    {
        CloseHandle(file);
        return false;
    }

    std::string contents(static_cast<size_t>(fileSize.QuadPart), '\0');
    DWORD bytesRead = 0;
    const bool read = ReadFile(file, contents.data(),
                               static_cast<DWORD>(contents.size()),
                               &bytesRead, nullptr) != FALSE;
    CloseHandle(file);
    if (!read || bytesRead == 0)
        return false;
    contents.resize(bytesRead);

    const auto resolutionSetting = contents.find("\"name\": \"Resolution\"");
    if (resolutionSetting == std::string::npos)
        return false;
    const auto valueKey = contents.find("\"value\"", resolutionSetting);
    const auto valueSeparator = valueKey != std::string::npos
        ? contents.find(':', valueKey)
        : std::string::npos;
    const auto valueStart = valueSeparator != std::string::npos
        ? contents.find('"', valueSeparator)
        : std::string::npos;
    const auto valueEnd = valueStart != std::string::npos
        ? contents.find('"', valueStart + 1)
        : std::string::npos;
    if (valueStart == std::string::npos || valueEnd == std::string::npos)
        return false;

    const std::string resolution =
        contents.substr(valueStart + 1, valueEnd - valueStart - 1);
    char* widthEnd = nullptr;
    const auto width = std::strtoul(resolution.c_str(), &widthEnd, 10);
    if (widthEnd == resolution.c_str() ||
        (*widthEnd != 'x' && *widthEnd != 'X'))
        return false;
    char* heightEnd = nullptr;
    const auto height = std::strtoul(widthEnd + 1, &heightEnd, 10);
    if (heightEnd == widthEnd + 1 || *heightEnd != '\0' ||
        width == 0 || height == 0)
        return false;

    s_configuredWidth = static_cast<uint32_t>(width);
    s_configuredHeight = static_cast<uint32_t>(height);

    char message[160]{};
    std::snprintf(message, sizeof(message),
                  "[BlackPillarsRemover] configured resolution detected: %ux%u",
                  s_configuredWidth, s_configuredHeight);
    LogInfo(message);
    return true;
}

struct WindowCandidate
{
    DWORD processId;
    HWND window;
    uint64_t area;
};

BOOL CALLBACK FindGameWindow(HWND aWindow, LPARAM aParameter)
{
    auto* candidate = reinterpret_cast<WindowCandidate*>(aParameter);
    DWORD processId = 0;
    GetWindowThreadProcessId(aWindow, &processId);
    if (processId != candidate->processId || !IsWindowVisible(aWindow) ||
        GetWindow(aWindow, GW_OWNER) != nullptr)
        return TRUE;

    RECT client{};
    if (!GetClientRect(aWindow, &client))
        return TRUE;
    const auto width = static_cast<uint64_t>(client.right - client.left);
    const auto height = static_cast<uint64_t>(client.bottom - client.top);
    const auto area = width * height;
    if (width > 0 && height > 0 && area > candidate->area)
    {
        candidate->window = aWindow;
        candidate->area = area;
    }
    return TRUE;
}

HWND GetGameWindow()
{
    const auto cachedValue = s_gameWindow.load(std::memory_order_relaxed);
    const auto cached = reinterpret_cast<HWND>(cachedValue);
    if (cached != nullptr && IsWindow(cached))
        return cached;

    const auto now = GetTickCount64();
    auto previousSearch = s_lastWindowSearchMs.load(std::memory_order_relaxed);
    if (now - previousSearch < 1000 ||
        !s_lastWindowSearchMs.compare_exchange_strong(
            previousSearch, now, std::memory_order_relaxed))
        return nullptr;

    WindowCandidate candidate{GetCurrentProcessId(), nullptr, 0};
    EnumWindows(FindGameWindow, reinterpret_cast<LPARAM>(&candidate));
    if (candidate.window != nullptr)
        s_gameWindow.store(reinterpret_cast<uintptr_t>(candidate.window),
                           std::memory_order_relaxed);
    return candidate.window;
}

bool HasMatchingAspect(float aInputAspect)
{
    constexpr float kAspectTolerance = 0.01f;
    // UserSettings.json is read once during plugin load, so the normal hot
    // path does not need to call into User32 for every fitted rectangle.
    if (s_configuredWidth > 0 && s_configuredHeight > 0 &&
        std::fabs(aInputAspect -
                  static_cast<float>(s_configuredWidth) /
                      static_cast<float>(s_configuredHeight)) <=
            kAspectTolerance)
        return true;

    // Fall back to the live game client rectangle if the setting is absent,
    // stale, or the resolution was changed after the plugin was loaded.
    const auto gameWindow = GetGameWindow();
    RECT client{};
    if (gameWindow != nullptr && GetClientRect(gameWindow, &client))
    {
        const auto width = client.right - client.left;
        const auto height = client.bottom - client.top;
        if (width > 0 && height > 0 &&
            std::fabs(aInputAspect -
                      static_cast<float>(width) / static_cast<float>(height)) <=
                kAspectTolerance)
            return true;
    }
    return false;
}

RED4ext::Vector2* FitReferenceRectOverride(RED4ext::Vector2* aResult,
                                           const RED4ext::Vector2* aInput)
{
    auto* result = s_originalFitReferenceRect(aResult, aInput);

    // This caller converts analog-controller pointer coordinates into the
    // stock UI reference space. Returning the physical ultrawide rectangle
    // here makes the virtual pointer appear but prevents stick movement.
    // Keep the stock fitted rectangle for this input path while allowing the
    // fullscreen compositor callers below to use the physical rectangle.
    const bool isControllerPointerPath =
        s_controllerPointerCallerReturn != 0 &&
        reinterpret_cast<uintptr_t>(_ReturnAddress()) ==
            s_controllerPointerCallerReturn;

    // REDengine normally fits fullscreen menus into a fixed 3840x2160
    // reference rectangle. Preserve the physical rectangle on ultrawide
    // displays so the compositor does not generate side pillars.
    if (result != nullptr && aInput != nullptr &&
        s_suppressed.load(std::memory_order_relaxed) &&
        !isControllerPointerPath &&
        aInput->X >= 1800.0f && aInput->Y >= 700.0f &&
        aInput->X / aInput->Y > (16.0f / 9.0f + 0.01f) &&
        // Match the aspect rather than the exact dimensions: REDengine may
        // pass either the physical resolution (for example 1920x816) or its
        // proportional 2160-high INK rectangle. The old 2500-pixel minimum
        // rejected legitimate lower-resolution ultrawide displays.
        (HasMatchingAspect(aInput->X / aInput->Y) ||
         // Preserve the former conservative behavior until either the game
         // window or UserSettings.json becomes available during early boot.
         (aInput->X >= 2500.0f && aInput->Y >= 700.0f)))
    {
        *result = *aInput;
    }

    return result;
}

void SetBlackBarsSuppressed(RED4ext::IScriptable* aContext,
                            RED4ext::CStackFrame* aFrame,
                            void* aOut, int64_t a4)
{
    RED4EXT_UNUSED_PARAMETER(aContext);
    RED4EXT_UNUSED_PARAMETER(aOut);
    RED4EXT_UNUSED_PARAMETER(a4);

    bool suppressed = false;
    RED4ext::GetParameter(aFrame, &suppressed);
    aFrame->code++;
    s_suppressed.store(suppressed, std::memory_order_relaxed);
    LogInfo(suppressed ? "[BlackPillarsRemover] pillars disabled"
                       : "[BlackPillarsRemover] pillars enabled");
}

// -1 in a pattern is a wildcard byte (RIP-relative displacements change with
// every game build).
uint8_t* FindUniquePattern(const int16_t* aPattern, size_t aLength)
{
    auto* imageBase = reinterpret_cast<uint8_t*>(GetModuleHandleW(nullptr));
    if (imageBase == nullptr)
        return nullptr;

    const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(imageBase);
    const auto* nt = reinterpret_cast<const IMAGE_NT_HEADERS64*>(
        imageBase + dos->e_lfanew);
    const auto* section = IMAGE_FIRST_SECTION(nt);
    for (WORD i = 0; i < nt->FileHeader.NumberOfSections; ++i, ++section)
    {
        if (std::memcmp(section->Name, ".text", 6) != 0)
            continue;

        uint8_t* begin = imageBase + section->VirtualAddress;
        const size_t size = section->Misc.VirtualSize;
        uint8_t* found = nullptr;
        for (size_t offset = 0; offset + aLength <= size; ++offset)
        {
            size_t j = 0;
            while (j < aLength &&
                   (aPattern[j] < 0 ||
                    begin[offset + j] == static_cast<uint8_t>(aPattern[j])))
                ++j;
            if (j != aLength)
                continue;
            // Refuse ambiguous matches instead of hooking the wrong code.
            if (found != nullptr)
                return nullptr;
            found = begin + offset;
        }
        return found;
    }
    return nullptr;
}

uint8_t* ResolveCallTarget(uint8_t* aCall)
{
    int32_t displacement = 0;
    std::memcpy(&displacement, aCall + 1, sizeof(displacement));
    return aCall + 5 + displacement;
}

void FindControllerPointerCaller(uint8_t* aTarget)
{
    // Small wrapper used by the analog-stick virtual pointer: it copies the
    // input vector to the stack and calls FitReferenceRect (2.31 / 2.5).
    constexpr int16_t kCallerPattern[] = {
        0x48, 0x8B, 0xC4, 0x48, 0x83, 0xEC, 0x28, 0xF3, 0x0F, 0x10, 0x02,
        0x4C, 0x8B, 0xC1, 0xF3, 0x0F, 0x10, 0x4A, 0x04, 0x48, 0x8D, 0x48,
        0x10, 0x48, 0x8D, 0x50, 0x08, 0xF3, 0x0F, 0x11, 0x40, 0x08, 0xF3,
        0x0F, 0x11, 0x48, 0x0C, 0xE8
    };
    constexpr size_t kCallOffset = sizeof(kCallerPattern) / sizeof(int16_t) - 1;

    auto* caller = FindUniquePattern(
        kCallerPattern, sizeof(kCallerPattern) / sizeof(int16_t));
    if (caller == nullptr || ResolveCallTarget(caller + kCallOffset) != aTarget)
    {
        LogInfo("[BlackPillarsRemover] controller pointer caller not found; "
                "stick pointer may not move while pillars are disabled");
        return;
    }
    s_controllerPointerCallerReturn =
        reinterpret_cast<uintptr_t>(caller + kCallOffset + 5);
}

bool InstallHook()
{
    if (s_sdk == nullptr || s_sdk->hooking == nullptr)
        return false;

    // Located by signature rather than a fixed RVA so game patches that only
    // move the function (2.31 -> 2.5) keep working. Refuse to attach if the
    // function body itself changed.
    constexpr int16_t kFitReferenceRectPattern[] = {
        0xF3, 0x0F, 0x10, 0x42, 0x04,             // movss xmm0, [rdx+4]
        0xF3, 0x0F, 0x10, 0x0A,                   // movss xmm1, [rdx]
        0x0F, 0x28, 0xD0,                         // movaps xmm2, xmm0
        0xF3, 0x0F, 0x59, 0x15, -1, -1, -1, -1,   // mulss xmm2, [rip+x]
        0x0F, 0x28, 0xD9,                         // movaps xmm3, xmm1
        0xF3, 0x0F, 0x59, 0x1D                    // mulss xmm3, [rip+x]
    };

    auto* target = FindUniquePattern(
        kFitReferenceRectPattern,
        sizeof(kFitReferenceRectPattern) / sizeof(int16_t));
    if (target == nullptr)
    {
        LogInfo("[BlackPillarsRemover] unsupported game executable; hook not installed");
        return false;
    }

    FindControllerPointerCaller(target);

    if (!s_sdk->hooking->Attach(s_pluginHandle, target,
                                reinterpret_cast<void*>(&FitReferenceRectOverride),
                                reinterpret_cast<void**>(&s_originalFitReferenceRect)))
    {
        LogInfo("[BlackPillarsRemover] hook installation failed");
        return false;
    }

    s_fitReferenceRectTarget = target;
    LogInfo("[BlackPillarsRemover] ultrawide fullscreen composition enabled");
    return true;
}
} // namespace

RED4EXT_C_EXPORT void RED4EXT_CALL RegisterTypes()
{
}

RED4EXT_C_EXPORT void RED4EXT_CALL PostRegisterTypes()
{
    auto* rtti = RED4ext::CRTTISystem::Get();
    RED4ext::CBaseFunction::Flags flags{};
    flags.isNative = true;
    flags.isStatic = true;

    auto* function = RED4ext::CGlobalFunction::Create(
        "UWMapSetBlackBarsSuppressed", "UWMapSetBlackBarsSuppressed", &SetBlackBarsSuppressed);
    function->flags = flags;
    function->AddParam("Bool", "suppressed");
    rtti->RegisterFunction(function);
}

RED4EXT_C_EXPORT bool RED4EXT_CALL Main(RED4ext::v1::PluginHandle aHandle,
                                        RED4ext::v1::EMainReason aReason,
                                        const RED4ext::v1::Sdk* aSdk)
{
    if (aReason == RED4ext::v1::EMainReason::Load)
    {
        s_pluginHandle = aHandle;
        s_sdk = aSdk;
        s_suppressed.store(false, std::memory_order_relaxed);
        s_gameWindow.store(0, std::memory_order_relaxed);
        s_lastWindowSearchMs.store(0, std::memory_order_relaxed);
        LoadConfiguredResolution();
        auto* rtti = RED4ext::CRTTISystem::Get();
        rtti->AddRegisterCallback(RegisterTypes);
        rtti->AddPostRegisterCallback(PostRegisterTypes);
        InstallHook();
    }
    else if (aReason == RED4ext::v1::EMainReason::Unload &&
             s_sdk != nullptr && s_sdk->hooking != nullptr &&
             s_fitReferenceRectTarget != nullptr)
    {
        s_sdk->hooking->Detach(s_pluginHandle, s_fitReferenceRectTarget);
        s_fitReferenceRectTarget = nullptr;
        s_originalFitReferenceRect = nullptr;
    }

    return true;
}

RED4EXT_C_EXPORT void RED4EXT_CALL Query(RED4ext::v1::PluginInfo* aInfo)
{
    aInfo->name = L"Black Pillars Remover";
    aInfo->author = L"djoole";
    aInfo->version = RED4EXT_V1_SEMVER(2, 5, 6);
    // The hook validates the executable itself by signature, so do not let
    // RED4ext reject the plugin on every game patch.
    aInfo->runtime = RED4EXT_V1_RUNTIME_VERSION_INDEPENDENT;
    aInfo->sdk = RED4EXT_V1_SDK_VERSION_CURRENT;
}

RED4EXT_C_EXPORT uint32_t RED4EXT_CALL Supports()
{
    return RED4EXT_API_VERSION_1;
}
