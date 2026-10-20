import QtQuick
import QtCore
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs

ApplicationWindow {
    id: root

    Settings {
        id: textreamSettings
        category: "Teleprompter"

        property alias savedSpeed: root.speed
        property alias savedFontSize: root.fontPointSize
        property alias savedOpacity: root.prompterOpacity
        property alias savedMirror: root.mirror
        property alias savedVoiceMode: root.voiceMode
        property alias savedAutoStartMicrophone:
            root.autoStartMicrophone
    }

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


    // Voice-following state. Manual scrolling remains the default.
    property bool voiceMode: false
    property bool autoStartMicrophone: false
    property var scriptWords: []
    property int voiceWordIndex: -1
    property int voiceTrackingUpdates: 0
    property real voiceReadingPosition: 0.33
    property int recoveryCandidate: -1
    property int recoveryConfirmations: 0
    property string voiceLastSpeech: ""
    property int voiceLastFinalCount: 0
    property real voiceTargetY: 0

    function tokenize(text) {
        const result = []
        const regex = /[a-z0-9]+(?:'[a-z0-9]+)*/g
        const lower = text.toLowerCase()
        let match

        while ((match = regex.exec(lower)) !== null) {
            result.push({
                word: match[0],
                position: match.index
            })
        }

        return result
    }

    function resetVoiceTracking() {
        scriptWords = tokenize(root.script)
        voiceWordIndex = -1
        voiceTrackingUpdates = 0
        voiceTargetY = 0
        voiceLastSpeech = ""
        voiceLastFinalCount = 0
            recoveryCandidate = -1
        recoveryConfirmations = 0
    }

    function updateVoicePosition() {
        if (!root.voiceMode || !prompter.visible ||
            scriptWords.length === 0)
            return

        // Match only the most recent speech. Keep a little
        // extra text before tokenizing to preserve word edges.
        function recentWords(text, limit) {
            const tail = text.slice(-512)
            const words = tokenize(tail).map(
                function(item) { return item.word }
            )
            return words.slice(-limit)
        }

        const finalWords = recentWords(
            audioCapture.finalTranscript, 12
        )

        const partialWords = recentWords(
            audioCapture.partialTranscript, 12
        )

        const heard = finalWords.concat(partialWords).slice(-12)
        if (heard.length === 0)
            return

        const speechKey = heard.join(" ")
        if (speechKey === voiceLastSpeech)
            return

        voiceLastSpeech = speechKey
        voiceTrackingUpdates++

        const current = voiceWordIndex
        const recent = heard.slice(Math.max(0, heard.length - 12))

        // Compare a spoken phrase ending at the latest word
        // against a phrase ending at script index j.
        function scoreAt(j) {
            let bestScore = -9999
            let bestMatches = 0

            const maxLength = Math.min(8, recent.length, j + 1)

            for (let length = 2; length <= maxLength; ++length) {
                let matches = 0
                let score = 0

                const scriptStart = j - length + 1
                const heardStart = recent.length - length

                for (let k = 0; k < length; ++k) {
                    const a = recent[heardStart + k]
                    const b = scriptWords[scriptStart + k].word

                    if (a === b) {
                        matches++
                        score += 3
                    } else {
                        score -= 2
                    }
                }

                if (matches < 2)
                    continue

                score += matches * 2

                if (score > bestScore) {
                    bestScore = score
                    bestMatches = matches
                }
            }

            return {
                score: bestScore,
                matches: bestMatches
            }
        }

        const localStart = Math.max(0, current + 1)
        const localEnd = Math.min(
            scriptWords.length,
            current + 25
        )

        let localIndex = -1
        let localScore = -9999

        for (let j = localStart; j < localEnd; ++j) {
            const result = scoreAt(j)

            // Prefer closer candidates when phrases tie.
            const distance = j - localStart
            const adjusted = result.score - distance * 0.8

            if (result.matches >= 2 &&
                adjusted > localScore) {
                localScore = adjusted
                localIndex = j
            }
        }

        let chosenIndex = -1

        if (localIndex >= 0 && localScore >= 6) {
            chosenIndex = localIndex

            // Normal tracking supersedes pending recovery.
            recoveryCandidate = -1
            recoveryConfirmations = 0
        } else {
            // Search farther only when local matching fails.
            const farStart = Math.max(
                localEnd,
                current + 1
            )
            const farEnd = Math.min(
                scriptWords.length,
                current + 160
            )

            let farIndex = -1
            let farScore = -9999
            let farMatches = 0

            for (let j = farStart; j < farEnd; ++j) {
                const result = scoreAt(j)

                if (result.matches < 4)
                    continue

                const adjusted = result.score -
                    (j - farStart) * 0.05

                if (adjusted > farScore) {
                    farScore = adjusted
                    farIndex = j
                    farMatches = result.matches
                }
            }

            if (farIndex >= 0 &&
                farMatches >= 4 &&
                farScore >= 15) {

                // Group nearby candidates together because
                // partial transcription can change word endings.
                if (recoveryCandidate >= 0 &&
                    Math.abs(farIndex - recoveryCandidate) <= 5) {
                    recoveryConfirmations++
                } else {
                    recoveryCandidate = farIndex
                    recoveryConfirmations = 1
                }

                if (recoveryConfirmations >= 3) {
                    chosenIndex = farIndex
                    recoveryCandidate = -1
                    recoveryConfirmations = 0
                }
            } else {
                recoveryCandidate = -1
                recoveryConfirmations = 0
            }
        }

        if (chosenIndex < 0 ||
            chosenIndex <= voiceWordIndex)
            return

        voiceWordIndex = chosenIndex

        const characterPosition =
            scriptWords[chosenIndex].position

        const rectangle =
            promptText.positionToRectangle(characterPosition)

        const desiredY =
            promptText.y +
            rectangle.y -
            scroll.height * root.voiceReadingPosition

        voiceTargetY = Math.max(
            0,
            Math.min(
                desiredY,
                Math.max(
                    0,
                    scroll.contentHeight - scroll.height
                )
            )
        )
    }

    onScriptChanged: resetVoiceTracking()

    onVoiceModeChanged: {
        root.playing = false
        resetVoiceTracking()

        if (voiceMode)
            updateVoicePosition()
    }

    Connections {
        target: audioCapture

        function onTranscriptChanged() {
            root.updateVoicePosition()
        }
    }


    Component.onCompleted: {
        if (root.autoStartMicrophone) {
            Qt.callLater(function() {
                if (!audioCapture.recording &&
                    micSelector.count > 0) {
                    audioCapture.start(micSelector.currentIndex)
                }
            })
        }
    }
    Component.onDestruction: audioCapture.stop()

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
            Button { text: "Open Prompter"; onClicked: { root.script = editor.text; root.resetVoiceTracking(); prompter.show(); prompter.raise() } }
        }
    }
    ColumnLayout {
        anchors.fill: parent; anchors.margins: 22; spacing: 14
        Label { text: "Presentation script"; color: "#eeeeff"; font.pixelSize: 21; font.bold: true }
        Label { text: "Write or paste a script, then open the floating prompter."; color: "#aeb4c6" }
        RowLayout {
            Layout.fillWidth: true
            spacing: 12

            Label {
                text: "Microphone"
                color: "white"
            }

            CheckBox {
                text: "Auto-start mic"
                checked: root.autoStartMicrophone
                onToggled: root.autoStartMicrophone = checked
            }
            ComboBox {
                id: micSelector
                Layout.preferredWidth: 280
                model: audioCapture.devices
                enabled: !audioCapture.recording
            }

            Button {
                text: audioCapture.recording ? "Stop Mic" : "Start Mic"
                onClicked: {
                    if (audioCapture.recording)
                        audioCapture.stop()
                    else
                        audioCapture.start(micSelector.currentIndex)
                }
            }

            ProgressBar {
                Layout.fillWidth: true
                from: 0
                to: 1
                value: audioCapture.level
            }

            Label {
                text: Math.round(audioCapture.level * 100) + "%"
                color: "white"
                Layout.preferredWidth: 45
            }
        }

        Label {
            Layout.fillWidth: true
            visible: audioCapture.error.length > 0
            text: audioCapture.error
            color: "#ff8585"
            wrapMode: Text.WordWrap
        }

        Label {
            Layout.fillWidth: true

            text: "Recognized speech: " +
                  audioCapture.finalTranscript +
                  (audioCapture.partialTranscript.length > 0
                   ? " [" + audioCapture.partialTranscript + "]"
                   : "")

            wrapMode: Text.WordWrap
            color: "#a6e3a1"

            visible: audioCapture.recording ||
                     audioCapture.finalTranscript.length > 0
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 12

            Label {
                text: "Scrolling mode"
                color: "white"
            }

            ComboBox {
                id: scrollingMode
                model: ["Manual", "Voice"]
                currentIndex: root.voiceMode ? 1 : 0

                onActivated: function(index) {
                    root.voiceMode = (index === 1)
                }
            }

            Label {
                Layout.fillWidth: true
                color: "#aeb4c6"
                wrapMode: Text.WordWrap
                text: root.voiceMode
                    ? "Start the microphone and speak your script. "
                      + "Scrolling follows recognized phrases."
                    : "Use Play/Pause and the speed slider."
            }
        }

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
                    Button { enabled: !root.voiceMode; text: root.voiceMode ? "Voice Mode" : (root.playing ? "Pause" : "Play"); onClicked: root.playing = !root.playing }
                    Button { text: "Restart"; onClicked: { scroll.contentY = 0; root.playing = false; root.resetVoiceTracking() } }
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
                Rectangle {
                    id: spokenWordHighlight

                    z: 0
                    radius: 5
                    color: "#3b8152"
                    opacity: 0.55

                    visible: root.voiceMode &&
                             root.voiceWordIndex >= 0 &&
                             root.voiceWordIndex < root.scriptWords.length

                    property int startPosition: visible
                        ? root.scriptWords[root.voiceWordIndex].position
                        : 0

                    property int wordLength: visible
                        ? root.scriptWords[root.voiceWordIndex].word.length
                        : 0

                    property rect startRect:
                        promptText.positionToRectangle(startPosition)

                    property rect endRect:
                        promptText.positionToRectangle(
                            startPosition + wordLength
                        )

                    x: promptText.x + startRect.x - 3
                    y: promptText.y + startRect.y - 2

                    width: Math.max(
                        8,
                        endRect.x - startRect.x + 6
                    )

                    height: Math.max(1, startRect.height + 4)
                }

                TextEdit {
                    id: promptText
                    z: 1
                    readOnly: true
                    selectByMouse: false
                    persistentSelection: false
                    activeFocusOnTab: false
                    width: scroll.width - 40
                    x: 20; y: scroll.height / 3
                    text: root.script
                    wrapMode: TextEdit.Wrap
                    color: "#ffffff"
                    font.pixelSize: root.fontPointSize
                    font.weight: Font.DemiBold
                    horizontalAlignment: Text.AlignHCenter
                }
                Timer {
                    interval: 16
                    repeat: true
                    running: root.voiceMode && prompter.visible

                    onTriggered: {
                        const delta =
                            root.voiceTargetY - scroll.contentY

                        if (Math.abs(delta) < 0.5) {
                            scroll.contentY = root.voiceTargetY
                            return
                        }

                        // Smooth movement towards recognized speech.
                        scroll.contentY += delta * 0.16
                    }
                }

                Timer {
                    interval: 16; repeat: true;
                    running: root.playing &&
                             !root.voiceMode &&
                             prompter.visible
                    onTriggered: {
                        scroll.contentY = Math.min(scroll.contentY + root.speed * interval / 1000,
                                                   Math.max(0, scroll.contentHeight - scroll.height))
                        if (scroll.contentY >= scroll.contentHeight - scroll.height) root.playing = false
                    }
                }
            }

            Rectangle {
                id: readingPositionGuide
                parent: scroll.parent

                x: scroll.x + 8
                y: scroll.y +
                    scroll.height * 0.333333

                width: 36
                height: 2
                radius: 1

                color: "#72d6a0"
                opacity: 0.55
                visible: root.voiceMode
                z: 5
            }


            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Rectangle {
                    width: 8
                    height: 8
                    radius: 4
                    color: audioCapture.recording
                        ? "#57d98b" : "#777b85"
                }

                Label {
                    text: audioCapture.recording
                        ? "MIC ACTIVE" : "MIC OFF"
                    color: audioCapture.recording
                        ? "#86e7aa" : "#9ca0ab"
                    font.pixelSize: 10
                    font.bold: true
                }

                Item {
                    Layout.fillWidth: true
                }

                Label {
                    text: root.voiceMode
                        ? "VOICE TRACKING" : "MANUAL"
                    color: "#aeb4c0"
                    font.pixelSize: 10
                }
            }

            Rectangle {
                id: voiceProgressTrack
                Layout.fillWidth: true
                Layout.preferredHeight: 3
                radius: 2
                color: "#343941"
                visible: root.voiceMode

                Rectangle {
                    height: parent.height
                    radius: parent.radius
                    color: "#72d6a0"

                    width: parent.width *
                        (root.scriptWords.length > 0
                            ? Math.max(
                                0,
                                Math.min(
                                    1,
                                    (root.voiceWordIndex + 1) /
                                    root.scriptWords.length
                                )
                              )
                            : 0)
                }
            }

