//
//  OutputDevices.swift
//  Quality
//
//  Created by Vincent Neo on 20/4/22.
//

import Combine
import Foundation
import SimplyCoreAudio
import CoreAudioTypes
import MediaRemoteAdapter
import CoreAudio
import AppKit

class OutputDevices: ObservableObject {
    @Published var selectedOutputDevice: AudioDevice? {
        didSet {
            if oldValue?.id != selectedOutputDevice?.id {
                print("[HogMode] 使用者手動切換選取裝置：從 \(oldValue?.name ?? "預設") 切換至 \(selectedOutputDevice?.name ?? "預設")，釋放舊裝置獨佔權")
                self.releaseHogMode(for: oldValue?.id)
            }
        }
    } // auto if nil
    @Published var defaultOutputDevice: AudioDevice?
    @Published var outputDevices = [AudioDevice]()
    @Published var currentSampleRate: Float64?
    
    /// 目前取得獨佔模式 (Hog Mode) 的音訊裝置 ID，若無則為 nil
    private var hoggedDeviceID: AudioObjectID?
    private var appWillTerminateCancellable: AnyCancellable?
    
    private var enableBitDepthDetection = Defaults.shared.userPreferBitDepthDetection
    private var enableBitDepthDetectionCancellable: AnyCancellable?
    
    private let coreAudio = SimplyCoreAudio()
    
    private var changesCancellable: AnyCancellable?
    private var defaultChangesCancellable: AnyCancellable?
    private var timerCancellable: AnyCancellable?
    private var outputSelectionCancellable: AnyCancellable?
    
    private var consoleQueue = DispatchQueue(label: "consoleQueue", qos: .userInteractive)
    
    private var previousSampleRate: Float64?
    var trackAndSample = [MediaTrack : Float64]()
    var previousTrack: MediaTrack?
    var currentTrack: MediaTrack?
    
    // MARK: - Playback Mid-Song Lock (播放中取樣率鎖定機制)
    var isSongLocked: Bool = false
    var lockedTrack: MediaTrack?
    var lockedSampleRate: Float64?
    var trackStartTime: Date = Date()
    
    var timerActive = false
    var timerCalls = 0
    
    /// 判斷兩首曲目是否為同一首歌（比對 ID、歌名與演出者）
    func isSameSong(_ track1: MediaTrack?, _ track2: MediaTrack?) -> Bool {
        guard let t1 = track1, let t2 = track2 else { return false }
        if let id1 = t1.id, let id2 = t2.id, !id1.isEmpty, id1 == id2 {
            return true
        }
        if let title1 = t1.title, let title2 = t2.title, !title1.isEmpty,
           let artist1 = t1.artist, let artist2 = t2.artist {
            return title1 == title2 && artist1 == artist2
        }
        return t1 == t2
    }
    
    /// 解除曲目取樣率鎖定（切換至新曲時呼叫）
    func resetSongLock() {
        self.isSongLocked = false
        self.lockedTrack = nil
        self.lockedSampleRate = nil
        self.trackStartTime = Date()
    }
    
