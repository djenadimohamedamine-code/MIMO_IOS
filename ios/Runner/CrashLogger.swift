import Foundation
import UIKit

// ─────────────────────────────────────────────────────────
// MIMO_NDI CrashLogger - Mode "Plateau Pro"
// Enregistre les crashes dans un fichier log lisible
// Affiche un popup au prochain démarrage avec le log
// ─────────────────────────────────────────────────────────

class CrashLogger {
    
    static let logFileURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("mimo_ndi_crash.log")
    }()
    
    // ── Installation des handlers ──
    static func install() {
        // 1. Capture les exceptions Swift / ObjC non gérées
        NSSetUncaughtExceptionHandler { exception in
            let log = """
            ╔══════════════════════════════════════╗
            ║     MIMO_NDI CRASH REPORT            ║
            ╚══════════════════════════════════════╝
            Date    : \(Date())
            Name    : \(exception.name.rawValue)
            Reason  : \(exception.reason ?? "Unknown")
            Stack   :
            \(exception.callStackSymbols.joined(separator: "\n"))
            """
            CrashLogger.write(log)
        }
        
        // 2. Capture les signaux système (SIGSEGV, SIGABRT, etc.)
        let signals: [Int32] = [SIGSEGV, SIGABRT, SIGILL, SIGFPE, SIGBUS, SIGTRAP]
        signals.forEach { sig in
            signal(sig) { signalCode in
                let names: [Int32: String] = [
                    SIGSEGV: "SIGSEGV (Segfault/Mémoire)",
                    SIGABRT: "SIGABRT (Abandon/Assertion)",
                    SIGILL:  "SIGILL (Instruction illégale)",
                    SIGFPE:  "SIGFPE (Division par zéro)",
                    SIGBUS:  "SIGBUS (Bus error)",
                    SIGTRAP: "SIGTRAP (Trap)"
                ]
                let log = """
                ╔══════════════════════════════════════╗
                ║     MIMO_NDI SIGNAL CRASH            ║
                ╚══════════════════════════════════════╝
                Date   : \(Date())
                Signal : \(names[signalCode] ?? "Signal \(signalCode)")
                """
                CrashLogger.write(log)
                // Rétablir le handler par défaut et re-déclencher
                signal(signalCode, SIG_DFL)
                raise(signalCode)
            }
        }
        print("✅ CrashLogger installé - Logs: \(logFileURL.path)")
    }
    
    // ── Écriture dans le fichier log ──
    static func write(_ message: String) {
        let fullMessage = message + "\n\n"
        if let data = fullMessage.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFileURL.path) {
                if let handle = try? FileHandle(forWritingTo: logFileURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: logFileURL)
            }
        }
    }
    
    // ── Log manuel d'un événement ──
    static func log(_ message: String) {
        let line = "[\(Date())] \(message)"
        print(line)
        write(line)
    }
    
    // ── Lire le dernier rapport de crash ──
    static func readLastCrash() -> String? {
        guard FileManager.default.fileExists(atPath: logFileURL.path),
              let content = try? String(contentsOf: logFileURL, encoding: .utf8),
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return content
    }
    
    // ── Effacer les logs ──
    static func clear() {
        try? FileManager.default.removeItem(at: logFileURL)
    }
    
    // ── Afficher popup au démarrage si crash précédent ──
    static func showLastCrashIfNeeded(in viewController: UIViewController) {
        guard let crash = readLastCrash() else { return }
        
        let alert = UIAlertController(
            title: "⚠️ Rapport de Crash MIMO_NDI",
            message: String(crash.prefix(800)), // 800 chars max pour lisibilité
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Copier", style: .default) { _ in
            UIPasteboard.general.string = crash
        })
        alert.addAction(UIAlertAction(title: "Effacer", style: .destructive) { _ in
            CrashLogger.clear()
        })
        alert.addAction(UIAlertAction(title: "Ignorer", style: .cancel))
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            viewController.present(alert, animated: true)
        }
    }
}
