import XCTest

/// 通过测试模式窗口驱动正式界面。菜单栏 MenuBarExtra 在 CI 里点不开，面板视图改由普通窗口承载。
final class MenuSSHUITests: XCTestCase {
    private let production = "11111111-1111-1111-1111-111111111111"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testMainPathEnglishLight() throws {
        let ctx = try launch(language: "en", appearance: "light")
        let app = ctx.app
        XCTAssertTrue(app.staticTexts["Recent"].waitForExistence(timeout: 15))
        let panel = marked(app, id.panel)
        replace(marked(panel, id.panelSearch), "leaf")
        XCTAssertTrue(marked(panel, "host.Leaf").waitForExistence(timeout: 5))
        XCTAssertFalse(marked(panel, "host.API").exists)
        replace(marked(panel, id.panelSearch), "")

        marked(app, id.panelManage).click()
        let hosts = marked(app, id.hosts)
        XCTAssertTrue(hosts.waitForExistence(timeout: 10))
        marked(hosts, "group.Production").click()
        XCTAssertTrue(marked(hosts, "host.API").waitForExistence(timeout: 5))
        XCTAssertTrue(marked(hosts, "host.Leaf").exists)
        XCTAssertFalse(marked(hosts, "host.Bastion").exists)
        marked(hosts, "group.Edge").click()
        XCTAssertTrue(marked(hosts, "host.Leaf").waitForExistence(timeout: 5))
        XCTAssertFalse(marked(hosts, "host.API").exists)

        click(marked(app, id.hostsNewGroup), app: app)
        let dialog = alert(app)
        XCTAssertTrue(dialog.waitForExistence(timeout: 5))
        let nameField = dialog.descendants(matching: .textField)[id.groupName]
        if nameField.waitForExistence(timeout: 2) {
            replace(nameField, "Ops")
        } else if dialog.textFields.firstMatch.waitForExistence(timeout: 2) {
            replace(dialog.textFields.firstMatch, "Ops")
        } else {
            replace(app.textFields[id.groupName], "Ops")
        }
        if dialog.buttons[id.groupCreate].exists {
            dialog.buttons[id.groupCreate].click()
        } else if dialog.buttons["Create"].exists {
            dialog.buttons["Create"].click()
        } else {
            app.buttons["Create"].click()
        }
        let ops = marked(hosts, "group.Ops")
        XCTAssertTrue(ops.waitForExistence(timeout: 5))
        ops.rightClick()
        chooseSubmenu(app, identifier: "group.nest.Production", parent: "Nest Under", child: "Production")
        let savedGroups = try groups(in: ctx.dataDir)
        XCTAssertEqual(savedGroups["Ops"]?.lowercased(), production)

        marked(app, id.hostsNew).click()
        replace(marked(app, id.editorLabel), "CI Web")
        replace(marked(app, id.editorHost), "127.0.0.1")
        replace(marked(app, id.editorPort), "22")
        replace(marked(app, id.editorUser), "ci")
        click(marked(app, id.editorUseJump), app: app)
        chooseMenu(app, identifier: "jump.pick.Bastion", titles: ["Bastion"])
        replace(marked(app, id.editorStartup), "echo ci-started")
        ensureOn(marked(app, id.editorForwardAgent), app: app)
        click(marked(app, id.editorAddForward), app: app)
        replace(marked(app, id.forwardListen), "9090")
        replace(marked(app, id.forwardDestinationHost), "127.0.0.1")
        replace(marked(app, id.forwardDestinationPort), "80")
        shot(marked(app, id.forwardListen), "forward-en-light", screen: "forward", appearance: "light", language: "en")
        marked(app, id.forwardSave).click()
        shot(marked(app, id.editorHost), "editor-filled-en-light", screen: "editor", appearance: "light", language: "en")
        marked(app, id.editorSave).click()
        XCTAssertTrue(marked(hosts, "host.CI Web").waitForExistence(timeout: 8))

        let host = try hostObject(named: "CI Web", in: ctx.dataDir)
        XCTAssertEqual(host["jumpHost"] as? String, "jump@bastion.example")
        XCTAssertEqual(host["startupCommand"] as? String, "echo ci-started")
        XCTAssertEqual(host["forwardAgent"] as? Bool, true)
        let forwards = host["portForwards"] as? [[String: Any]] ?? []
        XCTAssertEqual(forwards.first?["listenPort"] as? Int, 9090)

        marked(panel, "host.CI Web").click()
        let log = try waitForLog(ctx.logURL)
        let argv = log["argv"] as? [String] ?? []
        XCTAssertTrue(argv.contains("ForwardAgent=yes"), argv.joined(separator: " "))
        XCTAssertTrue(argv.contains("-J"), argv.joined(separator: " "))
        XCTAssertTrue(argv.contains { $0.contains("9090:127.0.0.1:80") }, argv.joined(separator: " "))
        XCTAssertEqual(log["startup"] as? String, "echo ci-started")

        openSettings(app)
        for pane in ["general", "terminal", "hosts", "about"] {
            marked(app, "settings.pane.\(pane)").click()
            shot(marked(app, id.settings), "settings-\(pane)-en-light", screen: pane, appearance: "light", language: "en")
        }
        app.terminate()
    }

