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
        plate(-62, -32, 62, 32, 0, 7, 7);
        stroke(poly(ringAt(P, rrect(-40, -12, 40, 12, 8, 8), 7)), "nf lo");
        const z = 25 + a[1] * reach;
        const shape = fillet([[-55,-18],[-42,-28],[-22,-28],[-10,-16],[-10,-6],[56,-6],
            [56,13],[43,13],[43,6],[32,6],[32,14],[19,14],[19,6],[-10,6],[-10,16],[-22,28],[-42,28],[-55,18]],
            [5,5,5,5,2,3,3,2,2,2,2,2,2,2,5,5,5,5]);
        const top = shape.map(([x,y]) => P(x,y,z+4));
        stroke(poly(shape.map(([x,y]) => P(x,y,z))), "sil");
        stroke(poly(top), "sil hi");
        stroke(poly(ringAt(P, rrect(-45,-14,-21,14,11,12), z+4)), "lo");
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
        read.textContent = index < 0 ? "rest" : "host key";
        loop.wake();
    }
    bag.add(pointer(stage, {
        move: ([x, y]) => select(x < 45 || x > 355 || y < 40 || y > 290 ? -1 : 1),
        leave: () => select(-1),
    }));
    bag.add(() => svg.replaceChildren());
    draw([0, 0, 0]);
    return { set: (v) => { reach = v; loop.wake(); }, destroy: bag.dispose };
}

hairline({
    name: "key",
    means: "A cut key over its host-side keeper: point at the key to lift it clear of its resting slot.",
    rules: [1, 2, 4, 5, 7, 8, 9, 10],
    range: [8, 18, 28],
    tour: [[170, 155], [230, 120], [260, 190], null],
    mount,
});
