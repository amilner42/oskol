//// The error a handler may return. Every JSON endpoint answers with the
//// same envelope, so the code and the HTTP status are decided here, in
//// Gleam, and Elixir only writes bytes onto the socket.

import gleam/option.{type Option, None, Some}

pub type ApiError {
  /// Nothing answers to this slug or code.
  NotFound(message: String)
  /// The request was understood and refused. `code` is the machine-readable
  /// reason; `message` is the sentence a player reads.
  Invalid(code: String, message: String)
  /// It is there and it is not yours. Only ever answered where the caller
  /// already holds the name of the thing -- their own idempotency key for
  /// somebody else's attempt -- so saying so tells them nothing new.
  Forbidden(message: String)
  /// The request was understood and there is nothing to do it to: a puzzle
  /// that is not in rotation to be put off, an answer with nothing to
  /// amend. Not the caller's mistake and not ours -- the state moved.
  Conflict(code: String, message: String)
  /// The platform could not do it. Same class as an unhandled crash before
  /// the port: a 500 with nothing useful to say.
  Internal(message: String)
  /// Not now: a budget is spent or a line is full (429). `retry_after_s`
  /// is how long until asking again could work, which the page says.
  Limited(code: String, message: String, retry_after_s: Int)
  /// Something this depends on is not answering (503), for about
  /// `retry_after_s`.
  Unavailable(code: String, message: String, retry_after_s: Int)
}

pub fn code(error: ApiError) -> String {
  case error {
    NotFound(_) -> "not_found"
    Invalid(code, _) -> code
    Forbidden(_) -> "forbidden"
    Conflict(code, _) -> code
    Internal(_) -> "server_error"
    Limited(code, _, _) -> code
    Unavailable(code, _, _) -> code
  }
}

pub fn message(error: ApiError) -> String {
  case error {
    NotFound(message) -> message
    Invalid(_, message) -> message
    Forbidden(message) -> message
    Conflict(_, message) -> message
    Internal(message) -> message
    Limited(_, message, _) -> message
    Unavailable(_, message, _) -> message
  }
}

pub fn status(error: ApiError) -> Int {
  case error {
    NotFound(_) -> 404
    Invalid(_, _) -> 422
    Forbidden(_) -> 403
    Conflict(_, _) -> 409
    Internal(_) -> 500
    Limited(_, _, _) -> 429
    Unavailable(_, _, _) -> 503
  }
}

/// How long until the same request could work, where the error says.
pub fn retry_after_s(error: ApiError) -> Option(Int) {
  case error {
    Limited(_, _, seconds) | Unavailable(_, _, seconds) -> Some(seconds)
    _ -> None
  }
}

/// The refusal a validating handler returns.
pub fn validation_failed(message: String) -> ApiError {
  Invalid("validation_failed", message)
}