    init() {
        self.outputDevices = self.coreAudio.allOutputDevices
        self.defaultOutputDevice = self.coreAudio.defaultOutputDevice
        self.getDeviceSampleRate()
        
        changesCancellable =
            NotificationCenter.default.publisher(for: .deviceListChanged).sink(receiveValue: { _ in
                self.outputDevices = self.coreAudio.allOutputDevices
            })
        
        defaultChangesCancellable =
            NotificationCenter.default.publisher(for: .defaultOutputDeviceChanged).sink(receiveValue: { [weak self] _ in
                guard let self = self else { return }
                let newDefault = self.coreAudio.defaultOutputDevice
                // 只有在系統預設裝置 ID 真正改變時（如拔掉 DAC 或切換成揚聲器），才釋放舊裝置獨佔模式
                if let currentHogged = self.hoggedDeviceID, let newID = newDefault?.id, currentHogged != newID {
                    print("[HogMode] 偵測到 macOS 系統預設輸出裝置切換至新裝置 (舊: \(currentHogged) -> 新: \(newID))，釋放舊裝置獨佔模式...")
                    self.releaseHogMode(for: currentHogged)
                }
                self.defaultOutputDevice = newDefault
                self.resetSongLock()
                self.getDeviceSampleRate()
            })
        
        outputSelectionCancellable = selectedOutputDevice.publisher.sink(receiveValue: { [weak self] _ in
            self?.resetSongLock()
            self?.getDeviceSampleRate()
        })
        
        // 當 App 準備退出時，釋放獨佔模式（寫回 0）
        appWillTerminateCancellable =
            NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification).sink { [weak self] _ in
                print("[HogMode] 偵測到 App 即將退出，立即釋放音訊輸出裝置獨佔模式 (寫回 0)...")
                self?.releaseHogMode()
                NSApp.dockTile.badgeLabel = nil
            }
        
