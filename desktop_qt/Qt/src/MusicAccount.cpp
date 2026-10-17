#include "MusicLibrary.h"
#include "MusicDiscover.h"
#include <QDateTime>
#include <QPointer>
#include <QRegularExpression>
#include <algorithm>

namespace {
QString loginFailureMessage(const QJsonObject &details) {
    const auto failure = details["lastFailure"].isObject() ? details["lastFailure"].toObject() : details;
    if (failure["upstreamCode"].toInt() == 20279) {
        return QStringLiteral("登录设备数量已达上限，请在 QQ 音乐设备管理中删除无用设备");
    }
    if (failure["failureReason"] == "qr-timeout") {
        return QStringLiteral("二维码已过期，请重新生成");
    }
    if (failure["failureReason"] == "user-canceled") {
        return QStringLiteral("已取消扫码登录");
    }
    if (failure["failureStage"] == "credential-validation") {
        return QStringLiteral("登录凭证验证失败，请重试或检查设备管理");
    }
    if (failure["failureStage"] == "credential-exchange") {
        return QStringLiteral("扫码授权交换失败，请重试或检查设备管理");
    }
    if (failure["failureStage"] == "mqtt-listener") {
        return QStringLiteral("扫码连接中断，请检查网络后重试");
    }
    if (failure["failureReason"] == "session-busy") {
        return QStringLiteral("扫码授权仍在处理中，请等待");
    }
    if (details["code"].toInt() == 429 || details["failureReason"] == "local-backoff") {
        return QStringLiteral("扫码登录暂时冷却");
    }
    if (details["code"].toInt() == 401) {
        return QStringLiteral("QQ 登录已失效，请重新扫码");
    }
    return details["code"].toInt() == 800 ? QStringLiteral("二维码会话已失效或登录失败，请重新生成")
                                          : QStringLiteral("扫码登录失败，请稍后重试");
}
}

void MusicLibrary::rememberIdentityName(QString source, QString name) {
    const auto normalized = name.trimmed();
    if (normalized.isEmpty()) {
        return;
    }
    identityNames[source] = normalized;
    const auto key = source == "kugou" ? accountKey() : source;
    host->setPreference("welcome-name-" + key, normalized);
    if (source == provider && !uid.isEmpty()) {
        host->setPreference("account-id-" + key, uid);
    }
}

void MusicLibrary::restoreIdentityName() {
    const auto source = provider == "netease" ? "qq" : "netease";
    if (!identityNames.value(source).isEmpty() || !host->hasCredential(source)) {
        return;
    }
    m_identityApi.provider = source;
    m_identityApi.call(
        "account", {},
        [this, source](MusicReply result) {
            if (result.ok()) {
                rememberIdentityName(source, result.value.toArray().at(1).toString());
                changed();
            }
        },
        valid(m_accountGeneration, &m_accountGeneration));
}

void MusicLibrary::restoreCachedAccount() {
    const auto authenticated = host->authenticated();
    uid = authenticated ? host->preference("account-id-" + accountKey()) : QString();
    nickname = authenticated ? identityNames.value(provider) : QStringLiteral("未登录");
    if (authenticated && nickname.isEmpty()) {
        nickname = QStringLiteral("正在恢复登录…");
    }
}

void MusicLibrary::restoreAccount(Completion done) {
    if (!host->authenticated()) {
        if (done) {
            done(true);
        }
        return;
    }
    api.call(
        "account", {},
        [this, done](MusicReply result) {
            if (result.ok()) {
                const auto values = result.value.toArray();
                uid = values.at(0).toString();
                nickname = values.at(1).toString();
                rememberIdentityName(provider, nickname);
            } else if (result.failure["code"].toInt() == 401 || result.failure["authExpired"].toBool() ||
                       (provider == "netease" && result.failure["code"].toInt() == 301)) {
                uid.clear();
                nickname = QStringLiteral("登录已失效");
                host->setPreference("account-id-" + accountKey(), "");
                status = QStringLiteral("登录已失效，请重新登录");
            } else {
                status = QStringLiteral("账号验证暂不可用，已保留本机登录记录");
            }
            changed();
            if (done) {
                done(result.ok());
            }
        },
        valid(m_accountGeneration, &m_accountGeneration));
}

