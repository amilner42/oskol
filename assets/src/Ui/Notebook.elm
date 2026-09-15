module Ui.Notebook exposing
    ( SubmitCta
    , eyebrow
    , focus
    , nameInput
    , style
    , submitCta
    )

{-| The handful of controls the landing pages share, in the quiet notebook
system (`assets/css/app.css`): the section eyebrow, the name field and the
call to action.

The eyebrow is the one place besides the wordmark where the pixel font is
still allowed: small, uppercase, in pencil, naming the row beneath it.

`style` is `Html.Attributes.attribute "style"` rather than
`Html.Attributes.style`: these pages set CSS custom properties (`--accent`),
and Elm's `style` assigns through `node.style[key]`, which silently drops
anything that is not a known property.

-}

import Browser.Dom
import Html exposing (Html)
import Html.Attributes as Attr exposing (attribute, class, id, type_)
import Html.Events exposing (onInput)
import Task


style : String -> Html.Attribute msg
style =
    attribute "style"


{-| Move focus to a node once it is in the DOM, the way the LiveView's
`phx-mounted={JS.focus()}` did. A node that is not there is not an error.
-}
focus : msg -> String -> Cmd msg
focus noOp nodeId =
    Task.attempt (\_ -> noOp) (Browser.Dom.focus nodeId)


{-| The small pixel label above a row of the form, or over a section.
-}
eyebrow : String -> Html msg
eyebrow label =
    Html.div [ class "pixel q-eyebrow text-[9px] mb-2" ] [ Html.text label ]


type alias SubmitCta =
    { id : String
    , label : String
    }


{-| A form's submit button: ink, one hairline, a 3px shadow.
-}
submitCta : SubmitCta -> Html msg
submitCta config =
    Html.button
        [ type_ "submit"
        , id config.id
        , class "q-btn w-full sm:w-auto sm:min-w-[12rem] px-7 py-3.5 text-base"
        ]
        [ Html.text config.label ]


{-| The display-name field. Bounded at 24 characters, and told in every way
available not to be autofilled: a display name is not an account.
-}
nameInput :
    { id : String
    , placeholder : String
    , value : String
    , onInput : String -> msg
    }
    -> Html msg
nameInput config =
    Html.input
        [ type_ "text"
        , id config.id
        , Attr.name "player_name"
        , Attr.value config.value
        , Attr.placeholder config.placeholder
        , Attr.maxlength 24
        , class "q-field w-full px-4 py-3 text-base"
        , Attr.autocomplete False
        , attribute "autocorrect" "off"
        , attribute "autocapitalize" "words"
        , attribute "spellcheck" "false"
        , attribute "data-1p-ignore" "true"
        , attribute "data-lpignore" "true"
        , onInput config.onInput
        ]
        []
