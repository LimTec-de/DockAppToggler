import AppKit

extension NSApplication {
    static func restart(skipUpdateCheck: Bool = true) {
        guard let executablePath = Bundle.main.executablePath else {
            Logger.error("Failed to get executable path for restart")
            return
        }
        
        // Clean up resources before restart
        Logger.info("Preparing for in-place restart...")
        
        // Prepare arguments
        var args = [executablePath]
        if skipUpdateCheck {
            args.append("--s")
        }
        
        // Convert arguments to C-style
        let cArgs = args.map { strdup($0) } + [nil]
        
        // Execute the new process image
        Logger.info("Executing in-place restart...")
        execv(executablePath, cArgs)
        
        // If we get here, exec failed
        Logger.error("Failed to restart application: \(String(cString: strerror(errno)))")
        
        // Clean up if exec failed
        for ptr in cArgs where ptr != nil {
            free(ptr)
        }
    }
} 