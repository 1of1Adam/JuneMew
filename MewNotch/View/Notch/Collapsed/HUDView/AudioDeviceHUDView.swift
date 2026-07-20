//
//  AudioDeviceHUDView.swift
//  MewNotch
//
//  Created by Monu Kumar on 11/03/25.
//

import SwiftUI

struct AudioDeviceHUDView: View {
    
    enum DeviceType: String {
        case Input = "Input Device"
        case Output = "Output Device"
    }
    
    @ObservedObject var notchViewModel: NotchViewModel
    
    var deviceType: DeviceType = .Output
    
    var hudModel: HUDPropertyModel?
    
    var body: some View {
        if let deviceName = hudModel?.name, !deviceName.isEmpty {
            VStack(
                spacing: 0
            ) {
                Text(deviceType.rawValue.capitalized)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text(deviceName)
                    .font(.body.bold())
                    .foregroundColor(.secondary)
            }
            .padding(
                .init(
                    top: 0,
                    leading: 10,
                    bottom: 10,
                    trailing: 10
                )
            )
            .padding(
                .horizontal, notchViewModel.extraNotchPadSize.width / 2
            )
            .transition(
                .move(
                    edge: .top
                )
                .combined(
                    with: .opacity
                )
            )
        }
    }
}
