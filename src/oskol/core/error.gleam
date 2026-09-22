//// The error a handler may return. Every JSON endpoint answers with the
//// same envelope, so the code and the HTTP status are decided here, in
//// Gleam, and Elixir only writes bytes onto the socket.

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
  /// Nothing to change: the thing named is not in a state this request can
  /// move it out of.
  Conflict(message: String)
  /// The platform could not do it. Same class as an unhandled crash before
  /// the port: a 500 with nothing useful to say.
  Internal(message: String)
}

pub fn code(error: ApiError) -> String {
  case error {
    NotFound(_) -> "not_found"
    Invalid(code, _) -> code
    Forbidden(_) -> "forbidden"
    Conflict(_) -> "conflict"
    Internal(_) -> "server_error"
  }
}

pub fn message(error: ApiError) -> String {
  case error {
    NotFound(message) -> message
    Invalid(_, message) -> message
    Forbidden(message) -> message
    Conflict(message) -> message
    Internal(message) -> message
  }
}

pub fn status(error: ApiError) -> Int {
  case error {
    NotFound(_) -> 404
    Invalid(_, _) -> 422
    Forbidden(_) -> 403
    Conflict(_) -> 409
    Internal(_) -> 500
  }
}

/// The refusal a validating handler returns.
pub fn validation_failed(message: String) -> ApiError {
  Invalid("validation_failed", message)
}
