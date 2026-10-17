#pragma once
#include <QString>
#include <QVariantList>
#include <QVariantMap>
#include <memory>

// 将静态模型的碰撞树放在原生连续内存中，避免 JS GC 反复遍历大量树节点。
class NativePicking {
  public:
    explicit NativePicking(QString root);
    ~NativePicking();
    void prepare();
    void trimMemory();
    QVariantMap raycast(int mesh, const QVariantList &origin, const QVariantList &direction, int side);

  private:
    struct Data;
    std::unique_ptr<Data> data;
};
