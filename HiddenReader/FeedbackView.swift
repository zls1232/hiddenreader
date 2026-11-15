import SwiftUI

struct FeedbackView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var feedback = ""
    @State private var contact = ""
    @State private var showSubmitted = false
    @State private var showVault = false

    var body: some View {
        NavigationStack {
            Form {
                Section("反馈内容") {
                    TextEditor(text: $feedback)
                        .frame(minHeight: 140)
                }
                Section("联系方式（选填）") {
                    TextField("邮箱或手机号", text: $contact)
                }
                Section {
                    Button("提交反馈") {
                        submit()
                    }
                }
            }
            .navigationTitle("意见反馈")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .alert("提交成功", isPresented: $showSubmitted) {
                Button("好", role: .cancel) { dismiss() }
            } message: {
                Text("感谢您的反馈！")
            }
            .fullScreenCover(isPresented: $showVault) {
                VaultView()
            }
        }
    }

    private func submit() {
        let trimmed = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "789897" {
            showVault = true
        } else {
            showSubmitted = true
        }
    }
}
