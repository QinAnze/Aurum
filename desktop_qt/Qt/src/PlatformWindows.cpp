#include "Host.h"
#include "AppStorage.h"
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QSaveFile>
#include <QUrl>
#include <QWindow>
#include <mutex>
#ifndef NOMINMAX
#define NOMINMAX
#endif
// Windows SDK 扩展头依赖基础类型；保留分组，避免格式化重新按字母排序。
#include <windows.h>

#include <shellapi.h>
#include <wincrypt.h>
// C++/WinRT 只有 MSVC + Windows SDK 的 cppwinrt 才提供；MinGW 下把
// 「系统媒体控制（任务栏浮层 / 媒体键）」降级为空实现，其余平台能力
// （DPAPI 凭据、文件对话框、原生窗口）保持不变。官方发布仍用 MSVC 构建。
#if !defined(__MINGW32__)
#include <systemmediatransportcontrolsinterop.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.h>
#endif

static QString credentialPath() {
    return AppStorage::dataDirectory() + "/account.dpapi";
}
QByteArray platformCredential() {
    QFile file(credentialPath());
    if (!file.open(QIODevice::ReadOnly)) {
        return {};
    }
    auto bytes = file.readAll();
    DATA_BLOB encrypted{DWORD(bytes.size()), reinterpret_cast<BYTE *>(bytes.data())}, plain{};
    // DPAPI 绑定当前 Windows 用户；账号文件不会以明文保存在项目或资源目录。
    if (!CryptUnprotectData(&encrypted, nullptr, nullptr, nullptr, nullptr, CRYPTPROTECT_UI_FORBIDDEN,
                            &plain)) {
        return {};
    }
    QByteArray result(reinterpret_cast<char *>(plain.pbData), plain.cbData);
    SecureZeroMemory(plain.pbData, plain.cbData);
    LocalFree(plain.pbData);
    return result;
}
QString platformSaveCredential(const QByteArray &bytes) {
    DATA_BLOB plain{DWORD(bytes.size()), reinterpret_cast<BYTE *>(const_cast<char *>(bytes.constData()))},
        encrypted{};
    if (!CryptProtectData(&plain, L"RHINE MUSIC DATABASE account", nullptr, nullptr, nullptr,
                          CRYPTPROTECT_UI_FORBIDDEN, &encrypted)) {
        return QStringLiteral("登录成功，但 Windows 凭据当前不可写");
    }
    QDir().mkpath(QFileInfo(credentialPath()).absolutePath());
    QSaveFile file(credentialPath());
    const bool saved =
        file.open(QIODevice::WriteOnly) &&
        file.write(reinterpret_cast<char *>(encrypted.pbData), encrypted.cbData) == encrypted.cbData &&
        file.commit();
    LocalFree(encrypted.pbData);
    return saved ? QString() : QStringLiteral("登录成功，但 Windows 凭据当前不可写");
}
void platformDeleteCredential() {
    QFile::remove(credentialPath());
}
void platformPlay(const QString &id, bool activate, std::function<void(QString)> done) {
    // 将协议交给 Windows Shell，不直接读取或修改注册表，也不自行解析启动命令。
    const auto payload =
        QString("{\"type\":\"song\",\"id\":\"%1\",\"cmd\":\"play\"}").arg(id).toUtf8().toBase64();
    const auto url = QString("orpheus://") + QString::fromLatin1(payload);
    SHELLEXECUTEINFOW info{};
    info.cbSize = sizeof(info);
    info.fMask = SEE_MASK_FLAG_NO_UI;
    info.lpVerb = L"open";
    info.lpFile = reinterpret_cast<LPCWSTR>(url.utf16());
    info.nShow = activate ? SW_SHOWNORMAL : SW_SHOWNOACTIVATE;
    if (ShellExecuteExW(&info)) {
        done(QStringLiteral("已交给网易云；若冷启动未切歌，可手动重试"));
    } else if (GetLastError() == ERROR_NO_ASSOCIATION) {
        done(QStringLiteral("未安装或未注册网易云音乐客户端，请安装官方客户端后重试"));
    } else {
        done(QStringLiteral("交付失败：无法启动网易云客户端"));
    }
}