/** 换来源先隔离旧请求并停止播放，再恢复目标来源的独立凭据和显示状态。 */
void MusicLibrary::switchProvider(QString source, QString edition, Completion done) {
    const auto editionChanged =
        source == "kugou" && QStringList{"standard", "lite"}.contains(edition) && edition != kugouEdition;
    if (!QStringList{"netease", "qq", "kugou"}.contains(source) || (source == provider && !editionChanged)) {
        if (done) {
            done(true);
        }
        return;
    }
    cancelLogin();
    ++m_generation;
    ++m_accountGeneration;
    ++m_selectionGeneration;
    ++m_directoryGeneration;
    ++m_wikiGeneration;
    ++m_suggestGeneration;
    discover->cancel();
    player.stop();
    emit musicClearRequested();
    provider = source;
    if (editionChanged) {
        kugouEdition = edition;
        host->setKugouEdition(edition);
        host->setPreference("kugou-edition", edition);
        identityNames["kugou"] = host->preference("welcome-name-" + accountKey());
    }
    host->setProvider(source);
    host->setPreference("provider", source);
    api.provider = source;
    restoreCachedAccount();
    loginStatus.clear();
    loginDiagnostics = {};
    current = {};
    directory.reset();
    groupLane = -1;
    groupName.clear();
    groupIndices.clear();
    details.clear();
    tracks = {};
    trackIDs = {};
    coverImage.clear();
    coverKey.clear();
    for (auto &list : lists) {
        list = {};
    }
    totals.fill(0);
    offsets.fill(0);
    hasMore.fill(true);
    rowMemory.fill(0);
    likedIDs.reset();
    likedCursor = 0;
    albumCursor = 0;
    playlistCursor = 0;
    searchCursor = 0;
    searchLoading = false;
    personalLoading = false;
    detailLoading = false;
    directoryLoading = false;
    trackLoad = false;
    writeLoading = false;
    subscriptions.clear();
    searchKind = "song";
    keyword.clear();
    suggestions.clear();
    selectedPhysical = -1;
    selectedLane = 0;
    privateSelection = false;
    loginMethod = "qr";
    status = QStringLiteral("已切换至") + providerName();
    changed();
    restoreAccount(done);
}

int MusicLibrary::loginRetrySeconds() const {
    const auto remaining = m_cooldowns.value(provider).deadline - QDateTime::currentMSecsSinceEpoch();
    return int(std::max(qint64(0), (remaining + 999) / 1000));
}

bool MusicLibrary::canRegenerateLogin() const {
    return loginRetrySeconds() == 0 && loginPhase != "preparing" && loginPhase != "confirming";
}

void MusicLibrary::reportLoginFailure(const QJsonObject &details, QString fallback) {
    loginDiagnostics = MusicApi::safeFailure(details);
    const auto message = fallback.isEmpty() ? loginFailureMessage(details) : fallback;
    loginPhase = "failed";
    loginStatus = message;
    const auto retry = std::max(qint64(0), details["retryAfterMs"].toInteger());
    if (retry > 0) {
        const Cooldown cooldown{QDateTime::currentMSecsSinceEpoch() + retry, message, ++m_cooldownGeneration};
        m_cooldowns[provider] = cooldown;
        updateLoginCooldown(provider, cooldown);
    }
    changed();
}

void MusicLibrary::updateLoginCooldown(QString source, Cooldown cooldown) {
    if (!m_cooldowns.contains(source) || m_cooldowns[source].token != cooldown.token) {
        return;
    }
    const auto remaining = cooldown.deadline - QDateTime::currentMSecsSinceEpoch();
    const auto seconds = std::max(qint64(0), (remaining + 999) / 1000);
    if (source == provider && loginPhase == "failed") {
        loginStatus = cooldown.message + (seconds > 0 ? QStringLiteral("（请等待 ") +
                                                            QString::number(seconds) + QStringLiteral(" 秒）")
                                                      : QStringLiteral("，可重新生成"));
        changed();
    }
    if (seconds > 0) {
        host->schedule(1000, [owner = QPointer(this), source, cooldown] {
            if (owner) {
                owner->updateLoginCooldown(source, cooldown);
            }
        });
    }
}

void MusicLibrary::waitCancellation(QString source, Completion done) {
    if (m_cancellations.contains(source)) {
        m_cancellations[source]->waiters.append(done);
    } else {
        done(true);
    }
}

