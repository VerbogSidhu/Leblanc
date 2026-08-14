import AppKit
import WebKit

/// Read-only Discord, embedded via WKWebView (the real discord.com/app, in a
/// wrapper — same as opening it in a browser). ToS-compliant: no token
/// handling, no private API calls.
///
/// Read-only is enforced structurally: the DualSense has no text input, and
/// this feature never adds a keyboard. Compose controls are additionally
/// hidden via injected CSS/JS targeting stable aria/role attributes (not
/// webpack-hashed class names).
final class DiscordController: NSObject {
    static let windowSize = NSSize(width: 580, height: 760)

    private(set) var isFloating = false
    private var panel: NSPanel?
    private var webView: WKWebView?

    // MARK: - Show / hide

    func toggle() {
        isFloating ? hide() : show()
    }

    func show() {
        ensurePanel()
        guard let panel else { return }
        positionPanel(panel)
        panel.orderFrontRegardless()
        // Soft scale-up (the spec'd "appears from the press point" feel).
        panel.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            panel.animator().alphaValue = 1.0
        }
        isFloating = true
        Log.info("DiscordController: floating window shown")
    }

    func hide() {
        panel?.orderOut(nil)
        isFloating = false
        AppDelegate.shared?.restoreFrontend()
        Log.info("DiscordController: floating window hidden")
    }

    // MARK: - Scrolling (right stick)

    /// Scrolls the message pane. Called on right-stick Y changes while floating.
    /// `y` is in -1...1 (up positive), scaled to a per-event scroll step.
    func scrollByStick(y: Float) {
        guard isFloating, let webView else { return }
        let dy = -Double(y) * 42.0 // up stick → scroll toward older messages
        let js = """
        (function() {
          const scroller = document.querySelector('[data-list-id="chat-messages"]')
            || document.querySelector('main div[class*="scroller"]')
            || document.scrollingElement;
          if (scroller) { scroller.scrollBy(0, \(dy)); }
          else { window.scrollBy(0, \(dy)); }
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - Panel + WebView setup

    private func ensurePanel() {
        guard panel == nil else { return }

        let contentController = WKUserContentController()
        contentController.addUserScript(readOnlyScript)

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default() // persistent: login survives relaunch
        config.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.load(URLRequest(url: URL(string: "https://discord.com/app")!))
        self.webView = webView

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: DiscordController.windowSize),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Discord"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false // keep alive across hide/show
        panel.contentView = webView
        webView.frame = panel.contentLayoutRect
        panel.setContentSize(DiscordController.windowSize)
        self.panel = panel

        // Close button = hide (not destroy).
        panel.delegate = self
    }

    private func positionPanel(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = DiscordController.windowSize
        let x = visible.maxX - size.width - 28
        let y = visible.maxY - size.height - 28
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Read-only injection

    /// Hides compose/attachment/emoji/reaction controls using aria/role
    /// attributes (stable), not hashed class names. Re-applied on an interval
    /// + MutationObserver because Discord re-renders its SPA DOM.
    private var readOnlyScript: WKUserScript {
        let js = """
        (function() {
          function hideControls() {
            // Compose box: hide the textbox and its immediate container.
            document.querySelectorAll('[role="textbox"]').forEach(function(el) {
              el.style.display = 'none';
              var p = el.parentElement;
              for (var i = 0; i < 2 && p; i++) {
                p.style.display = 'none';
                p = p.parentElement;
              }
            });
            // Input affordances by aria-label.
            document.querySelectorAll('button[aria-label], div[aria-label]').forEach(function(el) {
              var a = (el.getAttribute('aria-label') || '').toLowerCase();
              if (a.includes('attach') || a.includes('emoji') || a.includes('gif')
                  || a.includes('sticker') || a.includes('gift') || a.includes('add reaction')
                  || a === 'react' || a === 'reply' || a === 'edit') {
                el.style.display = 'none';
              }
            });
          }
          hideControls();
          setInterval(hideControls, 1500);
          new MutationObserver(hideControls).observe(document.documentElement, { childList: true, subtree: true });
        })();
        """
        return WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
    }
}

extension DiscordController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        isFloating = false
        AppDelegate.shared?.restoreFrontend()
    }
}
