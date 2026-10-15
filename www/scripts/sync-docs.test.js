// Publication contract checks: links survive topic splits and examples stay literal.
// SPDX-License-Identifier: Apache-2.0
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
    copyFileSync,
    mkdirSync,
    mkdtempSync,
    readFileSync,
    readdirSync,
    rmSync,
    symlinkSync,
    writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const site = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const repo = resolve(site, "..");

function fixture(t) {
    const root = mkdtempSync(join(tmpdir(), "iso-docs-"));
    t.after(() => rmSync(root, { recursive: true, force: true }));
    for (const directory of ["docs", "docs/design", "www/scripts"]) {
        mkdirSync(join(root, directory), { recursive: true });
        for (const name of readdirSync(join(repo, directory))) {
            if (
                name.endsWith(".md") ||
                ["sync-docs.js", "reference-pages.js"].includes(name)
            ) {
                copyFileSync(
                    join(repo, directory, name),
                    join(root, directory, name),
                );
            }
        }
    }
    for (const name of ["README.md", "CONTRIBUTING.md"])
        copyFileSync(join(repo, name), join(root, name));
    copyFileSync(join(site, "package.json"), join(root, "www/package.json"));
    symlinkSync(
        join(site, "node_modules"),
        join(root, "www/node_modules"),
        "dir",
    );
    return {
        read: (path) => readFileSync(join(root, path), "utf8"),
        write: (path, text) => writeFileSync(join(root, path), text),
        sync: () =>
            spawnSync(
                process.execPath,
                [join(root, "www/scripts/sync-docs.js")],
                { encoding: "utf8" },
            ),
    };
}

test("section links follow their topic from guides, overview pages, and other topics", (t) => {
    const f = fixture(t);
    f.write(
        "docs/routing.md",
        "# Routing\n\n[Pull](commands.md#pull), [egress](configuration.md#egress), [architecture](ARCHITECTURE.md).\n",
    );
    f.write(
        "docs/commands.md",
        f
            .read("docs/commands.md")
            .replace(
                "### `pull`\n",
                "### `pull`\n\n[Secrets](#secrets), [same topic](#push), [defaults](#global-flags).\n",
            ),
    );
    const result = f.sync();
    assert.equal(result.status, 0, result.stderr);
    const guide = f.read("www/content/routing.md");
    assert.match(guide, /\[Pull\]\(\.\/commands\/workspaces\.md#pull\)/);
    assert.match(guide, /\[egress\]\(\.\/configuration\/security\.md#egress\)/);
    assert.match(
        guide,
        /\[architecture\]\(\.\/contributing\/architecture\.md\)/,
    );
    const topic = f.read("www/content/commands/workspaces.md");
    assert.match(topic, /\[Secrets\]\(\.\/security\.md#secrets\)/);
    assert.match(topic, /\[same topic\]\(#push\)/);
    assert.match(topic, /\[defaults\]\(\.\.\/commands\.md#global-flags\)/);
    assert.match(
        f.read("www/content/commands.md"),
        /\(\.\/commands\/instances\.md#up\)/,
    );
});

test("code examples are neither split into pages nor retargeted", (t) => {
    const f = fixture(t);
    const example =
        "```markdown\n### `imaginary`\n[Literal](configuration.md#egress)\n```";
    f.write(
        "docs/commands.md",
        f
            .read("docs/commands.md")
            .replace("### `up`\n", `### \`up\`\n\n${example}\n`),
    );
    const result = f.sync();
    assert.equal(result.status, 0, result.stderr);
    assert.ok(f.read("www/content/commands/instances.md").includes(example));
});

test("formatted introductions remain once in the body with separate SEO metadata", (t) => {
    const f = fixture(t);
    const intro = "An **intro** with a [guide](getting-started.md).";
    f.write("docs/intro.md", `# Introduction\n\n${intro}\n`);
    const result = f.sync();
    assert.equal(result.status, 0, result.stderr);
    const output = f.read("www/content/intro.md");
    assert.match(output, /^seo:\n  description:/m);
    assert.doesNotMatch(output, /^description:/m);
    assert.equal(output.split("An **intro**").length - 1, 1);
    assert.match(output, /\[guide\]\(\.\/getting-started\.md\)/);
});

test("unassigned command or configuration sections fail before replacing published content", (t) => {
    const f = fixture(t);
    const initial = f.sync();
    assert.equal(initial.status, 0, initial.stderr);
    const previous = f.read("www/content/commands/instances.md");
    for (const [path, heading] of [
        ["docs/commands.md", "### `new-command`"],
        ["docs/configuration.md", "## New setting"],
    ]) {
        const source = f.read(path);
        f.write(path, `${source}\n${heading}\n\nNew reference content.\n`);
        const result = f.sync();
        assert.notEqual(result.status, 0);
        assert.match(result.stderr, /Assign new reference section/);
        assert.equal(f.read("www/content/commands/instances.md"), previous);
        f.write(path, source);
    }
});