    func testScreenshotMatrix() throws {
        let cases = [("en", "light", "Recent"), ("en", "dark", "Recent"), ("zh-Hans", "light", "最近"), ("zh-Hans", "dark", "最近")]
        for (language, appearance, recent) in cases {
            let ctx = try launch(language: language, appearance: appearance)
            let app = ctx.app
            let tag = "\(language == "zh-Hans" ? "zh" : "en")-\(appearance)"
            XCTAssertTrue(app.staticTexts[recent].waitForExistence(timeout: 15), recent)
            shot(marked(app, id.panel), "panel-\(tag)", screen: "panel", appearance: appearance, language: language)
            marked(app, id.panelManage).click()
            let hosts = marked(app, id.hosts)
            XCTAssertTrue(hosts.waitForExistence(timeout: 10))
            shot(hosts, "hosts-\(tag)", screen: "hosts", appearance: appearance, language: language)
            let api = marked(hosts, "host.API")
            api.click()
            api.rightClick()
            chooseMenu(app, identifier: id.hostEdit, titles: ["Edit…", "编辑…"])
            XCTAssertTrue(marked(app, id.editorHost).waitForExistence(timeout: 8))
            shot(marked(app, id.editorHost), "editor-\(tag)", screen: "editor", appearance: appearance, language: language)
            marked(app, id.editorCancel).click()
            openSettings(app)
            for pane in ["general", "terminal", "hosts", "about"] {
                marked(app, "settings.pane.\(pane)").click()
                shot(
                    marked(app, id.settings), "settings-\(pane)-\(tag)", screen: pane, appearance: appearance, language: language)
            }
            app.terminate()
        }
    }

    // MARK: - Launch

    private struct Context {
        var app: XCUIApplication
        var dataDir: URL
        var logURL: URL
    }

