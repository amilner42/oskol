module Ui.Identity exposing (Who(..), badge)

{-| Beside a name, wherever one is shown: whether it is a guest, an account,
or the bot. A guest is the outline of a person, quiet; an account is the
filled check badge, the mark people already read as "this one is real"; the
bot is a chip, because it is not a person at all. The page knows only which
of the three, never which account.
-}

import Html exposing (Html)
import Html.Attributes exposing (attribute, class, title)


{-| Who is behind a name.
-}
type Who
    = Guest
    | Account
    | Bot


badge : Who -> Html msg
badge who =
    case who of
        Account ->
            mark "is-account" "account" "Signed in" "hero-check-badge-solid"

        Bot ->
            mark "is-bot" "bot" "Bot" "hero-cpu-chip"

        Guest ->
            mark "is-guest" "guest" "Playing as a guest" "hero-user"


mark : String -> String -> String -> String -> Html msg
mark variant identity label icon =
    Html.span
        [ class ("identity-icon " ++ variant)
        , attribute "data-identity" identity
        , title label
        ]
        [ glyph icon ]


glyph : String -> Html msg
glyph name =
    Html.span [ class (name ++ " w-4 h-4 sm:w-[18px] sm:h-[18px] shrink-0"), attribute "aria-hidden" "true" ] []
