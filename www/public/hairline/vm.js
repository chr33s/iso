// Original isolate feature artwork, drawn with Hairline's unmodified kernel.
const {
    Cam, fit, proj, facing, rings, rrect, ringAt, prism, solid, put, mk,
    poly, open, seg, fillet, clamp, tween, tset, tval, tdone,
    pointer, register, disposer,
} = HL;

function mount({ stage, svg, read }, value) {
    const bag = disposer();
    const C = Cam(45, 0.5, 1.85);
    fit(C, [[-65, -48, 0], [65, 48, 0], [-65, 48, 0], [65, -48, 95]], 200, 166);
    const P = proj(C), front = facing(C);
    const group = mk("g", {}, svg), nodes = [];
    let cursor = 0, reach = value, active = -1, previous = "";
    const motion = [tween(0), tween(0), tween(0)];
    // Reuse nodes in the same back-to-front order; settled drawings do no work.
    function plate(x0, y0, x1, y1, z, h, r = 4, hi = false, project = P) {
        const node = nodes[cursor] || (nodes[cursor] = solid(group));
        cursor++;
        const [ring, inner] = rings(x0, y0, x1, y1, r, 1);
        put(node, prism(project, front, ring, inner, z, z + h));
        node.sil.classList.toggle("hi", hi);
    }
    function stroke(d, cls = "nf lo") {
        const node = nodes[cursor] || (nodes[cursor] = mk("path", {}, group));
        cursor++;
        node.setAttribute("d", d);
        node.setAttribute("class", cls);
    }
    function draw(a) {
        cursor = 0;
        plate(-58, -40, 58, 40, 0, 15, 7);
        for (let i = 0; i < 3; i++) {
            const z = 20 + i * 15 + Math.max(...a.slice(0, i + 1)) * reach;
            plate(-49 + i * 3, -33, 49 + i * 3, 33, z, 5, 5, active < 0 ? i === 2 : i === active);
            for (let j = 0; j < 4; j++)
                stroke(seg(P(-28 + j * 16, -17, z + 5), P(-28 + j * 16, 14, z + 5)));
        }
    }
    const loop = register(stage, (_dt, now) => {
        const a = motion.map((item) => tval(item, now));
        const key = a.join(",") + ":" + active + ":" + reach;
        if (key !== previous) { draw(a); previous = key; }
        return motion.some((item) => !tdone(item, now));
    });
    bag.add(loop.unregister);
    function select(index) {
        if (index === active) return;
        const origin = index < 0 ? active : index;
        active = index;
        motion.forEach((item, i) => tset(item, index < 0 ? 0 : i === index ? 1 : 0.22,
            performance.now(), Math.abs(i - origin) * 40));
        read.textContent = index < 0 ? "rest" : "layer " + (index + 1);
        loop.wake();
    }
    bag.add(pointer(stage, {
        move: ([x, y]) => select(x < 45 || x > 355 || y < 40 || y > 290 ? -1 : clamp(Math.floor((x - 100) / 70), 0, 2)),
        leave: () => select(-1),
    }));
    bag.add(() => svg.replaceChildren());
    draw([0, 0, 0]);
    return { set: (v) => { reach = v; loop.wake(); }, destroy: bag.dispose };
}

hairline({
    name: "vm",
    means: "A vented VM enclosure: point across the lid to lift its compute layers inside the chassis.",
    rules: [1, 2, 4, 5, 7, 8, 9, 10],
    range: [8, 18, 28],
    tour: [[170, 155], [230, 120], [260, 190], null],
    mount,
});
