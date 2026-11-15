import SwiftUI

struct Book: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let author: String
    let color: Color
    let progress: Double
}

struct ContentView: View {
    @State private var books: [Book] = [
        Book(title: "红楼梦", author: "曹雪芹", color: .brown, progress: 0.32),
        Book(title: "三体", author: "刘慈欣", color: .indigo, progress: 0.68),
        Book(title: "活着", author: "余华", color: .orange, progress: 1.0),
        Book(title: "百年孤独", author: "加西亚·马尔克斯", color: .teal, progress: 0.12),
        Book(title: "围城", author: "钱锺书", color: .green, progress: 0.55),
        Book(title: "月亮与六便士", author: "毛姆", color: .purple, progress: 0.08)
    ]
    @State private var selectedBook: Book?
    @State private var showFeedback = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("我的书架")
                        .font(.largeTitle.bold())

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 18) {
                        ForEach(books) { book in
                            cover(book)
                                .onTapGesture { selectedBook = book }
                        }
                    }

                    HStack {
                        Spacer()
                        Button {
                            showFeedback = true
                        } label: {
                            Text("意见反馈")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.top, 20)
                }
                .padding()
            }
            .navigationBarHidden(true)
            .sheet(item: $selectedBook) { book in
                BookReaderView(book: book)
            }
            .sheet(isPresented: $showFeedback) {
                FeedbackView()
            }
        }
    }

    private func cover(_ book: Book) -> some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(LinearGradient(colors: [book.color, book.color.opacity(0.55)],
                                         startPoint: .top, endPoint: .bottom))
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                Text(book.title)
                    .font(.headline)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(6)
            }
            Text(book.title)
                .font(.caption)
                .lineLimit(1)
        }
    }
}
