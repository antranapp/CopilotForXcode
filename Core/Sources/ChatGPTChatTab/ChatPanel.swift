import AppKit
import Combine
import ComposableArchitecture
import MarkdownUI
import OpenAIService
import SharedUIComponents
import SwiftUI

private let r: Double = 8

public struct ChatPanel: View {
    let chat: StoreOf<Chat>
    @Namespace var inputAreaNamespace

    public var body: some View {
        VStack(spacing: 0) {
            ChatPanelMessages(chat: chat)
            Divider()
            ChatPanelInputArea(chat: chat)
        }
        .background(.regularMaterial)
        .onAppear { chat.send(.appear) }
    }
}

private struct ScrollViewOffsetPreferenceKey: PreferenceKey {
    static var defaultValue = CGFloat.zero

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value += nextValue()
    }
}

private struct ListHeightPreferenceKey: PreferenceKey {
    static var defaultValue = CGFloat.zero

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value += nextValue()
    }
}

struct ChatPanelMessages: View {
    let chat: StoreOf<Chat>
    @State var cancellable = Set<AnyCancellable>()
    @State var isScrollToBottomButtonDisplayed = true
    @State var isPinnedToBottom = true
    @Namespace var bottomID
    @Namespace var scrollSpace
    @State var scrollOffset: Double = 0
    @State var listHeight: Double = 0
    @Environment(\.isEnabled) var isEnabled

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { listGeo in
                List {
                    Group {
                        Spacer(minLength: 12)

                        Instruction(chat: chat)

                        ChatHistory(chat: chat)
                            .listItemTint(.clear)

                        WithViewStore(chat, observe: \.isReceivingMessage) { viewStore in
                            if viewStore.state {
                                Spacer(minLength: 12)
                            }
                        }

                        Spacer(minLength: 12)
                            .id(bottomID)
                            .onAppear {
                                proxy.scrollTo(bottomID, anchor: .bottom)
                            }
                            .task {
                                proxy.scrollTo(bottomID, anchor: .bottom)
                            }
                            .background(GeometryReader { geo in
                                let offset = geo.frame(in: .named(scrollSpace)).minY
                                Color.clear.preference(
                                    key: ScrollViewOffsetPreferenceKey.self,
                                    value: offset
                                )
                            })
                    }
                    .modify { view in
                        if #available(macOS 13.0, *) {
                            view.listRowSeparator(.hidden).listSectionSeparator(.hidden)
                        } else {
                            view
                        }
                    }
                }
                .listStyle(.plain)
                .coordinateSpace(name: scrollSpace)
                .preference(
                    key: ListHeightPreferenceKey.self,
                    value: listGeo.size.height
                )
                .onPreferenceChange(ListHeightPreferenceKey.self) { value in
                    listHeight = value
                    updatePinningState()
                }
                .onPreferenceChange(ScrollViewOffsetPreferenceKey.self) { value in
                    scrollOffset = value
                    updatePinningState()
                }
                .overlay(alignment: .bottom) {
                    WithViewStore(chat, observe: \.isReceivingMessage) { viewStore in
                        StopRespondingButton(chat: chat)
                            .padding(.bottom, 8)
                            .opacity(viewStore.state ? 1 : 0)
                            .disabled(!viewStore.state)
                            .transformEffect(.init(translationX: 0, y: viewStore.state ? 0 : 20))
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    scrollToBottomButton(proxy: proxy)
                }
                .background {
                    PinToBottomHandler(chat: chat, pinnedToBottom: $isPinnedToBottom) {
                        proxy.scrollTo(bottomID, anchor: .bottom)
                    }
                }
            }
        }
        .onAppear {
            trackScrollWheel()
        }
        .onDisappear {
            cancellable.forEach { $0.cancel() }
            cancellable = []
        }
    }

    func trackScrollWheel() {
        NSApplication.shared.publisher(for: \.currentEvent)
            .filter {
                if !isEnabled { return false }
                return $0?.type == .scrollWheel
            }
            .compactMap { $0 }
            .sink { event in
                guard isPinnedToBottom else { return }
                let delta = event.deltaY
                let scrollUp = delta > 0
                if scrollUp {
                    isPinnedToBottom = false
                }
            }
            .store(in: &cancellable)
    }

    @MainActor
    func updatePinningState() {
        // where does the 32 come from?
        withAnimation(.linear(duration: 0.1)) {
            isScrollToBottomButtonDisplayed = scrollOffset > listHeight + 32 + 20
                || scrollOffset <= 0
        }
    }

    @ViewBuilder
    func scrollToBottomButton(proxy: ScrollViewProxy) -> some View {
        Button(action: {
            isPinnedToBottom = true
            withAnimation(.easeInOut(duration: 0.1)) {
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
        }) {
            Image(systemName: "arrow.down")
                .padding(4)
                .background {
                    Circle()
                        .fill(.thickMaterial)
                        .shadow(color: .black.opacity(0.2), radius: 2)
                }
                .overlay {
                    Circle().stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                }
                .foregroundStyle(.secondary)
                .padding(4)
        }
        .keyboardShortcut(.downArrow, modifiers: [.command])
        .opacity(isScrollToBottomButtonDisplayed ? 1 : 0)
        .buttonStyle(.plain)
    }

    struct PinToBottomHandler: View {
        let chat: StoreOf<Chat>
        @Binding var pinnedToBottom: Bool
        let scrollToBottom: () -> Void

        @State var isInitialLoad = true

        struct PinToBottomRelatedState: Equatable {
            var isReceivingMessage: Bool
            var lastMessage: DisplayedChatMessage?
        }

        var body: some View {
            WithViewStore(chat, observe: {
                PinToBottomRelatedState(
                    isReceivingMessage: $0.isReceivingMessage,
                    lastMessage: $0.history.last
                )
            }) { viewStore in
                EmptyView()
                    .onChange(of: viewStore.state.isReceivingMessage) { isReceiving in
                        if isReceiving {
                            pinnedToBottom = true
                            scrollToBottom()
                        }
                    }
                    .onChange(of: viewStore.state.lastMessage) { _ in
                        if pinnedToBottom || isInitialLoad {
                            if isInitialLoad {
                                isInitialLoad = false
                            }
                            scrollToBottom()
                        }
                    }
            }
        }
    }
}

