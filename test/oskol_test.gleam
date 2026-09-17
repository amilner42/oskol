import gleeunit

/// The suite runs across every core (`test/oskol_runner.erl`): gleeunit
/// hands eunit one flat list, which eunit runs on one scheduler, and this
/// suite has minutes of pure work in it. `gleeunit.main` is kept for the
/// JavaScript target, which this project does not build.
pub fn main() -> Nil {
  case run_in_parallel() {
    _ -> gleeunit.main()
  }
}

@external(erlang, "oskol_runner", "run")
fn run_in_parallel() -> Nil
