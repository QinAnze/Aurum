#include "RhiScene.h"
#include "DiscGeometry.h"
#include "Engine.h"
#include "Glyphs.h"
#include <QFile>
#include <QJsonDocument>
#include <QMatrix4x4>
#include <QOffscreenSurface>
#include <QPainter>
// Qt 6.8+ 的 qrhi.h 已提供各后端初始化参数，无需引用不存在的后端头文件。
#include <rhi/qrhi.h>

#include <algorithm>
#include <cstring>
#include <map>
#include <vector>

// 同一渲染通道和 GLSL 方程经 Qt Shader Tools 编译为 Metal / HLSL / SPIR-V。
struct PackedMatrix {
    float elements[16];
    PackedMatrix(const QMatrix4x4 &value = QMatrix4x4()) {
        std::copy_n(value.constData(), 16, elements);
    }
};
struct Globals {
    PackedMatrix view, projection, shadow, inverseProjection, aoProjection, aoInverseProjection;
    QVector4D eye, fogColor, fog, viewport, clip;
    PackedMatrix correction;
    QVector4D backend;
};
struct Surface {
    QVector4D color, physical, optics, attenuation, extra, flags, darkColor;
};
struct Instance {
    PackedMatrix model;
    QVector4D state;
};
static_assert(sizeof(Globals) == 544);
static_assert(sizeof(Surface) == 112);
static_assert(sizeof(Instance) == 80);
static constexpr qint64 MUSIC_TEXTURE_BUDGET_BYTES = 24 * 1024 * 1024;
static QMatrix4x4 matrix(QJsonArray a, int offset = 0) {
    QMatrix4x4 m;
    for (int i = 0; i < 16; ++i) {
        m.data()[i] = float(a[offset + i].toDouble());
    }
    return m;
}
static QVector3D vector(QJsonValue a) {
    auto v = a.toArray();
    return {float(v[0].toDouble()), float(v[1].toDouble()), float(v[2].toDouble())};
}
static float n(QJsonObject o, const char *k) {
    return float(o[k].toDouble());
}
static QVector4D v4(QVector3D v, float w = 0) {
    return {v, w};
}
static QByteArray read(QString root, QString name) {
    QFile f(root + "/" + name);
    if (!f.open(QIODevice::ReadOnly)) {
        qFatal("Missing render resource: %s", qPrintable(name));
    }
    return f.readAll();
}
static QShader shader(QString name) {
    QFile f(":/shaders/" + name + ".qsb");
    if (!f.open(QIODevice::ReadOnly)) {
        qFatal("Missing baked shader: %s", qPrintable(name));
    }
    auto s = QShader::fromSerialized(f.readAll());
    if (!s.isValid()) {
        qFatal("Invalid shader");
    }
    return s;
}
struct Mesh {
    QRhiBuffer *vertices = nullptr, *indices = nullptr;
    QJsonArray parts;
};
struct Target {
    QRhiTexture *texture = nullptr;
    QRhiTextureRenderTarget *rt = nullptr;
    QRhiRenderPassDescriptor *rp = nullptr;
};
class Renderer {
  public:
    QRhi *rhi;
    QString root;
    std::vector<std::unique_ptr<QRhiResource>> resources, sized, transient;
    QHash<QString, Mesh> meshes;
    QRhiTexture *environment = nullptr, *dfg = nullptr, *white = nullptr, *noise = nullptr,
                *capture = nullptr, *depth = nullptr, *normalDepth = nullptr, *shadow = nullptr,
                *opaqueDepth = nullptr;
    QRhiBuffer *globalBuffer = nullptr, *kernel = nullptr, *floor = nullptr, *coverPlane = nullptr,
               *musicLabelPlane = nullptr, *discBody = nullptr, *discHub = nullptr, *caseDecoration = nullptr;
    int discPrintCount = 0;
    int discBodyCount = 0;
    int discHubCount = 0;
    QRhiTexture *decorationTexture = nullptr, *placeholderCover = nullptr;
    QRhiSampler *linear = nullptr, *nearest = nullptr, *mipSampler = nullptr, *repeat = nullptr,
                *shadowSampler = nullptr;
    Target color, opaqueColor, normal, ao, blur, combined, bokeh, target;
    QRhiTextureRenderTarget *loaded = nullptr, *shadowTarget = nullptr;
    QRhiRenderPassDescriptor *shadowPass = nullptr;
    QRhiResourceUpdateBatch *updates = nullptr;
    QHash<QString, QRhiGraphicsPipeline *> pipelines;
    QHash<QString, QRhiShaderResourceBindings *> pipelineLayouts;
    struct BufferState {
        QRhiBuffer *buffer = nullptr;
        QByteArray bytes;
        quint64 used = 0;
    };
    struct MaterialState {
        BufferState uniform;
        QRhiShaderResourceBindings *bindings = nullptr;
        QRhiTexture *label = nullptr, *cover = nullptr;
        quint64 used = 0;
    };
    QHash<int, BufferState> instances;
    QHash<QString, MaterialState> materials;
    QHash<QString, QRhiShaderResourceBindings *> postBindings;
    QHash<QString, QString> labelRevisions;
    QHash<QString, qint64> coverRevisions;
    SceneDrawBuffers nativeBuffers;
    quint64 generation = 0;
    quint64 bindingCreations = 0;
    quint64 coverUploads = 0;
    quint64 drawCalls = 0;
    QByteArray shadowRevision;
    bool shadowValid = false;
    QHash<QString, QRhiTexture *> labels, covers;
    QHash<qint64, QRhiTexture *> coverTextures;
    QRhiTexture *labelTexture = nullptr, *coverTexture = nullptr;
    QStringList textureOrder;
    QSet<QString> activeTextureKeys;
    QSize size;
    std::unique_ptr<Glyphs> glyphs;
    QJsonObject musicItem;
    QString revision;
    template <class T> T *own(T *value, bool resize = false, bool temporary = false) {
        (temporary ? transient : resize ? sized : resources).emplace_back(value);
        return value;
    }
    template <class T> T *create(T *value) {
        if (!value->create()) {
            qFatal("RHI resource allocation failed");
        }
        return value;
    }
    QRhiBuffer *buffer(const QByteArray &data, QRhiBuffer::UsageFlags usage, bool temporary = false) {
        // D3D11 不支持非动态 uniform buffer；类型与上传方式必须同时匹配。
        const bool uniform = usage.testFlag(QRhiBuffer::UniformBuffer);
        auto b =
            own(rhi->newBuffer(uniform ? QRhiBuffer::Dynamic : QRhiBuffer::Immutable, usage, data.size()),
                false, temporary);
        if (!b->create()) {
            qFatal("RHI buffer allocation failed: backend=%d uniform=%d size=%lld", int(rhi->backend()),
                   int(uniform), static_cast<long long>(data.size()));
        }
        if (uniform) {
            updates->updateDynamicBuffer(b, 0, data.size(), data.constData());
        } else {
            updates->uploadStaticBuffer(b, data.constData());
        }
        return b;
    }
    QRhiTexture *texture(QSize s, QRhiTexture::Format format, QRhiTexture::Flags flags = {},
                         bool resize = false) {
        return create(own(rhi->newTexture(format, s, 1, flags), resize));
    }
    void upload(QRhiTexture *t, QByteArray bytes) {
        QRhiTextureSubresourceUploadDescription data(bytes);
        updates->uploadTexture(t, QRhiTextureUploadDescription({QRhiTextureUploadEntry(0, 0, data)}));
    }
    Renderer(QString path, QRhi *device) : rhi(device), root(path) {
        updates = rhi->nextResourceUpdateBatch();
        glyphs = std::make_unique<Glyphs>(root);
        globalBuffer =
            create(own(rhi->newBuffer(QRhiBuffer::Dynamic, QRhiBuffer::UniformBuffer, sizeof(Globals))));
        kernel = buffer(read(root, "ao-kernel.bin"), QRhiBuffer::UniformBuffer);
        for (auto pair :
             {std::pair{"cassette", "archive-cassette"}, std::pair{"assembly", "archive-assembly"}}) {
            meshes[pair.first] = {
                buffer(read(root, QString(pair.second) + ".bin"), QRhiBuffer::VertexBuffer),
                buffer(read(root, QString(pair.second) + "-indices.bin"), QRhiBuffer::IndexBuffer),
                QJsonDocument::fromJson(read(root, QString(pair.second) + ".json"))
                    .object()["meshes"]
                    .toArray()};
        }
        auto sampler = [&](QRhiSampler::Filter filter, QRhiSampler::Filter mip,
                           QRhiSampler::AddressMode address) {
            return create(own(rhi->newSampler(filter, filter, mip, address, address)));
        };
        linear = sampler(QRhiSampler::Linear, QRhiSampler::None, QRhiSampler::ClampToEdge);
        nearest = sampler(QRhiSampler::Nearest, QRhiSampler::None, QRhiSampler::ClampToEdge);
        mipSampler = sampler(QRhiSampler::Linear, QRhiSampler::Linear, QRhiSampler::ClampToEdge);
        repeat = sampler(QRhiSampler::Nearest, QRhiSampler::None, QRhiSampler::Repeat);
        shadowSampler = own(rhi->newSampler(QRhiSampler::Linear, QRhiSampler::Linear, QRhiSampler::None,
                                            QRhiSampler::ClampToEdge, QRhiSampler::ClampToEdge));
        shadowSampler->setTextureCompareOp(QRhiSampler::LessOrEqual);
        create(shadowSampler);
        environment = texture({768, 1024}, QRhiTexture::RGBA16F);
        upload(environment, read(root, "room-pmrem.bin"));
        dfg = texture({16, 16}, QRhiTexture::RGBA16F);
        auto rg = read(root, "dfg-lut.bin");
        QByteArray rgba;
        rgba.reserve(2048);
        for (int i = 0; i < rg.size(); i += 4) {
            rgba.append(rg.constData() + i, 4);
            rgba.append(QByteArray(4, 0));
        }
        upload(dfg, rgba);
        white = texture({1, 1}, QRhiTexture::RGBA8);
        upload(white, QByteArray(4, char(255)));
        noise = texture({4, 4}, QRhiTexture::R32F);
        upload(noise, read(root, "ao-noise.bin"));
        floor = plane(-100, -100, 100, 100, 0, 0, 0, 0, 0);
        // 盘面、盘边和中心透明环共享外壳中心；原网格及变换保持不变。
        auto print =
            DiscGeometry::annulus(DiscGeometry::HubRadius, DiscGeometry::PrintRadius, .105f, .105f, false);
        auto body = DiscGeometry::annulus(DiscGeometry::HoleRadius, DiscGeometry::Radius, .10f, .055f);
        auto hub = DiscGeometry::annulus(DiscGeometry::HoleRadius, DiscGeometry::HubRadius, .112f, .055f);
        coverPlane = buffer(print.bytes(), QRhiBuffer::VertexBuffer);
        discBody = buffer(body.bytes(), QRhiBuffer::VertexBuffer);
        discHub = buffer(hub.bytes(), QRhiBuffer::VertexBuffer);
        discPrintCount = print.count();
        discBodyCount = body.count();
        discHubCount = hub.count();
        musicLabelPlane = plane(-.83, .07, -.03, .29, 0, -.83, .07, .8, .22);
        caseDecoration = plane(-2.5, 0, 2.5, 3.7, .222, -2.5, 0, 5, 3.7);
        QImage decoration(1000, 740, QImage::Format_RGBA8888_Premultiplied);
        decoration.fill(Qt::transparent);
        QPainter painter(&decoration);
        painter.setRenderHint(QPainter::Antialiasing);
        const QColor ink(65, 70, 62, 170), accent(119, 123, 96, 195);
        painter.setPen(QPen(ink, 1.4));
        for (auto point : {QPointF(75, 60), QPointF(930, 60), QPointF(75, 685), QPointF(930, 685)}) {
            painter.drawLine(point + QPointF(-10, 0), point + QPointF(10, 0));
            painter.drawLine(point + QPointF(0, -10), point + QPointF(0, 10));
        }
        glyphs->text(painter, "MUSIC ARCHIVE / 001", 130, 688, 15, "regular", .5, ink);
        painter.save();
        painter.translate(75, 465);
        painter.rotate(-90);
        glyphs->text(painter, "RHINE LAB", 0, 0, 21, "demibold", 2, ink);
        painter.restore();
        painter.drawEllipse(QRectF(875, 574, 55, 55));
        painter.drawEllipse(QRectF(891, 574, 23, 55));
        painter.drawLine(875, 601, 930, 601);
        painter.fillRect(QRectF(875, 654, 25, 5), accent);
        painter.end();
        decorationTexture = texture(decoration.size(), QRhiTexture::RGBA8);
        updates->uploadTexture(decorationTexture, decoration);
        QImage placeholder(512, 512, QImage::Format_RGBA8888_Premultiplied);
        placeholder.fill(QColor(94, 115, 112));
        QPainter placeholderPainter(&placeholder);
        placeholderPainter.setRenderHint(QPainter::Antialiasing);
        placeholderPainter.setPen(QPen(QColor(185, 196, 178), 2));
        placeholderPainter.drawEllipse(QRectF(52, 52, 408, 408));
        glyphs->text(placeholderPainter, "RHINE LAB", 130, 340, 34, "demibold", 1, QColor(215, 220, 204));
        placeholderPainter.end();
        placeholderCover = texture(placeholder.size(), QRhiTexture::RGBA8);
        updates->uploadTexture(placeholderCover, placeholder);
    }
    ~Renderer() {
        if (updates) {
            updates->release();
        }
    }
    QRhiBuffer *plane(float x0, float y0, float x1, float y1, float z, float ux, float uy, float uw,
                      float uh) {
        std::vector<float> vertices;
        for (auto v : {QVector2D{x0, y0}, QVector2D{x1, y0}, QVector2D{x1, y1}, QVector2D{x0, y0},
                       QVector2D{x1, y1}, QVector2D{x0, y1}}) {
            float data[] = {
                v.x(), v.y(), z, 1, 0, 0, 1, 0, uw ? (v.x() - ux) / uw : 0, uh ? (v.y() - uy) / uh : 0, 0, 0};
            vertices.insert(vertices.end(), std::begin(data), std::end(data));
        }
        return buffer(QByteArray(reinterpret_cast<const char *>(vertices.data()), vertices.size() * 4),
                      QRhiBuffer::VertexBuffer);
    }
    Target makeTarget(QRhiTexture *texture, QRhiTexture *depth = nullptr, QRhiTexture *second = nullptr) {
        QRhiTextureRenderTargetDescription desc;
        if (texture) {
            if (second) {
                desc.setColorAttachments({QRhiColorAttachment(texture), QRhiColorAttachment(second)});
            } else {
                desc.setColorAttachments({QRhiColorAttachment(texture)});
            }
        }
        desc.setDepthTexture(depth);
        auto rt = own(rhi->newTextureRenderTarget(desc), true);
        auto rp = own(rt->newCompatibleRenderPassDescriptor(), true);
        rt->setRenderPassDescriptor(rp);
        create(rt);
        return {texture, rt, rp};
    }
    void invalidateBindings(QRhiTexture *texture = nullptr) {
        for (auto &state : materials) {
            // 换曲只影响采样该纹理的材质；窗口尺寸变化才需要整批重新绑定。
            if (texture && state.label != texture && state.cover != texture) {
                continue;
            }
            retire(state.bindings);
            state.bindings = nullptr;
        }
    }
    void resize(QSize value, bool needsReadbackTarget) {
        if (size == value) {
            return;
        }
        invalidateBindings();
        postBindings.clear();
        shadowRevision.clear();
        shadowValid = false;
        pipelines.clear();
        pipelineLayouts.clear();
        sized.clear();
        size = value;
        auto rtFlags = QRhiTexture::RenderTarget | QRhiTexture::UsedAsTransferSource;
        depth = texture(size, QRhiTexture::D32F, rtFlags, true);
        normalDepth = texture(size, QRhiTexture::D32F, rtFlags, true);
        opaqueDepth = texture(size, QRhiTexture::D32F, rtFlags, true);
        shadow = texture({2048, 2048}, QRhiTexture::D32F, rtFlags, true);
        auto st = makeTarget(nullptr, shadow);
        shadowTarget = st.rt;
        shadowPass = st.rp;
        color = makeTarget(texture(size, QRhiTexture::RGBA16F, rtFlags, true), depth);
        opaqueColor = makeTarget(texture(size, QRhiTexture::RGBA16F, rtFlags, true));
        capture = texture(size, QRhiTexture::RGBA16F,
                          rtFlags | QRhiTexture::MipMapped | QRhiTexture::UsedWithGenerateMips, true);
        // AO 和景深共用真实 D32F 深度，不再额外打包、写入和解包四通道深度图。
        normal = makeTarget(texture(size, QRhiTexture::RGBA16F, rtFlags, true), normalDepth);
        // AO 和模糊只使用红通道，R16F 保留同样的半精度数值，减少四通道显存和带宽。
        const auto aoFormat = rhi->isTextureFormatSupported(QRhiTexture::R16F, rtFlags)
                                  ? QRhiTexture::R16F
                                  : QRhiTexture::RGBA16F;
        for (auto t : {&ao, &blur}) {
            *t = makeTarget(texture(size, aoFormat, rtFlags, true));
        }
        combined = makeTarget(texture(size, QRhiTexture::RGBA16F, rtFlags, true));
        // AO 完成后不再读取法线颜色；景深复用其 HDR 纹理，避免再分配一张全尺寸中间图。
        // 此目标不挂载深度附件，因此可安全采样 normalDepth，不形成读写反馈。
        bokeh = makeTarget(normal.texture);
        target = {};
        if (needsReadbackTarget) {
            target = makeTarget(texture(size, QRhiTexture::RGBA8, rtFlags, true));
        }
        auto desc = color.rt->description();
        loaded =
            own(rhi->newTextureRenderTarget(desc, QRhiTextureRenderTarget::PreserveColorContents |
                                                      QRhiTextureRenderTarget::PreserveDepthStencilContents),
                true);
        loaded->setRenderPassDescriptor(color.rp);
        create(loaded);
    }
    Globals globals(QJsonObject f) {
        QMatrix4x4 light;
        light.lookAt({-6, 14, -5}, {0, 0, 0}, {0, 1, 0});
        QMatrix4x4 ortho;
        ortho.fill(0);
        ortho(0, 0) = 1 / 16.f;
        ortho(1, 1) = 1 / 15.f;
        ortho(2, 2) = -1 / 44.9f;
        ortho(2, 3) = -.1f / 44.9f;
        ortho(3, 3) = 1;
        QMatrix4x4 bias;
        bias(0, 0) = .5;
        bias(1, 1) = -.5;
        bias(0, 3) = .5;
        bias(1, 3) = .5;
        auto projection = matrix(f["projection"].toArray());
        auto aoProjection = matrix(f["aoProjection"].toArray());
        auto theme = n(f["draws"].toArray().first().toObject(), "theme");
        return {matrix(f["view"].toArray()),
                projection,
                bias * ortho * light,
                projection.inverted(),
                aoProjection,
                aoProjection.inverted(),
                v4(vector(f["eye"])),
                v4(vector(f["fogColor"])),
                {n(f, "fogNear"), n(f, "fogFar"), n(f, "focus"), n(f, "aperture")},
                {float(size.width()), float(size.height()), theme, f["viewer"].toBool() ? 1.f : 0.f},
                {n(f, "near"), n(f, "far"), n(f, "detail"), f["reference"].toBool() ? 1.f : 0.f},
                rhi->clipSpaceCorrMatrix(),
                {rhi->isYUpInFramebuffer() ? 1.f : 0.f, 0, 0, 0}};
    }
    QVector3D dark(QString name) {
        static const QHash<QString, uint32_t> colors = {
            {"Frosted_Polymer", 0x626b70},    {"Ivory_Edges", 0x687277},   {"Optical_Diffuser", 0x192226},
            {"Titanium_Fasteners", 0xb1b9bb}, {"Index_Inlay", 0xc6a36b},   {"Printed_Label", 0x303a3e},
            {"Subsurface_Optics", 0x939e9f},  {"Optical_Edges", 0xbbc3bc}, {"Carbon_Ink", 0xb6bdb8}};
        auto hex = colors.value(name, name.contains("Orange") ? 0xbb8850 : 0x969f9f);
        auto channel = [](uint32_t n) {
            float v = n / 255.f;
            return v <= .04045f ? v / 12.92f : float(pow((v + .055f) / 1.055f, 2.4f));
        };
        return {channel((hex >> 16) & 255), channel((hex >> 8) & 255), channel(hex & 255)};
    }
    Surface surface(QJsonObject d) {
        auto name = d["name"].toString();
        bool optical = name.startsWith("Optical_Glass") || name == "Optical_Bridge_Glass";
        float type = d["mesh"].toInt() == -2                            ? 6
                     : d["label"].toBool()                              ? 1
                     : name == "Frosted_Polymer"                        ? 3
                     : name == "Ivory_Edges"                            ? 4
                     : name == "Optical_Diffuser"                       ? 5
                     : !d["instanced"].toBool() && !d["floor"].toBool() ? 2
                                                                        : 0;
        return {v4(vector(d["color"]), n(d, "opacity")),
                {n(d, "roughness"), n(d, "metalness"), n(d, "transmission"), n(d, "thickness")},
                {n(d, "ior"), n(d, "attenuationDistance"), name == "Index_Inlay" ? 1.f : 0.f, 0},
                v4(vector(d["attenuation"])),
                {n(d, "clearcoat"), n(d, "clearcoatRoughness"), optical ? 1.f : 0.f, 0},
                {type, n(d, "side"), n(d, "subdued"), d["floor"].toBool() ? 1.f : 0.f},
                v4(dark(name), d["instanced"].toBool() ? 1.f : 0.f)};
    }
    QList<QJsonObject> musicDraws(QJsonObject f) {
        static const QStringList removed = {"Internal_Ceramic",  "Optical_Edges",       "Subsurface_Optics",
                                            "Optical_Film_Edge", "Amber_Optical_Inlay", "Optical_Film",
                                            "Champagne_Index",   "Printed_Label"};
        QList<QJsonObject> result;
        for (auto v : f["draws"].toArray()) {
            auto d = v.toObject();
            const auto name = d["name"].toString();
            if (removed.contains(name)) {
                continue;
            }
            // 背板完全不透光；只修改背板，正面磨砂盖板继续沿用当前材质。
            if (name == "Optical_Diffuser" && !d["shadowOnly"].toBool()) {
                d["color"] = QJsonArray{.95, .95, .92};
                d["transmission"] = 0;
                d["transparent"] = false;
                d["opacity"] = 1;
                d["roughness"] = .15;
                d["thickness"] = .018;
                d["attenuation"] = QJsonArray{1, 1, 1};
                d["attenuationDistance"] = 8;
                d["depthWrite"] = true;
            }
            if (name == "Frosted_Polymer" && !d["instanced"].toBool()) {
                // 选中的光盘盒只保留轻磨砂；阵列及原来的清晰度揭示动画不变。
                const double quality = n(d, "quality");
                d["thickness"] = .028 * quality + n(d, "thickness") * (1 - quality);
                d["transmission"] = .97 * quality + n(d, "transmission") * (1 - quality);
            }
            result << d;
            if (name != "Frosted_Polymer" || d["shadowOnly"].toBool()) {
                continue;
            }
            auto part = d;
            part["color"] = QJsonArray{1, 1, 1};
            part["roughness"] = .36;
            part["metalness"] = 0;
            part["transmission"] = 0;
            part["thickness"] = 0;
            part["opacity"] = 1;
            part["clearcoat"] = .12;
            part["clearcoatRoughness"] = .25;
            part["transparent"] = false;
            part["depthWrite"] = true;
            part["order"] = 0;
            part["side"] = 2;
            part["castShadow"] = false;
            part["name"] = "Music_Disc_Print";
            part["mesh"] = -2;
            result << part;
            part["name"] = "Music_Disc_Silver";
            part["mesh"] = -3;
            part["color"] = QJsonArray{.68, .72, .74};
            part["metalness"] = .82;
            part["roughness"] = .22;
            result << part;
            part["name"] = "Music_Disc_Hub";
            part["mesh"] = -4;
            part["color"] = QJsonArray{.96, .97, .96};
            part["metalness"] = 0;
            part["transmission"] = .65;
            part["thickness"] = .02;
            part["roughness"] = .13;
            part["depthWrite"] = false;
            result << part;
            part["name"] = "Music_Case_Marks";
            part["mesh"] = -5;
            part["transmission"] = 0;
            part["transparent"] = true;
            part["label"] = true;
            part["order"] = 50;
            result << part;
        }
        return result;
    }
    void retire(QRhiResource *texture) {
        if (!texture) {
            return;
        }
        auto it =
            std::find_if(resources.begin(), resources.end(), [&](auto &v) { return v.get() == texture; });
        if (it != resources.end()) {
            it->release()->deleteLater();
            resources.erase(it);
        }
    }
    void releaseCover(const QString &key) {
        const auto revision = coverRevisions.take(key);
        const auto previous = covers.take(key);
        // 同专辑曲目及无封面的曲目共享纹理，最后一个引用退出后才退休 GPU 对象。
        if (!previous || covers.values().contains(previous)) {
            return;
        }
        invalidateBindings(previous);
        coverTextures.remove(revision);
        retire(previous);
    }
    void updateMusic(const QJsonObject &value, QImage image) {
        const auto key = value["key"].toString("empty");
        const auto labelRevision = value["title"].toString() + "|" + value["artist"].toString() + "|" +
                                   value["kind"].toString() + "|" + value["id"].toString();
        const qint64 coverRevision = image.cacheKey();
        musicItem = value;
        textureOrder.removeAll(key);
        textureOrder << key;
        if (!labels.contains(key) || labelRevisions.value(key) != labelRevision) {
            if (const auto previous = labels.value(key)) {
                invalidateBindings(previous);
            }
            // 覆盖同一 key 时退休的是该 key 的旧对象，而非上一首当前曲目的对象。
            retire(labels.take(key));
            const auto label = glyphs->label(value);
            labels[key] = texture(label.size(), QRhiTexture::RGBA8);
            updates->uploadTexture(labels[key], label);
            labelRevisions[key] = labelRevision;
        }
        if (!covers.contains(key) || (!image.isNull() && coverRevisions.value(key) != coverRevision)) {
            releaseCover(key);
            if (!coverTextures.contains(coverRevision)) {
                QImage pixels(512, 512, QImage::Format_RGBA8888_Premultiplied);
                pixels.fill(QColor::fromRgbF(.36, .45, .45));
                QPainter painter(&pixels);
                painter.setRenderHints(QPainter::Antialiasing | QPainter::SmoothPixmapTransform);
                if (!image.isNull()) {
                    const auto dimensions = image.size().scaled(512, 512, Qt::KeepAspectRatioByExpanding);
                    painter.drawImage(QRectF((512 - dimensions.width()) / 2.,
                                             (512 - dimensions.height()) / 2., dimensions.width(),
                                             dimensions.height()),
                                      image);
                } else {
                    painter.setPen(QPen(QColor::fromRgbF(.7, .72, .64), 2));
                    painter.drawEllipse(QRectF(52, 52, 408, 408));
                    glyphs->text(painter, "RHINE LAB", 156, 370, 28, "demibold", 1, QColor(215, 220, 204));
                }
                painter.end();
                const auto cover = texture(pixels.size(), QRhiTexture::RGBA8);
                updates->uploadTexture(cover, pixels);
                coverTextures[coverRevision] = cover;
                ++coverUploads;
            }
            covers[key] = coverTextures.value(coverRevision);
            coverRevisions[key] = coverRevision;
        }
        labelTexture = labels.value(key);
        coverTexture = covers.value(key);
        // 按实际 RGBA8 像素占用限制缓存；仍在动画中的纹理只在归位后参与淘汰。
        while (textureOrder.size() > 32 || musicTextureBytes() > MUSIC_TEXTURE_BUDGET_BYTES) {
            const auto candidate =
                std::find_if(textureOrder.begin(), textureOrder.end(),
                             [&](const auto &key) { return !activeTextureKeys.contains(key); });
            if (candidate == textureOrder.end()) {
                break;
            }
            const auto old = *candidate;
            textureOrder.erase(candidate);
            if (const auto label = labels.value(old)) {
                invalidateBindings(label);
            }
            retire(labels.take(old));
            releaseCover(old);
            labelRevisions.remove(old);
        }
    }
    qint64 musicTextureBytes() const {
        qint64 bytes = 0;
        for (const auto texture : labels) {
            const auto dimensions = texture->pixelSize();
            bytes += qint64(dimensions.width()) * dimensions.height() * 4;
        }
        for (const auto texture : coverTextures) {
            const auto dimensions = texture->pixelSize();
            bytes += qint64(dimensions.width()) * dimensions.height() * 4;
        }
        return bytes;
    }
    QRhiShaderResourceBindings *bindings(std::vector<QRhiShaderResourceBinding> list,
                                         bool temporary = false) {
        ++bindingCreations;
        auto b = own(rhi->newShaderResourceBindings(), false, temporary);
        b->setBindings(list.begin(), list.end());
        return create(b);
    }
    QRhiGraphicsPipeline *pipeline(QString kind, QRhiShaderResourceBindings *srb,
                                   QRhiRenderPassDescriptor *rp, bool back = false, bool doubleSided = false,
                                   bool depthWrite = true, bool blend = false) {
        auto key = kind + QString("/%1/%2/%3/%4/%5")
                              .arg(quintptr(rp))
                              .arg(back)
                              .arg(doubleSided)
                              .arg(depthWrite)
                              .arg(blend);
        if (pipelines.contains(key)) {
            return pipelines[key];
        }
        auto p = own(rhi->newGraphicsPipeline(), true);
        const bool geo = kind == "surface" || kind == "normal" || kind == "shadow";
        p->setShaderStages(
            {{QRhiShaderStage::Vertex,
              shader(geo ? (kind == "shadow" ? "shadow.vert" : "geometry.vert") : "quad.vert")},
             {QRhiShaderStage::Fragment, shader(kind + ".frag")}});
        if (geo) {
            QRhiVertexInputLayout layout;
            layout.setBindings({{48}, {80, QRhiVertexInputBinding::PerInstance}});
            layout.setAttributes({{0, 0, QRhiVertexInputAttribute::Float4, 0},
                                  {0, 1, QRhiVertexInputAttribute::Float4, 16},
                                  {0, 2, QRhiVertexInputAttribute::Float4, 32},
                                  {1, 3, QRhiVertexInputAttribute::Float4, 0},
                                  {1, 4, QRhiVertexInputAttribute::Float4, 16},
                                  {1, 5, QRhiVertexInputAttribute::Float4, 32},
                                  {1, 6, QRhiVertexInputAttribute::Float4, 48},
                                  {1, 7, QRhiVertexInputAttribute::Float4, 64}});
            p->setVertexInputLayout(layout);
            p->setDepthTest(true);
            p->setDepthWrite(depthWrite);
            p->setDepthOp(QRhiGraphicsPipeline::LessOrEqual);
            p->setCullMode(back          ? QRhiGraphicsPipeline::Front
                           : doubleSided ? QRhiGraphicsPipeline::None
                                         : QRhiGraphicsPipeline::Back);
            p->setFrontFace(QRhiGraphicsPipeline::CCW);
        }
        QRhiGraphicsPipeline::TargetBlend b;
        if (blend) {
            b.enable = true;
            b.srcColor = QRhiGraphicsPipeline::SrcAlpha;
            b.dstColor = QRhiGraphicsPipeline::OneMinusSrcAlpha;
            b.srcAlpha = QRhiGraphicsPipeline::One;
            b.dstAlpha = QRhiGraphicsPipeline::OneMinusSrcAlpha;
        }
        if (kind == "normal") {
            p->setTargetBlends({b, b});
        } else if (kind != "shadow") {
            p->setTargetBlends({b});
        }
        // 管线的布局对象必须比管线活得久，不能持有本帧临时绑定。
        if (!pipelineLayouts.contains(kind)) {
            auto layout = own(rhi->newShaderResourceBindings(), true);
            auto stage = QRhiShaderResourceBinding::VertexStage | QRhiShaderResourceBinding::FragmentStage;
            std::vector<QRhiShaderResourceBinding> values = {QRhiShaderResourceBinding::uniformBuffer(
                0, kind == "shadow" ? QRhiShaderResourceBinding::VertexStage : stage, globalBuffer)};
            if (kind != "shadow" && kind != "normal") {
                values.push_back(QRhiShaderResourceBinding::uniformBuffer(
                    1, QRhiShaderResourceBinding::FragmentStage, kernel));
            }
            int count = kind == "surface"                                ? 6
                        : kind == "shadow" || kind == "normal"           ? 0
                        : kind == "aoFragment"                           ? 3
                        : kind == "combineAO" || kind == "bokehFragment" ? 2
                                                                         : 1;
            for (int i = 0; i < count; ++i) {
                values.push_back(QRhiShaderResourceBinding::sampledTexture(
                    2 + i, QRhiShaderResourceBinding::FragmentStage,
                    kind == "surface" && i == 2 ? shadow : white,
                    kind == "surface" && i == 2 ? shadowSampler : linear));
            }
            layout->setBindings(values.begin(), values.end());
            create(layout);
            pipelineLayouts[kind] = layout;
        }
        p->setSampleCount(1);
        p->setShaderResourceBindings(pipelineLayouts[kind]);
        p->setRenderPassDescriptor(rp);
        create(p);
        return pipelines[key] = p;
    }
    QRhiBuffer *dynamicBuffer(BufferState &state, const QByteArray &bytes, QRhiBuffer::UsageFlags usage) {
        if (!state.buffer || state.buffer->size() < bytes.size()) {
            retire(state.buffer);
            const int capacity = qMax(256, int(bytes.size()) * 2);
            state.buffer = create(own(rhi->newBuffer(QRhiBuffer::Dynamic, usage, capacity)));
            state.bytes.clear();
        }
        if (state.bytes != bytes) {
            // 单个连续区间覆盖实际变化；容量增长之外不再创建每帧临时 GPU 对象。
            qsizetype first = 0, last = bytes.size();
            if (state.bytes.size() == bytes.size()) {
                while (first < last && state.bytes[first] == bytes[first]) {
                    ++first;
                }
                while (last > first && state.bytes[last - 1] == bytes[last - 1]) {
                    --last;
                }
            }
            first = (first / 4) * 4;
            last = qMin(bytes.size(), ((last + 3) / 4) * 4);
            if (last > first) {
                updates->updateDynamicBuffer(state.buffer, int(first), int(last - first),
                                             bytes.constData() + first);
            }
            state.bytes = bytes;
        }
        state.used = generation;
        return state.buffer;
    }
    QByteArray matrixBytes(const QJsonObject &draw) const {
        const auto native = nativeBuffers.constFind(draw["id"].toInt());
        if (native != nativeBuffers.constEnd()) {
            return native->matrices;
        }
        QByteArray result;
        for (const auto &value : draw["matrices"].toArray()) {
            const float number = float(value.toDouble());
            result.append(reinterpret_cast<const char *>(&number), 4);
        }
        return result;
    }
    QRhiBuffer *instance(QJsonObject draw) {
        auto &state = instances[draw["id"].toInt()];
        if (state.used == generation) {
            return state.buffer;
        }
        const auto matrices = matrixBytes(draw);
        const auto native = nativeBuffers.value(draw["id"].toInt());
        const auto themes = draw["themes"].toArray();
        std::vector<Instance> values;
        values.reserve(draw["count"].toInt());
        for (int i = 0; i < draw["count"].toInt(); ++i) {
            Instance value;
            if ((i + 1) * 64 <= matrices.size()) {
                memcpy(value.model.elements, matrices.constData() + i * 64, 64);
            }
            float theme = n(draw, "theme");
            if ((i + 1) * 4 <= native.themes.size()) {
                memcpy(&theme, native.themes.constData() + i * 4, 4);
            } else if (i < themes.size()) {
                theme = float(themes[i].toDouble());
            }
            value.state = {n(draw, "quality"), n(draw, "clarity"), theme, 0};
            values.push_back(value);
        }
        const QByteArray bytes(reinterpret_cast<const char *>(values.data()),
                               values.size() * sizeof(Instance));
        return dynamicBuffer(state, bytes, QRhiBuffer::VertexBuffer);
    }
    struct Draw {
        QJsonObject data;
        QRhiBuffer *vertices, *indices, *instances;
        QRhiTexture *label;
        QRhiTexture *cover;
        int start;
        int count;
        QRhiShaderResourceBindings *bindings;
    };
    QList<Draw> prepare(const QList<QJsonObject> &draws) {
        QList<Draw> result;
        const auto stages = QRhiShaderResourceBinding::VertexStage | QRhiShaderResourceBinding::FragmentStage;
        for (auto d : draws) {
            if (d["count"].toInt() <= 0) {
                continue;
            }
            int start = 0;
            int count = 6;
            int mesh = d["mesh"].toInt();
            QRhiBuffer *vertices = floor, *indices = nullptr;
            if (mesh == -2) {
                vertices = coverPlane;
                count = discPrintCount;
            } else if (mesh == -3) {
                vertices = discBody;
                count = discBodyCount;
            } else if (mesh == -4) {
                vertices = discHub;
                count = discHubCount;
            } else if (mesh == -5) {
                vertices = caseDecoration;
            } else if (mesh >= 0 && meshes.contains(d["asset"].toString()) &&
                       mesh < meshes[d["asset"].toString()].parts.size()) {
                auto m = meshes[d["asset"].toString()];
                auto part = m.parts[mesh].toObject();
                start = part["start"].toInt();
                count = part["count"].toInt();
                vertices = m.vertices;
                indices = m.indices;
            } else if (d["label"].toBool()) {
                vertices = musicLabelPlane;
            } else if (!d["floor"].toBool()) {
                continue;
            }
            const auto resourceKey =
                QString::number(d["id"].toInt()) + "/" + QString::number(mesh) + "/" + d["name"].toString();
            auto &state = materials[resourceKey];
            state.used = generation;
            const auto material = surface(d);
            const auto mb = dynamicBuffer(
                state.uniform, QByteArray(reinterpret_cast<const char *>(&material), sizeof(material)),
                QRhiBuffer::UniformBuffer);
            const auto key =
                d["musicSelected"].toBool() ? musicItem["key"].toString() : d["musicKey"].toString();
            QRhiTexture *label = white;
            if (mesh == -5) {
                label = decorationTexture;
            } else if (d["label"].toBool()) {
                label = labels.value(key, labelTexture ? labelTexture : white);
            }
            // 着色器只有盘面读取封面，只有标签读取文字；其他表面绑定稳定的占位纹理。
            const auto cover = mesh == -2 ? covers.value(key, placeholderCover) : placeholderCover;
            // 缓存命中仍可能换曲，同一个 draw 的绑定必须跟随实际纹理指针。
            if (state.label != label || state.cover != cover) {
                retire(state.bindings);
                state.bindings = nullptr;
                state.label = label;
                state.cover = cover;
            }
            if (!state.bindings) {
                state.bindings = bindings(
                    {QRhiShaderResourceBinding::uniformBuffer(0, stages, globalBuffer),
                     QRhiShaderResourceBinding::uniformBuffer(1, QRhiShaderResourceBinding::FragmentStage,
                                                              mb),
                     QRhiShaderResourceBinding::sampledTexture(2, QRhiShaderResourceBinding::FragmentStage,
                                                               environment, linear),
                     QRhiShaderResourceBinding::sampledTexture(3, QRhiShaderResourceBinding::FragmentStage,
                                                               capture, mipSampler),
                     QRhiShaderResourceBinding::sampledTexture(4, QRhiShaderResourceBinding::FragmentStage,
                                                               shadow, shadowSampler),
                     QRhiShaderResourceBinding::sampledTexture(5, QRhiShaderResourceBinding::FragmentStage,
                                                               label, linear),
                     QRhiShaderResourceBinding::sampledTexture(6, QRhiShaderResourceBinding::FragmentStage,
                                                               dfg, linear),
                     QRhiShaderResourceBinding::sampledTexture(7, QRhiShaderResourceBinding::FragmentStage,
                                                               cover, linear)},
                    false);
            }
            result.append({d, vertices, indices, instance(d), label, cover, start, count, state.bindings});
        }
        return result;
    }
    QHash<QByteArray, BufferState> batchInstances;
    /**
     * 把同几何的阴影物体和完全相同材质的不透明物体合成实例批次。
     * 透明与透射物体保留原排序；每个实例继续使用原来的矩阵、主题和揭示状态。
     */
    QList<Draw> batchDraws(const QList<Draw> &input, bool shadowPass, bool normalPass = false) {
        QList<Draw> result;
        QList<QByteArray> bytes;
        QList<QByteArray> keys;
        QHash<QByteArray, int> groups;
        QHash<QByteArray, int> groupSlots;
        for (const auto &draw : input) {
            const auto &data = draw.data;
            if (shadowPass && !(data["castShadow"].toBool() || data["shadowOnly"].toBool())) {
                continue;
            }
            if (!shadowPass && data["shadowOnly"].toBool()) {
                continue;
            }
            const auto material = surface(data);
            const bool eligible = shadowPass || normalPass ||
                                  (!data["transparent"].toBool() && n(data, "transmission") <= .000001 &&
                                   material.flags.x() != 2 && data["depthWrite"].toBool());
            if (!eligible) {
                result.append(draw);
                bytes.append(QByteArray());
                keys.append(QByteArray());
                continue;
            }
            QByteArray prefix = "opaque/";
            if (shadowPass) {
                prefix = "shadow/";
            } else if (normalPass) {
                prefix = "normal/";
            }
            auto key = prefix + QByteArray::number(quintptr(draw.vertices)) + '/' +
                       QByteArray::number(quintptr(draw.indices)) + '/' + QByteArray::number(draw.start) +
                       '/' + QByteArray::number(draw.count) + '/' +
                       QByteArray::number(normalPass ? 0 : data["side"].toInt());
            if (!shadowPass && !normalPass) {
                key += '/' + QByteArray::number(data["order"].toInt()) + '/' +
                       QByteArray::number(quintptr(draw.label)) + '/' +
                       QByteArray::number(quintptr(draw.cover)) + ':';
            }
            const auto bufferKey = key;
            if (!shadowPass && !normalPass) {
                key.append(reinterpret_cast<const char *>(&material), sizeof(material));
            }
            auto group = groups.constFind(key);
            int index;
            if (group == groups.constEnd()) {
                index = result.size();
                groups.insert(key, index);
                result.append(draw);
                result.last().data["count"] = 0;
                bytes.append(QByteArray());
                // 材质插值每帧变化，但批次缓冲区按几何和槽位复用，不能按材质值反复创建。
                const int slot = groupSlots[bufferKey]++;
                keys.append(bufferKey + '/' + QByteArray::number(slot));
            } else {
                index = group.value();
            }
            bytes[index].append(instances.value(data["id"].toInt()).bytes);
            result[index].data["count"] = result[index].data["count"].toInt() + data["count"].toInt();
        }
        for (int i = 0; i < result.size(); ++i) {
            if (!keys[i].isEmpty()) {
                result[i].instances =
                    dynamicBuffer(batchInstances[keys[i]], bytes[i], QRhiBuffer::VertexBuffer);
            }
        }
        return result;
    }
    void geometry(QRhiCommandBuffer *cb, const QList<Draw> &draws, QString kind, QRhiRenderPassDescriptor *rp,
                  bool back = false) {
        for (const auto &draw : draws) {
            auto d = draw.data;
            if (d["shadowOnly"].toBool() && kind != "shadow") {
                continue;
            }
            if (kind == "shadow" && !(d["castShadow"].toBool() || d["shadowOnly"].toBool())) {
                continue;
            }
            const bool hashed = surface(d).flags.x() == 2;
            const bool blend =
                kind == "surface" && (hashed || d["transparent"].toBool() || n(d, "transmission") > .000001);
            const bool write = kind != "surface" || hashed || !blend || d["depthWrite"].toBool();
            cb->setGraphicsPipeline(pipeline(kind, draw.bindings, rp, back,
                                             kind != "normal" && d["side"].toInt() == 2, write, blend));
            // D3D11 会按首次使用的着色器缓存绑定映射。阴影/法线阶段只绑定全局参数，
            // 不能复用材质的纹理绑定，否则深度贴图会被误读成环境光贴图。
            cb->setShaderResources(kind == "surface" ? draw.bindings : pipelineLayouts.value(kind));
            auto s = kind == "shadow" ? QSize(2048, 2048) : size;
            cb->setViewport({0, 0, float(s.width()), float(s.height())});
            const QRhiCommandBuffer::VertexInput inputs[] = {{draw.vertices, 0}, {draw.instances, 0}};
            cb->setVertexInput(0, 2, inputs, draw.indices, 0, QRhiCommandBuffer::IndexUInt32);
            if (draw.indices) {
                cb->drawIndexed(draw.count, d["count"].toInt(), draw.start);
            } else {
                cb->draw(draw.count, d["count"].toInt(), draw.start);
            }
            ++drawCalls;
        }
    }
    void quad(QRhiCommandBuffer *cb, QString kind, QRhiRenderTarget *rt, QRhiRenderPassDescriptor *rp,
              QList<QRhiTexture *> textures) {
        const auto stages = QRhiShaderResourceBinding::VertexStage | QRhiShaderResourceBinding::FragmentStage;
        std::vector<QRhiShaderResourceBinding> list = {
            QRhiShaderResourceBinding::uniformBuffer(0, stages, globalBuffer),
            QRhiShaderResourceBinding::uniformBuffer(1, QRhiShaderResourceBinding::FragmentStage, kernel)};
        for (int i = 0; i < textures.size(); ++i) {
            auto s = (kind == "aoFragment"                ? (i == 2 ? repeat : nearest)
                      : kind == "bokehFragment" && i == 1 ? nearest
                                                          : linear);
            list.push_back(QRhiShaderResourceBinding::sampledTexture(
                2 + i, QRhiShaderResourceBinding::FragmentStage, textures[i], s));
        }
        // 查看封面使用当前颜色纹理，资料库使用景深纹理；缓存必须区分实际输入。
        // 否则切换查看器后会继续采样上一张资料库画面。
        QString bindingKey = kind;
        for (auto texture : textures) {
            bindingKey += "/" + QString::number(quintptr(texture), 16);
        }
        auto &sb = postBindings[bindingKey];
        if (!sb) {
            sb = own(rhi->newShaderResourceBindings(), true);
            sb->setBindings(list.begin(), list.end());
            create(sb);
        }
        cb->beginPass(rt, Qt::black, {1, 0});
        cb->setGraphicsPipeline(pipeline(kind, sb, rp));
        cb->setShaderResources(sb);
        cb->setViewport({0, 0, float(size.width()), float(size.height())});
        cb->draw(3);
        ++drawCalls;
        cb->endPass();
    }
    void render(QRhiCommandBuffer *cb, QJsonObject frame, QSize dimensions, QJsonObject item, QImage cover,
                QRhiRenderTarget *finalTarget = nullptr, const Engine::MusicTextures &musicTextures = {}) {
        transient.clear();
        ++generation;
        if (!updates) {
            updates = rhi->nextResourceUpdateBatch();
        }
        resize(dimensions, !finalTarget);
        activeTextureKeys.clear();
        activeTextureKeys.insert(item["key"].toString("empty"));
        for (auto it = musicTextures.begin(); it != musicTextures.end(); ++it) {
            activeTextureKeys.insert(it.key());
        }
        // 恢复图形设备时先还原仍可见的旧唱片，最后绑定当前曲目。
        for (auto it = musicTextures.begin(); it != musicTextures.end(); ++it) {
            if (it.key() != item["key"].toString("empty") && !labels.contains(it.key())) {
                updateMusic(it->item, it->cover);
            }
        }
        updateMusic(item, cover);
        auto g = globals(frame);
        updates->updateDynamicBuffer(globalBuffer, 0, sizeof(g), &g);
        auto data = prepare(musicDraws(frame));
        for (auto it = materials.begin(); it != materials.end();) {
            if (it->used != generation) {
                retire(it->bindings);
                retire(it->uniform.buffer);
                it = materials.erase(it);
            } else {
                ++it;
            }
        }
        for (auto it = instances.begin(); it != instances.end();) {
            if (it->used != generation) {
                retire(it->buffer);
                it = instances.erase(it);
            } else {
                ++it;
            }
        }
        const bool useBatches = frame["batchDraws"].toBool(true);
        auto shadowDraws = useBatches ? batchDraws(data, true) : data;
        QByteArray shadowInputs;
        for (const auto &draw : data) {
            if (draw.data["castShadow"].toBool() || draw.data["shadowOnly"].toBool()) {
                const auto identity = QByteArray::number(draw.data["id"].toInt()) + "/" +
                                      draw.data["asset"].toString().toUtf8() + "/" +
                                      QByteArray::number(draw.data["mesh"].toInt()) + "/" +
                                      QByteArray::number(draw.data["count"].toInt()) + ":";
                shadowInputs.append(identity);
                shadowInputs.append(matrixBytes(draw.data));
            }
        }
        if (!shadowValid || shadowInputs != shadowRevision) {
            // 合批缓冲区与其他实例更新一起提交，阴影只需按几何而非按卡片发出指令。
            cb->resourceUpdate(updates);
            updates = nullptr;
            cb->beginPass(shadowTarget, Qt::black, {1, 0});
            geometry(cb, shadowDraws, "shadow", shadowPass);
            cb->endPass();
            shadowRevision = shadowInputs;
            shadowValid = true;
        }
        QList<Draw> opaque, glass, transparent, backs;
        for (auto d : data) {
            if (n(d.data, "transmission") > .000001) {
                glass << d;
                if (d.data["side"].toInt() == 2) {
                    backs << d;
                }
            } else if (d.data["transparent"].toBool()) {
                transparent << d;
            } else {
                opaque << d;
            }
        }
        auto sort = [](auto &v) {
            std::stable_sort(v.begin(), v.end(), [](auto &a, auto &b) {
                return a.data["order"].toInt() < b.data["order"].toInt();
            });
        };
        sort(opaque);
        sort(glass);
        sort(transparent);
        sort(backs);
        // 阴影未重绘时更新批次仍未提交；颜色通道需要的实例缓冲区在此准备。
        if (!updates) {
            updates = rhi->nextResourceUpdateBatch();
        }
        if (useBatches) {
            opaque = batchDraws(opaque, false);
        }
        QList<Draw> normalDraws;
        if (!frame["viewer"].toBool()) {
            normalDraws =
                useBatches && frame["batchNormal"].toBool(true) ? batchDraws(data, false, true) : data;
        }
        for (auto it = batchInstances.begin(); it != batchInstances.end();) {
            if (it->used != generation) {
                retire(it->buffer);
                it = batchInstances.erase(it);
            } else {
                ++it;
            }
        }
        cb->resourceUpdate(updates);
        updates = nullptr;
        auto bg = vector(frame["background"]);
        cb->beginPass(color.rt, QColor::fromRgbF(bg.x(), bg.y(), bg.z()), {1, 0});
        geometry(cb, opaque, "surface", color.rp);
        cb->endPass();
        auto copy = rhi->nextResourceUpdateBatch();
        copy->copyTexture(capture, color.texture);
        copy->copyTexture(opaqueColor.texture, color.texture);
        copy->copyTexture(opaqueDepth, depth);
        copy->generateMips(capture);
        cb->resourceUpdate(copy);
        if (!backs.isEmpty()) {
            cb->beginPass(loaded, Qt::black, {1, 0});
            geometry(cb, backs, "surface", color.rp, true);
            cb->endPass();
            auto copy = rhi->nextResourceUpdateBatch();
            copy->copyTexture(capture, color.texture);
            copy->generateMips(capture);
            copy->copyTexture(color.texture, opaqueColor.texture);
            copy->copyTexture(depth, opaqueDepth);
            cb->resourceUpdate(copy);
        }
        cb->beginPass(loaded, Qt::black, {1, 0});
        geometry(cb, glass, "surface", color.rp);
        geometry(cb, transparent, "surface", color.rp);
        cb->endPass();
        if (!frame["viewer"].toBool()) {
            cb->beginPass(normal.rt, Qt::white, {1, 0});
            geometry(cb, normalDraws, "normal", normal.rp);
            cb->endPass();
            quad(cb, "aoFragment", ao.rt, ao.rp, {normal.texture, normalDepth, noise});
            quad(cb, "blurAO", blur.rt, blur.rp, {ao.texture});
            quad(cb, "combineAO", combined.rt, combined.rp, {color.texture, blur.texture});
            quad(cb, "bokehFragment", bokeh.rt, bokeh.rp, {combined.texture, normalDepth});
        }
        auto destination = finalTarget ? finalTarget : target.rt;
        quad(cb, "finalFragment", destination, destination->renderPassDescriptor(),
             {frame["viewer"].toBool() ? color.texture : bokeh.texture});
    }
};
class ItemRenderer : public QQuickRhiItemRenderer {
    Engine *backend = nullptr;
    std::unique_ptr<Renderer> renderer;
    QJsonObject frame, item;
    SceneDrawBuffers buffers;
    Engine::MusicTextures musicTextures;
    QImage cover;
    QString root;