/** 取消旧二维码并建立完成屏障，下一次生成必须等待真正的取消结果。 */
void MusicLibrary::cancelLogin(Completion done) {
    const auto previousKey = qrKey;
    ++m_loginGeneration;
    qrKey.clear();
    qr.clear();
    loginPhase = "idle";
    accountLoading = false;
    if (provider != "qq" || previousKey.isEmpty()) {
        if (done) {
            waitCancellation(provider, done);
        }
        return;
    }
    const auto source = provider;
    auto pending = std::make_shared<Cancellation>();
    if (done) {
        pending->waiters.append(done);
    }
    m_cancellations[source] = pending;
    api.request("/login/qr/cancel", {{"key", previousKey}}, [this, source, pending](MusicReply result) {
        if (m_cancellations.value(source) == pending) {
            m_cancellations.remove(source);
        }
        for (const auto &complete : pending->waiters) {
            complete(result.ok());
        }
    });
}

void MusicLibrary::passwordLogin(QString method, QString account, QString password) {
    if (accountLoading && loginMethod == method) {
        return;
    }
    if (account.trimmed().isEmpty() || password.isEmpty()) {
        loginStatus = QStringLiteral("请输入账号和密码");
        changed();
        return;
    }
    cancelLogin();
    const auto token = ++m_loginGeneration;
    loginMethod = method;
    loginStatus = QStringLiteral("正在登录…");
    accountLoading = true;
    changed();
    api.request(
        method == "phone" ? "/login/cellphone" : "/login",
        {{method == "phone" ? "phone" : "email", account}, {"password", password}},
        [this, token](MusicReply result) {
            if (!result.ok()) {
                loginStatus = result.error;
                accountLoading = false;
                changed();
                return;
            }
            confirmLogin(token, true);
        },
        valid(token, &m_loginGeneration));
}

void MusicLibrary::failLogin(const MusicReply &result) {
    loginPhase = "failed";
    accountLoading = false;
    if (provider == "qq" && result.failure.contains("code")) {
        reportLoginFailure(result.failure);
    } else {
        loginStatus = result.error;
        changed();
    }
}

void MusicLibrary::confirmLogin(quint64 token, bool password) {
    api.call(
        "account", {},
        [this, password](MusicReply result) {
            if (!result.ok()) {
                if (password) {
                    loginStatus = result.error;
                    accountLoading = false;
                    changed();
                } else {
                    failLogin(result);
                }
                return;
            }
            const auto error = host->saveCredential();
            if (!error.isEmpty()) {
                if (password) {
                    loginStatus = error;
                    accountLoading = false;
                    changed();
                } else {
                    failLogin({{}, error, {}});
                }
                return;
            }
            ++m_accountGeneration;
            uid = result.value.toArray().at(0).toString();
            nickname = result.value.toArray().at(1).toString();
            rememberIdentityName(provider, nickname);
            loginStatus = QStringLiteral("已登录：") + nickname;
            status = password ? loginStatus : QStringLiteral("已登录，可读取我的音乐");
            if (!password) {
                qr.clear();
                qrKey.clear();
                loginPhase = "complete";
                m_cooldowns.remove(provider);
            }
            accountLoading = false;
            loadMoreSource(2);
            changed();
        },
        valid(token, &m_loginGeneration));
}

void MusicLibrary::startLogin() {
    if (!canRegenerateLogin()) {
        const auto seconds = loginRetrySeconds();
        if (seconds > 0) {
            loginPhase = "failed";
            loginStatus = m_cooldowns.value(provider).message + QStringLiteral("（请等待 ") +
                          QString::number(seconds) + QStringLiteral(" 秒）");
            changed();
        }
        return;
    }
    cancelLogin();
    const auto token = ++m_loginGeneration;
    const auto alive = valid(token, &m_loginGeneration);
    loginPhase = "preparing";
    loginDiagnostics = {};
    loginStatus = QStringLiteral("准备二维码…");
    qr.clear();
    accountLoading = true;
    changed();
    waitCancellation(provider, [this, token, alive](bool cancelled) {
        if (!alive()) {
            return;
        }
        if (!cancelled) {
            failLogin({{}, QStringLiteral("旧二维码取消失败，请稍后重试"), {}});
            return;
        }
        prepareQR(token);
    });
}