    private func launch(language: String, appearance: String) throws -> Context {
        let dataDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("menush-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        try fixtureJSON().write(to: dataDir.appendingPathComponent("hosts.json"), atomically: true, encoding: .utf8)
        let logURL = dataDir.appendingPathComponent("terminal.log")
        let app = XCUIApplication()
        app.launchEnvironment = [
            "MENUSH_UI_TEST": "1",
            "MENUSH_DATA_DIR": dataDir.path,
            "MENUSH_FAKE_TERMINAL_LOG": logURL.path,
            "MENUSH_APPEARANCE": appearance,
        ]
        app.launchArguments = ["--ui-test", "-ApplePersistenceIgnoreState", "YES"]
        if language == "zh-Hans" {
            app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_Hans"]
        } else {
            app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        }
        if appearance == "dark" {
            app.launchArguments += ["-AppleInterfaceStyle", "Dark"]
        }
        app.launch()
        XCTAssertTrue(marked(app, id.panel).waitForExistence(timeout: 20))
        return Context(app: app, dataDir: dataDir, logURL: logURL)
    }

    private func openSettings(_ app: XCUIApplication) {
        marked(app, id.hostsSettings).click()
        XCTAssertTrue(marked(app, id.settings).waitForExistence(timeout: 10))
    }

    private func marked(_ root: XCUIElement, _ identifier: String) -> XCUIElement {
        root.descendants(matching: .any)[identifier]
    }

    /// macOS 的 SwiftUI alert 有时是 sheet，有时是 dialog。
    private func alert(_ app: XCUIApplication) -> XCUIElement {
        let sheet = app.sheets.firstMatch
        if sheet.waitForExistence(timeout: 2) { return sheet }
        return app.dialogs.firstMatch
    }

    private func click(_ element: XCUIElement, app: XCUIApplication) {
        reveal(element, app: app)
        element.click()
    }

    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 8))
        var tries = 0
        while !element.isHittable && tries < 8 {
            let sheet = app.sheets.firstMatch
            if sheet.exists {
                sheet.swipeUp()
            } else {
                app.swipeUp()
            }
            tries += 1
        }
    }

    private func ensureOn(_ toggle: XCUIElement, app: XCUIApplication) {
        reveal(toggle, app: app)
        if !isOn(toggle) { toggle.click() }
    }

    private func isOn(_ toggle: XCUIElement) -> Bool {
        let raw = toggle.value
        if let number = raw as? NSNumber { return number.intValue == 1 }
        if let text = raw as? String { return text == "1" || text == "true" }
        return false
    }

    /// 上下文菜单的 identifier 经常到不了 NSMenuItem，所以同时接受标题。
    private func chooseMenu(_ app: XCUIApplication, identifier: String, titles: [String]) {
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            let identified = app.menuItems[identifier]
            if identified.exists {
                identified.click()
                return
            }
            if let title = titles.first(where: { app.menuItems[$0].exists }) {
                app.menuItems[title].click()
                return
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTFail("menu item not found: \(identifier) \(titles.joined(separator: ", "))")
    }

    private func chooseSubmenu(_ app: XCUIApplication, identifier: String, parent: String, child: String) {
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            let identified = app.menuItems[identifier]
            if identified.exists {
                identified.click()
                return
            }
            let parentItem = app.menuItems[parent]
            if parentItem.exists {
                parentItem.hover()
                let childItem = app.menuItems[child]
                if childItem.waitForExistence(timeout: 2) {
                    childItem.click()
                    return
                }
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTFail("menu item not found: \(identifier) \(parent) / \(child)")
    }

    private func replace(_ field: XCUIElement, _ text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        if text.isEmpty {
            field.typeKey(XCUIKeyboardKey.delete, modifierFlags: [])
        } else {
            field.typeText(text)
        }
    }

    private func shot(_ element: XCUIElement, _ name: String, screen: String, appearance: String, language: String) {
        _ = element.exists
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let dir = screenshotDirectory() else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(name).png")
        try? screenshot.pngRepresentation.write(to: file)
        let index = dir.appendingPathComponent("index.md")
        if !FileManager.default.fileExists(atPath: index.path) {
            let header = "# UI screenshots\n\n| File | Screen | Appearance | Language |\n| --- | --- | --- | --- |\n"
            try? header.write(to: index, atomically: true, encoding: .utf8)
        }
        if let handle = try? FileHandle(forWritingTo: index) {
            handle.seekToEndOfFile()
            handle.write(Data("| \(name).png | \(screen) | \(appearance) | \(language) |\n".utf8))
            try? handle.close()
        }
    }

    private func screenshotDirectory() -> URL? {
        guard let path = ProcessInfo.processInfo.environment["MENUSH_SCREENSHOT_DIR"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func groups(in dataDir: URL) throws -> [String: String] {
        let root = try json(at: dataDir.appendingPathComponent("hosts.json"))
        let groups = root["groups"] as? [[String: Any]] ?? []
        var result: [String: String] = [:]
        for group in groups {
            if let name = group["name"] as? String {
                result[name] = group["parentID"] as? String
            }
        }
        return result
    }

    private func hostObject(named label: String, in dataDir: URL) throws -> [String: Any] {
        let root = try json(at: dataDir.appendingPathComponent("hosts.json"))
        let hosts = root["hosts"] as? [[String: Any]] ?? []
        return try XCTUnwrap(hosts.first { ($0["label"] as? String) == label })
    }

    private func json(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func waitForLog(_ url: URL) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if let text = try? String(contentsOf: url, encoding: .utf8), let line = text.split(separator: "\n").last {
                let data = Data(line.utf8)
                if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    return object
                }
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTFail("fake terminal log was not written")
        return [:]
    }

    private func fixtureJSON() -> String {
        """
        {
          "schemaVersion": 2,
          "groups": [
            {"id": "\(production)", "name": "Production", "sortOrder": 0,
             "updatedAt": "2026-01-01T00:00:00Z"},
            {"id": "22222222-2222-2222-2222-222222222222", "name": "Edge",
             "parentID": "\(production)", "sortOrder": 0, "updatedAt": "2026-01-01T00:00:00Z"}
          ],
          "hosts": [
            {"id": "33333333-3333-3333-3333-333333333333", "label": "API",
             "hostname": "api.example", "username": "deploy", "groupID": "\(production)",
             "authMethod": "automatic", "isFavorite": true, "lastConnectedAt": "2026-01-02T00:00:00Z"},
            {"id": "44444444-4444-4444-4444-444444444444", "label": "Leaf",
             "hostname": "leaf.example", "username": "deploy",
             "groupID": "22222222-2222-2222-2222-222222222222", "authMethod": "automatic"},
            {"id": "55555555-5555-5555-5555-555555555555", "label": "Bastion",
             "hostname": "bastion.example", "username": "jump", "authMethod": "automatic"}
          ],
          "tombstones": []
        }
        """
    }
}

private enum id {
    static let panel = "screen.panel"
    static let hosts = "screen.hosts"
    static let settings = "screen.settings"
    static let panelSearch = "panel.search"
    static let panelManage = "panel.manageHosts"
    static let hostsNew = "hosts.new"
    static let hostsSettings = "hosts.settings"
    static let hostsNewGroup = "hosts.newGroup"
    static let groupName = "group.name"
    static let groupCreate = "group.create"
    static let hostEdit = "host.edit"
    static let editorLabel = "editor.label"
    static let editorHost = "editor.host"
    static let editorPort = "editor.port"
    static let editorUser = "editor.user"
    static let editorStartup = "editor.startup"
    static let editorForwardAgent = "editor.forwardAgent"
    static let editorUseJump = "editor.useJump"
    static let editorAddForward = "editor.addForward"
    static let editorSave = "editor.save"
    static let editorCancel = "editor.cancel"
    static let forwardListen = "forward.listen"
    static let forwardDestinationHost = "forward.destinationHost"
    static let forwardDestinationPort = "forward.destinationPort"
    static let forwardSave = "forward.save"
}