  public:
    void synchronize(QQuickRhiItem *value) override {
        auto scene = static_cast<RhiScene *>(value);
        auto engine = scene->engine();
        backend = engine;
        if (engine) {
            frame = engine->frame();
            buffers = engine->drawBuffers();
            musicTextures = engine->musicTextures();
            item = engine->current();
            cover = engine->cover();
            root = engine->root();
        }
    }
    void initialize(QRhiCommandBuffer *) override {
        if (renderer && renderer->rhi != rhi()) {
            renderer.reset();
        }
    }
    void render(QRhiCommandBuffer *cb) override {
        if (frame.isEmpty() || (frame["mode"] == "boot" && frame["time"].toDouble() < 21.9)) {
            cb->beginPass(renderTarget(), Qt::transparent, {1, 0});
            cb->endPass();
            return;
        }
        if (!renderer) {
            renderer = std::make_unique<Renderer>(root, rhi());
        }
        renderer->nativeBuffers = buffers;
        const auto previousBindings = renderer->bindingCreations;
        const auto previousUploads = renderer->coverUploads;
        const auto previousDrawCalls = renderer->drawCalls;
        renderer->render(cb, frame, renderTarget()->pixelSize(), item, cover, renderTarget(), musicTextures);
        if (backend) {
            backend->recordRender(
                renderer->resources.size() + renderer->sized.size() + renderer->transient.size(),
                renderer->bindingCreations - previousBindings, renderer->musicTextureBytes(),
                renderer->coverUploads - previousUploads, renderer->drawCalls - previousDrawCalls);
        }
    }
};
RhiScene::RhiScene(QQuickItem *parent) : QQuickRhiItem(parent) {
    setAlphaBlending(true);
}
void RhiScene::setEngine(Engine *value) {
    if (value == m_engine) {
        return;
    }
    if (m_engine) {
        disconnect(m_engine, nullptr, this, nullptr);
    }
    m_engine = value;
    if (value) {
        connect(value, &Engine::sceneUpdated, this, [this] { update(); });
    }
    emit engineChanged();
    update();
}
QQuickRhiItemRenderer *RhiScene::createRenderer() {
    return new ItemRenderer;
}
/**
 * 使用同一份场景数据生成参考图，供离线渲染比较使用。
 */
