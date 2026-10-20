import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs

ApplicationWindow {
    id: root
    width: 980; height: 680
    minimumWidth: 600; minimumHeight: 400
    visible: true
    title: "Textream Linux — Editor"
    color: "#17191f"
    property string script: "Welcome to Textream Linux.\n\nPaste your presentation script here, then select Open Prompter.\n\nAdjust the scrolling speed and font size while presenting."
    property real speed: 35
    property int fontPointSize: 28
    property real prompterOpacity: 0.90
    property bool mirror: false
    property bool playing: false
    property bool alwaysOnTop: true

    FileDialog {
        id: openDialog
        title: "Open a plain text script"
        nameFilters: ["Text files (*.txt *.md)", "All files (*)"]
        onAccepted: {
            const contents = fileManager.readTextFile(selectedFile)

            if (fileManager.lastError.length > 0) {
                loadError.text = fileManager.lastError
                loadError.open()
            } else {
                editor.text = contents
                root.script = contents
            }
        }
    }
    Dialog { id: loadError; title: "File error"; property alias text: errorLabel.text
        standardButtons: Dialog.Ok
        Label { id: errorLabel; text: "" }
    }

    header: ToolBar {
        background: Rectangle { color: "#252832" }
        RowLayout {
            anchors.fill: parent; anchors.margins: 10; spacing: 12
            Label { text: "TEXTREAM / LINUX"; font.bold: true; font.pixelSize: 16; color: "#e8e8ef" }
            Item { Layout.fillWidth: true }
            Button { text: "Open text file"; onClicked: openDialog.open() }
            Button { text: "Open Prompter"; onClicked: { root.script = editor.text; prompter.show(); prompter.raise() } }
        }
    }
    ColumnLayout {
        anchors.fill: parent; anchors.margins: 22; spacing: 14
        Label { text: "Presentation script"; color: "#eeeeff"; font.pixelSize: 21; font.bold: true }
        Label { text: "Write or paste a script, then open the floating prompter."; color: "#aeb4c6" }
        TextArea {
            id: editor; text: root.script; wrapMode: TextEdit.Wrap
            Layout.fillWidth: true; Layout.fillHeight: true
            font.pixelSize: 18; color: "#f3f4f8"; selectByMouse: true
            background: Rectangle { color: "#232630"; radius: 12; border.color: "#3a4050" }
            padding: 18
        }
        RowLayout {
            spacing: 12
            Label { text: "Speed"; color: "white" }
            Slider { from: 0; to: 150; value: root.speed; onMoved: root.speed = value; Layout.preferredWidth: 160 }
            Label { text: Math.round(root.speed) + " px/s"; color: "white"; Layout.preferredWidth: 75 }
            Label { text: "Font"; color: "white" }
            SpinBox { from: 14; to: 90; value: root.fontPointSize; onValueModified: root.fontPointSize = value }
            Label { text: "Opacity"; color: "white" }
            Slider { from: 0.35; to: 1; value: root.prompterOpacity; onMoved: root.prompterOpacity = value; Layout.preferredWidth: 115 }
            Item { Layout.fillWidth: true }
        }
    }

    Window {
        id: prompter
        width: 850; height: 290
        visible: false
        title: "Textream Linux — Prompter"
        color: "transparent"
        flags: Qt.Window | Qt.FramelessWindowHint | (root.alwaysOnTop ? Qt.WindowStaysOnTopHint : 0)
        Rectangle {
            anchors.fill: parent; color: "#101117"; opacity: root.prompterOpacity
            radius: 18; border.color: "#5c647b"; border.width: 1
        }
        ColumnLayout {
            anchors.fill: parent; anchors.margins: 12; spacing: 5
            Rectangle {
                Layout.fillWidth: true; Layout.preferredHeight: 42
                color: "transparent"
                RowLayout {
                    anchors.fill: parent
                    Label { text: "TEXTREAM"; color: "#c8cbe6"; font.bold: true }
                    Item { Layout.fillWidth: true }
                    Button { text: root.playing ? "Pause" : "Play"; onClicked: root.playing = !root.playing }
                    Button { text: "Restart"; onClicked: { scroll.contentY = 0; root.playing = false } }
                    Button { text: "−"; onClicked: root.fontPointSize = Math.max(14, root.fontPointSize - 2) }
                    Button { text: "+"; onClicked: root.fontPointSize = Math.min(90, root.fontPointSize + 2) }
                    Button { text: "Close"; onClicked: { root.playing = false; prompter.hide() } }
                }
                DragHandler { target: null; onActiveChanged: if (active) prompter.startSystemMove() }
            }
            Flickable {
                id: scroll
                Layout.fillWidth: true; Layout.fillHeight: true
                clip: true
                contentWidth: width
                contentHeight: promptText.height + height
                boundsBehavior: Flickable.StopAtBounds
                transform: Scale { origin.x: scroll.width / 2; xScale: root.mirror ? -1 : 1 }
                Text {
                    id: promptText
                    width: scroll.width - 40
                    x: 20; y: scroll.height / 3
                    text: root.script
                    wrapMode: Text.Wrap
                    color: "#ffffff"
                    font.pixelSize: root.fontPointSize
                    font.weight: Font.DemiBold
                    horizontalAlignment: Text.AlignHCenter
                }
                Timer {
                    interval: 16; repeat: true; running: root.playing && prompter.visible
                    onTriggered: {
                        scroll.contentY = Math.min(scroll.contentY + root.speed * interval / 1000,
                                                   Math.max(0, scroll.contentHeight - scroll.height))
                        if (scroll.contentY >= scroll.contentHeight - scroll.height) root.playing = false
                    }
                }
            }
            RowLayout {
                Layout.fillWidth: true
                Label { text: "Drag the top bar to move • Scroll manually with mouse/touchpad"; color: "#a6aabd"; font.pixelSize: 11 }
                Item { Layout.fillWidth: true }
                CheckBox { text: "Mirror"; checked: root.mirror; onToggled: root.mirror = checked }
            }
        }
        onClosing: root.playing = false
    }
}
