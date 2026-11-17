// A history graph: `values` (0–1, oldest first) drawn right-aligned over a faint grid, so the
// newest reading is always at the right edge.
import QtQuick
import QtQuick.Layouts

Canvas {
    id: root

    property var values: []
    property int capacity: 90
    property color color: Theme.accent

    Layout.fillWidth: true
    implicitHeight: 34

    onValuesChanged: requestPaint()
    onColorChanged: requestPaint()
    onWidthChanged: requestPaint()

    onPaint: {
        const ctx = getContext("2d");
        ctx.reset();
        const w = width, h = height;

        ctx.strokeStyle = Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.08);
        ctx.lineWidth = 1;
        for (let i = 1; i < 4; i++) {
            const y = Math.round(h * i / 4) + 0.5;
            ctx.beginPath();
            ctx.moveTo(0, y);
            ctx.lineTo(w, y);
            ctx.stroke();
        }

        const v = values;
        if (v.length < 2) return;
        const step = w / (capacity - 1);
        const x0 = w - (v.length - 1) * step;
        const y = value => h - 1 - Math.max(0, Math.min(1, value)) * (h - 2);

        ctx.beginPath();
        ctx.moveTo(x0, y(v[0]));
        for (let i = 1; i < v.length; i++) ctx.lineTo(x0 + i * step, y(v[i]));
        ctx.strokeStyle = root.color;
        ctx.lineWidth = 1.5;
        ctx.stroke();

        ctx.lineTo(w, h);
        ctx.lineTo(x0, h);
        ctx.closePath();
        ctx.fillStyle = Qt.rgba(root.color.r, root.color.g, root.color.b, 0.15);
        ctx.fill();
    }
}
