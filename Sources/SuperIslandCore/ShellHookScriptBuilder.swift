import Foundation

public enum ShellHookScriptBuilder {
    public static func sourceBlock(scriptPath: String) -> String {
        "\n# SuperIsland shell integration\nsource \"\(scriptPath)\"\n"
    }

    public static func zshScript(port: UInt16) -> String {
        let start =
            sq("{\"event\":\"start\",\"tty\":\"") + dq("$__drop_tty") + sq("\",\"cmd\":\"")
            + dq("$__drop_cmd") + sq("\"}")
        let done =
            sq("{\"event\":\"done\",\"tty\":\"") + dq("$__drop_tty") + sq("\",\"cmd\":\"")
            + dq("$__drop_cmd") + sq("\",\"exit_code\":") + dq("$code") + sq(",\"duration\":")
            + dq("$dur") + sq("}")
        let reg = sq("{\"event\":\"register\",\"tty\":\"") + dq("$__drop_tty") + sq("\"}")

        let lines: [String] = [
            "#!/usr/bin/env zsh",
            "# SuperIsland shell integration — do not edit manually.",
            "# To uninstall: SuperIsland -> Settings -> Integrations -> Uninstall",
            "",
            "__drop_tty=$(tty 2>/dev/null)",
            "__drop_cmd=\"\"",
            "__drop_start=0",
            "__drop_port=\(port)",
            "",
            "__drop_post() {",
            "    curl -sf -m 1 -X POST \"http://localhost:$__drop_port/shell\" \\",
            "        -H \"Content-Type: application/json\" \\",
            "        -d \"$1\" &>/dev/null &!",
            "}",
            "",
            "__drop_preexec() {",
            "    # Full command line, JSON-safe: strip quotes/backslashes/newlines.",
            "    local c=\"${1//$'\\n'/ }\"",
            "    c=\"${c//$'\\r'/ }\"",
            "    c=\"${c//\\\\/}\"",
            "    c=\"${c//\\\"/}\"",
            "    __drop_cmd=\"${c[1,120]}\"",
            "    __drop_start=$SECONDS",
            "    __drop_post \(start)",
            "}",
            "",
            "__drop_precmd() {",
            "    local code=$?",
            "    [[ -z \"$__drop_cmd\" ]] && return",
            "    local dur=$(( SECONDS - __drop_start ))",
            "    __drop_post \(done)",
            "    __drop_cmd=\"\"",
            "}",
            "",
            "autoload -Uz add-zsh-hook",
            "add-zsh-hook preexec __drop_preexec",
            "add-zsh-hook precmd  __drop_precmd",
            "",
            "__drop_post \(reg)",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    public static func bashScript(port: UInt16) -> String {
        let start =
            sq("{\"event\":\"start\",\"tty\":\"") + dq("$__drop_tty") + sq("\",\"cmd\":\"")
            + dq("$__drop_cmd") + sq("\"}")
        let done =
            sq("{\"event\":\"done\",\"tty\":\"") + dq("$__drop_tty") + sq("\",\"cmd\":\"")
            + dq("$__drop_cmd") + sq("\",\"exit_code\":") + dq("$code") + sq(",\"duration\":")
            + dq("$dur") + sq("}")
        let reg = sq("{\"event\":\"register\",\"tty\":\"") + dq("$__drop_tty") + sq("\"}")

        let lines: [String] = [
            "#!/usr/bin/env bash",
            "# SuperIsland shell integration — do not edit manually.",
            "# To uninstall: SuperIsland -> Settings -> Integrations -> Uninstall",
            "",
            "[[ -n \"$__SUPERISLAND_BASH_INSTALLED\" ]] && return",
            "__SUPERISLAND_BASH_INSTALLED=1",
            "__drop_tty=$(tty 2>/dev/null)",
            "__drop_cmd=\"\"",
            "__drop_start=0",
            "__drop_port=\(port)",
            "",
            "__drop_post() {",
            "    curl -sf -m 1 -X POST \"http://localhost:$__drop_port/shell\" \\",
            "        -H \"Content-Type: application/json\" \\",
            "        -d \"$1\" &>/dev/null &",
            "}",
            "",
            "__drop_preexec() {",
            "    local first=\"${BASH_COMMAND%% *}\"",
            "    case \"$first\" in __drop_*|trap|local|PROMPT_COMMAND*) return ;; esac",
            "    # Full command line, JSON-safe: strip quotes/backslashes/newlines.",
            "    local c=\"${BASH_COMMAND//[$'\\n'$'\\r']/ }\"",
            "    c=\"${c//\\\\/}\"",
            "    c=\"${c//\\\"/}\"",
            "    c=\"${c:0:120}\"",
            "    [[ \"$c\" == \"$__drop_cmd\" ]] && return",
            "    __drop_cmd=\"$c\"",
            "    __drop_start=$SECONDS",
            "    __drop_post \(start)",
            "}",
            "",
            "__drop_precmd() {",
            "    local code=$?",
            "    [[ -z \"$__drop_cmd\" ]] && return",
            "    local dur=$(( SECONDS - __drop_start ))",
            "    __drop_post \(done)",
            "    __drop_cmd=\"\"",
            "}",
            "",
            "trap '__drop_preexec' DEBUG",
            "PROMPT_COMMAND=\"__drop_precmd${PROMPT_COMMAND:+;$PROMPT_COMMAND}\"",
            "",
            "__drop_post \(reg)",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    private static func sq(_ s: String) -> String { "'\(s)'" }
    private static func dq(_ s: String) -> String { "\"\(s)\"" }
}
