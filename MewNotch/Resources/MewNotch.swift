//
//  MewNotch.swift
//  MewNotch
//
//  Created by Monu Kumar on 27/02/25.
//

import SwiftUI

class MewNotch {
    
    enum IconColor: String {
        case blue
        case red
        case green
        case orange
        case yellow
        case pink
        case purple
        case gray
        case cyan
        case indigo
        case teal
        
        var color: Color {
            switch self {
            case .blue: return Color(red: 0.298, green: 0.686, blue: 0.969)  // Soft Blue
            case .red: return Color(red: 1.0, green: 0.498, blue: 0.498)     // Soft Red
            case .green: return Color(red: 0.353, green: 0.824, blue: 0.588) // Soft Green
            case .orange: return Color(red: 1.0, green: 0.698, blue: 0.4)    // Soft Orange
            case .yellow: return Color(red: 1.0, green: 0.843, blue: 0.0)    // Soft Yellow (Gold)
            case .pink: return Color(red: 1.0, green: 0.627, blue: 0.784)    // Soft Pink
            case .purple: return Color(red: 0.725, green: 0.518, blue: 0.933)// Soft Purple
            case .gray: return Color(red: 0.663, green: 0.663, blue: 0.663)  // Soft Gray
            case .cyan: return Color(red: 0.4, green: 0.9, blue: 0.95)       // Soft Cyan
            case .indigo: return Color(red: 0.45, green: 0.5, blue: 0.85)    // Soft Indigo
            case .teal: return Color(red: 0.4, green: 0.8, blue: 0.8)        // Soft Teal
            }
        }
    }

    class Assets {
        static let iconMenuBar = Image("MenuBarIcon")
        
        static let iconBrightness = Image("Brightness")
        static let iconSpeaker = Image("Speaker")
        
        // Settings Icons (SF Symbols)
        static let icGeneral = Image(systemName: "gear")
        static let icNotch = Image(systemName: "macbook")
        static let icMirror = Image(systemName: "person.crop.square.fill")
        static let icNowPlaying = Image(systemName: "music.note")
        static let icHud = Image(systemName: "slider.horizontal.3")
        static let icAudio = Image(systemName: "speaker.wave.3.fill")
        static let icBrightnessFill = Image(systemName: "sun.max.fill")
        static let icPower = Image(systemName: "bolt.fill")
        static let icMedia = Image(systemName: "music.note")
        static let icAbout = Image(systemName: "info.circle")
        static let icTimer = Image(systemName: "timer")
        static let icVideo = Image(systemName: "video.fill")
        
        static let icDisplay = Image(systemName: "display")
        static let icLock = Image(systemName: "lock.fill")
        static let icReset = Image(systemName: "arrow.counterclockwise")
        static let icHeight = Image(systemName: "ruler.fill")
        static let icGlass = Image(systemName: "sparkles")
        static let icHover = Image(systemName: "cursorarrow.rays")
        static let icHaptic = Image(systemName: "hand.tap.fill")
        static let icCornerRadius = Image(systemName: "app.dashed")
        static let icSeparator = Image(systemName: "line.3.horizontal")
        
        static let icAlbumArt = Image(systemName: "photo")
        static let icArtist = Image(systemName: "music.mic")
        static let icAlbumName = Image(systemName: "music.note.list")
        static let icAppIcon = Image(systemName: "app.fill")
        
        // HUD Detail Icons
        static let icMicrophone = Image(systemName: "mic.fill")
        static let icPaintbrush = Image(systemName: "paintbrush.fill")
        static let icSpeakerWave2 = Image(systemName: "speaker.wave.2.fill")
        static let icChartBar = Image(systemName: "chart.bar.fill")
        static let icBoltBadgeAutomatic = Image(systemName: "bolt.badge.automatic.fill")
        
        // General Settings Icons
        static let icLaunchAtLogin = Image(systemName: "arrow.up.circle.fill")
        static let icStatusIcon = Image(systemName: "menubar.rectangle")
        static let icDisableSystemHud = Image(systemName: "eye.slash.fill")
        static let icWarning = Image(systemName: "exclamationmark.triangle.fill")

        // Countdown
        static let icCandle = Image(systemName: "chart.bar.xaxis")
        static let icBell = Image(systemName: "bell.fill")
        static let icPosition = Image(systemName: "arrow.left.and.right")
        static let icMoon = Image(systemName: "moon.zzz.fill")
        static let icLabel = Image(systemName: "textformat")
        static let icClockCheck = Image(systemName: "clock.badge.checkmark")
        static let icCalendar = Image(systemName: "calendar")
        static let icGlobe = Image(systemName: "globe.americas.fill")
    }
    
