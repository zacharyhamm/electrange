//
//  ContentView.swift
//  electragne
//
//  Created by zacharyhamm on 2/3/26.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        ElectragneView()
    }
}

struct ElectragneView: View {
    @State private var viewModel = PetViewModel()
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
        })
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { _ in
                    let mouseLocation = NSEvent.mouseLocation

                    if !viewModel.state.isDragging {
                        // Calculate offset from mouse to window origin
                        if viewModel.state.canInteract, let window = viewModel.petWindow {
                            let offset = NSPoint(
                                x: mouseLocation.x - window.frame.origin.x,
                                y: mouseLocation.y - window.frame.origin.y
                            )
                            viewModel.startDragging(mouseOffset: offset)
                        }
                    }

                    viewModel.updateWindowPosition(to: mouseLocation)
                }
                .onEnded { _ in
                    viewModel.endDragging()
                }
        )
        .onAppear {
            viewModel.loadAnimations()

            // Defer window positioning to after the layout pass completes
            // to avoid "layoutSubtreeIfNeeded called during layout" warning
            DispatchQueue.main.async {
                viewModel.positionWindowForFall()
                viewModel.startFalling()
            }
        }
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
    ContentView()
}