        enableBitDepthDetectionCancellable = Defaults.shared.$userPreferBitDepthDetection.sink(receiveValue: { newValue in
            self.enableBitDepthDetection = newValue
        })

        
    }
    
    deinit {
        releaseHogMode()
        NSApp.dockTile.badgeLabel = nil
        changesCancellable?.cancel()
        defaultChangesCancellable?.cancel()
        timerCancellable?.cancel()
        enableBitDepthDetectionCancellable?.cancel()
        appWillTerminateCancellable?.cancel()
        outputSelectionCancellable?.cancel()
        //timer.upstream.connect().cancel()
    }
    
    func renewTimer() {
        if timerCancellable != nil { return }
        timerCancellable = Timer
            .publish(every: 2, on: .main, in: .default)
            .autoconnect()
            .sink { _ in
                if self.timerCalls == 5 {
                    self.timerCalls = 0
                    self.timerCancellable?.cancel()
                    self.timerCancellable = nil
                    // 輪詢週期結束後，若已有取樣率，強制確認鎖定
                    if let currentRate = self.currentSampleRate, self.currentTrack != nil {
                        self.isSongLocked = true
                        self.lockedTrack = self.currentTrack
                        self.lockedSampleRate = currentRate * 1000
                        print("[Lock] 輪詢結束，歌曲「\(self.currentTrack?.title ?? "")」取樣率確認鎖定在 \(currentRate) kHz")
                    }
                }
                else {
                    self.timerCalls += 1
                    self.consoleQueue.async {
                        self.switchLatestSampleRate()
                    }
                }
            }
    }
    
    func getDeviceSampleRate() {
        let defaultDevice = self.selectedOutputDevice ?? self.defaultOutputDevice
        guard let sampleRate = defaultDevice?.nominalSampleRate else { return }
        self.updateSampleRate(sampleRate)
    }
    
    func getSampleRateFromAppleScript() -> Double? {
        let scriptContents = "tell application \"Music\" to get sample rate of current track"
        var error: NSDictionary?
        
        if let script = NSAppleScript(source: scriptContents) {
            let output = script.executeAndReturnError(&error).stringValue
            
            if let error = error {
                print("[APPLESCRIPT] - \(error)")
            }
            guard let output = output else { return nil }

            if output == "missing value" {
                return nil
            }
            else {
                return Double(output)
            }
        }
        
        return nil
    }
    
    func getAllStats() -> [CMPlayerStats] {
        var allStats = [CMPlayerStats]()
        
        do {
//            let musicLogs = try Console.getRecentEntries(type: .music)
            let coreAudioLogs = try Console.getRecentEntries(type: .coreAudio)
//            let coreMediaLogs = try Console.getRecentEntries(type: .coreMedia)
            
//            allStats.append(contentsOf: CMPlayerParser.parseMusicConsoleLogs(musicLogs))
//            if enableBitDepthDetection {
                allStats.append(contentsOf: CMPlayerParser.parseCoreAudioConsoleLogs(coreAudioLogs))
//            }
//            else {
//                allStats.append(contentsOf: CMPlayerParser.parseCoreMediaConsoleLogs(coreMediaLogs))
//            }

//            allStats.sort(by: {$0.priority > $1.priority})
            print("[getAllStats] \(allStats)")
        }
        catch {
            print("[getAllStats, error] \(error)")
        }
        
        return allStats
    }
    
    func switchLatestSampleRate(recursion: Bool = false) {
        let allStats = self.getAllStats()
        let defaultDevice = self.selectedOutputDevice ?? self.defaultOutputDevice
        
        if let first = allStats.first, let supported = defaultDevice?.nominalSampleRates {
            let sampleRate = Float64(first.sampleRate)
            let bitDepth = Int32(first.bitDepth)
            
            // 播放中鎖定檢查：
            // 如果當前歌曲已經處於鎖定狀態：
            if self.isSongLocked, let lockedRate = self.lockedSampleRate, self.isSameSong(self.currentTrack, self.lockedTrack) {
                // 僅在播放初期的 8 秒內，若 Apple Music 由 44.1k/48k 升級至更高解析度無損 (如 96k/192k)，允許升級
                let elapsed = Date().timeIntervalSince(self.trackStartTime)
                if elapsed < 8.0 && sampleRate > lockedRate {
                    print("[Lock] 初播升級：歌曲「\(self.currentTrack?.title ?? "")」升級至高解析無損 (\(lockedRate) Hz -> \(sampleRate) Hz)")
                } else {
                    // 若歌曲已鎖定且非初期升級，強力阻擋中途跳轉（包含預載下一首、系統通知音訊等）
                    print("[Lock] 播放中鎖定生效：歌曲「\(self.currentTrack?.title ?? "")」已鎖定在 \(lockedRate) Hz，忽略中途非預期變更 (候選值: \(sampleRate) Hz)")
                    return
                }
            }
            
            if self.currentTrack == self.previousTrack, let prevSampleRate = currentSampleRate, prevSampleRate > sampleRate {
                print("same track, prev sample rate is higher")
                return
            }
            
            if sampleRate == 48000 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self.switchLatestSampleRate(recursion: true)
                }
            }
            
            let formats = self.getFormats(bestStat: first, device: defaultDevice!)!
            
            // https://stackoverflow.com/a/65060134
            let nearest = supported.min(by: {
                abs($0 - sampleRate) < abs($1 - sampleRate)
            })
            
            let nearestBitDepth = formats.min(by: {
                abs(Int32($0.mBitsPerChannel) - bitDepth) < abs(Int32($1.mBitsPerChannel) - bitDepth)
            })
            
            let nearestFormat = formats.filter({
                $0.mSampleRate == nearest && $0.mBitsPerChannel == nearestBitDepth?.mBitsPerChannel
            })
            
            print("NEAREST FORMAT \(nearestFormat)")
            
            if let suitableFormat = nearestFormat.first {
                guard let targetDevice = defaultDevice else { return }
                
                let targetSampleRate = suitableFormat.mSampleRate
                let streams = targetDevice.streams(scope: .output)
                let currentFormat = streams?.first?.physicalFormat
                let formatChanged = (currentFormat != suitableFormat)
                let sampleRateChanged = (targetDevice.nominalSampleRate != targetSampleRate || targetSampleRate != previousSampleRate)
                let needsChange = enableBitDepthDetection ? formatChanged : sampleRateChanged
                
                if needsChange {
                    print("[Switch] 檢測到取樣率規格改變，準備切換至 \(targetSampleRate) Hz...")
                    // 1. 在更改取樣率前，先透過 kAudioDevicePropertyHogMode 取得該音訊輸出裝置的獨佔控制權
                    self.acquireHogMode(for: targetDevice)
                    
                    if enableBitDepthDetection {
                        self.setFormats(device: targetDevice, format: suitableFormat)
                    }
                    else {
                        targetDevice.setNominalSampleRate(targetSampleRate)
                    }
                    
                    // 2. 切換硬體完成後，立即釋放 Hog Mode（寫回 0），讓音訊伺服器與 Apple Music 順暢串流播放，避免歌曲被中斷
                    self.releaseHogMode(for: targetDevice.id)
                }
                
                self.updateSampleRate(targetSampleRate)
                if let currentTrack = currentTrack {
                    self.trackAndSample[currentTrack] = targetSampleRate
                }
                
                // 設定鎖定狀態
                self.lockedTrack = self.currentTrack
                self.lockedSampleRate = targetSampleRate
                // 若已達 88.2 kHz 以上之高解析無損，或是播放已超過 4 秒，立即鎖定防止中途被干擾
                if targetSampleRate >= 88200 || Date().timeIntervalSince(self.trackStartTime) >= 4.0 {
                    self.isSongLocked = true
                    print("[Lock] 成功鎖定歌曲「\(self.currentTrack?.title ?? "")」取樣率至 \(targetSampleRate) Hz")
                }
            }

