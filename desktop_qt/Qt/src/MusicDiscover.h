#pragma once
#include "MusicApi.h"
class MusicLibrary;

class MusicDiscover {
  public:
    explicit MusicDiscover(MusicLibrary *store);
    void load(QString tab = {}, bool more = false);
    void loadCategories();
    void cancel();
    void open(int index);
    QString tab = "playlists";
    QJsonArray items;
    bool loading = false;
    QString status;
    quint64 generation = 0;
    int offset = 0;
    bool more = false;
    QString category = "全部";
    QJsonArray categories;

  private:
    MusicLibrary *m_store;
    MusicApi::Valid valid(quint64 token, quint64 account);
    void accept(MusicReply result, QString tab, int offset, bool more);
};