    class Colors {
        static let general = IconColor.gray
        static let notch = IconColor.blue

        /// About 页的应用名标题。独立于 `notch`（那个是设置项图标的底色），
        /// 免得日后调其中一个把另一个也带偏。
        static let appTitle = IconColor.pink
        
        static let mirror = IconColor.purple
        static let nowPlaying = IconColor.pink
        
        static let hud = IconColor.orange
        static let audio = IconColor.blue
        static let brightness = IconColor.yellow
        static let power = IconColor.green
        static let timer = IconColor.gray
        
        static let about = IconColor.gray
        
        static let lock = IconColor.gray
        static let height = IconColor.orange
        static let glass = IconColor.cyan
        static let hover = IconColor.indigo
        static let haptic = IconColor.teal
        static let separator = IconColor.gray
        
        static let albumArt = IconColor.blue
        static let artist = IconColor.green
        static let albumName = IconColor.purple
        static let appIcon = IconColor.orange
        
        static let input = IconColor.green
        static let style = IconColor.blue
        static let output = IconColor.green
        static let stepSize = IconColor.orange
        static let autoBrightness = IconColor.green
        static let systemHud = IconColor.red
        static let video = IconColor.purple

        static let countdown = IconColor.orange
        static let alert = IconColor.red
        static let session = IconColor.indigo
        static let diagnostics = IconColor.gray
    }

    /// 刘海上倒计时的相位配色。背景是纯黑，且 app 强制深色模式。
    ///
    /// 核心原则：**余光（周边视觉）基本是色盲的** —— 它对亮度和运动敏感、
    /// 对色相不敏感。所以紧迫度主要编码在亮度和辉光里，色相只是中央凹的
    /// 二次线索。这顺带解决了色盲友好问题：亮度阶梯对所有 CVD 类型都有效，
    /// 不需要专门做红绿处理。
    class CountdownColors {

        /// 常态字色。
        ///
        /// 原本设成 0.72（实测 #C5C5C5），理由是「比菜单栏时钟低半档、
        /// 没事时自然后退」。实际盯盘反馈是偏暗看不清 —— 后退感不该以
        /// 牺牲可读性为代价，这是个交易工具不是装饰件。
        /// 0.92 实测约 #F0F0F0，接近菜单栏文字又略低一点。
        ///
        /// 不用绿色：一是把整个方案架在红绿轴（最差的 CVD 轴）上，
        /// 二是常驻绿字会产生适应疲劳，等真变色时反差反而不够。
        static let normal = Color.white.opacity(0.92)

        /// 图标色，固定琥珀 #FFB021。
        ///
        /// 不跟随相位变色：图标是固定的视觉锚点，数字才是变化的信号。
        /// 注意 warning 相位的字色是 #FFB020，与此几乎同色 ——
        /// 届时整条刘海会统一成琥珀，这是预期效果而非 bug。
        static let icon = Color(red: 1.00, green: 0.69, blue: 0.13)

        /// 琥珀。饱和色里亮度最高的色相，在所有 CVD 类型下都保持明亮。
        static let warning = Color(red: 1.00, green: 0.69, blue: 0.13)

        /// 暖橙红，不是纯红。
        ///
        /// 这里有个必须承认的物理限制：红是饱和色相里亮度最低的，
        /// 所以 normal → warning → urgent 的逐像素亮度阶梯最后一段是往下走的。
        /// 解法不是换色，是加辉光 —— 见 urgentGlow。
        static let urgent = Color(red: 1.00, green: 0.42, blue: 0.29)

        /// **这个辉光不是装饰。** 4pt 的 shadow 让发光面积约翻倍，
        /// 而周边视觉响应的是总光通量而非峰值亮度，于是总辐射量的阶梯
        /// 仍然单调上升。半径不能超过约 4pt，否则会被 NotchShape 的 mask 切掉。
        static let urgentGlow = Color(red: 1.00, green: 0.35, blue: 0.20).opacity(0.65)

        /// 故障态的告警字形。
        static let fault = Color(red: 1.00, green: 0.35, blue: 0.32)

        /// 非致命关切的小圆点。
        static let concernAmber = Color(red: 1.00, green: 0.69, blue: 0.13)
        static let concernGray = Color.white.opacity(0.35)

        /// 进度环走空后剩下的暗色轨道。够暗以免在余光里形成第二个亮环，
        /// 又够亮让「已消耗」的部分可辨。
        static let ringTrack = Color.white.opacity(0.16)
    }
}
