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
    @AppStorage("petSize") private var petSize: Double = PetSizeConstants.defaultSize

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
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { _ in
                    let mouseLocation = NSEvent.mouseLocation

                    if !viewModel.state.isDragging {
                        // Calculate offset from mouse to window origin
                        if let window = viewModel.petWindow {
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
            setupWindow()
            viewModel.loadAnimations()

            // Defer window positioning to after the layout pass completes
            // to avoid "layoutSubtreeIfNeeded called during layout" warning
            DispatchQueue.main.async {
                viewModel.positionWindowForFall()
                viewModel.startFalling()
            }
        }
    }

    private func setupWindow() {
        // Store reference to window in viewModel
        if let window = NSApplication.shared.windows.first {
            viewModel.petWindow = window
        }
    }
}

#Preview {
    ContentView()
}
