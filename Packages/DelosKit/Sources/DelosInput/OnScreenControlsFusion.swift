import DelosCore

extension ControllerState {
    /// The one state of a controller number made of the states of every source with that number (`sendControllerInputPacket`
    /// of DELOS for Android's `ControllerHandler`): the physical controller and, for number 0, the on-screen controls. In
    /// Android's arithmetic: the buttons are or-ed, and each axis is or-ed with the value of larger magnitude of what was
    /// gathered so far and the next source (a trigger as a signed byte, as Java widens it). With one source moving it is that
    /// source's value.
    public static func fused(_ states: [ControllerState]) -> ControllerState {
        var out = ControllerState()
        for s in states {
            out.buttons.formUnion(s.buttons)
            out.leftTrigger = fuse(out.leftTrigger, s.leftTrigger)
            out.rightTrigger = fuse(out.rightTrigger, s.rightTrigger)
            out.leftStickX = fuse(out.leftStickX, s.leftStickX)
            out.leftStickY = fuse(out.leftStickY, s.leftStickY)
            out.rightStickX = fuse(out.rightStickX, s.rightStickX)
            out.rightStickY = fuse(out.rightStickY, s.rightStickY)
        }
        return out
    }

    /// `maxByMagnitude`: [a] when its magnitude is larger, else [b].
    private static func maxByMagnitude(_ a: Int16, _ b: Int16) -> Int16 {
        abs(Int(a)) > abs(Int(b)) ? a : b
    }

    private static func fuse(_ a: Int16, _ b: Int16) -> Int16 { a | maxByMagnitude(a, b) }

    private static func fuse(_ a: UInt8, _ b: UInt8) -> UInt8 {
        let signedA = Int16(Int8(bitPattern: a)), signedB = Int16(Int8(bitPattern: b))
        return UInt8(truncatingIfNeeded: signedA | maxByMagnitude(signedA, signedB))
    }
}
