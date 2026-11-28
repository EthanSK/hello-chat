// Exercise native-output policy with injected hardware; never write this Mac's volume or routes. — GPT-6.1 Sol
import CoreAudio
import Foundation

@main enum SystemOutputVolumeTests {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        final class Fixture {
            let a = SystemOutputVolume.Device(id: 10, uid: "output-a", name: "Fixture output")
            let b = SystemOutputVolume.Device(id: 11, uid: "output-b", name: "Other output")
            var controls = [SystemOutputVolume.Control(selector: kAudioDevicePropertyVolumeScalar, element: 0, value: 0.7)]
            var writes: [Float] = []
            var currentReads = 0
            var changeAt: Int?
            var ignoredWrites = false
            var ignoredElement: UInt32?
            var failAt: Int?
            var muted = true
            var input = "unchanged microphone", alerts = "unchanged alert route"
            func backend() -> SystemOutputVolume {
                .init(hardware: .init(current: {
                    self.currentReads += 1
                    return self.changeAt.map { self.currentReads >= $0 } == true ? self.b : self.a
                }, controls: { _ in self.controls }, muted: { _ in self.muted }, write: { device, control, value in
                    precondition(device == self.a && control.selector == kAudioDevicePropertyVolumeScalar)
                    self.writes.append(value)
                    if self.failAt == self.writes.count { throw SystemOutputVolume.Failure.write(-1) }
                    if !self.ignoredWrites, self.ignoredElement != control.element, let at = self.controls.firstIndex(where: { $0.element == control.element }) {
                        self.controls[at] = .init(selector: control.selector, element: control.element, value: value)
                    }
                }))
            }
        }
        for percent in [0, 1, 30, 70, 99, 100] {
            let f = Fixture();let result = try f.backend().set(percent, on: f.a)
            check(result.percent == percent, "Absolute output volume is read back")
            check(result.device == f.a && result.muted == true, "Never select or unmute a device")
            check(f.input == "unchanged microphone" && f.alerts == "unchanged alert route", "No input or alert writer is available")
        }
        for value in [-1, 101, Int.max] {
            let f=Fixture()
            do { _=try f.backend().set(value,on:f.a);preconditionFailure() }
            catch let e as SystemOutputVolume.OperationFailure {check(e.beforeDispatch && f.writes.isEmpty,"Invalid values cannot write")}
        }
        let same=Fixture();_ = try same.backend().set(70,on:same.a);check(same.writes.isEmpty,"Already selected value needs no write")
        let unsupported=Fixture();unsupported.controls=[]
        check(try unsupported.backend().read().adjustable == false,"Hardware without volume is reported unsupported")
        do {_=try unsupported.backend().set(30,on:unsupported.a);preconditionFailure()}
        catch let e as SystemOutputVolume.OperationFailure {check(e.beforeDispatch && unsupported.writes.isEmpty,"Unsupported interfaces cannot fake success")}
        for level:Float in [.nan,.infinity,-0.1,1.1] {
            let f=Fixture();f.controls=[.init(selector:kAudioDevicePropertyVolumeScalar,element:0,value:level)]
            do {_=try f.backend().set(30,on:f.a);preconditionFailure()}
            catch let e as SystemOutputVolume.OperationFailure {check(e.beforeDispatch && f.writes.isEmpty,"Malformed readback cannot write")}
        }
        let stereo=Fixture();stereo.controls=[.init(selector:kAudioDevicePropertyVolumeScalar,element:1,value:0.8),.init(selector:kAudioDevicePropertyVolumeScalar,element:2,value:0.4)]
        check(try stereo.backend().set(30,on:stereo.a).percent==30,"Stereo peak reaches requested level")
        check(abs(stereo.controls[0].value-0.3)<0.001 && abs(stereo.controls[1].value-0.15)<0.001,"Stereo balance survives")
        let uneven=Fixture(); uneven.controls=[.init(selector:kAudioDevicePropertyVolumeScalar,element:1,value:0.8),.init(selector:kAudioDevicePropertyVolumeScalar,element:2,value:0.2)];uneven.ignoredElement=2
        do {_=try uneven.backend().set(30,on:uneven.a);preconditionFailure()}
        catch let e as SystemOutputVolume.OperationFailure {check(!e.beforeDispatch,"Every channel must confirm, not only the peak")}
        let zero=Fixture();zero.controls=stereo.controls.map { .init(selector:$0.selector,element:$0.element,value:0) }
        _=try zero.backend().set(30,on:zero.a);check(zero.controls.allSatisfy{abs($0.value-0.3)<0.001},"Zeroed pair can return to requested level")
        for at in [1,2] {
            let f=Fixture();f.changeAt=at
            do {_=try f.backend().set(30,on:f.a);preconditionFailure()}
            catch let e as SystemOutputVolume.OperationFailure {check(e.beforeDispatch && f.writes.isEmpty,"A changed output refuses before dispatch")}
        }
        let partial=Fixture();partial.controls=stereo.controls;partial.changeAt=3
        do {_=try partial.backend().set(70,on:partial.a);preconditionFailure()}
        catch let e as SystemOutputVolume.OperationFailure {check(!e.beforeDispatch && partial.writes.count==1,"Mid-transaction device change is uncertain, never retried or rolled back")}
        let balance = Fixture(); balance.controls = [.init(selector:kAudioDevicePropertyVolumeScalar,element:1,value:0.8), .init(selector:kAudioDevicePropertyVolumeScalar,element:2,value:0.2)]; balance.ignoredElement = 2
        do { _ = try balance.backend().set(30, on:balance.a); preconditionFailure() }
        catch let e as SystemOutputVolume.OperationFailure { check(!e.beforeDispatch, "Every channel’s readback must preserve balance, not only the peak") }
        let rejected=Fixture();rejected.failAt=1
        do {_=try rejected.backend().set(30,on:rejected.a);preconditionFailure()}
        catch let e as SystemOutputVolume.OperationFailure {check(!e.beforeDispatch && rejected.writes.count==1,"Native write failure stays uncertain")}
        let ignored=Fixture();ignored.ignoredWrites=true
        do {_=try ignored.backend().set(30,on:ignored.a);preconditionFailure()}
        catch let e as SystemOutputVolume.OperationFailure {check(!e.beforeDispatch && ignored.writes.count==1,"Readback must confirm effect")}
        print("Passed \(checks) output-volume hardware policy checks; no real hardware write")
    }
}
