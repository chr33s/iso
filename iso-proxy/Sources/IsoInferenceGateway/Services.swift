import IsoInferenceCore
import Synchronization

/// What request handling needs from the scheduler. The in-process
/// ``Scheduler`` serves it in the broker and in tests; a session worker's
/// handler reaches the broker's scheduler over its link (§5.1).
package protocol AdmissionService: Sendable {
  func permit(session: String) throws(InferenceError) -> Scheduler.Permit
  func admit(_ work: Scheduler.Work, permit: Scheduler.Permit) throws(InferenceError)
    -> Scheduler.Admission
  @discardableResult func withdraw(_ ticket: Scheduler.Ticket) -> Bool
  func finish(_ ticket: Scheduler.Ticket, outputTokens: Int?)
  func markUncertain(_ ticket: Scheduler.Ticket)
  func quarantine(_ backend: BackendID, _ reason: Scheduler.QuarantineReason)
}

extension Scheduler: AdmissionService {}

/// The audit log's writer: the broker's file, or a worker's link to it.
package protocol AuditService: Sendable {
  func record(_ event: String, _ fields: KeyValuePairs<String, JSON>)
  func rejected(session: String, code: InferenceErrorCode)
}

extension AuditLog: AuditService {}

/// Outstanding work per backend, so a crash quarantines it. A worker's
/// broker records it when it grants and settles a ticket.
package protocol JournalService: Sendable {
  func dispatched(_ backend: BackendID) throws
  func settled(_ backend: BackendID)
}

extension Journal: JournalService {}

/// Everything a session's request handlers and listener use: the in-process
/// ``Gateway`` or a ``SessionWorker``.
package protocol RequestServices: AnyObject, Sendable {
  var admission: any AdmissionService { get }
  var journalService: any JournalService { get }
  var auditService: any AuditService { get }
  var buffers: ByteBudget { get }
  var sharedConnections: SlotPool { get }
  var normalizers: NormalizerPool { get }
  var timing: GatewayTiming { get }
  /// Accounting for tests and status only: a handler started (+1) or ended (-1).
  func handlerCount(_ delta: Int)
  func backendPolicy(_ id: BackendID) -> BackendPolicy?
}
