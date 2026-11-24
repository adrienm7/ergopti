// static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/UpdatePromptPanel.swift
//
// Non-modal windows of the in-app update flow. A modal alert would block the
// launcher's main queue, which supervises the embedded Hammerspoon process
// (a Sparkle modal once stalled that supervision in CI). One panel at
// a time: a prompt with its buttons, or a progress bar. Closing a prompt with
// its close button reports "no choice", and a progress window reports its
// onClose; closing either programmatically reports nothing.

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
	/// Space between the window's edges and its content, on every side.
	static let contentMargin: CGFloat = 20

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

	func showProgress(_ text: UpdateProgressText, fraction: Double?,
					  onCancel: (() -> Void)?, onClose: (() -> Void)?) {
		if let indicator = progressIndicator, let message = progressMessage, let panel {
			panel.title = WindowTitles.compose(text.title)
			let changed = message.stringValue != text.message
			message.stringValue = text.message
			indicator.setAccessibilityLabel(text.message)
			apply(fraction: fraction, to: indicator)
			// A screen reader does not read a label that changes under it:
			// the new step (checking, downloading, installing) is announced.
			if changed {
				NSAccessibility.post(element: message, notification: .announcementRequested, userInfo: [
					.announcement: text.message,
					.priority: NSAccessibilityPriorityLevel.medium.rawValue,
				])
			}
			onUserClose = onClose
			return
		}
		closeAll()

		let message = NSTextField(labelWithString: text.message)
		let indicator = NSProgressIndicator()
		indicator.style = .bar
		indicator.minValue = 0
		indicator.maxValue = 1
		indicator.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
		// VoiceOver reads a bare bar as « progress indicator, 50 % » with no
		// word on what progresses: the step's message names it.
		indicator.setAccessibilityLabel(text.message)
		apply(fraction: fraction, to: indicator)

		var rows: [NSView] = [message, indicator]
		if let cancelTitle = text.cancelTitle, let onCancel {
			let action = UpdatePromptAction { [weak self] in
				self?.closeAll()
				onCancel()
			}
			actions.append(action)
			rows.append(NSButton(title: cancelTitle, target: action, action: #selector(UpdatePromptAction.fire(_:))))
		}
		// The close box is not Cancel: a download goes on when its window is
		// closed (UPD-05); the caller says what closing means.
		onUserClose = onClose
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
		stack.translatesAutoresizingMaskIntoConstraints = false

		// The stack is pinned inside a plain content view on all four sides.
		// As the window's own content view it took the window's autoresizing
		// frame, so a row wider than the frame computed before layout (the
		// progress bar, a long localized button row) ran into the right edge
		// with no margin.
		let content = NSView()
		content.addSubview(stack)
		NSLayoutConstraint.activate([
			stack.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.contentMargin),
			stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.contentMargin),
			content.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: Self.contentMargin),
			content.bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: Self.contentMargin),
		])

		// Measured before the view enters the window: a content view takes
		// fixed autoresizing constraints from the window's frame, which would
		// win over the rows' own widths.
		let size = content.fittingSize
		let panel = NSPanel(
			contentRect: NSRect(origin: .zero, size: size),
			styleMask: [.titled, .closable],
			backing: .buffered,
			defer: false)
		panel.title = WindowTitles.compose(title)
		panel.isReleasedWhenClosed = false
		panel.hidesOnDeactivate = false
		// Normal level: the prompt is ordered front (and focused when the user
		// asked for it), never kept above the windows the user opens next.
		panel.contentView = content
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
