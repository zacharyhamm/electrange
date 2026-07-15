//
//  ContentView.swift
//  electragne
//
//  Created by zacharyhamm on 2/3/26.
//

import SwiftUI

struct ContentView: View {
    let appModel: AppModel

    var body: some View {
        ElectragneView(
            viewModel: appModel.petViewModel,
            chatBubbleController: appModel.chatBubbleController
        )
            .onAppear { appModel.start() }
    }
}

struct ElectragneView: View {
    let viewModel: PetViewModel
    let chatBubbleController: ChatBubbleWindowController
    @State private var pressStartMouseLocation: NSPoint?
    @AppStorage(PetSizeConstants.storageKey) private var petSize: Double = PetSizeConstants.defaultSize

    var body: some View {
        ZStack {
            if let frameImage = viewModel.animationManager.getCurrentFrameImage() {
                Image(nsImage: frameImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: petSize, height: petSize)
                    .scaleEffect(x: viewModel.isMovingRight ? -1 : 1, y: 1)
                    .offset(y: -viewModel.animationManager.getCurrentOffsetY())
            } else {
                // Fallback if image not loaded
                Image(systemName: "hare.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: petSize, height: petSize)
                    .scaleEffect(x: viewModel.isMovingRight ? -1 : 1, y: 1)
                    .foregroundStyle(.brown)
            }
        }
        .frame(width: petSize, height: petSize)
        .background(WindowAccessor { window in
            viewModel.petWindow = window
            syncChatBubble()
        })
        .gesture(
            // The click-vs-drag decision lives in ClickDragClassifier; see
            // its header for why this uses screen-space NSEvent.mouseLocation.
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { _ in
                    let mouseLocation = NSEvent.mouseLocation
                    if pressStartMouseLocation == nil {
                        pressStartMouseLocation = mouseLocation
                    }

                    if !viewModel.state.isDragging {
                        guard let start = pressStartMouseLocation,
                              ClickDragClassifier.isDrag(from: start, to: mouseLocation),
                              viewModel.state.canInteract,
                              let window = viewModel.petWindow else { return }
                        // Calculate offset from mouse to window origin
                        let offset = NSPoint(
                            x: mouseLocation.x - window.frame.origin.x,
                            y: mouseLocation.y - window.frame.origin.y
                        )
                        viewModel.startDragging(mouseOffset: offset)
                    }

                    viewModel.updateWindowPosition(to: mouseLocation)
                }
                .onEnded { _ in
                    defer { pressStartMouseLocation = nil }

                    if viewModel.state.isDragging {
                        viewModel.endDragging()
                        return
                    }

                    guard let start = pressStartMouseLocation,
                          !ClickDragClassifier.isDrag(from: start, to: NSEvent.mouseLocation)
                    else { return }

                    if viewModel.state.isChatting {
                        viewModel.dismissChat()
                    } else {
                        viewModel.beginChat()
                    }
                }
        )
        .onChange(of: viewModel.state) { _, _ in
            syncChatBubble()
        }
        .onDisappear {
            chatBubbleController.dismiss(notify: false)
        }
    }

    private func syncChatBubble() {
        guard viewModel.state.isChatting, let window = viewModel.petWindow else {
            chatBubbleController.dismiss(notify: false)
            return
        }

        chatBubbleController.present(
            anchoredTo: window,
            onDismiss: { viewModel.dismissChat() }
        )
    }
}

/// Reports the NSWindow hosting this view. Unlike NSApp.windows.first, this
/// can't pick up the status-bar item's window or any other unrelated window.
private struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> AccessorView {
        let view = AccessorView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: AccessorView, context: Context) {}

    final class AccessorView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                onWindow?(window)
            }
        }
    }
}

#Preview {
    ContentView(appModel: AppModel())
}