void MusicLibrary::prepareQR(quint64 token) {
    QJsonObject parameters{{"timestamp", QDateTime::currentMSecsSinceEpoch()}};
    if (provider == "qq") {
        parameters["channel"] = loginMethod == "wechat" ? "wechat" : "qq";
    }
    const auto alive = valid(token, &m_loginGeneration);
    api.request(
        "/login/qr/key", parameters,
        [this, token, alive](MusicReply result) {
            if (!result.ok()) {
                failLogin(result);
                return;
            }
            const auto body = result.value.toObject();
            auto key = body["unikey"];
            if (key.isNull() || key.isUndefined()) {
                key = body["data"].toObject()["unikey"];
            }
            if (!key.isString()) {
                failLogin({{}, QStringLiteral("二维码生成失败"), {}});
                return;
            }
            qrKey = key.toString();
            const auto ready = [this, token] {
                QString scanner = providerName();
                if (provider == "qq") {
                    scanner = loginMethod == "wechat" ? QStringLiteral("微信") : QStringLiteral("手机 QQ");
                }
                loginPhase = "waiting";
                loginStatus = QStringLiteral("请用") + scanner + QStringLiteral("扫描并确认登录");
                changed();
                pollQR(token, 0);
            };
            if (provider == "netease") {
                qr = host->qr(qrKey);
                ready();
                return;
            }
            api.request(
                "/login/qr/create",
                {{"key", qrKey}, {"qrimg", true}, {"timestamp", QDateTime::currentMSecsSinceEpoch()}},
                [this, ready](MusicReply image) {
                    if (!image.ok()) {
                        failLogin(image);
                        return;
                    }
                    const auto data = image.value.toObject()["data"].toObject()["qrimg"].toString();
                    static const QRegularExpression format(
                        QStringLiteral("^data:image/(png|jpeg|gif|webp);base64,"));
                    if (!format.match(data).hasMatch()) {
                        failLogin({{}, providerName() + QStringLiteral("二维码格式无效"), {}});
                        return;
                    }
                    qr = host->qrImage(data);
                    if (qr.isEmpty()) {
                        failLogin({{}, providerName() + QStringLiteral("二维码读取失败"), {}});
                        return;
                    }
                    ready();
                },
                alive);
        },
        alive);
}

void MusicLibrary::pollQR(quint64 token, int count) {
    if (count >= 300) {
        failLogin({{}, QStringLiteral("二维码超时，请重新生成"), {}});
        return;
    }
    const auto alive = valid(token, &m_loginGeneration);
    host->schedule(1000, [this, token, count, alive] {
        if (!alive()) {
            return;
        }
        api.request("/login/qr/check", {{"key", qrKey}, {"timestamp", QDateTime::currentMSecsSinceEpoch()}},
                    [this, token, count](MusicReply result) {
                        if (!result.ok()) {
                            failLogin(result);
                            return;
                        }
                        const auto body = result.value.toObject();
                        const auto code = body["code"].toInt(800);
                        if (code == 800) {
                            qr.clear();
                            accountLoading = false;
                            if (provider == "qq") {
                                reportLoginFailure(body);
                            } else {
                                failLogin({{}, QStringLiteral("二维码已过期，请重新生成"), {}});
                            }
                            return;
                        }
                        if (code == 802) {
                            loginPhase = "confirming";
                            loginStatus = QStringLiteral("已扫描，请在手机上确认");
                            changed();
                        }
                        if (code == 803) {
                            loginPhase = "confirming";
                            confirmLogin(token);
                            return;
                        }
                        pollQR(token, count + 1);
                    },
                    alive, {800, 801, 802, 803});
    });
}

/** 退出只清理当前来源凭据与私有资料，并撤销该账号的全部异步更新。 */
void MusicLibrary::logout() {
    const auto clearSelection = selectedLane > 0 || privateSelection;
    writeLoading = false;
    subscriptions.clear();
    discover->cancel();
    player.stop();
    player.history = {};
    host->setPreference("play-history", "[]");
    while (directory) {
        leaveDirectory();
    }
    groupLane = -1;
    groupName.clear();
    groupIndices.clear();
    cancelLogin();
    ++m_accountGeneration;
    host->logout();
    host->setPreference("account-id-" + accountKey(), "");
    uid.clear();
    nickname = QStringLiteral("未登录");
    likedIDs.reset();
    likedCursor = 0;
    playlistCursor = 0;
    albumCursor = 0;
    personalLoading = false;
    details.clear();
    for (int lane = 1; lane < 5; ++lane) {
        lists[lane] = {};
        totals[lane] = 0;
        offsets[lane] = 0;
        hasMore[lane] = true;
    }
    emit musicClearRequested();
    choose(clearSelection ? QJsonObject{} : current);
    privateSelection = false;
    status = QStringLiteral("已退出登录");
    changed();
}
