import Testing
@testable import SheepVTRender

@Suite struct RenderSmoke {
    @Test func targetLinks() {
        let t = Terminal(cols: 10, rows: 2)
        t.feed("ok")
        #expect(t.screenLines().first == "ok")
    }
}
