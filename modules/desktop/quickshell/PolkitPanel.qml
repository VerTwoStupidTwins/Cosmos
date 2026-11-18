// The polkit agent: when something asks for authorisation (udisksctl, systemctl, pkexec, 1Password,
// Thunar mounting another user's drive…), an AUTH plate over a dimmed screen says what's asking,
// with the lock screen's password field. Enter submits, Esc clears the field or (empty) refuses,
// and so does a click outside. A wrong password shakes the plate and asks again.
//
// Quickshell registers as the session's only agent, so while the bar is down, nothing can prompt
// (systemd restarts it).
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.Polkit

PanelWindow {
    id: prompt

    readonly property var flow: agent.flow
    property bool busy: false
    property int attempts: 0

    function submit() {
        if (!flow || busy || !flow.isResponseRequired) return;
        busy = true;
        flow.submit(field.text);
    }
    function cancel() {
        flow?.cancelAuthenticationRequest();
    }

    visible: agent.isActive && flow !== null
    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "quickshell-polkit"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    color: Qt.rgba(0, 0, 0, 0.55)

    PolkitAgent {
        id: agent
        onAuthenticationRequestStarted: {
            prompt.busy = false;
            prompt.attempts = 0;
            field.text = "";
        }
    }

    Connections {
        target: prompt.flow

        // Polkit asks again after a wrong password, and that's when the field is free to type in.
        function onIsResponseRequiredChanged() {
            if (prompt.flow.isResponseRequired) {
                prompt.busy = false;
                field.focusInput();
            }
        }
        function onAuthenticationFailed() {
            prompt.busy = false;
            prompt.attempts += 1;
            field.text = "";
            shakeAnimation.restart();
        }
    }

    onVisibleChanged: if (visible) field.focusInput()

    // A click outside the plate refuses.
    MouseArea {
        anchors.fill: parent
        onClicked: prompt.cancel()
    }
    // …but not a click on it.
    MouseArea {
        anchors.fill: auth
    }

    Plate {
        id: auth
        anchors.centerIn: parent
        width: 480
        title: "AUTH"
        status: prompt.busy ? "VERIFYING" : prompt.flow?.failed ? "DENIED" : "PRIVILEGE REQUEST"
        statusTone: prompt.busy ? Theme.warn : prompt.flow?.failed ? Theme.urgent : Theme.dim
        cutTopLeft: 6
        cutBottomRight: 18
        cutBottomLeft: 6
        padding: 16

        // Shakes when a password is refused.
        transform: Translate {
            id: shake
        }

        Label {
            Layout.fillWidth: true
            Layout.topMargin: 2
            text: prompt.flow?.message ?? ""
            font.pixelSize: 14
            font.bold: true
            wrapMode: Text.Wrap
        }
        Stat {
            key: "ACTION"
            value: prompt.flow?.actionId ?? ""
        }
        Stat {
            key: "OPERATOR"
            value: Quickshell.env("USER")
        }

        KeyField {
            id: field
            Layout.topMargin: 6
            busy: prompt.busy
            failed: prompt.flow?.failed ?? false
            reveal: prompt.flow?.responseVisible ?? false
            // Polkit's prompt is "Password: " for the usual case; anything else is worth showing.
            placeholder: {
                const p = (prompt.flow?.inputPrompt ?? "").replace(/:\s*$/, "").trim();
                return p === "" || /^password$/i.test(p) ? "ENTER KEY" : p.toUpperCase();
            }
            onAccepted: prompt.submit()
            onEscaped: prompt.cancel()
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Label {
                Layout.fillWidth: true
                text: prompt.flow?.supplementaryMessage
                    ? prompt.flow.supplementaryMessage.toUpperCase()
                    : prompt.attempts > 0 ? "ACCESS DENIED  ·  ATTEMPT " + String(prompt.attempts).padStart(2, "0") : "AWAITING KEY"
                color: prompt.flow?.supplementaryIsError || prompt.attempts > 0 ? Theme.urgent : Theme.muted
                font.pixelSize: 10
                font.letterSpacing: 2
                elide: Text.ElideRight
            }
            Label {
                text: "ESC REFUSES"
                color: Theme.muted
                font.pixelSize: 9
                font.letterSpacing: 2
            }
        }
    }

    SequentialAnimation {
        id: shakeAnimation
        NumberAnimation { target: shake; property: "x"; to: -12; duration: 50 }
        NumberAnimation { target: shake; property: "x"; to: 10; duration: 70 }
        NumberAnimation { target: shake; property: "x"; to: -6; duration: 70 }
        NumberAnimation { target: shake; property: "x"; to: 0; duration: 60 }
    }
}