QImage renderReference(const QString &root, const QJsonObject &frame, const QJsonObject &item,
                       const QImage &cover, QSize size, const SceneDrawBuffers &buffers, quint64 *drawCalls) {
    std::unique_ptr<QRhi> rhi;
#ifdef Q_OS_MACOS
    QRhiMetalInitParams params;
    rhi.reset(QRhi::create(QRhi::Metal, &params));
#elif defined(Q_OS_WIN)
    QRhiD3D11InitParams params;
    rhi.reset(QRhi::create(QRhi::D3D11, &params,
                           qEnvironmentVariableIntValue("RHINE_SOFTWARE_GPU") == 1
                               ? QRhi::PreferSoftwareRenderer
                               : QRhi::Flags{}));
#else
    std::unique_ptr<QOffscreenSurface> surface(QRhiGles2InitParams::newFallbackSurface());
    QRhiGles2InitParams params;
    params.fallbackSurface = surface.get();
    rhi.reset(QRhi::create(QRhi::OpenGLES2, &params));
#endif
    if (!rhi) {
        qFatal("No RHI device for reference render");
    }
    QRhiCommandBuffer *cb = nullptr;
    if (rhi->beginOffscreenFrame(&cb) != QRhi::FrameOpSuccess) {
        qFatal("Offscreen frame failed");
    }
    Renderer renderer(root, rhi.get());
    renderer.nativeBuffers = buffers;
    renderer.render(cb, frame, size, item, cover);
    if (drawCalls) {
        *drawCalls = renderer.drawCalls;
    }
    QRhiReadbackResult result;
    bool completed = false;
    result.completed = [&] { completed = true; };
    auto batch = rhi->nextResourceUpdateBatch();
    batch->readBackTexture(QRhiReadbackDescription(renderer.target.texture), &result);
    cb->resourceUpdate(batch);
    rhi->endOffscreenFrame();
    rhi->finish();
    if (!completed) {
        qFatal("RHI readback failed");
    }
    QImage image(reinterpret_cast<const uchar *>(result.data.constData()), result.pixelSize.width(),
                 result.pixelSize.height(), QImage::Format_RGBA8888);
    if (!rhi->isYUpInFramebuffer()) {
        return image.copy();
    }
#if QT_VERSION >= QT_VERSION_CHECK(6, 9, 0)
    return image.flipped(Qt::Vertical);
#else
    return image.mirrored(false, true);
#endif
}
