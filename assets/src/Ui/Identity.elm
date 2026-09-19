module Ui.Identity exposing (badge)

{-| Beside a name, wherever one is shown: whether it is a guest or an
account. A guest is the outline of a person, quiet; an account is the filled
check badge, the mark people already read as "this one is real". The page
knows only yes or no, never which account.
-}

import Html exposing (Html)
import Html.Attributes exposing (attribute, class, title)


badge : Bool -> Html msg
badge account =
    if account then
        Html.span [ class "identity-icon is-account", attribute "data-identity" "account", title "Signed in" ]
            [ glyph "hero-check-badge-solid" ]

    else
        Html.span [ class "identity-icon is-guest", attribute "data-identity" "guest", title "Playing as a guest" ]
            [ glyph "hero-user" ]


glyph : String -> Html msg
glyph name =
    Html.span [ class (name ++ " w-4 h-4 sm:w-[18px] sm:h-[18px] shrink-0"), attribute "aria-hidden" "true" ] []
