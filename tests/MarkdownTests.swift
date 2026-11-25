import Foundation
@main struct MarkdownTests {
    static func main() {
        let markdown = "# 标题\n\n**重点**和[链接](https://example.com)\n\n- 项目\n  1. 子项\n- [x] 已完成\n\n> 引用\n\n```swift\nlet x = 1\n```\n\n| 名称 | 值 |\n| :--- | ---: |\n| A\\|B | `x|y` |\n\n---"
        let expected: [MarkdownBlock] = [.heading(1,"标题"), .paragraph("**重点**和[链接](https://example.com)"),
            .item("•","项目",0), .item("1.","子项",1), .item("☑","已完成",0), .quote("引用"),
            .code("swift","let x = 1"), .table([["名称","值"],["A|B","`x|y`"]]), .rule]
        precondition(MarkdownDocument(markdown).blocks == expected)
        precondition(MarkdownDocument("```\n# unfinished").blocks == [.code("", "# unfinished")])
        precondition(MarkdownDocument("<script>alert(1)</script>").blocks == [.paragraph("<script>alert(1)</script>")])
        precondition(MarkdownDocument("a | b\njust text").blocks == [.paragraph("a | b\njust text")])
        precondition(MarkdownDocument("####### plain").blocks == [.paragraph("####### plain")])
        print("PASS: Markdown headings, lists, checkboxes, quotes, fenced code, escaped table pipes and incomplete streaming blocks")
    }
}
