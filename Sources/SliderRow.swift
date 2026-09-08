import AppKit

/// A labelled slider that lives inside a menu. Menus keep custom views alive
/// while they are open, so dragging works without dismissing the menu.
final class SliderRow: NSView {
    private let slider = NSSlider()
    private let valueLabel = NSTextField(labelWithString: "")
    private let onChange: (Int) -> Void
    private var lastSent: Int

    init(title: String, value: Int, maximum: Int, onChange: @escaping (Int) -> Void) {
        self.onChange = onChange
        self.lastSent = value
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 44))

        let title = NSTextField(labelWithString: title)
        title.font = .menuFont(ofSize: 13)
        title.textColor = .labelColor

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        valueLabel.stringValue = "\(value)/\(maximum)"

        slider.minValue = 0
        slider.maxValue = Double(maximum)
        slider.doubleValue = Double(value)
        slider.numberOfTickMarks = maximum + 1
        slider.allowsTickMarkValuesOnly = true
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(sliderMoved)

        for view in [title, valueLabel, slider] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 2),

            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            valueLabel.centerYAnchor.constraint(equalTo: title.centerYAnchor),

            slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            slider.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func sliderMoved() {
        let value = Int(slider.doubleValue.rounded())
        valueLabel.stringValue = "\(value)/\(Int(slider.maxValue))"
        // The slider fires continuously; only talk to the earbuds on a real step.
        guard value != lastSent else { return }
        lastSent = value
        onChange(value)
    }
}
