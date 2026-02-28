import AppKit
import Carbon
import Foundation

enum HotkeyKey: String, CaseIterable, Codable {
    case space
    case a
    case b
    case c
    case d
    case e
    case f
    case g
    case h
    case i
    case j
    case k
    case l
    case m
    case n
    case o
    case p
    case q
    case r
    case s
    case t
    case u
    case v
    case w
    case x
    case y
    case z
    case one
    case two
    case three
    case four
    case five
    case six
    case seven
    case eight
    case nine
    case zero

    var displayName: String {
        switch self {
        case .space: return "Space"
        case .a: return "A"
        case .b: return "B"
        case .c: return "C"
        case .d: return "D"
        case .e: return "E"
        case .f: return "F"
        case .g: return "G"
        case .h: return "H"
        case .i: return "I"
        case .j: return "J"
        case .k: return "K"
        case .l: return "L"
        case .m: return "M"
        case .n: return "N"
        case .o: return "O"
        case .p: return "P"
        case .q: return "Q"
        case .r: return "R"
        case .s: return "S"
        case .t: return "T"
        case .u: return "U"
        case .v: return "V"
        case .w: return "W"
        case .x: return "X"
        case .y: return "Y"
        case .z: return "Z"
        case .one: return "1"
        case .two: return "2"
        case .three: return "3"
        case .four: return "4"
        case .five: return "5"
        case .six: return "6"
        case .seven: return "7"
        case .eight: return "8"
        case .nine: return "9"
        case .zero: return "0"
        }
    }

    var carbonKeyCode: UInt32 {
        switch self {
        case .space: return UInt32(kVK_Space)
        case .a: return UInt32(kVK_ANSI_A)
        case .b: return UInt32(kVK_ANSI_B)
        case .c: return UInt32(kVK_ANSI_C)
        case .d: return UInt32(kVK_ANSI_D)
        case .e: return UInt32(kVK_ANSI_E)
        case .f: return UInt32(kVK_ANSI_F)
        case .g: return UInt32(kVK_ANSI_G)
        case .h: return UInt32(kVK_ANSI_H)
        case .i: return UInt32(kVK_ANSI_I)
        case .j: return UInt32(kVK_ANSI_J)
        case .k: return UInt32(kVK_ANSI_K)
        case .l: return UInt32(kVK_ANSI_L)
        case .m: return UInt32(kVK_ANSI_M)
        case .n: return UInt32(kVK_ANSI_N)
        case .o: return UInt32(kVK_ANSI_O)
        case .p: return UInt32(kVK_ANSI_P)
        case .q: return UInt32(kVK_ANSI_Q)
        case .r: return UInt32(kVK_ANSI_R)
        case .s: return UInt32(kVK_ANSI_S)
        case .t: return UInt32(kVK_ANSI_T)
        case .u: return UInt32(kVK_ANSI_U)
        case .v: return UInt32(kVK_ANSI_V)
        case .w: return UInt32(kVK_ANSI_W)
        case .x: return UInt32(kVK_ANSI_X)
        case .y: return UInt32(kVK_ANSI_Y)
        case .z: return UInt32(kVK_ANSI_Z)
        case .one: return UInt32(kVK_ANSI_1)
        case .two: return UInt32(kVK_ANSI_2)
        case .three: return UInt32(kVK_ANSI_3)
        case .four: return UInt32(kVK_ANSI_4)
        case .five: return UInt32(kVK_ANSI_5)
        case .six: return UInt32(kVK_ANSI_6)
        case .seven: return UInt32(kVK_ANSI_7)
        case .eight: return UInt32(kVK_ANSI_8)
        case .nine: return UInt32(kVK_ANSI_9)
        case .zero: return UInt32(kVK_ANSI_0)
        }
    }
}

struct HotkeyShortcut: Codable, Equatable {
    var key: HotkeyKey
    var command: Bool
    var shift: Bool
    var option: Bool
    var control: Bool

    static let `default` = HotkeyShortcut(
        key: .space,
        command: true,
        shift: true,
        option: false,
        control: false
    )

    var carbonModifiers: UInt32 {
        var modifiers: UInt32 = 0
        if command { modifiers |= UInt32(cmdKey) }
        if shift { modifiers |= UInt32(shiftKey) }
        if option { modifiers |= UInt32(optionKey) }
        if control { modifiers |= UInt32(controlKey) }
        return modifiers
    }

    var displayString: String {
        var parts: [String] = []
        if command { parts.append("Cmd") }
        if shift { parts.append("Shift") }
        if option { parts.append("Option") }
        if control { parts.append("Ctrl") }
        parts.append(key.displayName)
        return parts.joined(separator: " + ")
    }
}
