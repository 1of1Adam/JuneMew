//
//  NotchDefaults.swift
//  MewNotch
//
//  Created by Monu Kumar on 23/03/25.
//

import SwiftUI

/// 刘海本体的几何与显示设置。
/// 倒计时相关的设置刻意放在独立的 `CountdownDefaults` 里 —— `NotchView` 订阅了
/// 本类的 `objectWillChange` 来触发 `refreshNotchSize()`，混在一起会让调阈值
/// 也触发一次刘海几何重算。
class NotchDefaults: ObservableObject {

    private static var PREFIX: String = "Notch_"

    static let shared = NotchDefaults()

    private init() {}

    @PrimitiveUserDefault(
        PREFIX + "HideOnFullScreen",
        defaultValue: true
    )
    var hideOnFullScreen: Bool {
        didSet {
            self.objectWillChange.send()
        }
    }

    @CodableUserDefault(
        PREFIX + "NotchDisplayVisibility",
        defaultValue: NotchDisplayVisibility.NotchedDisplayOnly
    )
    var notchDisplayVisibility: NotchDisplayVisibility {
        didSet {
            self.objectWillChange.send()
        }
    }

    @CodableUserDefault(
        PREFIX + "ShownOnDisplay",
        defaultValue: [:]
    )
    var shownOnDisplay: [String: Bool] {
        didSet {
            self.objectWillChange.send()
        }
    }

    @PrimitiveUserDefault(
        PREFIX + "ShownOnLockScreen",
        defaultValue: true
    )
    var shownOnLockScreen: Bool {
        didSet {
            self.objectWillChange.send()
        }
    }

    @CodableUserDefault(
        PREFIX + "HeightMode",
        defaultValue: NotchHeightMode.Match_Notch
    )
    var heightMode: NotchHeightMode {
        didSet {
            self.objectWillChange.send()
        }
    }

    @PrimitiveUserDefault(
        PREFIX + "GlassEffect",
        defaultValue: false
    )
    var applyGlassEffect: Bool {
        didSet {
            self.objectWillChange.send()
        }
    }

}
