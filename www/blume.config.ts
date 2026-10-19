// Blume documentation site for iso. Pages come from ../README.md and ../docs/
// through scripts/sync-docs.js; edit those files, not content/.
import { defineConfig } from "blume";
import { references } from "./scripts/reference-pages.js";

const design = [
    "apple-sandbox-runtime",
    "apple-sandbox-transactions",
    "apple-sandbox-experiment",
    "local-and-remote-hosts-spec",
    "embedded-secrets-spec",
    "selective-hardening-spec",
    "iso-policy",
    "issue-411-injecting-proxy",
    "proxy-jail-graceful-degradation",
    "sandboxy-inspired-features-spec",
    "editor-providers-spec",
    "editor-hardening",
    "macos-guest-computer-use",
    "macos-computer-use-qualification-plan",
    "macos-computer-use-q0-spike",
    "macos-vz-context-experiment",
    "macos-vz-context-headless-experiment-spec",
    "linux-computer-use-sketch",
].map((slug) => `/design/${slug}`);

export default defineConfig({
    basePath: "/docs",
    title: "isolate",
    logo: "/icon.svg",
    description:
        "Run Claude Code and Codex in disposable Linux VMs on macOS 27+ Apple Silicon, with the VM as the isolation boundary.",
    content: { root: "content", pages: "pages" },
    github: { owner: "chr33s", repo: "iso" },
    theme: {
        accent: { light: "#c23f29", dark: "#ff987a" },
        mode: "system",
    },
    navigation: {
        tabs: [
            { label: "Docs", path: "/" },
            { label: "Contributing", path: "/contributing" },
            { label: "Design records", path: "/design" },
        ],
        sidebar: {
            display: "group",
            items: [
                "/",
                {
                    label: "Get started",
                    collapsed: false,
                    items: ["/getting-started", "/installation"],
                },
                {
                    label: "Guides",
                    items: [
                        "/claude-integration",
                        "/codex-integration",
                        "/images-and-profiles",
                        "/workspaces",
                        "/multi-instance",
                        "/remote-hosts",
                        "/devcontainer",
                        "/editor",
                        "/backends",
                        "/shell-completion",
                    ],
                },
                {
                    label: "Security",
                    items: ["/trust-model", "/credential-proxy", "/policy"],
                },
                {
                    label: "Reference",
                    items: [
                        ...references.map((reference) => ({
                            label:
                                reference.route === "commands"
                                    ? "Commands"
                                    : "Configuration",
                            root: `/${reference.route}`,
                            items: [
                                `/${reference.route}`,
                                ...reference.topics.map(
                                    (topic) =>
                                        `/${reference.route}/${topic.slug}`,
                                ),
                            ],
                        })),
                        "/machine-interface",
                    ],
                },
                {
                    label: "Contributing",
                    root: "/contributing",
                    items: [
                        "/contributing",
                        "/contributing/architecture",
                        "/contributing/code-style",
                        "/contributing/testing",
                        "/contributing/platform-notes",
                        "/contributing/release-validation",
                        "/contributing/map",
                    ],
                },
                {
                    label: "Design records",
                    root: "/design",
                    items: ["/design", ...design],
                },
            ],
        },
    },
});
