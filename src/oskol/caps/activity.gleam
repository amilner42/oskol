//// Was this player here today? One reading, for the streak the home
//// prints beside the two ratings. Built for real in
//// lib/oskol/gleam/caps/activity.ex -- that file and this one must agree
//// on constructor tag and field order.
////
//// A streak is the long-term hook, so what counts has to be the whole of
//// what a player does here, not one corner of it: a puzzle answered **or**
//// a game of theirs that finished. Two sources, one list of days, so the
//// number can never disagree with itself.
////
//// Which day a moment falls on is the **player's** local day, as the deck
//// reckons it (`retain` holds their timezone; a player who has never
//// practised is read on the site's default). Nothing here decides how the
//// days are counted into a streak -- that is the handler's, in Gleam.

pub type ActivityCaps {
  ActivityCaps(
    /// Which of the last `n` local days this account was active on --
    /// oldest first, ending today, exactly as `practice.days` is ordered.
    ///
    /// Active is a puzzle answered (the deck's own rule: an attempt counts,
    /// putting a card off does not, and a correction sits on the day of the
    /// answer it corrects) or a game of theirs that finished that day.
    ///
    /// The window is what bounds the read: a streak is counted back from
    /// today until the first day off, so the answer never has to be every
    /// day this account has ever had.
    days: fn(String, Int) -> List(Bool),
  )
}

pub fn stub() -> ActivityCaps {
  ActivityCaps(days: fn(_, _) { panic as "stub activity.days" })
}
