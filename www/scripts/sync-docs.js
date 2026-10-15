// Copies the repository's Markdown docs into www/content/ for Blume.
//
// docs/ stays the system of record and keeps rendering on GitHub, so this
// script adapts each page instead of the docs being rewritten for the site:
//   - the first `# Heading` becomes frontmatter `title` (Blume renders it),
//     and the first paragraph supplies SEO metadata without a second intro;
//   - README.md becomes the home page (titled "Overview"), docs/index.md
//     becomes /contributing/map, and routes are lowercase;
//   - a relative link to a synced page stays relative; a link to any other
//     repository file becomes a GitHub URL, since the site does not serve it.
//
// SPDX-License-Identifier: Apache-2.0

import {
    existsSync,
    mkdirSync,
    readFileSync,
    readdirSync,
    rmSync,
    statSync,
    writeFileSync,
} from "node:fs";
import { dirname, join, posix, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import GithubSlugger from "github-slugger";
import { references } from "./reference-pages.js";

const SITE = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const REPO = resolve(SITE, "..");
const OUT = join(SITE, "content");
const GITHUB = "https://github.com/chr33s/iso";
const BRANCH = "main";

// Repository path → content path. Only these pages are published; design
// records keep their evidence trees (JSON, prototypes) on GitHub.
const PAGES = new Map([
    ["README.md", "index.md"],
    ["CONTRIBUTING.md", "contributing/index.md"],
    ["docs/index.md", "contributing/map.md"],
    ...[
        "ARCHITECTURE",
        "code-style",
        "testing",
        "platform-notes",
        "release-validation",
    ].map((name) => [
        `docs/${name}.md`,
        `contributing/${name.toLowerCase()}.md`,
    ]),
]);
for (const dir of ["docs", "docs/design"]) {
    for (const name of readdirMarkdown(join(REPO, dir))) {
        const from = `${dir}/${name}`;
        if (!PAGES.has(from))
            PAGES.set(from, from.slice("docs/".length).toLowerCase());
    }
}

// Resolve anchors before rendering any page, including links from a fragment
// to a section moved into a different topic. All prose stays in docs/.
const ANCHORS = new Map();
const documents = [];
for (const [from, to] of PAGES) {
    const source = readFileSync(join(REPO, from), "utf8");
    const reference = references.find((entry) => entry.source === from);
    documents.push(
        ...(reference
            ? splitReference(source, from, to, reference)
            : [{ from, to, source }]),
    );
}

rmSync(OUT, { recursive: true, force: true });
for (const { from, to, source } of documents) {
    const page = adapt(source, from, to);
    const target = join(OUT, to);
    mkdirSync(dirname(target), { recursive: true });
    writeFileSync(target, page);
}
console.error(
    `sync-docs: wrote ${documents.length} pages to ${relative(REPO, OUT)}/`,
);

function readdirMarkdown(dir) {
    return readdirSync(dir)
        .filter((name) => name.endsWith(".md"))
        .sort();
}

// Retain source line positions so code examples containing Markdown headings
// cannot become section boundaries or be changed by heading promotion.
function headings(lines) {
    const slugger = new GithubSlugger();
    const result = [];
    let comment = false;
    let fence = null;
    for (let i = 0; i < lines.length; i++) {
        const line = lines[i];
        if (comment) {
            if (line.includes("-->")) comment = false;
            continue;
        }
        if (/^\s*<!--/.test(line)) {
            if (!line.includes("-->")) comment = true;
            continue;
        }
        const marker = line.match(/^\s*(`{3,}|~{3,})/);
        if (marker) {
            if (fence === null) fence = marker[1];
            else if (
                marker[1][0] === fence[0] &&
                marker[1].length >= fence.length
            )
                fence = null;
            continue;
        }
        if (fence !== null) continue;
        const match = line.match(/^(#{1,6})\s+(.+?)\s*#*\s*$/);
        if (match) {
            result.push({
                line: i,
                level: match[1].length,
                title: match[2],
                slug: slugger.slug(plain(match[2])),
            });
        }
    }
    return result;
}

function splitReference(source, from, to, reference) {
    const lines = source.split("\n");
    const allHeadings = headings(lines);
    const boundaries = allHeadings.filter(
        (heading) => heading.level === reference.level,
    );
    const sections = boundaries.map((heading, index) => ({
        ...heading,
        end: boundaries[index + 1]?.line ?? lines.length,
    }));
    const assigned = new Map();
    const topics = reference.topics.map((topic) => {
        const path = `${reference.route}/${topic.slug}.md`;
        const bodies = topic.sections.map((id) => {
            const section = sections.find((entry) => entry.slug === id);
            if (!section || assigned.has(id))
                throw new Error(`Invalid or duplicate section ${from}#${id}`);
            assigned.set(id, path);
            return lines
                .slice(section.line, section.end)
                .map((line, offset) => {
                    const heading = allHeadings.find(
                        (entry) => entry.line === section.line + offset,
                    );
                    if (heading) {
                        ANCHORS.set(`${from}#${heading.slug}`, path);
                        // Commands are H3 under a shared H2 in the repository reference.
                        if (reference.level === 3) return line.slice(1);
                    }
                    return line;
                })
                .join("\n")
                .trim();
        });
        return {
            from,
            to: path,
            source: `# ${topic.title}\n\n${topic.summary}\n\n${bodies.join("\n\n")}\n`,
        };
    });
    const overview =
        reference.level === 2
            ? new Set(["top-level-fields", "cli-overrides"])
            : new Set();
    for (const section of sections) {
        if (!assigned.has(section.slug) && !overview.has(section.slug)) {
            throw new Error(
                `Assign new reference section ${from}#${section.slug} to a topic`,
            );
        }
    }
    const removed = sections.filter((section) => assigned.has(section.slug));
    const kept = lines.filter(
        (line, index) =>
            !removed.some(
                (section) => index >= section.line && index < section.end,
            ) && !(reference.level === 3 && line === "## Commands"),
    );
    const links = reference.topics.map(
        (topic) =>
            `- [${topic.title}](#${topic.sections[0]}): ${topic.summary}`,
    );
    return [
        {
            from,
            to,
            source: `${kept.join("\n").trim()}\n\n## Topics\n\n${links.join("\n")}\n`,
        },
        ...topics,
    ];
}

