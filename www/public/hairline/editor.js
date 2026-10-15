// Original isolate feature artwork, drawn with Hairline's unmodified kernel.
const {
    Cam, fit, proj, facing, rings, rrect, ringAt, prism, solid, put, mk,
    poly, open, seg, fillet, clamp, tween, tset, tval, tdone,
    pointer, register, disposer,
} = HL;

function mount({ stage, svg, read }, value) {
    const bag = disposer();
    const C = Cam(45, 0.5, 1.85);
    fit(C, [
        [-65, -48, 0], [65, -48, 0], [-65, 48, 0], [65, 48, 0],
        [-65, -48, 110], [65, -48, 110], [-65, 48, 110], [65, 48, 110],
    ], 200, 166);
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
        const z = 12 + a[1] * reach * 0.4;
        plate(-59, -37, 59, 43, 0, 5, 6);
        // Screen is a solid in a vertical plane; its lower edge sits behind the keys.
        const screen = (u, v, d) => P(u, -29 + d, v);
        plate(-55, z, 55, z+76, 0, 4, 5, true, screen);
        const face = (u,v) => screen(u,v,4);
        stroke(poly(rrect(-47,z+8,47,z+68,3,6).map(q=>face(q.u,q.v))), "nf lo");
        stroke(seg(face(-29,z+14),face(-29,z+61)));
        for (let j = 0; j < 4; j++)
            stroke(seg(face(-18,z+54-j*10),face(30-j%2*12,z+54-j*10)), j===1 ? "nf" : "nf lo");
        plate(-43, -15, 43, 15, 5, 1, 3);
        for (let j=0;j<3;j++) stroke(seg(P(-35,-8+j*8,6),P(35,-8+j*8,6)));
        stroke(poly(ringAt(P,rrect(-17,23,17,35,3,6),5)),"nf lo");
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
        read.textContent = index < 0 ? "rest" : "workspace";
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
    name: "editor",
    means: "A laptop with its screen above the keyboard: point at a pane to raise the remote workspace.",
    rules: [1, 2, 4, 5, 7, 8, 9, 10],
    range: [8, 18, 28],
    tour: [[170, 155], [230, 120], [260, 190], null],
    mount,
});