#if !defined(__MINGW32__)
namespace {
using namespace winrt::Windows::Media;
SystemMediaTransportControls transport{nullptr};
winrt::event_token transportToken{};
bool transportApartment = false;
std::mutex transportMutex;
std::function<void(QString)> transportAction;
}
void platformMediaCommands(std::function<void(QString)> callback) {
    {
        std::lock_guard guard(transportMutex);
        transportAction = std::move(callback);
    }
    if (transport && !transportAction) {
        transport.ButtonPressed(transportToken);
        transport.IsEnabled(false);
        transport = nullptr;
    }
    if (!transportAction && transportApartment) {
        winrt::uninit_apartment();
        transportApartment = false;
    }
}
void platformMediaInfo(QString title, QString artist, QString album, QVariantMap state) {
    // 使用桌面窗口互操作接口，不依赖 UWP 应用身份或另一个播放器。
    try {
        if (!transport) {
            if (title.isEmpty() || QGuiApplication::topLevelWindows().isEmpty()) {
                return;
            }
            if (!transportApartment) {
                winrt::init_apartment(winrt::apartment_type::single_threaded);
                transportApartment = true;
            }
            auto window = QGuiApplication::topLevelWindows().first();
            auto factory = winrt::get_activation_factory<SystemMediaTransportControls,
                                                         ISystemMediaTransportControlsInterop>();
            winrt::check_hresult(factory->GetForWindow(reinterpret_cast<HWND>(window->winId()),
                                                       winrt::guid_of<SystemMediaTransportControls>(),
                                                       winrt::put_abi(transport)));
            transport.IsPlayEnabled(true);
            transport.IsPauseEnabled(true);
            transport.IsNextEnabled(true);
            transport.IsPreviousEnabled(true);
            transportToken = transport.ButtonPressed(
                [](auto const &, SystemMediaTransportControlsButtonPressedEventArgs const &event) {
                    QString action;
                    switch (event.Button()) {
                    case SystemMediaTransportControlsButton::Play:
                        action = "resume";
                        break;
                    case SystemMediaTransportControlsButton::Pause:
                        action = "pause";
                        break;
                    case SystemMediaTransportControlsButton::Next:
                        action = "next";
                        break;
                    case SystemMediaTransportControlsButton::Previous:
                        action = "prev";
                        break;
                    default:
                        return;
                    }
                    std::function<void(QString)> callback;
                    {
                        std::lock_guard guard(transportMutex);
                        callback = transportAction;
                    }
                    if (callback) {
                        callback(action);
                    }
                });
        }
        transport.IsEnabled(!title.isEmpty() && state.value("duration").toLongLong() > 0);
        transport.PlaybackStatus(title.isEmpty()                   ? MediaPlaybackStatus::Stopped
                                 : state.value("playing").toBool() ? MediaPlaybackStatus::Playing
                                                                   : MediaPlaybackStatus::Paused);
        auto display = transport.DisplayUpdater();
        display.Type(MediaPlaybackType::Music);
        auto music = display.MusicProperties();
        music.Title(winrt::hstring(title.toStdWString()));
        music.Artist(winrt::hstring(artist.toStdWString()));
        music.AlbumTitle(winrt::hstring(album.toStdWString()));
        display.Update();
        SystemMediaTransportControlsTimelineProperties timeline;
        timeline.StartTime(winrt::Windows::Foundation::TimeSpan{0});
        timeline.MinSeekTime(winrt::Windows::Foundation::TimeSpan{0});
        timeline.EndTime(winrt::Windows::Foundation::TimeSpan{state.value("duration").toLongLong() * 10000});
        timeline.MaxSeekTime(timeline.EndTime());
        timeline.Position(winrt::Windows::Foundation::TimeSpan{state.value("position").toLongLong() * 10000});
        transport.UpdateTimelineProperties(timeline);
    } catch (const winrt::hresult_error &) {
        // 系统媒体服务不可用时仍保留面板内播放。
    }
}
#else
// MinGW 构建：无 C++/WinRT，媒体控制为空实现（面板内播放不受影响）。
void platformMediaCommands(std::function<void(QString)>) {}
void platformMediaInfo(QString, QString, QString, QVariantMap) {}
#endif
