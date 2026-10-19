import Testing
import SheepVT

@Suite("Chinese output") struct ChineseOutputTests {
    @Test func fragmentedUTF8ProducesTheSameChineseTextAsAWholePacket() {
        let text = "设备：交换机\r\n接口状态：已连接\r\n繁體中文 𠮷"
        let whole = Terminal(cols: 40, rows: 6)
        whole.feed(text)
        let fragmented = Terminal(cols: 40, rows: 6)
        for byte in text.utf8 { fragmented.feed([byte]) }
        #expect(fragmented.screenLines() == whole.screenLines())
        #expect(whole.screenLines()[0] == "设备：交换机")
        #expect(whole.screenLines()[1] == "接口状态：已连接")
        #expect(whole.screenLines()[2] == "繁體中文 𠮷")
    }

    @Test func chineseCharactersAndFullWidthPunctuationOccupyTwoColumns() {
        let terminal = Terminal(cols: 20, rows: 3)
        terminal.feed("A中文，B")
        let row = terminal.buffer.row(0)
        #expect(row[0].code == 65)
        for col in [1, 3, 5] {
            #expect(row[col].width == 2)
            #expect(row[col + 1].isSpacer)
        }
        #expect(row[7].code == 66)
        #expect(terminal.screenLines()[0] == "A中文，B")
    }

    @Test func wrappingAndResizePreserveChineseText() {
        let terminal = Terminal(cols: 5, rows: 6)
        // Completed output reflows; the active cursor line belongs to the host.
        terminal.feed("A中文测试B\r\n")
        #expect(terminal.screenLines()[0] == "A中文")
        #expect(terminal.screenLines()[1] == "测试B")
        terminal.resize(cols: 20, rows: 6)
        #expect(terminal.screenLines()[0] == "A中文测试B")
    }
}
