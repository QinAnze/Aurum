#pragma once
#include "MusicPlayer.h"
#include <QHash>
#include <QSet>
#include <array>
#include <memory>

class MusicDiscover;

struct MusicDirectory {
    std::shared_ptr<MusicDirectory> parent;
    QJsonObject item;
    QJsonArray songs;
    QJsonArray ids;
    QJsonArray albums;
    int cursor = 0;
    int index = 0;
    int anchor = 0;
    int page = 0;
    int parentPhysical = 0;
    int parentLane = 0;
    QJsonObject parentItem;
    int albumCursor = 0;
    bool albumsMore = false;
    bool albumsLoading = false;
};

class MusicLibrary : public QObject {
    Q_OBJECT
  public:
    using Completion = std::function<void(bool)>;
    MusicLibrary(Host *host, const QJsonObject &content, QObject *parent = nullptr);
    ~MusicLibrary() override;
    void changed();
    void observe(int selected);
    void choose(QJsonObject value, bool containerDetails = false,
                std::optional<bool> showDetails = std::nullopt);
    void search(QString text, QString kind = {}, bool more = false);
    void suggest(QString text);
    void showSource(int lane);
    void selectResult(int index, int lane, bool open = true);
    void next(int direction);
    void loadMoreSource(int lane);
    void loadTrackPage(int start);
    void sameAlbum();
    void loadSongWiki();
    void play();
    void playDirectory();
    void playOfficial(QJsonObject value = {});
    QJsonArray directoryQueue() const;
    QString sourceURL(QJsonObject value = {}) const;
    void setGroupView(QString name, QVector<int> indices = {}, int lane = 0);
    QJsonArray sourceItems(int lane) const;
    QJsonArray libraryItems() const;
    QString libraryName() const;
    int libraryTotal() const;
    int libraryIndex() const;
    QString providerName() const;
    QString accountKey() const;
    QString identityName() const;
    bool editable() const {
        return provider == "netease";
    }
    bool sourceLoading() const {
        return searchLoading || personalLoading;
    }
    quint64 accountGeneration() const {
        return m_accountGeneration;
    }
    void switchProvider(QString provider, QString edition = {}, Completion done = {});
    void restoreAccount(Completion done = {});
    void restoreIdentityName();
    void startLogin();
    void cancelLogin(Completion done = {});
    void passwordLogin(QString method, QString account, QString password);
    void logout();
    int loginRetrySeconds() const;
    bool canRegenerateLogin() const;
    void mutate(QString route, QJsonObject values, std::function<void(QJsonObject)> success,
                Completion done = {});
    void like(QJsonObject value = {});
    void subscribe(QJsonObject value = {});
    void playlistForm(QString kind, QString name, QString id = {}, Completion done = {});
    void playlistTrack(QString id, QJsonObject value = {}, bool remove = false, Completion done = {});
    void enterDirectory(QJsonObject value);
    void loadArtistAlbums();
    void openSongArtist(int index = 0);
    void observeDirectory(int physical);
    void selectDirectory(int index, QString mode = "archive", QString axis = "row", int direction = 1);
    void navigateDirectory(int step, QString axis = {});
    void loadDirectoryPage(std::optional<int> selectAfter = std::nullopt);
    void showDirectoryInfo();
    void returnToDirectory();
    void leaveDirectory(bool restore = true);
    void followPlayback(QJsonObject track);
    Host *host;
    MusicApi api;
    MusicPlayer player;
    std::unique_ptr<MusicDiscover> discover;
    std::array<QJsonArray, 5> lists;
    std::array<int, 5> totals{};
    std::array<int, 5> offsets{};
    std::array<bool, 5> hasMore{true, true, true, true, true};
    std::array<int, 5> rowMemory{};
    std::array<QVector<int>, 5> physicalSlots;
    QStringList columns{"搜索结果", "喜欢的歌曲", "我的歌单", "收藏歌单", "收藏专辑"};
    QJsonObject current;
    QJsonArray tracks;
    QJsonArray trackIDs;
    QHash<QString, QJsonObject> details;
    QString searchKind = "song";
    QString keyword;
    QString status = "输入关键词检索音乐";
    QString provider;
    QString kugouEdition;
    QString uid;
    QString nickname = "未登录";
    QHash<QString, QString> identityNames;
    int selectedPhysical = -1;
    int selectedLane = 0;
    bool detailLoading = false;
    QString coverImage;
    QString coverKey;
    QString qr;
    QString qrKey;
    QString loginStatus;
    QString loginPhase = "idle";
    QString loginMethod = "qr";
    QJsonObject loginDiagnostics;
    bool accountLoading = false;
    bool wantsSongDetails = false;
    std::shared_ptr<MusicDirectory> directory;
    bool directoryLoading = false;
    bool directoryInfo = false;
    bool searchLoading = false;
    bool personalLoading = false;
    bool trackLoad = false;
    bool albumLoaded = false;
    bool writeLoading = false;
    bool privateSelection = false;
    int searchCursor = 0;
    int playlistCursor = 0;
    int albumCursor = 0;
    int likedCursor = 0;
    int trackCursor = 0;
    std::optional<QJsonArray> likedIDs;
    QSet<QString> subscriptions;
    QStringList searchHistory;
    QStringList suggestions;
    QString groupName;
    QVector<int> groupIndices;
    int groupLane = -1;
    QJsonObject frame;
    quint64 revision = 0;

  signals:
    void invalidated();
    void selectionRequested(int index, QJsonObject navigation);
    void modeRequested(QString mode);
    void navigationRequested(QString axis, int direction);
    void musicIdentityRequested(QString key);
    void musicClearRequested();

  private:
    struct Cooldown {
        qint64 deadline = 0;
        QString message;
        quint64 token = 0;
    };
    struct Cancellation {
        QVector<Completion> waiters;
    };
    QHash<QString, std::shared_ptr<Cancellation>> m_cancellations;
    QHash<QString, Cooldown> m_cooldowns;
    quint64 m_generation = 0;
    quint64 m_selectionGeneration = 0;
    quint64 m_accountGeneration = 0;
    quint64 m_directoryGeneration = 0;
    quint64 m_wikiGeneration = 0;
    quint64 m_suggestGeneration = 0;
    quint64 m_loginGeneration = 0;
    quint64 m_cooldownGeneration = 0;
    MusicApi m_identityApi;
    MusicApi::Valid valid(quint64 token, const quint64 *counter);
    void loadCover(const QJsonObject &value);
    void loadLikedIDs(int lane, quint64 token, QString user);
    void completePersonal(int lane);
    void restoreCachedAccount();
    void rememberIdentityName(QString provider, QString name);
    void reportLoginFailure(const QJsonObject &details, QString message = {});
    void updateLoginCooldown(QString source, Cooldown cooldown);
    void prepareQR(quint64 token);
    void pollQR(quint64 token, int count);
    void confirmLogin(quint64 token, bool password = false);
    void failLogin(const MusicReply &result);
    void waitCancellation(QString provider, Completion done);
};
