import QtQuick
import QtQuick.Window
import Rhine.Native 1.0

Window {
    id: root
    width: 1280
    height: 720
    minimumWidth: 960
    minimumHeight: 540
    visible: true
    flags: Qt.Window | Qt.WindowTitleHint | Qt.WindowSystemMenuHint | Qt.WindowMinMaxButtonsHint | Qt.WindowCloseButtonHint | Qt.WindowFullscreenButtonHint
    title: "RHINE MUSIC DATABASE"
    color: "#e7e7e1"
    property real stageScale: height / 1080
    property real stageWidth: width / stageScale
    onVisibilityChanged: function (visibility) {
        rhine.setVisible(visible && visibility !== Window.Minimized);
    }
    onWidthChanged: rhine.resize(width, height)
    onHeightChanged: rhine.resize(width, height)
    Component.onCompleted: {
        rhine.resize(width, height);
        inputLayer.forceActiveFocus();
    }
    Shortcut {
        sequences: [StandardKey.Quit]
        onActivated: Qt.quit()
    }
    Shortcut {
        sequences: Qt.platform.os === "osx" ? [StandardKey.FullScreen, "F11"] : ["F11"]
        onActivated: rhine.toggleFullscreen()
    }
    RhiScene {
        anchors.fill: parent
        engine: rhine
    }
    Hud {
        anchors.fill: parent
        engine: rhine
    }
    // 透明 QML 输入层使用原舞台坐标；可见画面由同一份字形和材质绘制。
    MouseArea {
        id: inputLayer
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton
        focus: true
        onPressed: function (mouse) {
            forceActiveFocus();
            rhine.pointer("pointerdown", mouse.x / root.stageScale, mouse.y / root.stageScale);
        }
        onPositionChanged: function (mouse) {
            rhine.pointer("pointermove", mouse.x / root.stageScale, mouse.y / root.stageScale);
        }
        onReleased: function (mouse) {
            rhine.pointer("pointerup", mouse.x / root.stageScale, mouse.y / root.stageScale);
        }
        onExited: rhine.pointer("pointerleave", 0, 0)
        onCanceled: rhine.pointer("pointercancel", 0, 0)
        onWheel: function (wheel) {
            rhine.wheelInput(wheel.x / root.stageScale, wheel.y / root.stageScale, wheel.pixelDelta.y, wheel.angleDelta.y);
            wheel.accepted = true;
        }
        Keys.onPressed: function (event) {
            event.accepted = rhine.keyEvent(event.key, event.modifiers, event.text);
        }
    }
    Item {
        id: controls
        width: root.stageWidth
        height: 1080
        scale: root.stageScale
        transformOrigin: Item.TopLeft
        Repeater {
            model: rhine.hits
            delegate: Item {
                required property var modelData
                x: modelData.x
                y: modelData.y + (rhine.state.modal && !modelData.fixed ? rhine.state.modalOffset || 0 : 0)
                width: modelData.width
                height: modelData.height
                Accessible.role: Accessible.Button
                Accessible.name: modelData.label
                Accessible.onPressAction: rhine.action(modelData.action)
                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onEntered: rhine.pointer("pointerleave", 0, 0)
                    onPressed: {
                        inputLayer.forceActiveFocus();
                        rhine.action(modelData.action);
                    }
                    onWheel: function (wheel) {
                        var p = mapToItem(inputLayer, wheel.x, wheel.y);
                        rhine.wheelInput(p.x / root.stageScale, p.y / root.stageScale, wheel.pixelDelta.y, wheel.angleDelta.y);
                        wheel.accepted = true;
                    }
                }
            }
        }
    }
    // 密码只在输入组件和单次登录请求中短暂存在，提交后立即清空。
    Item {
        id: formFields
        visible: rhine.state.modal === "playlist-form" || (rhine.state.modal === "login" && (rhine.state.loginMethod === "phone" || rhine.state.loginMethod === "email"))
        x: (rhine.state.inputX || 0) * root.stageScale
        y: (rhine.state.modalOffset || 0) * root.stageScale
        width: (rhine.state.inputWidth || 0) * root.stageScale
        height: root.height
        opacity: rhine.state.modalOpacity || 0
        onVisibleChanged: {
            accountField.text = "";
            passwordField.text = "";
            if (visible) {
                accountField.forceActiveFocus();
            }
        }
        function submit() {
            rhine.submitForm(accountField.text, passwordField.text);
            passwordField.text = "";
        }
        Rectangle {
            x: 0
            y: 430 * root.stageScale
            width: parent.width
            height: 55 * root.stageScale
            color: rhine.state.dark ? "#30312b" : "#d9d8ce"
        }
        TextInput {
            id: accountField
            objectName: "accountField"
            x: 14 * root.stageScale
            y: 430 * root.stageScale
            width: parent.width - 28 * root.stageScale
            height: 55 * root.stageScale
            verticalAlignment: TextInput.AlignVCenter
            color: rhine.state.dark ? "#eeeeeb" : "#161914"
            font.pixelSize: 19 * root.stageScale
            cursorVisible: activeFocus && !rhine.performance.idle
            maximumLength: 100
            Accessible.name: rhine.state.modal === "playlist-form" ? "歌单名称" : "登录账号"
            Keys.onReturnPressed: {
                if (rhine.state.modal !== "login") {
                    formFields.submit();
                } else {
                    passwordField.forceActiveFocus();
                }
            }
            Keys.onEscapePressed: rhine.action("close-modal")
        }
        Rectangle {
            visible: rhine.state.modal === "login"
            x: 0
            y: 541 * root.stageScale
            width: parent.width
            height: 55 * root.stageScale
            color: rhine.state.dark ? "#30312b" : "#d9d8ce"
        }
        TextInput {
            id: passwordField
            objectName: "passwordField"
            visible: rhine.state.modal === "login"
            x: 14 * root.stageScale
            y: 541 * root.stageScale
            width: parent.width - 28 * root.stageScale
            height: 55 * root.stageScale
            verticalAlignment: TextInput.AlignVCenter
            color: rhine.state.dark ? "#eeeeeb" : "#161914"
            font.pixelSize: 19 * root.stageScale
            cursorVisible: activeFocus && !rhine.performance.idle
            maximumLength: 256
            echoMode: TextInput.Password
            Accessible.name: "密码"
            Keys.onReturnPressed: formFields.submit()
            Keys.onEscapePressed: rhine.action("close-modal")
        }
        Rectangle {
            x: parent.width - width
            y: (rhine.state.modal === "login" ? 611 : 530) * root.stageScale
            width: 170 * root.stageScale
            height: 36 * root.stageScale
            color: "#777b60"
            Text {
                anchors.centerIn: parent
                text: rhine.state.modal === "login" ? "登录 →" : "保存 →"
                color: "#f0eee5"
                font.pixelSize: 14 * root.stageScale
            }
            Accessible.role: Accessible.Button
            Accessible.name: "提交表单"
            Accessible.onPressAction: formFields.submit()
            MouseArea {
                anchors.fill: parent
                onClicked: formFields.submit()
            }
        }
    }
    Repeater {
        model: ["seek", "volume"]
        delegate: MouseArea {
            required property string modelData
            property var region: rhine.state[modelData]
            visible: !!region
            enabled: visible && !rhine.state.closing
            x: region ? region.x * root.stageScale : 0
            y: region ? (region.y + (rhine.state.modal ? rhine.state.modalOffset || 0 : 0)) * root.stageScale : 0
            width: region ? region.width * root.stageScale : 0
            height: region ? region.height * root.stageScale : 0
            cursorShape: Qt.PointingHandCursor
            onPressed: function (mouse) {
                rhine.adjustPlayer(modelData, mouse.x, width);
            }
            onPositionChanged: function (mouse) {
                if (pressed) {
                    rhine.adjustPlayer(modelData, mouse.x, width);
                }
            }
        }
    }
    Connections {
        target: rhine
        function onClearCredentials() {
            accountField.text = "";
            passwordField.text = "";
        }
    }

    Rectangle {
        visible: searchInput.visible
        x: searchInput.x
        y: searchInput.y
        width: searchInput.width
        height: searchInput.height
        color: rhine.state.dark ? "#ffffff" : "#141613"
        opacity: (rhine.state.modalOpacity || 0) * 0.045
    }
    TextInput {
        id: searchInput
        objectName: "musicSearchInput"
        verticalAlignment: TextInput.AlignVCenter
        leftPadding: 14 * root.stageScale
        rightPadding: 14 * root.stageScale
        renderType: Text.NativeRendering
        visible: rhine.state.modal === "search" || rhine.state.modal === "saved"
        enabled: !rhine.state.closing
        x: (rhine.state.inputX || 0) * root.stageScale
        y: ((rhine.state.inputY || 302) + (rhine.state.modalOffset || 0)) * root.stageScale
        width: (rhine.state.inputWidth || 0) * root.stageScale
        height: 54 * root.stageScale
        font.family: rhineFontFamily
        font.pixelSize: 22 * root.stageScale
        color: rhine.state.dark ? "#ebebeb" : "#141613"
        opacity: rhine.state.modalOpacity || 0
        clip: true
        cursorVisible: activeFocus && !rhine.performance.idle
        selectByMouse: true
        Accessible.name: "搜索歌曲、歌手、专辑或歌单"
        onTextEdited: rhine.query(text)
        onVisibleChanged: {
            if (visible) {
                text = rhine.state.query || "";
                forceActiveFocus();
            } else {
                inputLayer.forceActiveFocus();
            }
        }
        Keys.onEscapePressed: rhine.action("close-modal")
        Keys.onReturnPressed: function (event) {
            rhine.searchAccepted(text, event.modifiers);
        }
        Text {
            anchors.fill: parent
            visible: searchInput.text.length === 0 && !searchInput.preeditText
            text: "搜索歌曲、歌手、专辑或歌单"
            font: searchInput.font
            leftPadding: searchInput.leftPadding
            verticalAlignment: Text.AlignVCenter
            color: "#777777"
        }
    }
}
