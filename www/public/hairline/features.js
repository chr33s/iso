/* Mount the six decorative figures; each keeps its static SVG if loading fails. */
(() => {
    "use strict";
    const handles = [];
    window.hairline = ({ name, mount, range }) => {
        const stage = document.querySelector(`[data-hairline="${name}"]`);
        if (!stage) return;
        const fallback = stage.querySelector("svg");
        const svg = HL.mk("svg", { viewBox: "0 0 400 320", "aria-hidden": "true" });
        const read = { textContent: "rest" };
        try {
            const handle = mount({ stage, svg, read }, range[1]);
            stage.replaceChildren(svg);
            handles.push(handle);
        } catch (error) {
            if (fallback) stage.replaceChildren(fallback);
            console.error(`Could not mount the ${name} figure.`, error);
        }
    };
    const names = ["vm", "key", "review", "editor", "network", "audit"];
    const base = new URL(".", document.currentScript.src);
    Promise.allSettled(names.map((name) => import(new URL(`${name}.js`, base))));
    addEventListener("pagehide", (event) => {
        if (!event.persisted) handles.forEach((handle) => handle.destroy());
    });
})();
