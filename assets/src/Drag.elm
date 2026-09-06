module Drag exposing
    ( Active, End(..), State, Zone
    , idle, press, move, release, setZones
    , active, hover
    , sourceAttrs
    )

{-| A press-drag-drop state machine for board pieces, game-agnostic.

A game view that wants its pieces dragged keeps a `State` in its model,
routes the messages produced by `sourceAttrs` through `press`, `move` and
`release`, and derives everything it renders (ghost, lifted origin,
highlighted destinations) from `active` and `hover`. The machine never
decides legality: the view hands `press` a piece's origin and what a plain
tap there would have done, tells it (via `setZones`) where that origin's
legal destinations sit on screen, and `release` answers with an `End`.

The gesture grammar: a press that never travels past a small threshold is
a tap (`End` carries the stored tap message, so tap handling stays whatever
it already was); past the threshold it is a drag, and release either hits a
zone (`Drop origin loc`) or is a no-op snap-back. Zones and pointer
positions are both in viewport (client) coordinates.

Events are Pointer Events (via `mpizenberg/elm-pointer-events`), which
unify mouse and touch. Two things live outside Elm, keyed on the
`data-drag-capture` attribute that `sourceAttrs` sets: app.js calls
`setPointerCapture` on pointerdown so move/up keep arriving at the source
element wherever the pointer goes, and app.css sets `touch-action: none`
so a touch drag never scrolls the page.

-}

import Html
import Html.Attributes
import Html.Events
import Html.Events.Extra.Pointer as Pointer
import Json.Decode as D



-- STATE


{-| Idle, pressed (may still become a tap), or dragging. One record serves
both live phases; the constructors are not exported, so every transition
goes through the functions below.
-}
type State item msg
    = Idle
    | Pressed (Gesture item msg)
    | Dragging (Gesture item msg)


type alias Gesture item msg =
    { origin : String
    , item : item
    , tap : Maybe msg
    , startX : Float
    , startY : Float
    , x : Float
    , y : Float
    , zones : List Zone
    }


{-| A legal drop target on screen, in viewport coordinates.
-}
type alias Zone =
    { loc : String
    , left : Float
    , top : Float
    , width : Float
    , height : Float
    }


{-| What a release amounted to: nothing (snap back), the stored tap, or a
drop (`Drop origin destination`) for the view to stage as a move.
-}
type End msg
    = None
    | Tap msg
    | Drop String String


{-| The visible facts of a drag in progress, for the ghost and the lifted
origin. A press under the threshold shows nothing yet.
-}
type alias Active item =
    { origin : String
    , item : item
    , x : Float
    , y : Float
    }


{-| Movement past this many pixels turns a press into a drag.
-}
threshold : Float
threshold =
    8



-- TRANSITIONS


idle : State item msg
idle =
    Idle


press : { origin : String, item : item, tap : Maybe msg, x : Float, y : Float } -> State item msg
press p =
    Pressed
        { origin = p.origin
        , item = p.item
        , tap = p.tap
        , startX = p.x
        , startY = p.y
        , x = p.x
        , y = p.y
        , zones = []
        }


move : { x : Float, y : Float } -> State item msg -> State item msg
move pos state =
    case state of
        Idle ->
            Idle

        Pressed g ->
            let
                ( dx, dy ) =
                    ( pos.x - g.startX, pos.y - g.startY )

                moved =
                    { g | x = pos.x, y = pos.y }
            in
            if dx * dx + dy * dy > threshold * threshold then
                Dragging moved

            else
                Pressed moved

        Dragging g ->
            Dragging { g | x = pos.x, y = pos.y }


release : { x : Float, y : Float } -> State item msg -> ( State item msg, End msg )
release pos state =
    case state of
        Idle ->
            ( Idle, None )

        Pressed g ->
            ( Idle, g.tap |> Maybe.map Tap |> Maybe.withDefault None )

        Dragging g ->
            ( Idle
            , case zoneAt g.zones pos.x pos.y of
                Just loc ->
                    Drop g.origin loc

                Nothing ->
                    None
            )


{-| The drop zones for the pressed origin, measured by the caller (they
arrive a beat after the press, from `Browser.Dom`).
-}
setZones : List Zone -> State item msg -> State item msg
setZones zones state =
    case state of
        Idle ->
            Idle

        Pressed g ->
            Pressed { g | zones = zones }

        Dragging g ->
            Dragging { g | zones = zones }



-- QUERIES


active : State item msg -> Maybe (Active item)
active state =
    case state of
        Dragging g ->
            Just { origin = g.origin, item = g.item, x = g.x, y = g.y }

        _ ->
            Nothing


{-| The legal zone the drag currently hovers, if any.
-}
hover : State item msg -> Maybe String
hover state =
    case state of
        Dragging g ->
            zoneAt g.zones g.x g.y

        _ ->
            Nothing


zoneAt : List Zone -> Float -> Float -> Maybe String
zoneAt zones x y =
    zones
        |> List.filter (\z -> x >= z.left && x <= z.left + z.width && y >= z.top && y <= z.top + z.height)
        |> List.head
        |> Maybe.map .loc



-- VIEW


{-| The attributes that make an element a drag source. Only the primary
pointer drags (a second finger maps to `ignore`). The click browsers
synthesise after pointerup is swallowed, so a drop or a pointer-handled tap
never also fires the click handler of whatever it bubbles to.
-}
sourceAttrs :
    { press : { x : Float, y : Float } -> msg
    , move : { x : Float, y : Float } -> msg
    , release : { x : Float, y : Float } -> msg
    , cancel : msg
    , ignore : msg
    }
    -> List (Html.Attribute msg)
sourceAttrs handlers =
    let
        primary toMsg event =
            if event.isPrimary then
                toMsg { x = Tuple.first event.pointer.clientPos, y = Tuple.second event.pointer.clientPos }

            else
                handlers.ignore
    in
    [ Html.Attributes.attribute "data-drag-capture" ""
    , Pointer.onDown (primary handlers.press)
    , Pointer.onMove (primary handlers.move)
    , Pointer.onUp (primary handlers.release)
    , Pointer.onCancel (\_ -> handlers.cancel)
    , Html.Events.custom "click" (D.succeed { message = handlers.ignore, stopPropagation = True, preventDefault = True })
    ]