struct ChatHistory: View {
    let chat: StoreOf<Chat>

    var body: some View {
        WithViewStore(chat, observe: \.history) { viewStore in
            ForEach(viewStore.state, id: \.id) { message in
                let text = message.text

                switch message.role {
                case .user:
                    UserMessage(id: message.id, text: text, chat: chat)
                        .listRowInsets(EdgeInsets(
                            top: 0,
                            leading: -8,
                            bottom: 0,
                            trailing: -8
                        ))
                        .padding(.vertical, 4)
                case .assistant:
                    BotMessage(
                        id: message.id,
                        text: text,
                        references: message.references,
                        chat: chat
                    )
                    .listRowInsets(EdgeInsets(
                        top: 0,
                        leading: -8,
                        bottom: 0,
                        trailing: -8
                    ))
                    .padding(.vertical, 4)
                case .tool:
                    FunctionMessage(id: message.id, text: text)
                case .ignored:
                    EmptyView()
                }
            }
        }
    }
}

private struct StopRespondingButton: View {
    let chat: StoreOf<Chat>

    var body: some View {
        Button(action: {
            chat.send(.stopRespondingButtonTapped)
        }) {
            HStack(spacing: 4) {
                Image(systemName: "stop.fill")
                Text("Stop Responding")
            }
            .padding(8)
            .background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: r, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: r, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            }
        }
        .buttonStyle(.borderless)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

struct ChatPanelInputArea: View {
    let chat: StoreOf<Chat>
    @FocusState var focusedField: Chat.State.Field?

    var body: some View {
        HStack {
            clearButton
            textEditor
        }
        .padding(8)
        .background(.ultraThickMaterial)
    }

    @MainActor
    var clearButton: some View {
        Button(action: {
            chat.send(.clearButtonTap)
        }) {
            Group {
                if #available(macOS 13.0, *) {
                    Image(systemName: "eraser.line.dashed.fill")
                } else {
                    Image(systemName: "trash.fill")
                }
            }
            .padding(6)
            .background {
                Circle().fill(Color(nsColor: .controlBackgroundColor))
            }
            .overlay {
                Circle().stroke(Color(nsColor: .controlColor), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    @MainActor
    var textEditor: some View {
        HStack(spacing: 0) {
            WithViewStore(
                chat,
                removeDuplicates: {
                    $0.typedMessage == $1.typedMessage && $0.focusedField == $1.focusedField
                }
            ) { viewStore in
                AutoresizingCustomTextEditor(
                    text: viewStore.$typedMessage,
                    font: .systemFont(ofSize: 14),
                    isEditable: true,
                    maxHeight: 400,
                    onSubmit: { viewStore.send(.sendButtonTapped) },
                    completions: chatAutoCompletion
                )
                .focused($focusedField, equals: .textField)
                .bind(viewStore.$focusedField, to: $focusedField)
                .padding(8)
                .fixedSize(horizontal: false, vertical: true)
            }

            WithViewStore(chat, observe: \.isReceivingMessage) { viewStore in
                Button(action: {
                    viewStore.send(.sendButtonTapped)
                }) {
                    Image(systemName: "paperplane.fill")
                        .padding(8)
                }
                .buttonStyle(.plain)
                .disabled(viewStore.state)
                .keyboardShortcut(KeyEquivalent.return, modifiers: [])
            }
        }
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .controlColor), lineWidth: 1)
        }
        .background {
            Button(action: {
                chat.send(.returnButtonTapped)
            }) {
                EmptyView()
            }
            .keyboardShortcut(KeyEquivalent.return, modifiers: [.shift])

            Button(action: {
                focusedField = .textField
            }) {
                EmptyView()
            }
            .keyboardShortcut("l", modifiers: [.command])
        }
    }

