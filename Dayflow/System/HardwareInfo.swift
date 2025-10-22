//
//  HardwareInfo.swift
//  Dayflow
//
//  Utility for detecting macOS hardware information
//

import Foundation
import IOKit
import Darwin

class HardwareInfo {
    static let shared = HardwareInfo()
    
    private init() {}
    
    
    var modelName: String {
        getSystemProfilerValue(for: "SPHardwareDataType", key: "machine_model") ?? "Unknown Mac"
    }
    
    var marketingName: String {
        getSystemProfilerValue(for: "SPHardwareDataType", key: "machine_name") ?? modelName
    }
    
    var chipName: String {
        if let chipInfo = getSystemProfilerValue(for: "SPHardwareDataType", key: "chip_type") {
            return chipInfo
        }
        
        // Fallback to processor name for Intel Macs
        if let processorName = getSystemProfilerValue(for: "SPHardwareDataType", key: "cpu_type") {
            return processorName
        }
        
        return "Unknown Chip"
    }
    
    var memorySize: String {
        if let memory = getSystemProfilerValue(for: "SPHardwareDataType", key: "physical_memory") {
            return memory
        }
        
        // Fallback to manual calculation
        let memoryInBytes = ProcessInfo.processInfo.physicalMemory
        let memoryInGB = Double(memoryInBytes) / (1024 * 1024 * 1024)
        return String(format: "%.0f GB", memoryInGB)
    }
    
    var macOSVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let versionString = "\(version.majorVersion).\(version.minorVersion)"
        
        // Add the patch version if it's not 0
        if version.patchVersion > 0 {
            return "\(versionString).\(version.patchVersion)"
        }
        
        return versionString
    }
    
    var macOSVersionName: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        
        switch version.majorVersion {
        case 15:
            return "macOS Sequoia \(macOSVersion)"
        case 14:
            return "macOS Sonoma \(macOSVersion)"
        case 13:
            return "macOS Ventura \(macOSVersion)"
        case 12:
            return "macOS Monterey \(macOSVersion)"
        case 11:
            return "macOS Big Sur \(macOSVersion)"
        case 10:
            if version.minorVersion >= 15 {
                return "macOS Catalina \(macOSVersion)"
            } else {
                return "macOS \(macOSVersion)"
            }
        default:
            return "macOS \(macOSVersion)"
        }
    }
    
    var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        if #available(macOS 11.0, *) {
            var arm64Capable: Int32 = 0
            var size = MemoryLayout<Int32>.size
            if sysctlbyname("hw.optional.arm64", &arm64Capable, &size, nil, 0) == 0, arm64Capable == 1 {
                return true
            }
        }

        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        // common values: "arm64", "x86_64"
        return machine.contains("arm64") || machine.contains("arm")
        #endif
    }
    
    var cpuArchitectureLabel: String {
        isAppleSilicon ? "Apple Silicon" : "Intel"
    }
    
    
    private func getSystemProfilerValue(for dataType: String, key: String) -> String? {
        let task = Process()
        task.launchPath = "/usr/sbin/system_profiler"
        task.arguments = ["-json", dataType]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            
            if let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let items = json[dataType] as? [[String: Any]],
               let firstItem = items.first {
                
                // Handle different key formats
                if let value = firstItem[key] as? String {
                    return value
                }
                
                // Some keys have slightly different names in the JSON
                switch key {
                case "machine_name":
                    return firstItem["machine_name"] as? String
                case "machine_model":
                    return firstItem["machine_model"] as? String
                case "chip_type":
                    // For Apple Silicon Macs
                    if let chipType = firstItem["chip_type"] as? String {
                        return chipType
                    }
                    // Alternative key name
                    return firstItem["platform_cpu_htt"] as? String
                case "cpu_type":
                    // For Intel Macs
                    if let cpuType = firstItem["cpu_type"] as? String {
                        return cpuType
                    }
                    return firstItem["current_processor_speed"] as? String
                case "physical_memory":
                    return firstItem["physical_memory"] as? String
                default:
                    return nil
                }
            }
        } catch {
            print("Error getting system profiler data: \(error)")
        }
        
        return nil
    }
    
    
    func getSystemSummary() -> String {
        var summary = ""
        summary += "Model: \(marketingName)\n"
        summary += "Chip: \(chipName)\n"
        summary += "Memory: \(memorySize)\n"
        summary += "OS: \(macOSVersionName)\n"
        summary += "Architecture: \(cpuArchitectureLabel)"
        return summary
    }
    
    func getSystemInfo() -> [String: String] {
        return [
            "model": marketingName,
            "chip": chipName,
            "memory": memorySize,
            "os": macOSVersionName,
            "architecture": cpuArchitectureLabel
        ]
    }
}