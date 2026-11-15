func traps(_ raw: String, _ value: Any) {
  // ruleid: iso.unexplained-trap
  let a = try! OperationID("h-" + raw)
  // ruleid: iso.unexplained-trap
  let b = try! JSONOutput.render(value, pretty: false)
  // ruleid: iso.unexplained-trap
  let c = value as! String
  // ruleid: iso.unexplained-trap
  let d = try! VmMemory(MiB(4096)!)
  // ok: iso.unexplained-trap
  let e = try! GuestUser("ubuntu")
  // ok: iso.unexplained-trap
  let f = try! TimeoutSecs(10)
  // A canonical UUID is lowercase hex and dashes, which OperationID accepts.
  let g = try! OperationID("h-" + raw)
  // ok: iso.unexplained-trap
  let h = try? OperationID(raw)
}
