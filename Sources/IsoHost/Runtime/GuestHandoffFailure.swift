/// A readiness refusal is not a guest command failure. Best-effort hooks must
/// propagate it rather than warning and reporting a successful startup.
struct GuestHandoffFailure: Error, CustomStringConvertible {
  let cause: any Error
  var description: String { String(describing: cause) }
}
