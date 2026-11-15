import SwiftUI

struct BookReaderView: View {
    let book: Book

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(book.title)
                    .font(.title.bold())
                Text(book.author)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Divider()
                Text(sampleText)
                    .font(.body)
                    .lineSpacing(8)
            }
            .padding()
        }
        .navigationTitle("阅读")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var sampleText: String {
        """
        夜色渐深，窗外的风把树影吹得沙沙作响。他合上手里的书，靠在椅背上，脑海里还翻涌着方才读过的段落。

        故事里的人翻山越岭，只为寻找一个早已模糊的答案。而他自己，也像是在这样的夜里，沿着字里行间，慢慢地走回自己的来处。

        桌上的茶已经凉了，但他并不在意。有些夜晚，适合读书，适合沉默，也适合与自己的影子对坐。
        """
    }
}
