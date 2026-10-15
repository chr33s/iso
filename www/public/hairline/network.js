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
        plate(-61, -44, 61, 44, 0, 5, 6);
        for (let i=0;i<3;i++) {
            const x = -30+i*30;
            stroke(seg(P(x,-36,5),P(x,36,5)));
        }
        plate(-58,-12,-47,6,5,75,3);
        plate(47,-12,58,6,5,75,3);
        const lift = Math.max(...a) * reach * 0.6;
        const gate = (u,v,d) => P(u,-3+d,v+lift);
        plate(-46,13,46,62,0,3,4,true,gate);
        for(let i=0;i<5;i++) stroke(seg(gate(-32+i*16,19,3),gate(-32+i*16,55,3)));
        plate(-60,-15,60,9,80,8,4);
        for(let i=0;i<3;i++) {
            const x=-30+i*30, y=22-a[i]*38;
            plate(x-6,y-6,x+6,y+6,6,8,5);
            // Put a bead behind the gate once it has crossed the resting plane.
            if (y < -3) group.insertBefore(nodes[cursor-1].g, nodes[4].g);
            else group.append(nodes[cursor-1].g);
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
        read.textContent = index < 0 ? "rest" : "lane " + (index + 1);
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
    name: "network",
    means: "A portcullis over three lanes: point to lift the gate while its passing bead stays on its track.",
    rules: [1, 2, 4, 5, 7, 8, 9, 10],
    range: [8, 18, 28],
    tour: [[170, 155], [230, 120], [260, 190], null],
    mount,
});
