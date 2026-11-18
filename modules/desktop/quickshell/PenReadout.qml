// The pen on the bottom bar while it's out of its garage: its battery once it reports one. A tap
// brings the pen menu back.
import QtQuick

Readout {
    visible: Pen.out
    tag: "PEN"
    value: Math.max(0, Pen.battery) / 100
    segments: 5
    showGauge: Pen.battery >= 0
    reading: Pen.battery >= 0 ? String(Pen.battery).padStart(3, "0") : "OUT"
    tone: Pen.battery >= 0 && Pen.battery <= 15 ? Theme.urgent : Theme.accent

    onPressed: Pen.toggleMenu()
}
