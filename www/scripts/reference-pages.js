// Section IDs refer to headings in the canonical repository references.
// The same topic list drives publication and navigation.
// SPDX-License-Identifier: Apache-2.0

export const references = [
    {
        source: "docs/commands.md",
        route: "commands",
        level: 3,
        topics: [
            {
                slug: "instances",
                title: "Instance lifecycle",
                summary:
                    "Create, start, inspect, stop, and destroy project VMs.",
                sections: [
                    "up",
                    "start",
                    "stop",
                    "destroy",
                    "list",
                    "status",
                    "logs",
                ],
            },
            {
                slug: "sessions",
                title: "Shells and agent sessions",
                summary:
                    "Run commands, coding agents, and disposable sessions.",
                sections: [
                    "shell",
                    "claude",
                    "claude-agents",
                    "codex",
                    "exec",
                    "run",
                    "run-cleanup",
                    "model",
                ],
            },
            {
                slug: "agents",
                title: "Agent definitions",
                summary: "Inspect and manage reusable agent definitions.",
                sections: [
                    "agent-list",
                    "agent-inspect",
                    "agent-add",
                    "agent-update",
                ],
            },
            {
                slug: "images",
                title: "Images and resources",
                summary:
                    "Build templates, manage profiles, resize disks, and save or restore images.",
                sections: [
                    "setup",
                    "images",
                    "resize",
                    "commit",
                    "restore",
                    "profiles",
                ],
            },
            {
                slug: "workspaces",
                title: "Workspace and editor commands",
                summary:
                    "Transfer files, review guest changes, and connect editors.",
                sections: [
                    "push",
                    "pull",
                    "diff",
                    "code--zed",
                    "editor",
                    "ssh-config",
                ],
            },
            {
                slug: "devcontainers",
                title: "Devcontainer commands",
                summary:
                    "Inspect discovery, validate configuration, and manage skip markers.",
                sections: [
                    "devcontainer-check",
                    "devcontainer-ignore",
                    "devcontainer-status",
                    "devcontainer-clear",
                ],
            },
            {
                slug: "hosts",
                title: "Execution host commands",
                summary:
                    "Enroll trusted Macs and manage their VMs and access grants.",
                sections: ["host"],
            },
            {
                slug: "security",
                title: "Credentials, policy, and audit",
                summary:
                    "Manage GitHub access, the credential proxy, local secrets, and policy.",
                sections: [
                    "github",
                    "proxy",
                    "secrets",
                    "policy-show",
                    "audit",
                ],
            },
            {
                slug: "maintenance",
                title: "CLI maintenance",
                summary:
                    "Update, uninstall, generate completions, and inspect capabilities or configuration.",
                sections: [
                    "update",
                    "uninstall",
                    "completions",
                    "capabilities",
                    "validate",
                ],
            },
        ],
    },
    {
        source: "docs/configuration.md",
        route: "configuration",
        level: 2,
        topics: [
            {
                slug: "github",
                title: "GitHub authentication",
                summary:
                    "Choose a token strategy and configure repository-scoped PATs.",
                sections: ["github-auth"],
            },
            {
                slug: "vm",
                title: "VM and runtime settings",
                summary:
                    "Configure CPU, memory, disks, the guest user, and Apple runtime timeouts.",
                sections: [
                    "vm-section",
                    "guest-user",
                    "guest-path",
                    "apple_container-section",
                ],
            },
            {
                slug: "agents",
                title: "Agent and profile settings",
                summary:
                    "Configure Claude Code, Codex, local models, MCP servers, and image profiles.",
                sections: [
                    "claude-section",
                    "codex-section",
                    "local-model-routing",
                    "profiles-section",
                ],
            },
            {
                slug: "security",
                title: "Proxy, network, and limits",
                summary:
                    "Configure credential isolation, egress rules, security presets, and session budgets.",
                sections: [
                    "proxy-section",
                    "egress",
                    "network",
                    "security-presets",
                    "limits",
                ],
            },
            {
                slug: "workspaces",
                title: "Workspace and editor settings",
                summary:
                    "Configure guest variables, port forwarding, editor security, and file returns.",
                sections: [
                    "guest_env-section",
                    "forward_ports-field",
                    "editor",
                    "workspace-section",
                ],
            },
            {
                slug: "execution",
                title: "Execution and update settings",
                summary:
                    "Select execution hosts and configure release updates.",
                sections: ["execution-section", "updates-section"],
            },
            {
                slug: "examples",
                title: "Configuration examples",
                summary:
                    "Start from a minimal configuration or a full annotated example.",
                sections: ["examples"],
            },
        ],
    },
];
