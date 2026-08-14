import Combine
import CoreAudio
import Foundation

/// System volume + mute via CoreAudio (the default output device's
/// `virtualMainVolume`). Observes property changes so the HUD also appears for
/// physical keyboard volume keys and volume changes from other apps.
final class VolumeController: ObservableObject {
    @Published private(set) var level: Float = 0.5
    @Published private(set) var isMuted = false
    @Published private(set) var hudVisible = false

    private var defaultDevice: AudioDeviceID = 0
    private var hideTask: DispatchWorkItem?

    init() {
        refreshDevice()
        refresh()
        installListeners()
    }

    // MARK: - CoreAudio plumbing

    private func refreshDevice() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
        if err == noErr { defaultDevice = device }
    }

    private func volumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    func refresh() {
        var addr = volumeAddress()
        var vol: Float32 = 0.5
        var size = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectGetPropertyData(defaultDevice, &addr, 0, nil, &size, &vol) == noErr {
            level = vol
        }
        addr = muteAddress()
        var muted: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(defaultDevice, &addr, 0, nil, &size, &muted) == noErr {
            isMuted = muted != 0
        }
    }

    // MARK: - Control

    func setVolume(_ newLevel: Float) {
        let clamped = min(max(newLevel, 0), 1)
        var vol = Float32(clamped)
        var addr = volumeAddress()
        AudioObjectSetPropertyData(defaultDevice, &addr, 0, nil,
                                   UInt32(MemoryLayout<Float32>.size), &vol)
        level = clamped
        showHUD()
    }

    func adjust(by delta: Float) {
        setVolume(level + delta)
    }

    func toggleMute() {
        var muted: UInt32 = isMuted ? 0 : 1
        var addr = muteAddress()
        AudioObjectSetPropertyData(defaultDevice, &addr, 0, nil,
                                   UInt32(MemoryLayout<UInt32>.size), &muted)
        isMuted = !isMuted
        showHUD()
    }

    // MARK: - HUD + change observation

    private func showHUD() {
        hudVisible = true
        hideTask?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.hudVisible = false }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: task)
    }

    private func installListeners() {
        var addr = volumeAddress()
        AudioObjectAddPropertyListenerBlock(defaultDevice, &addr, nil) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.refresh()
                self?.showHUD()
            }
        }
        addr = muteAddress()
        AudioObjectAddPropertyListenerBlock(defaultDevice, &addr, nil) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.refresh()
                self?.showHUD()
            }
        }
    }
}
