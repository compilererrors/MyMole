import Foundation
import SystemKit
import Testing

@testable import MyMole

@Suite struct StatusHistoryTests {
    @Test func onlyTheLatestReadingsAreKeptAndAMissingOneEndsTheLine() {
        var h = StatusHistory()
        let cpu = SystemSnapshot.CPU(usage: 40, perCore: [40], load: nil)
        for i in 0..<(StatusHistory.kept + 10) {
            h.add(SystemSnapshot(date: Date(timeIntervalSince1970: Double(i)), hardware: .init(model: nil, chip: nil, memoryBytes: nil, osVersion: "26"), uptime: nil, cpu: cpu, memory: nil, volumes: [], disk: nil, network: [], battery: nil, topProcesses: []))
        }
        #expect(h.cpu.count == StatusHistory.kept)
        #expect(h.memory.isEmpty && h.battery.isEmpty)
        h.add(SystemSnapshot(date: Date(), hardware: .init(model: nil, chip: nil, memoryBytes: nil, osVersion: "26"), uptime: nil, cpu: nil, memory: nil, volumes: [], disk: nil, network: [], battery: nil, topProcesses: []))
        #expect(h.cpu.isEmpty)
    }
}
