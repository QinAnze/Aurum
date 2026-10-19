#pragma once

namespace AppIdentity {
// 系统标识由 CMake 唯一配置，应用包、缓存与凭据使用同一命名空间。
inline constexpr const char *Id = RHINE_APPLICATION_ID;
inline constexpr const char *Organization = "RhineMusicDatabase";
inline constexpr const char *DisplayName = "RHINE MUSIC DATABASE";
inline constexpr const char *PlayerPreference = "rhine.music.database.activate-player";
}
