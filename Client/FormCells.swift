import UIKit

// Small UIKit table cells used by the connect and settings screens. Cells are created once and kept by the owning
// controller, so a text field / slider never loses focus or its drag when other rows reload.

/// A cell with a title line, an arbitrary control below it and constraints that size the cell automatically.
class StackFormCell: UITableViewCell {
    let stack = UIStackView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

enum FormStyle {
    static var secondaryText: UIColor {
        if #available(iOS 13.0, *) { return UIColor.secondaryLabel }
        return UIColor.gray
    }

    static func footnoteLabel(_ text: String) -> UILabel {
        let l = UILabel()
        l.font = UIFont.preferredFont(forTextStyle: .footnote)
        l.textColor = secondaryText
        l.numberOfLines = 0
        l.text = text
        return l
    }
}

final class SegmentedCell: StackFormCell {
    let control: UISegmentedControl
    let note = FormStyle.footnoteLabel("")
    var onChange: ((Int) -> Void)?

    init(title: String?, items: [String], selected: Int) {
        control = UISegmentedControl(items: items)
        super.init(style: .default, reuseIdentifier: nil)
        if let t = title {
            let l = UILabel()
            l.text = t
            stack.addArrangedSubview(l)
        }
        control.selectedSegmentIndex = selected
        control.addTarget(self, action: #selector(changed), for: .valueChanged)
        stack.addArrangedSubview(control)
        note.isHidden = true
        stack.addArrangedSubview(note)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setNote(_ text: String?) {
        note.text = text
        note.isHidden = (text == nil || text!.isEmpty)
    }

    @objc private func changed() { onChange?(control.selectedSegmentIndex) }
}

final class SwitchCell: UITableViewCell {
    let toggle = UISwitch()
    var onChange: ((Bool) -> Void)?

    init(title: String, isOn: Bool) {
        super.init(style: .default, reuseIdentifier: nil)
        selectionStyle = .none
        textLabel?.text = title
        textLabel?.numberOfLines = 0
        toggle.isOn = isOn
        toggle.addTarget(self, action: #selector(changed), for: .valueChanged)
        accessoryView = toggle
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func changed() { onChange?(toggle.isOn) }
}

final class SliderCell: StackFormCell {
    let titleLabel = UILabel()
    let slider = UISlider()
    var titleForValue: ((Float) -> String)?
    var onChange: ((Float) -> Void)?

    init(minimum: Float, maximum: Float, value: Float) {
        super.init(style: .default, reuseIdentifier: nil)
        slider.minimumValue = minimum
        slider.maximumValue = maximum
        slider.value = value
        slider.addTarget(self, action: #selector(changed), for: .valueChanged)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(slider)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func refresh() { titleLabel.text = titleForValue?(slider.value) }

    @objc private func changed() {
        slider.value = slider.value.rounded()
        refresh()
        onChange?(slider.value)
    }
}

final class NoteCell: StackFormCell {
    init(text: String) {
        super.init(style: .default, reuseIdentifier: nil)
        stack.addArrangedSubview(FormStyle.footnoteLabel(text))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

final class TextFieldCell: UITableViewCell {
    let field = UITextField()

    init(placeholder: String) {
        super.init(style: .default, reuseIdentifier: nil)
        selectionStyle = .none
        field.placeholder = placeholder
        field.translatesAutoresizingMaskIntoConstraints = false
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.clearButtonMode = .whileEditing
        contentView.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            field.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            field.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// Width x height fields for the custom resolution.
final class SizeFieldsCell: UITableViewCell {
    let widthField = UITextField()
    let heightField = UITextField()

    init() {
        super.init(style: .default, reuseIdentifier: nil)
        selectionStyle = .none
        let times = UILabel()
        times.text = "×"
        for f in [widthField, heightField] {
            f.keyboardType = .numberPad
            f.borderStyle = .roundedRect
            f.textAlignment = .center
        }
        widthField.placeholder = "Width"
        heightField.placeholder = "Height"
        let row = UIStackView(arrangedSubviews: [widthField, times, heightField])
        row.axis = .horizontal
        row.spacing = 12
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            widthField.widthAnchor.constraint(equalTo: heightField.widthAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// Builds the rows shared by the connect screen and the settings sheet.
final class SettingsRows: NSObject {
    let touch: SegmentedCell
    let touchNote: NoteCell
    let display: SegmentedCell
    let sound: SwitchCell
    let resolution: SegmentedCell
    let sizeFields = SizeFieldsCell()
    let fps: SegmentedCell
    let cable: SliderCell
    let wifi: SliderCell
    let keyboardAuto: SwitchCell
    let controllers: SwitchCell

    private let fpsValues = [30, 60, 120]
    /// Called when the number of rows in the resolution section changes.
    var onResolutionLayoutChange: (() -> Void)?

    var customResolutionVisible: Bool { ResolutionSetting.mode == 2 }

    override init() {
        touch = SegmentedCell(title: nil, items: ["Touchpad", "Touchscreen"],
                              selected: LumenSettings.touchMode == .touchpad ? 0 : 1)
        touchNote = NoteCell(text: "Touchpad moves the cursor like a laptop trackpad. Touchscreen sends your touches to the computer where you tap (native multi-touch on Windows and Linux).")
        display = SegmentedCell(title: nil, items: ["Mirror", "Extend"], selected: LumenSettings.extend ? 1 : 0)
        sound = SwitchCell(title: "Sound", isOn: LumenSettings.audioOn)
        resolution = SegmentedCell(title: nil, items: ["Full screen", "16:9 (1080p)", "Custom"], selected: ResolutionSetting.mode)
        fps = SegmentedCell(title: "Frame rate", items: ["30", "60", "120"], selected: 1)
        cable = SliderCell(minimum: LumenSettings.minMbps, maximum: LumenSettings.cableMaxMbps, value: LumenSettings.cableMbps)
        wifi = SliderCell(minimum: LumenSettings.minMbps, maximum: LumenSettings.wifiMaxMbps, value: LumenSettings.wifiMbps)
        keyboardAuto = SwitchCell(title: "Show the on-screen keyboard when streaming starts", isOn: LumenSettings.keyboardAuto)
        controllers = SwitchCell(title: "Send controllers to the computer", isOn: LumenSettings.controllersOn)
        super.init()

        touch.onChange = { LumenSettings.touchMode = ($0 == 0) ? .touchpad : .touchscreen }
        display.setNote(LumenSettings.extend ? "Adds a new screen to the computer, sized for this device." : "Shows the computer's existing screen.")
        display.onChange = { [weak self] i in
            LumenSettings.extend = (i == 1)
            self?.display.setNote(i == 1 ? "Adds a new screen to the computer, sized for this device." : "Shows the computer's existing screen.")
        }
        sound.onChange = { LumenSettings.audioOn = $0 }
        resolution.setNote(ResolutionSetting.footnote)
        resolution.onChange = { [weak self] i in
            ResolutionSetting.mode = i
            self?.resolution.setNote(ResolutionSetting.footnote)
            self?.onResolutionLayoutChange?()
        }
        sizeFields.widthField.text = String(ResolutionSetting.customWidth)
        sizeFields.heightField.text = String(ResolutionSetting.customHeight)
        sizeFields.widthField.addTarget(self, action: #selector(sizeChanged), for: .editingChanged)
        sizeFields.heightField.addTarget(self, action: #selector(sizeChanged), for: .editingChanged)

        fps.control.selectedSegmentIndex = fpsValues.firstIndex(of: LumenSettings.fps) ?? 1
        fps.onChange = { [weak self] i in
            if let v = self?.fpsValues[i] { LumenSettings.fps = v }
        }
        cable.titleForValue = { "Cable bitrate: \(Int($0)) Mbps" }
        cable.onChange = { LumenSettings.cableMbps = $0 }
        cable.refresh()
        wifi.titleForValue = { "Wi-Fi bitrate: \(Int($0)) Mbps" }
        wifi.onChange = { LumenSettings.wifiMbps = $0 }
        wifi.refresh()
        keyboardAuto.onChange = { LumenSettings.keyboardAuto = $0 }
        controllers.onChange = { LumenSettings.controllersOn = $0 }
    }

    /// Re-reads every control from the stored settings (another screen may have changed them).
    func refreshFromSettings() {
        touch.control.selectedSegmentIndex = LumenSettings.touchMode == .touchpad ? 0 : 1
        display.control.selectedSegmentIndex = LumenSettings.extend ? 1 : 0
        sound.toggle.isOn = LumenSettings.audioOn
        resolution.control.selectedSegmentIndex = ResolutionSetting.mode
        resolution.setNote(ResolutionSetting.footnote)
        sizeFields.widthField.text = String(ResolutionSetting.customWidth)
        sizeFields.heightField.text = String(ResolutionSetting.customHeight)
        fps.control.selectedSegmentIndex = fpsValues.firstIndex(of: LumenSettings.fps) ?? 1
        cable.slider.value = LumenSettings.cableMbps; cable.refresh()
        wifi.slider.value = LumenSettings.wifiMbps; wifi.refresh()
        keyboardAuto.toggle.isOn = LumenSettings.keyboardAuto
        controllers.toggle.isOn = LumenSettings.controllersOn
    }

    @objc private func sizeChanged() {
        if let w = Int(sizeFields.widthField.text ?? "") { ResolutionSetting.customWidth = w }
        if let h = Int(sizeFields.heightField.text ?? "") { ResolutionSetting.customHeight = h }
    }

    /// Rows of the "Resolution" section.
    var resolutionRows: [UITableViewCell] {
        var rows: [UITableViewCell] = [resolution]
        if customResolutionVisible { rows.append(sizeFields) }
        return rows
    }
}