    func chatAutoCompletion(text: String, proposed: [String], range: NSRange) -> [String] {
        guard text.count == 1 else { return [] }
        let plugins = [String]() // chat.pluginIdentifiers.map { "/\($0)" }
        let availableFeatures = plugins + [
            "/exit",
            "@code",
            "@sense",
            "@project",
            "@web",
        ]

        let result: [String] = availableFeatures
            .filter { $0.hasPrefix(text) && $0 != text }
            .compactMap {
                guard let index = $0.index(
                    $0.startIndex,
                    offsetBy: range.location,
                    limitedBy: $0.endIndex
                ) else { return nil }
                return String($0[index...])
            }
        return result
    }
}

// MARK: - Previews

struct ChatPanel_Preview: PreviewProvider {
    static let history: [DisplayedChatMessage] = [
        .init(
            id: "1",
            role: .user,
            text: "**Hello**",
            references: []
        ),
        .init(
            id: "2",
            role: .assistant,
            text: """
            ```swift
            func foo() {}
            ```
            **Hey**! What can I do for you?**Hey**! What can I do for you?**Hey**! What can I do for you?**Hey**! What can I do for you?
            """,
            references: [
                .init(
                    title: "Hello Hello Hello Hello",
                    subtitle: "Hi Hi Hi Hi",
                    uri: "https://google.com",
                    startLine: nil,
                    kind: .class
                ),
            ]
        ),
        .init(
            id: "7",
            role: .ignored,
            text: "Ignored",
            references: []
        ),
        .init(
            id: "6",
            role: .tool,
            text: """
            Searching for something...
            - abc
            - [def](https://1.com)
            > hello
            > hi
            """,
            references: []
        ),
        .init(
            id: "5",
            role: .assistant,
            text: "Yooo",
            references: []
        ),
        .init(
            id: "4",
            role: .user,
            text: "Yeeeehh",
            references: []
        ),
        .init(
            id: "3",
            role: .user,
            text: #"""
            Please buy me a coffee!
            | Coffee | Milk |
            |--------|------|
            | Espresso | No |
            | Latte | Yes |

            ```swift
            func foo() {}
            ```
            ```objectivec
            - (void)bar {}
            ```
            """#,
            references: []
        ),
    ]

    static var previews: some View {
        ChatPanel(chat: .init(
            initialState: .init(history: ChatPanel_Preview.history, isReceivingMessage: true),
            reducer: Chat(service: .init())
        ))
        .frame(width: 450, height: 1200)
        .colorScheme(.dark)
    }
}

struct ChatPanel_EmptyChat_Preview: PreviewProvider {
    static var previews: some View {
        ChatPanel(chat: .init(
            initialState: .init(history: [], isReceivingMessage: false),
            reducer: Chat(service: .init())
        ))
        .padding()
        .frame(width: 450, height: 600)
        .colorScheme(.dark)
    }
}

struct ChatCodeSyntaxHighlighter: CodeSyntaxHighlighter {
    let brightMode: Bool
    let fontSize: Double

    init(brightMode: Bool, fontSize: Double) {
        self.brightMode = brightMode
        self.fontSize = fontSize
    }

    func highlightCode(_ content: String, language: String?) -> Text {
        let content = highlightedCodeBlock(
            code: content,
            language: language ?? "",
            brightMode: brightMode,
            fontSize: fontSize
        )
        return Text(AttributedString(content))
    }
}

struct ChatPanel_InputText_Preview: PreviewProvider {
    static var previews: some View {
        ChatPanel(chat: .init(
            initialState: .init(history: ChatPanel_Preview.history, isReceivingMessage: false),
            reducer: Chat(service: .init())
        ))
        .padding()
        .frame(width: 450, height: 600)
        .colorScheme(.dark)
    }
}

struct ChatPanel_InputMultilineText_Preview: PreviewProvider {
    static var previews: some View {
        ChatPanel(
            chat: .init(
                initialState: .init(
                    typedMessage: "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Fusce turpis dolor, malesuada quis fringilla sit amet, placerat at nunc. Suspendisse orci tortor, tempor nec blandit a, malesuada vel tellus. Nunc sed leo ligula. Ut at ligula eget turpis pharetra tristique. Integer luctus leo non elit rhoncus fermentum.",

                    history: ChatPanel_Preview.history,
                    isReceivingMessage: false
                ),
                reducer: Chat(service: .init())
            )
        )
        .padding()
        .frame(width: 450, height: 600)
        .colorScheme(.dark)
    }
}

struct ChatPanel_Light_Preview: PreviewProvider {
    static var previews: some View {
        ChatPanel(chat: .init(
            initialState: .init(history: ChatPanel_Preview.history, isReceivingMessage: true),
            reducer: Chat(service: .init())
        ))
        .padding()
        .frame(width: 450, height: 600)
        .colorScheme(.light)
    }
}

