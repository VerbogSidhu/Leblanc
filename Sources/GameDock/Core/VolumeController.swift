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
    private var volumeListenerBlock: AudioObjectPropertyListenerBlock?
    private var muteListenerBlock: AudioObjectPropertyListenerBlock?
    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?

    init() {
        refreshDevice()
        refresh()
        installListeners()
        installDeviceListener()
    }

    // MARK: - CoreAudio plumbing

    private func defaultDeviceAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func refreshDevice() {
        var addr = defaultDeviceAddress()
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

    /// Re-points listeners when the system's default output device changes
    /// (AirPods ↔ speakers ↔ HDMI, device disconnect, etc.). Without this the
    /// volume/mute listeners would keep targeting a stale AudioDeviceID and the
    /// HUD + L2/R2 volume control would stop affecting the real output.
    private func installDeviceListener() {
        var addr = defaultDeviceAddress()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.handleDefaultDeviceChanged()
            }
        }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, nil, block)
        deviceListenerBlock = block
    }

    private func handleDefaultDeviceChanged() {
        let old = defaultDevice
        if old != 0 {
            removeListeners()
        }
        refreshDevice()
        if defaultDevice != 0 {
            installListeners()
        }
        if defaultDevice != old {
            Log.info("VolumeController: default output device changed (\(old) → \(defaultDevice))")
            refresh()
        }
    }

    private func installListeners() {
        removeListeners()
        guard defaultDevice != 0 else { return }

        var addr = volumeAddress()
        let volumeBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.refresh()
                self?.showHUD()
            }
        }
        AudioObjectAddPropertyListenerBlock(defaultDevice, &addr, nil, volumeBlock)
        volumeListenerBlock = volumeBlock

        addr = muteAddress()
        let muteBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.refresh()
                self?.showHUD()
            }
        }
        AudioObjectAddPropertyListenerBlock(defaultDevice, &addr, nil, muteBlock)
        muteListenerBlock = muteBlock
    }

    private func removeListeners() {
        if defaultDevice != 0 {
            var addr = volumeAddress()
            if let block = volumeListenerBlock {
                AudioObjectRemovePropertyListenerBlock(defaultDevice, &addr, nil, block)
            }
            addr = muteAddress()
            if let block = muteListenerBlock {
                AudioObjectRemovePropertyListenerBlock(defaultDevice, &addr, nil, block)
            }
        }
        volumeListenerBlock = nil
        muteListenerBlock = nil
    }
}