//            if let nearest = nearest {
//                let nearestSampleRate = nearest.element
//                if nearestSampleRate != previousSampleRate {
//                    defaultDevice?.setNominalSampleRate(nearestSampleRate)
//                    self.updateSampleRate(nearestSampleRate)
//                    if let currentTrack = currentTrack {
//                        self.trackAndSample[currentTrack] = nearestSampleRate
//                    }
//                }
//            }
        }
        else if !recursion {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.switchLatestSampleRate(recursion: true)
            }
        }
        else {
//                print("cache \(self.trackAndSample)")
            if self.currentTrack == self.previousTrack {
                print("same track, ignore cache")
                return
            }
//            if let currentTrack = currentTrack, let cachedSampleRate = trackAndSample[currentTrack] {
//                print("using cached data")
//                if cachedSampleRate != previousSampleRate {
//                    defaultDevice?.setNominalSampleRate(cachedSampleRate)
//                    self.updateSampleRate(cachedSampleRate)
//                }
//            }
        }

    }
    
    func getFormats(bestStat: CMPlayerStats, device: AudioDevice) -> [AudioStreamBasicDescription]? {
        // new sample rate + bit depth detection route
        let streams = device.streams(scope: .output)
        let availableFormats = streams?.first?.availablePhysicalFormats?.compactMap({$0.mFormat})
        return availableFormats
    }
    
    func setFormats(device: AudioDevice?, format: AudioStreamBasicDescription?) {
        guard let device, let format else { return }
        let streams = device.streams(scope: .output)
        if streams?.first?.physicalFormat != format {
            streams?.first?.physicalFormat = format
        }
    }
    
    func updateSampleRate(_ sampleRate: Float64) {
        self.previousSampleRate = sampleRate
        DispatchQueue.main.async {
            let readableSampleRate = sampleRate / 1000
            self.currentSampleRate = readableSampleRate
            
            let delegate = AppDelegate.instance
            delegate?.statusItemTitle = String(format: "%.1f kHz", readableSampleRate)
            
            // 同步更新 macOS Dock 圖示上的即時取樣率標籤 (Dock Tile Badge)
            self.updateDockTile(readableSampleRate: readableSampleRate)
        }
        self.runUserScript(sampleRate)
    }
    
    /// 更新 macOS Dock 圖示上的即時取樣率標籤 (Dock Tile Badge)
    func updateDockTile(readableSampleRate: Float64) {
        let labelText: String
        if readableSampleRate.truncatingRemainder(dividingBy: 1) == 0 {
            labelText = String(format: "%.0f kHz", readableSampleRate)
        } else {
            labelText = String(format: "%.1f kHz", readableSampleRate)
        }
        
        DispatchQueue.main.async {
            NSApp.dockTile.badgeLabel = labelText
            NSApp.dockTile.display()
        }
    }
    
    func runUserScript(_ sampleRate: Float64) {
        guard let scriptPath = Defaults.shared.shellScriptPath else { return }
        let argumentSampleRate = String(Int(sampleRate))
        Task.detached {
            let scriptURL = URL(fileURLWithPath: scriptPath)
            do {
                let task = try NSUserUnixTask(url: scriptURL)
                let arguments = [
                    argumentSampleRate
                ]
                try await task.execute(withArguments: arguments)
            }
            catch {
                print("TASK ERR \(error)")
            }
        }
    }
    
    func trackDidChange(_ newTrack: TrackInfo) {
        let incomingTrack = MediaTrack(trackInfo: newTrack)
        
        // 若為同一首歌曲且取樣率已穩定鎖定，過濾掉歌詞滾動、進度時間軸同步等中途事件
        if self.isSameSong(incomingTrack, self.currentTrack) && self.isSongLocked {
            return
        }
        
        let isGenuinelyNewTrack = !self.isSameSong(incomingTrack, self.currentTrack)
        if isGenuinelyNewTrack {
            print("[Track] 檢測到新歌曲: 「\(incomingTrack.title ?? "未知") - \(incomingTrack.artist ?? "未知")」，解除舊曲鎖定狀態")
            self.resetSongLock()
            self.previousTrack = self.currentTrack
            self.currentTrack = incomingTrack
            self.renewTimer()
        } else {
            self.previousTrack = self.currentTrack
            self.currentTrack = incomingTrack
        }
        
        self.switchLatestSampleRate()
    }
    
    // MARK: - Core Audio Hog Mode (獨佔控制)
    
    /// 將 OSStatus 錯誤碼轉為 4 字元可讀字串（如 'nope', '!obj', 'stop' 等）
    private func fourCharCode(from status: OSStatus) -> String {
        let n = UInt32(bitPattern: status)
        let bytes: [UInt8] = [
            UInt8((n >> 24) & 0xFF),
            UInt8((n >> 16) & 0xFF),
            UInt8((n >> 8) & 0xFF),
            UInt8(n & 0xFF)
        ]
        if bytes.allSatisfy({ $0 >= 32 && $0 <= 126 }) {
            return String(bytes: bytes, encoding: .ascii) ?? "\(status)"
        }
        return "\(status)"
    }
    
    /// 安全取得音訊裝置的獨佔存取權 (Hog Mode)
    @discardableResult
    func acquireHogMode(for device: AudioDevice) -> Bool {
        return acquireHogMode(for: device.id)
    }
    
    /// 安全取得音訊裝置的獨佔存取權 (Hog Mode)
    @discardableResult
    func acquireHogMode(for deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyHogMode,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMaster
        )
        
        // 1. 檢查裝置是否支援 Hog Mode
        guard AudioObjectHasProperty(deviceID, &address) else {
            print("[CoreAudio HogMode] 裝置 ID: \(deviceID) 不支援 kAudioDevicePropertyHogMode 屬性")
            return false
        }
        
        let myPID = getpid()
        
        // 2. 查詢當前 Hog Mode 擁有者
        var currentPID: pid_t = -1
        var dataSize = UInt32(MemoryLayout<pid_t>.size)
        let getStatus = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &currentPID
        )
        
        if getStatus != noErr {
            let codeStr = fourCharCode(from: getStatus)
            print("[CoreAudio HogMode] ❌ 無法讀取裝置 ID: \(deviceID) 的 Hog Mode。錯誤碼: \(getStatus) ('\(codeStr)')")
            return false
        }
        
        // 若當前行程已擁有獨佔權，直接記錄並返回成功
        if currentPID == myPID {
            self.hoggedDeviceID = deviceID
            print("[CoreAudio HogMode] ℹ️ 當前行程 (PID: \(myPID)) 已擁有裝置 ID: \(deviceID) 的獨佔控制權")
            return true
        }
        
        // 若已有其他裝置被本行程鎖定，先釋放舊裝置
        if let previousID = self.hoggedDeviceID, previousID != deviceID {
            self.releaseHogMode(for: previousID)
        }
        
        // 3. 檢查屬性是否可寫入
        var isSettable: DarwinBoolean = false
        let settableStatus = AudioObjectIsPropertySettable(deviceID, &address, &isSettable)
        if settableStatus != noErr || !isSettable.boolValue {
            let codeStr = fourCharCode(from: settableStatus)
            print("[CoreAudio HogMode] ❌ 裝置 ID: \(deviceID) 的 Hog Mode 不可寫入。錯誤碼: \(settableStatus) ('\(codeStr)')")
            return false
        }
        
        // 4. 寫入當前 process pid_t 請求獨佔模式 (使用 kAudioObjectPropertyScopeGlobal 與 kAudioObjectPropertyElementMaster)
        var requestPID = myPID
        let setStatus = AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            dataSize,
            &requestPID
        )
        
        if setStatus != noErr {
            let codeStr = fourCharCode(from: setStatus)
            print("[CoreAudio HogMode] ❌ 取得獨佔模式失敗！裝置 ID: \(deviceID), PID: \(myPID), 錯誤碼: \(setStatus) ('\(codeStr)')")
            return false
        }
        
        // 5. 驗證是否成功取得獨佔控制
        var confirmedPID: pid_t = -1
        let verifyStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &confirmedPID)
        if verifyStatus == noErr && confirmedPID != myPID {
            print("[CoreAudio HogMode] ⚠️ 寫入成功但裝置當前擁有者為 PID: \(confirmedPID)（預期 PID: \(myPID)），可能被其他優先程序搶佔")
            return false
        }
        
        self.hoggedDeviceID = deviceID
        print("[CoreAudio HogMode] ✅ 成功取得裝置 ID: \(deviceID) 的獨佔模式 (PID: \(myPID))")
        return true
    }
    
    /// 釋放音訊裝置的獨佔存取權 (Hog Mode)，將其值寫回 0
    @discardableResult
    func releaseHogMode(for specificDeviceID: AudioObjectID? = nil) -> Bool {
        let targetID = specificDeviceID ?? hoggedDeviceID
        guard let deviceID = targetID else { return true }
        
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyHogMode,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMaster
        )
        
        guard AudioObjectHasProperty(deviceID, &address) else {
            if self.hoggedDeviceID == deviceID {
                self.hoggedDeviceID = nil
            }
            return true
        }
        
        let myPID = getpid()
        var currentPID: pid_t = -1
        var dataSize = UInt32(MemoryLayout<pid_t>.size)
        let getStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &currentPID)
        
        // 若當前獨佔者不是本程序，且也不是已被釋放 (-1) 或 0，則不應越權釋放其他 App 的獨佔
        if getStatus == noErr && currentPID != myPID && currentPID != -1 && currentPID != 0 {
            print("[CoreAudio HogMode] ⚠️ 裝置 ID: \(deviceID) 獨佔者為 PID: \(currentPID)，非本行程 (PID: \(myPID))，略過釋放")
            if self.hoggedDeviceID == deviceID {
                self.hoggedDeviceID = nil
            }
            return false
        }
        
        // 極度重要：將 Hog Mode 的值寫回 0，釋放 DAC 獨佔權，避免硬體被永久鎖死
        var releasePID: pid_t = 0
        let status = AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            dataSize,
            &releasePID
        )
        
        if status != noErr {
            let codeStr = fourCharCode(from: status)
            print("[CoreAudio HogMode] ❌ 釋放獨佔模式失敗！裝置 ID: \(deviceID), 錯誤碼: \(status) ('\(codeStr)')")
            return false
        }
        
        if self.hoggedDeviceID == deviceID {
            self.hoggedDeviceID = nil
        }
        print("[CoreAudio HogMode] 🔓 成功釋放裝置 ID: \(deviceID) 的獨佔模式（值已寫回 0）")
        return true
    }
}
