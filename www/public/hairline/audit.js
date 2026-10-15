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
        plate(-50,-39,50,39,0,8,5);
        plate(-46,-36,47,36,8,7,4);
        // A cover opening around its bound edge, rather than floating away.
        const angle = 0.16 + a[1] * reach / 55;
        const cover = (u,v,z) => P(-45+(u+45)*Math.cos(angle),v,17+z+(u+45)*Math.sin(angle));
        plate(-48,-39,50,39,0,3,5,true,cover);
        for (let j=0;j<4;j++)
            stroke(seg(cover(-22,-19+j*12,3),cover(31-(j%2)*10,-19+j*12,3)));
        for (let j=0;j<4;j++) {
            const y=-25+j*17;
            const loop=rrect(-55,9,-39,25,7,10).map(q=>P(q.u,y,q.v));
            stroke(poly(loop),"nf");
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
        read.textContent = index < 0 ? "rest" : "audit ledger";
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
    name: "audit",
    means: "A bound audit ledger: point across its pages to lift the cover while its records remain in the book.",
    rules: [1, 2, 4, 5, 7, 8, 9, 10],
    range: [8, 18, 28],
    tour: [[170, 155], [230, 120], [260, 190], null],
    mount,
});