RowLayout {
                Layout.fillWidth: true
                Label {
                    visible: root.voiceMode
                    color: "#a6e3a1"
                    font.pixelSize: 11

                    text: root.voiceWordIndex >= 0
                        ? "Voice: word " +
                          (root.voiceWordIndex + 1) +
                          " / " + root.scriptWords.length
                        : "Voice: waiting for script match"
                }

                Label { text: "Drag the top bar to move • Scroll manually with mouse/touchpad"; color: "#a6aabd"; font.pixelSize: 11 }
                Item { Layout.fillWidth: true }
                CheckBox { text: "Mirror"; checked: root.mirror; onToggled: root.mirror = checked }
            }
        }

        // Native compositor-managed resize handle.
        Rectangle {
            id: resizeHandle
            width: 28
            height: 28
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            color: "transparent"
            z: 10

            Label {
                anchors.centerIn: parent
                text: "◢"
                color: "#aeb4c6"
                font.pixelSize: 18
            }

            HoverHandler {
                cursorShape: Qt.SizeFDiagCursor
            }

            DragHandler {
                target: null
                acceptedButtons: Qt.LeftButton
                onActiveChanged: {
                    if (active)
                        prompter.startSystemResize(Qt.RightEdge | Qt.BottomEdge)
                }
            }
        }


        // Teleprompter keyboard shortcuts.
        // Active only when this window has focus.

        Shortcut {
            id: shortcutPlayPause
            sequence: "Space"
            context: Qt.WindowShortcut
            enabled: prompter.active
            onActivated: if (!root.voiceMode) root.playing = !root.playing
        }

        Shortcut {
            sequence: "R"
            context: Qt.WindowShortcut
            enabled: prompter.active
            onActivated: {
                scroll.contentY = 0
                root.playing = false
                root.resetVoiceTracking()
            }
        }

        Shortcut {
            sequence: "Up"
            context: Qt.WindowShortcut
            enabled: prompter.active
            onActivated: root.speed = Math.min(150, root.speed + 5)
        }

        Shortcut {
            sequence: "Down"
            context: Qt.WindowShortcut
            enabled: prompter.active
            onActivated: root.speed = Math.max(0, root.speed - 5)
        }

        Shortcut {
            sequence: "+"
            context: Qt.WindowShortcut
            enabled: prompter.active
            onActivated: root.fontPointSize = Math.min(90, root.fontPointSize + 2)
        }

        Shortcut {
            sequence: "-"
            context: Qt.WindowShortcut
            enabled: prompter.active
            onActivated: root.fontPointSize = Math.max(14, root.fontPointSize - 2)
        }

        Shortcut {
            sequence: "Escape"
            context: Qt.WindowShortcut
            enabled: prompter.active
            onActivated: {
                root.playing = false
                prompter.hide()
            }
        }

        onClosing: root.playing = false
    }
}
