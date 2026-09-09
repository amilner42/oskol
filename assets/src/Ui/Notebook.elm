module Ui.Notebook exposing
    ( SubmitCta
    , focus
    , nameInput
    , style
    , submitCta
    )

{-| The handful of controls the landing pages share, in the multicade
notebook design system (`assets/css/app.css`): the arcade button and the
name field. Same markup and same class names the LiveView rendered.

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


type alias SubmitCta =
    { id : String
    , color : String
    , label : String
    }


{-| The big arcade call to action, as a form's submit button.
-}
submitCta : SubmitCta -> Html msg
submitCta config =
    Html.button
        [ type_ "submit"
        , id config.id
        , class (ctaClass config.color)
        ]
        [ Html.text config.label ]


ctaClass : String -> String
ctaClass color =
    "btn-arcade pixel text-[11px] sm:text-xs w-full sm:w-auto sm:min-w-[12rem] px-6 py-4 " ++ color


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
        , class "name-field w-full px-4 py-3 text-lg"
        , style "color: var(--ink)"
        , Attr.autocomplete False
        , attribute "autocorrect" "off"
        , attribute "autocapitalize" "words"
        , attribute "spellcheck" "false"
        , attribute "data-1p-ignore" "true"
        , attribute "data-lpignore" "true"
        , onInput config.onInput
        ]
        []
