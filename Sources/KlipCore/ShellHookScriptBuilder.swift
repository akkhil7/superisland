import Foundation

public enum ShellHookScriptBuilder {
    public static func sourceBlock(scriptPath: String) -> String {
        "\n# Klip shell integration\nsource \"\(scriptPath)\"\n"
    }

    public static func zshScript(port: UInt16) -> String {
        let start = sq("{\"event\":\"start\",\"tty\":\"") + dq("$__klip_tty") + sq("\",\"cmd\":\"") + dq("$__klip_cmd") + sq("\"}")
        let done = sq("{\"event\":\"done\",\"tty\":\"") + dq("$__klip_tty") + sq("\",\"cmd\":\"") + dq("$__klip_cmd") + sq("\",\"exit_code\":") + dq("$code") + sq(",\"duration\":") + dq("$dur") + sq("}")
        let reg = sq("{\"event\":\"register\",\"tty\":\"") + dq("$__klip_tty") + sq("\"}")

        let lines: [String] = [
            "#!/usr/bin/env zsh",
            "# Klip shell integration — do not edit manually.",
            "# To uninstall: Klip -> Settings -> Integrations -> Uninstall",
            "",
            "__klip_tty=$(tty 2>/dev/null)",
            "__klip_cmd=\"\"",
            "__klip_start=0",
            "__klip_port=\(port)",
            "",
            "__klip_post() {",
            "    curl -sf -m 1 -X POST \"http://localhost:$__klip_port/shell\" \\",
            "        -H \"Content-Type: application/json\" \\",
            "        -d \"$1\" &>/dev/null &!",
            "}",
            "",
            "__klip_preexec() {",
            "    # Full command line, JSON-safe: strip quotes/backslashes/newlines.",
            "    local c=\"${1//$'\\n'/ }\"",
            "    c=\"${c//$'\\r'/ }\"",
            "    c=\"${c//\\\\/}\"",
            "    c=\"${c//\\\"/}\"",
            "    __klip_cmd=\"${c[1,120]}\"",
            "    __klip_start=$SECONDS",
            "    __klip_post \(start)",
            "}",
            "",
            "__klip_precmd() {",
            "    local code=$?",
            "    [[ -z \"$__klip_cmd\" ]] && return",
            "    local dur=$(( SECONDS - __klip_start ))",
            "    __klip_post \(done)",
            "    __klip_cmd=\"\"",
            "}",
            "",
            "autoload -Uz add-zsh-hook",
            "add-zsh-hook preexec __klip_preexec",
            "add-zsh-hook precmd  __klip_precmd",
            "",
            "__klip_post \(reg)",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    public static func bashScript(port: UInt16) -> String {
        let start = sq("{\"event\":\"start\",\"tty\":\"") + dq("$__klip_tty") + sq("\",\"cmd\":\"") + dq("$__klip_cmd") + sq("\"}")
        let done = sq("{\"event\":\"done\",\"tty\":\"") + dq("$__klip_tty") + sq("\",\"cmd\":\"") + dq("$__klip_cmd") + sq("\",\"exit_code\":") + dq("$code") + sq(",\"duration\":") + dq("$dur") + sq("}")
        let reg = sq("{\"event\":\"register\",\"tty\":\"") + dq("$__klip_tty") + sq("\"}")

        let lines: [String] = [
            "#!/usr/bin/env bash",
            "# Klip shell integration — do not edit manually.",
            "# To uninstall: Klip -> Settings -> Integrations -> Uninstall",
            "",
            "[[ -n \"$__KLIP_BASH_INSTALLED\" ]] && return",
            "__KLIP_BASH_INSTALLED=1",
            "__klip_tty=$(tty 2>/dev/null)",
            "__klip_cmd=\"\"",
            "__klip_start=0",
            "__klip_port=\(port)",
            "",
            "__klip_post() {",
            "    curl -sf -m 1 -X POST \"http://localhost:$__klip_port/shell\" \\",
            "        -H \"Content-Type: application/json\" \\",
            "        -d \"$1\" &>/dev/null &",
            "}",
            "",
            "__klip_preexec() {",
            "    local first=\"${BASH_COMMAND%% *}\"",
            "    case \"$first\" in __klip_*|trap|local|PROMPT_COMMAND*) return ;; esac",
            "    # Full command line, JSON-safe: strip quotes/backslashes/newlines.",
            "    local c=\"${BASH_COMMAND//[$'\\n'$'\\r']/ }\"",
            "    c=\"${c//\\\\/}\"",
            "    c=\"${c//\\\"/}\"",
            "    c=\"${c:0:120}\"",
            "    [[ \"$c\" == \"$__klip_cmd\" ]] && return",
            "    __klip_cmd=\"$c\"",
            "    __klip_start=$SECONDS",
            "    __klip_post \(start)",
            "}",
            "",
            "__klip_precmd() {",
            "    local code=$?",
            "    [[ -z \"$__klip_cmd\" ]] && return",
            "    local dur=$(( SECONDS - __klip_start ))",
            "    __klip_post \(done)",
            "    __klip_cmd=\"\"",
            "}",
            "",
            "trap '__klip_preexec' DEBUG",
            "PROMPT_COMMAND=\"__klip_precmd${PROMPT_COMMAND:+;$PROMPT_COMMAND}\"",
            "",
            "__klip_post \(reg)",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    private static func sq(_ s: String) -> String { "'\(s)'" }
    private static func dq(_ s: String) -> String { "\"\(s)\"" }
}