function adapt(source, from, to) {
    const lines = source.replace(/\r\n/g, "\n").split("\n");
    const heading = headings(lines).find((entry) => entry.level === 1);
    if (heading) lines.splice(heading.line, 1);

    const body = rewriteLinks(lines.join("\n"), from, to);
    const description = firstParagraph(body.split("\n"));
    const front = [
        "---",
        `title: ${yamlString(from === "README.md" ? "Overview" : plain(heading?.title ?? from))}`,
    ];
    // The source intro keeps its formatting and links; SEO summaries do not
    // render above it, unlike Blume's top-level description field.
    if (description)
        front.push("seo:", `  description: ${yamlString(description)}`);
    if (from.startsWith("docs/design/") && to !== "design/index.md") {
        front.push("search:", "  boost: 0.5", "ai:", "  exclude: true");
    }
    front.push("---", "");
    return `${front.join("\n")}${body.replace(/^\n+/, "\n")}`;
}

function firstParagraph(lines) {
    let inComment = false;
    let inFence = false;
    const paragraph = [];
    for (const line of lines) {
        if (inComment) {
            if (line.includes("-->")) inComment = false;
            continue;
        }
        if (/^\s*<!--/.test(line)) {
            if (!line.includes("-->")) inComment = true;
            continue;
        }
        if (/^\s*(`{3,}|~{3,})/.test(line)) {
            if (paragraph.length) break;
            inFence = !inFence;
            continue;
        }
        if (inFence) continue;
        if (line.trim() === "") {
            if (paragraph.length) break;
            continue;
        }
        // Headings, lists, tables, quotes and HTML are not a summary sentence.
        if (/^\s*(#|[-*+]\s|\d+\.\s|\||>|<)/.test(line)) {
            if (paragraph.length) break;
            continue;
        }
        paragraph.push(line.trim());
    }
    const text = plain(paragraph.join(" "));
    if (text.length <= 200) return text;
    const cut = text.slice(0, 200);
    const sentence = cut.lastIndexOf(". ");
    return sentence > 80
        ? cut.slice(0, sentence + 1)
        : `${cut.replace(/\s+\S*$/, "")}…`;
}

function plain(markdown) {
    return markdown
        .replace(/!\[([^\]]*)\]\([^)]*\)/g, "$1")
        .replace(/\[([^\]]*)\]\([^)]*\)/g, "$1")
        .replace(/\[([^\]]*)\]\[[^\]]*\]/g, "$1")
        .replace(/[*`]/g, "")
        .replace(/\s+/g, " ")
        .trim();
}

function yamlString(value) {
    return JSON.stringify(value);
}

// Rewrites relative link targets outside fenced code blocks.
function rewriteLinks(markdown, from, to) {
    let inFence = null;
    return markdown
        .split("\n")
        .map((line) => {
            const fence = line.match(/^\s*(`{3,}|~{3,})/);
            if (fence) {
                inFence =
                    inFence === null
                        ? fence[1][0]
                        : inFence === fence[1][0]
                          ? null
                          : inFence;
                return line;
            }
            if (inFence !== null) return line;
            return line
                .replace(
                    /(\]\()(<?)([^)\s>]+)(>?)((?:\s+"[^"]*")?\))/g,
                    (_, open, lt, target, gt, close) =>
                        `${open}${lt}${retarget(target, from, to)}${gt}${close}`,
                )
                .replace(
                    /^(\s*\[[^\]]+\]:\s+)(\S+)/,
                    (_, def, target) => `${def}${retarget(target, from, to)}`,
                );
        })
        .join("\n");
}

function retarget(target, from, to) {
    if (/^([a-z][a-z0-9+.-]*:|\/)/i.test(target)) return target;
    const hashAt = target.indexOf("#");
    const path = hashAt >= 0 ? target.slice(0, hashAt) : target;
    const hash = hashAt >= 0 ? target.slice(hashAt) : "";
    const repoPath =
        path === ""
            ? from
            : posix
                  .normalize(posix.join(posix.dirname(from), decodeURI(path)))
                  .replace(/\/$/, "");
    if (repoPath.startsWith("..")) return target;

    const page = ANCHORS.get(`${repoPath}${hash}`) ?? PAGES.get(repoPath);
    if (page) {
        if (path === "" && page === to) return target;
        const here = posix.dirname(to);
        let link = posix.relative(here, page);
        if (!link.startsWith(".")) link = `./${link}`;
        return `${link}${hash}`;
    }

    const absolute = join(REPO, repoPath);
    if (!existsSync(absolute)) return target;
    const kind = statSync(absolute).isDirectory() ? "tree" : "blob";
    return `${GITHUB}/${kind}/${BRANCH}/${encodeURI(repoPath)}${hash}`;
}
