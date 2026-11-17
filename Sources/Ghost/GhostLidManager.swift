import Foundation

// MARK: - Modo tapa cerrada
//
// Al cerrar la tapa (sin monitor externo + corriente), macOS duerme el Mac aunque haya
// aserciones de energía: ninguna API de usuario lo impide. La única vía soportada es
// `pmset -a disablesleep 1`, que exige root.
//
// Para no pedir la contraseña cada vez, Ghost instala UNA vez (con el diálogo de
// administrador de macOS) una regla en /etc/sudoers.d/ghost que solo permite, sin
// contraseña y solo a este usuario, exactamente estos dos comandos:
//
//     /usr/bin/pmset -a disablesleep 1
//     /usr/bin/pmset -a disablesleep 0
//
// Nada más se ejecuta como root. La regla se valida con `visudo -c` antes de instalarla
// y `uninstall.sh` la retira.
//
// Seguridad: si Ghost se cierra con el modo activo, `disablesleep` sobreviviría. Por eso
// Ghost lo desactiva al salir, al terminar la sesión, por batería baja y, al arrancar,
// si una ejecución anterior lo dejó activado (marca en UserDefaults).

enum GhostLidManager {
    static let sudoersPath = "/etc/sudoers.d/ghost"
    private static let pmset = "/usr/bin/pmset"
    private static let sudo = "/usr/bin/sudo"
    private static let leftoverKey = "lidSleepDisabledByGhost"

    /// ¿Está instalada la regla que permite cambiarlo sin contraseña?
    static var isAuthorized: Bool {
        run(sudo, ["-n", "-l", pmset, "-a", "disablesleep", "1"]) == 0
    }

    /// Estado real del sistema según `pmset -g` ("SleepDisabled 1").
    static var isSleepDisabled: Bool {
        let output = capture(pmset, ["-g"])
        for line in output.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count >= 2, parts[0] == "SleepDisabled" { return parts[1] == "1" }
        }
        return false
    }

    /// Activa o desactiva `disablesleep`. Devuelve true si el sistema quedó como se pidió.
    @discardableResult
    static func setSleepDisabled(_ disabled: Bool) -> Bool {
        let ok = run(sudo, ["-n", pmset, "-a", "disablesleep", disabled ? "1" : "0"]) == 0
        if ok { UserDefaults.standard.set(disabled, forKey: leftoverKey) }
        return ok
    }

    /// Al arrancar: si una ejecución anterior de Ghost dejó la tapa desbloqueada, la restaura.
    static func restoreIfLeftOver() {
        guard UserDefaults.standard.bool(forKey: leftoverKey) else { return }
        if setSleepDisabled(false) {
            NSLog("Ghost: restaurado el reposo con tapa cerrada que quedó activo de una ejecución anterior")
        } else {
            NSLog("Ghost: no se pudo restaurar disablesleep 0 (¿se quitó la regla de sudoers?)")
        }
    }

    /// Muestra el diálogo de administrador de macOS e instala la regla de sudoers.
    /// Bloquea hasta que el usuario responde: llámalo fuera del hilo principal.
    static func authorize() -> Result<Void, AuthorizationError> {
        let user = NSUserName()
        guard !user.isEmpty, user.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }) else {
            return .failure(.message("Nombre de usuario no compatible: \(user)"))
        }
        // Sin comillas dobles ni barras invertidas: el script viaja como argumento a osascript.
        let rule = "\(user) ALL=(root) NOPASSWD: \(pmset) -a disablesleep 0, \(pmset) -a disablesleep 1"
        let script = [
            "set -e",
            "umask 077",
            "tmp=$(/usr/bin/mktemp /private/tmp/ghost-sudoers.XXXXXX)",
            "echo '# Ghost (github.com/MagdaIG/ghost): Modo tapa cerrada sin contraseña. Lo quita uninstall.sh.' > $tmp",
            "echo '\(rule)' >> $tmp",
            "/usr/sbin/visudo -cf $tmp > /dev/null",
            "/usr/sbin/chown root:wheel $tmp",
            "/bin/chmod 0440 $tmp",
            "/bin/mkdir -p /private/etc/sudoers.d",
            "/bin/mv -f $tmp /private\(sudoersPath)"
        ].joined(separator: "; ")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e", "on run argv",
            "-e", "do shell script (item 1 of argv) with prompt \"Ghost necesita permiso una sola vez para mantener el Mac despierto con la tapa cerrada.\" with administrator privileges",
            "-e", "end run",
            script
        ]
        let errorPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        do {
            try process.run()
        } catch {
            return .failure(.message(error.localizedDescription))
        }
        process.waitUntilExit()
        if process.terminationStatus == 0, isAuthorized { return .success(()) }

        let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if stderr.contains("-128") { return .failure(.cancelled) }
        return .failure(.message(stderr.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    enum AuthorizationError: Error {
        case cancelled
        case message(String)
    }

    // MARK: Procesos

    @discardableResult
    private static func run(_ path: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static func capture(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
