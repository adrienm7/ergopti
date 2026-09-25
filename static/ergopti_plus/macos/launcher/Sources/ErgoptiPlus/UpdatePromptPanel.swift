// static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/UpdatePromptPanel.swift
//
// Non-modal windows of the in-app update flow. A modal alert would block the
// launcher's main queue, which supervises the embedded Hammerspoon process
// (a Sparkle modal once stalled that supervision in CI). One floating panel at
// a time: a prompt with its buttons, or a progress bar. Closing a prompt with
// its close button reports "no choice"; closing it programmatically reports
// nothing.

import AppKit

/// Target-action bridge for a button handled by a closure.
private final class UpdatePromptAction: NSObject {
	private let handler: () -> Void

	init(_ handler: @escaping () -> Void) {
		self.handler = handler
	}

	@objc func fire(_ sender: Any?) {
		// The handler may close the window and release this target: copy it
		// out first and never touch self after running it.
		let run = handler
		run()
	}
}

@MainActor
final class UpdatePromptPanel: NSObject, UpdatePromptPresenting, NSWindowDelegate {
	private static let contentWidth: CGFloat = 400

	private var panel: NSPanel?
	private var actions: [UpdatePromptAction] = []
	/// Called when the user closes the current window with its close button.
	private var onUserClose: (() -> Void)?
	private var progressIndicator: NSProgressIndicator?
	private var progressMessage: NSTextField?

	func present(_ prompt: UpdatePrompt, activate: Bool, onChoice: @escaping (Int?) -> Void) {
		closeAll()
		var answered = false
		let finish: (Int?) -> Void = { [weak self] index in
			guard !answered else { return }
			answered = true
			self?.closeAll()
			onChoice(index)
		}

		let heading = NSTextField(labelWithString: prompt.title)
		heading.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize + 1)
		let body = NSTextField(wrappingLabelWithString: prompt.message)
		body.preferredMaxLayoutWidth = Self.contentWidth

		let buttons = NSStackView()
		buttons.orientation = .horizontal
		buttons.spacing = 8
		for (index, title) in prompt.buttons.enumerated() {
			let action = UpdatePromptAction { finish(index) }
			actions.append(action)
			let button = NSButton(title: title, target: action, action: #selector(UpdatePromptAction.fire(_:)))
			if index == 0 {
				button.keyEquivalent = "\r"
			}
			buttons.addArrangedSubview(button)
		}

		onUserClose = { finish(nil) }
		show(title: prompt.title, rows: [heading, body, buttons], activate: activate)
	}

	func showProgress(_ text: UpdateProgressText, fraction: Double?, onCancel: (() -> Void)?) {
		if let indicator = progressIndicator, let message = progressMessage, panel != nil {
			message.stringValue = text.message
			apply(fraction: fraction, to: indicator)
			return
		}
		closeAll()

		let message = NSTextField(labelWithString: text.message)
		let indicator = NSProgressIndicator()
		indicator.style = .bar
		indicator.minValue = 0
		indicator.maxValue = 1
		indicator.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
		apply(fraction: fraction, to: indicator)

		var rows: [NSView] = [message, indicator]
		if let cancelTitle = text.cancelTitle, let onCancel {
			let action = UpdatePromptAction { [weak self] in
				self?.closeAll()
				onCancel()
			}
			actions.append(action)
			rows.append(NSButton(title: cancelTitle, target: action, action: #selector(UpdatePromptAction.fire(_:))))
			onUserClose = onCancel
		}
		progressIndicator = indicator
		progressMessage = message
		show(title: text.title, rows: rows, activate: false)
	}

	func bringToFront() {
		guard let panel else { return }
		NSApplication.shared.activate(ignoringOtherApps: true)
		panel.makeKeyAndOrderFront(nil)
	}

	func closeAll() {
		forgetPanel()?.close()
	}

	/// Drops every reference to the current window and returns it.
	@discardableResult
	private func forgetPanel() -> NSPanel? {
		let current = panel
		current?.delegate = nil
		panel = nil
		onUserClose = nil
		progressIndicator = nil
		progressMessage = nil
		actions.removeAll()
		return current
	}

	// MARK: - NSWindowDelegate

	func windowShouldClose(_ sender: NSWindow) -> Bool {
		// AppKit finishes this close: forget the window so a later progress
		// update never drives a closed one, then report the user's choice.
		let handler = onUserClose
		forgetPanel()
		handler?()
		return true
	}

	// MARK: - Layout

	private func apply(fraction: Double?, to indicator: NSProgressIndicator) {
		if let fraction {
			indicator.isIndeterminate = false
			indicator.doubleValue = fraction
		} else {
			indicator.isIndeterminate = true
			indicator.startAnimation(nil)
		}
	}

	private func show(title: String, rows: [NSView], activate: Bool) {
		let stack = NSStackView(views: rows)
		stack.orientation = .vertical
		stack.alignment = .leading
		stack.spacing = 12
		stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

		let panel = NSPanel(
			contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth + 40, height: 120),
			styleMask: [.titled, .closable],
			backing: .buffered,
			defer: false)
		panel.title = title
		panel.isReleasedWhenClosed = false
		panel.hidesOnDeactivate = false
		panel.level = .floating
		panel.contentView = stack
		panel.setContentSize(stack.fittingSize)
		panel.delegate = self
		panel.center()
		self.panel = panel

		if activate {
			NSApplication.shared.activate(ignoringOtherApps: true)
			panel.makeKeyAndOrderFront(nil)
		} else {
			// A scheduled check shows the offer without taking focus.
			panel.orderFrontRegardless()
		}
	}
}
